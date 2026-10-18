const std = @import("std");
const protocol = @import("boot_protocol");
const pci = @import("pci");
const platform = @import("x86_64.zig");
const transport = @import("../mt7922_transport.zig");
const mt = @import("../mediatek/root.zig");
const FakeMemory = struct {
    pub const heap_api = struct {
        pub const Ticket = struct { generation: u64 };
    };
    var live = false;
    var generation: u64 = 1;
    const range: protocol.PhysicalRange = .{ .base = 0x400000, .length = transport.allocation_size };
    pub fn allocateKernel(_: usize, _: usize) !heap_api.Ticket {
        live = true;
        return .{ .generation = generation };
    }
    pub fn resolveKernel(ticket: heap_api.Ticket) !struct { range: protocol.PhysicalRange } {
        if (!live or ticket.generation != generation) return error.StaleAllocation;
        return .{ .range = range };
    }
    pub fn freeKernel(ticket: heap_api.Ticket) !void {
        _ = try resolveKernel(ticket);
        live = false;
        generation += 1;
    }
};
const Provider = platform.Owned(FakeMemory);
const Port = transport.Owned(FakeMemory);
const device: pci.Device = .{ .bdf = .{ .bus = 1, .device = 0, .function = 0 }, .vendor = 0x14c3, .product = 0x0616, .class = 2, .subclass = 0x80, .programming_interface = 0, .revision = 1, .header = 0 };
const options: platform.Options = .{ .opt_in = true, .coherent_identity_dma = true, .iommu_disabled = true, .exclusive_takeover = true, .identity = .{ .vendor = 0x14c3, .product = 0x0616, .subsystem_vendor = 0x1234, .subsystem_product = 0x5678, .revision = 1 }, .first_bus = 1, .last_bus = 1 };
const Fake = struct {
    raw: [4096]u8 align(4096) = @splat(0),
    command: u16 = 6,
    status: u16 = 0x10,
    subsystem: u32 = 0x56781234,
    dev_control: u16 = 0,
    config_reads: usize = 0,
    config_writes: usize = 0,
    mmio_reads: usize = 0,
    mmio_writes: usize = 0,
    snapshot_reads: usize = 0,
    table_reads: usize = 0,
    fences: usize = 0,
    conn_reads: usize = 0,
    tsc: u64 = 1,
    tsc_step: u64 = 1_000_000,
    user_alias: bool = false,
    user_ancestors: bool = false,
    translated: bool = false,
    bar_wb: bool = false,
    ram_uc: bool = false,
    fail_reset: bool = false,
    irq_masked: bool = true,
    duplicate: bool = false,
    remap: u32 = 0,
    current_root: u64 = 0x100000,
    read_only: bool = false,
    capability: u32 = 0x10,
    fn cast(ctx: *anyopaque) *Fake {
        return @ptrCast(@alignCast(ctx));
    }
    fn readConfig(ctx: *anyopaque, bdf: pci.Bdf, offset: u16) !u32 {
        const f = cast(ctx);
        f.config_reads += 1;
        if (bdf.bus != 1 or bdf.function != 0 or (bdf.device != 0 and !(f.duplicate and bdf.device == 1))) return 0xffffffff;
        return switch (offset) {
            0 => 0x061614c3,
            4 => @as(u32, f.status) << 16 | f.command,
            8 => 0x02800001,
            12 => 0,
            16 => 0xe0000000,
            0x2c => f.subsystem,
            0x34 => 0x40,
            0x40 => f.capability,
            0x48 => f.dev_control,
            else => 0,
        };
    }
    fn writeConfig(ctx: *anyopaque, bdf: pci.Bdf, offset: u16, value: u32) !void {
        const f = cast(ctx);
        if (!bdf.eql(device.bdf) or offset != 4 or value >> 16 != 0) return error.InvalidFakeWrite;
        f.config_writes += 1;
        f.command = @intCast(value);
    }
    fn config(f: *Fake) pci.Config {
        return .{ .context = f, .read32 = readConfig, .write32 = writeConfig };
    }
    fn snapshot(ctx: *anyopaque, output: *platform.Cpu) !void {
        cast(ctx).snapshot_reads += 1;
        output.* = .{ .cache_policy = .{ .root = 0x100000, .physical_bits = 36, .pat = 0x0007040600070406, .mtrr_enabled = true, .default_type = .wb }, .ratio = try platform.clock.Ratio.init(true, 1, 1, 1_000_000) };
    }
    fn table(ctx: *anyopaque, address: u64) !u64 {
        const f = cast(ctx);
        f.table_reads += 1;
        const flags: u64 = @as(u64, if (f.read_only) 1 else 3) | @as(u64, if (f.user_alias) 4 else 0);
        const parent_flags = flags | @as(u64, if (f.user_ancestors) 4 else 0);
        return switch (address) {
            0x100000 => 0x101000 | parent_flags,
            0x101000 => 0x102000 | parent_flags,
            0x101018 => 0x103000 | parent_flags,
            0x102010 => @as(u64, if (f.translated) 0x600000 else 0x400000) | flags | 0x80 | @as(u64, if (f.ram_uc) 0x18 else 0),
            0x103800 => @as(u64, 0xe0000000) | flags | 0x80 | @as(u64, if (f.bar_wb) 0 else 0x18),
            else => error.UnexpectedTableRead,
        };
    }
    fn masked(ctx: *anyopaque) !void {
        if (!cast(ctx).irq_masked) return error.InterruptsMustBeMasked;
    }
    fn tscRead(ctx: *anyopaque) !u64 {
        const f = cast(ctx);
        const value = f.tsc;
        f.tsc += f.tsc_step;
        return value;
    }
    fn fence(ctx: *anyopaque) void {
        cast(ctx).fences += 1;
    }
    fn root(ctx: *anyopaque) !u64 {
        return cast(ctx).current_root;
    }
    fn begin(_: *anyopaque) !void {}
    fn end(_: *anyopaque) void {}
    fn mmioRead(ctx: *anyopaque, offset: u32) !u32 {
        const f = cast(ctx);
        f.mmio_reads += 1;
        if (f.command & 4 != 0) return error.BusMasterBeforeReset;
        if (f.fail_reset) return error.DeviceRemoved;
        if (offset == mt.regs.remap_l1) return f.remap;
        const physical = if (offset >= mt.regs.remap_window and offset < mt.regs.remap_window + 0x10000) ((f.remap & 0xffff) << 16) | (offset - mt.regs.remap_window) else offset;
        if (offset == try mt.registers.fixedOffset(mt.regs.conn_lpc)) {
            f.conn_reads += 1;
            return if (f.conn_reads == 1) mt.regs.conn_own_sync else 0;
        }
        if (physical == mt.regs.chip_id) return 0x7922;
        if (physical == mt.regs.wfsys_reset) return mt.regs.reset_done;
        return 0;
    }
    fn mmioWrite(ctx: *anyopaque, offset: u32, value: u32) !void {
        const f = cast(ctx);
        if (f.command & 4 != 0) return error.BusMasterBeforeReset;
        f.mmio_writes += 1;
        if (f.fail_reset) return error.DeviceRemoved;
        if (offset == mt.regs.remap_l1) f.remap = value;
    }
    fn hardware(f: *Fake) platform.Hardware {
        return .{ .context = f, .config = f.config(), .mmio = .{ .context = f, .span = transport.bar_span, .begin = begin, .end = end, .read32 = mmioRead, .write32 = mmioWrite, .fence = fence }, .checkContext = masked, .snapshot = snapshot, .readTable = table, .currentRoot = root, .readTsc = tscRead, .fence = fence };
    }
    fn info(f: *Fake) protocol.BootInfo {
        @memset(&f.raw, 0);
        put(&f.raw, 11, 4);
        put(f.raw[8..], 0xe0000000, 8);
        put(f.raw[24..], transport.bar_span / 4096, 8);
        var value: protocol.BootInfo = undefined;
        value.drivers = .{};
        value.apps = .{};
        value.header = protocol.Header.init(.x86_64);
        value.boot_environment = @backingInt(protocol.BootEnvironment.uefi);
        value.loader_reserved = .{ .base = @intFromPtr(&f.raw), .length = f.raw.len };
        value.kernel_reserved = .{ .base = 0x100000, .length = 0x40000 };
        value.framebuffer = .{};
        value.wifi = .{};
        value.memory_region_count = 4;
        value.memory_regions[0] = .{ .range = value.kernel_reserved, .kind = @backingInt(protocol.MemoryKind.kernel), .attributes = 0 };
        value.memory_regions[1] = .{ .range = .{ .base = 0x400000, .length = 0x100000 }, .kind = @backingInt(protocol.MemoryKind.usable), .attributes = 0 };
        value.memory_regions[2] = .{ .range = .{ .base = 0xe0000000, .length = transport.bar_span }, .kind = @backingInt(protocol.MemoryKind.mmio), .attributes = 0 };
        value.memory_regions[3] = .{ .range = value.loader_reserved, .kind = @backingInt(protocol.MemoryKind.loader_reclaimable), .attributes = 0 };
        value.mapped_range_count = 4;
        for (0..4) |i| value.mapped_ranges[i] = value.memory_regions[i].range;
        value.firmware_memory_map = .{ .base = @intFromPtr(&f.raw), .length = 40 };
        value.firmware_descriptor_size = 40;
        return value;
    }
};
fn put(bytes: []u8, value: u64, len: usize) void {
    for (0..len) |i| bytes[i] = @truncate(value >> @intCast(i * 8));
}
test "platform opt-in and board identity fail before privileged or mutating callbacks" {
    var fake: Fake = .{};
    var info = fake.info();
    var provider: Provider = .{};
    var denied = options;
    denied.opt_in = false;
    try std.testing.expectError(error.PhysicalWifiDisabled, provider.prepareWith(&info, device, denied, fake.hardware()));
    denied = options;
    denied.iommu_disabled = false;
    try std.testing.expectError(error.UnsupportedDmaPlatform, provider.prepareWith(&info, device, denied, fake.hardware()));
    try std.testing.expectEqual(@as(usize, 0), fake.config_reads + fake.snapshot_reads + fake.table_reads + fake.config_writes + fake.mmio_writes);
    fake.subsystem = 0x99991234;
    try std.testing.expectError(error.WrongBoard, provider.prepareWith(&info, device, options, fake.hardware()));
    try std.testing.expect(provider.owner_address == 0 and provider.state == .empty);
    try std.testing.expectEqual(@as(usize, 0), fake.config_writes + fake.mmio_writes);
}
test "exclusive selection rejects duplicate exact identities without hardware writes" {
    var fake: Fake = .{};
    var info = fake.info();
    try std.testing.expect((try platform.selectWith(&info, options, fake.config())).bdf.eql(device.bdf));
    fake.duplicate = true;
    try std.testing.expectError(error.AmbiguousDevice, platform.selectWith(&info, options, fake.config()));
    try std.testing.expectEqual(@as(usize, 0), fake.config_writes + fake.mmio_writes);
}
test "live BAR proof rejects RAM policy user aliases and incoherent PCI ordering" {
    var fake: Fake = .{ .bar_wb = true };
    var info = fake.info();
    var provider: Provider = .{};
    try std.testing.expectError(error.NonUncachedMmio, provider.prepareWith(&info, device, options, fake.hardware()));
    fake.bar_wb = false;
    fake.user_alias = true;
    try std.testing.expectError(error.UserAccessibleAlias, provider.prepareWith(&info, device, options, fake.hardware()));
    fake.user_alias = false;
    fake.dev_control = 1 << 11;
    try std.testing.expectError(error.UnsupportedPcieOrdering, provider.prepareWith(&info, device, options, fake.hardware()));
    fake.dev_control = 0;
    put(&fake.raw, 7, 4);
    try std.testing.expectError(error.FirmwareMmioAlias, provider.prepareWith(&info, device, options, fake.hardware()));
    try std.testing.expectEqual(@as(usize, 0), fake.config_writes + fake.mmio_reads + fake.mmio_writes);
}
test "actual takeover clears inherited bus mastering before reset and exposes no lease" {
    var fake: Fake = .{};
    var info = fake.info();
    var provider: Provider = .{};
    try provider.prepareWith(&info, device, options, fake.hardware());
    try std.testing.expectEqual(@as(usize, 0), fake.config_writes + fake.mmio_reads + fake.mmio_writes);
    try provider.takeover();
    try std.testing.expect(provider.state == .quiescent and provider.bound == null);
    try std.testing.expectEqual(@as(u16, 1026), fake.command);
    try std.testing.expect(fake.config_writes == 1 and fake.mmio_writes > 0);
    var moved = provider;
    const count = fake.config_writes + fake.mmio_writes;
    try std.testing.expectError(error.MovedPlatformProvider, moved.takeover());
    try std.testing.expectEqual(count, fake.config_writes + fake.mmio_writes);
}
test "failed takeover remains quarantined with bus mastering disabled" {
    var fake: Fake = .{ .fail_reset = true };
    var info = fake.info();
    var provider: Provider = .{};
    try provider.prepareWith(&info, device, options, fake.hardware());
    try std.testing.expectError(error.DeviceRemoved, provider.takeover());
    try std.testing.expect(provider.state == .failed and fake.command & 4 == 0 and provider.bound == null);
    try std.testing.expectError(error.InvalidPlatformState, provider.takeover());
}
test "live DMA proof rejects foreign range translated or UC aliases and stale generations" {
    var fake: Fake = .{};
    var info = fake.info();
    var provider: Provider = .{};
    try provider.prepareWith(&info, device, options, fake.hardware());
    try provider.takeover();
    fake.fences = 0;
    var port: Port = .{};
    try provider.bindTransport(&port);
    // Set the same in-place state Port.prepare establishes before mapDma;
    // callbacks return views only, and no fake physical pointer is dereferenced.
    port.owner_address = @intFromPtr(&port);
    try port.lease.init(transport.allocation_size, 4096);
    const callbacks = provider.platform();
    const mapped = try callbacks.mapDma(callbacks.context, FakeMemory.range);
    try std.testing.expectEqual(FakeMemory.range.base, @as(u64, @intFromPtr(mapped.ptr)));
    try std.testing.expectEqual(FakeMemory.range.length, @as(u64, mapped.len));
    try std.testing.expectError(error.InvalidDmaMapping, callbacks.mapDma(callbacks.context, .{ .base = 0x401000, .length = 4096 }));
    fake.translated = true;
    try std.testing.expectError(error.NonIdentityCpuAlias, callbacks.mapDma(callbacks.context, FakeMemory.range));
    fake.translated = false;
    fake.ram_uc = true;
    try std.testing.expectError(error.NonWriteBackDma, callbacks.mapDma(callbacks.context, FakeMemory.range));
    fake.ram_uc = false;
    const buffer: mt.dma.Buffer = .{ .address = mapped.len + 0x400000, .bytes = mapped[0..16] };
    try std.testing.expectError(error.InvalidDmaBuffer, callbacks.dma.toDevice(callbacks.dma.context, buffer, 16));
    try callbacks.dma.toDevice(callbacks.dma.context, .{ .address = 0x400000, .bytes = mapped[0..16] }, 16);
    try std.testing.expectEqual(@as(usize, 1), fake.fences);
    fake.current_root = 0xdead000;
    try std.testing.expectError(error.InvalidPageTable, callbacks.dma.fromDevice(callbacks.dma.context, .{ .address = 0x400000, .bytes = mapped[0..16] }, 16));
    try std.testing.expectEqual(@as(usize, 1), fake.fences);
    fake.current_root = 0x100000;
    const old = port.lease.ticket.?;
    try FakeMemory.freeKernel(old);
    _ = try FakeMemory.allocateKernel(transport.allocation_size, 4096);
    try std.testing.expectError(error.StaleAllocation, callbacks.mapDma(callbacks.context, FakeMemory.range));
    try std.testing.expectError(error.StaleAllocation, callbacks.dma.toDevice(callbacks.dma.context, .{ .address = 0x400000, .bytes = mapped[0..16] }, 16));
    try std.testing.expectEqual(@as(usize, 1), fake.fences);
    FakeMemory.live = false;
}
test "hardware context and measured clock regression fail without writes" {
    var fake: Fake = .{ .irq_masked = false };
    var info = fake.info();
    var provider: Provider = .{};
    try std.testing.expectError(error.InterruptsMustBeMasked, provider.prepareWith(&info, device, options, fake.hardware()));
    fake.irq_masked = true;
    try provider.prepareWith(&info, device, options, fake.hardware());
    try std.testing.expectEqual(@as(u64, 1_000_000), try provider.nowMicros());
    fake.tsc = 0;
    try std.testing.expectError(error.ClockRegressed, provider.nowMicros());
    try std.testing.expectEqual(@as(usize, 0), fake.config_writes + fake.mmio_writes);
}
test "BAR proof rejects partial firmware coverage cyclic PCI caps and read-only aliases atomically" {
    var fake: Fake = .{};
    var info = fake.info();
    var provider: Provider = .{};
    put(fake.raw[24..], 1, 8);
    try std.testing.expectError(error.IncompleteFirmwareMmio, provider.prepareWith(&info, device, options, fake.hardware()));
    put(fake.raw[24..], transport.bar_span / 4096, 8);
    fake.capability = 0x4005;
    try std.testing.expectError(error.InvalidPciCapabilities, provider.prepareWith(&info, device, options, fake.hardware()));
    fake.capability = 0x10;
    fake.read_only = true;
    try std.testing.expectError(error.ReadOnlyCpuAlias, provider.prepareWith(&info, device, options, fake.hardware()));
    try std.testing.expect(provider.state == .empty and provider.owner_address == 0);
    try std.testing.expectEqual(@as(usize, 0), fake.config_writes + fake.mmio_writes);
}
test "PCI and MMIO adapter reject foreign or unprepared operations before mutation" {
    var fake: Fake = .{};
    var info = fake.info();
    var provider: Provider = .{};
    try provider.prepareWith(&info, device, options, fake.hardware());
    const config = provider.config();
    try std.testing.expectError(error.NonOwnedPciFunction, config.read(.{ .bus = 2, .device = 0, .function = 0 }, 0));
    try std.testing.expectError(error.NonOwnedPciWrite, config.write32(config.context, device.bdf, 16, 0));
    try std.testing.expectError(error.InvalidPlatformState, config.write32(config.context, device.bdf, 4, 6));
    const mmio = provider.platform().mmio;
    try std.testing.expectError(error.InvalidRegisterTransaction, mmio.begin(mmio.context));
    try provider.takeover();
    const writes = fake.config_writes;
    try std.testing.expectError(error.UnboundTransport, config.write32(config.context, device.bdf, 4, 6));
    try std.testing.expectEqual(writes, fake.config_writes);
    try mmio.begin(mmio.context);
    try std.testing.expectError(error.InvalidRegisterTransaction, mmio.begin(mmio.context));
    try std.testing.expectError(error.InvalidRegisterAccess, mmio.write32(mmio.context, transport.bar_span, 0));
    mmio.end(mmio.context);
    const reads = fake.mmio_reads;
    fake.current_root = 0xdead000;
    try std.testing.expectError(error.InvalidPageTable, mmio.begin(mmio.context));
    try std.testing.expectEqual(reads, fake.mmio_reads);
}
test "DMA cache proof intersects every MTRR boundary and never treats unknown memory as RAM" {
    var fake: Fake = .{};
    var info = fake.info();
    var cpu: platform.Cpu = .{};
    try Fake.snapshot(&fake, &cpu);
    cpu.cache_policy.variables[0] = .{ .base = 0x410000, .length = 0x10000, .kind = .uc };
    cpu.cache_policy.count = 1;
    try std.testing.expectError(error.NonWriteBackDma, platform.cache.require(&cpu.cache_policy, &info, .{ .context = &fake, .read = Fake.table }, FakeMemory.range, .wb));
    try platform.cache.require(&cpu.cache_policy, &info, .{ .context = &fake, .read = Fake.table }, .{ .base = 0x400000, .length = 4096 }, .wb);
    info.memory_regions[1].kind = 0xffff;
    try std.testing.expect(!platform.cache.ramCovered(&info, FakeMemory.range, false));
    info.memory_region_count = protocol.max_memory_regions + 1;
    try std.testing.expect(!platform.cache.ramCovered(&info, FakeMemory.range, true));
}
test "task root can share user ancestors while physical MMIO and DMA leaves remain supervisor only" {
    var fake: Fake = .{ .user_ancestors = true };
    var info = fake.info();
    var provider: Provider = .{};
    try provider.prepareWith(&info, device, options, fake.hardware());
    try provider.takeover();
    try platform.cache.require(&provider.cpu.cache_policy, &info, .{ .context = &fake, .read = Fake.table }, FakeMemory.range, .wb);
    fake.user_alias = true;
    try std.testing.expectError(error.UserAccessibleAlias, platform.cache.require(&provider.cpu.cache_policy, &info, .{ .context = &fake, .read = Fake.table }, FakeMemory.range, .wb));
    const writes = fake.mmio_writes;
    const mmio = provider.platform().mmio;
    try std.testing.expectError(error.UserAccessibleAlias, mmio.begin(mmio.context));
    try std.testing.expectEqual(writes, fake.mmio_writes);
}
