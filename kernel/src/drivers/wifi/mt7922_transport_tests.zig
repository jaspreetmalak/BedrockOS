const std = @import("std");
const protocol = @import("boot_protocol");
const pci = @import("pci");
const mt = @import("mediatek/root.zig");
const transport = @import("mt7922_transport.zig");
const FakeMemory = struct {
    pub const heap_api = struct {
        pub const Ticket = struct { generation: u64 };
    };
    var live: bool = false;
    var generation: u64 = 1;
    var allocations: usize = 0;
    var frees: usize = 0;
    var fail_free: bool = false;
    var range: protocol.PhysicalRange = .{ .base = 0x100000, .length = transport.allocation_size };
    var arena: [transport.allocation_size]u8 = undefined;
    fn reset() void {
        live = false;
        generation = 1;
        allocations = 0;
        frees = 0;
        fail_free = false;
        range = .{ .base = 0x100000, .length = transport.allocation_size };
        @memset(&arena, 0xaa);
    }
    pub fn allocateKernel(bytes: usize, alignment: usize) !heap_api.Ticket {
        if (live or bytes != arena.len or alignment != 4096) return error.InvalidAllocation;
        allocations += 1;
        live = true;
        return .{ .generation = generation };
    }
    pub fn resolveKernel(ticket: heap_api.Ticket) !struct { range: protocol.PhysicalRange } {
        if (!live or ticket.generation != generation) return error.StaleAllocation;
        return .{ .range = range };
    }
    pub fn freeKernel(ticket: heap_api.Ticket) !void {
        if (!live or ticket.generation != generation) return error.StaleAllocation;
        if (fail_free) return error.FreeFailed;
        frees += 1;
        live = false;
        generation += 1;
    }
};
const Port = transport.Owned(FakeMemory);
const Fake = struct {
    command: u16 = 2,
    identity: u32 = 0x061614c3,
    bar: u32 = 0xe0000000,
    config_writes: usize = 0,
    mmio_reads: usize = 0,
    mmio_writes: usize = 0,
    bad_mapping: bool = false,
    fail_mmio: bool = false,
    reentrant: ?*Port = null,
    denied_stops: usize = 0,
    fn cast(context: *anyopaque) *Fake {
        return @ptrCast(@alignCast(context));
    }
    fn read(context: *anyopaque, _: pci.Bdf, offset: u16) !u32 {
        const self = cast(context);
        return switch (offset) {
            0 => self.identity,
            4 => self.command,
            16 => self.bar,
            else => 0,
        };
    }
    fn write(context: *anyopaque, _: pci.Bdf, offset: u16, value: u32) !void {
        const self = cast(context);
        if (offset != 4 or value >> 16 != 0) return error.UnexpectedConfigWrite;
        self.config_writes += 1;
        self.command = @intCast(value);
    }
    fn begin(_: *anyopaque) !void {}
    fn end(_: *anyopaque) void {}
    fn readMmio(context: *anyopaque, _: u32) !u32 {
        const self = cast(context);
        self.mmio_reads += 1;
        if (self.fail_mmio) return error.DeviceTimeout;
        return 0;
    }
    fn writeMmio(context: *anyopaque, _: u32, _: u32) !void {
        const self = cast(context);
        self.mmio_writes += 1;
        if (self.fail_mmio) return error.DeviceTimeout;
    }
    fn fence(_: *anyopaque) void {}
    fn delay(_: *anyopaque, _: u32) !void {}
    fn maintain(context: *anyopaque, _: mt.dma.Buffer, _: usize) !void {
        const self = cast(context);
        if (self.reentrant) |port| {
            port.stop() catch |err| {
                if (err != error.TransportBusy) return err;
                self.denied_stops += 1;
                return;
            };
            return error.StopFreedActiveDma;
        }
    }
    fn map(context: *anyopaque, range: protocol.PhysicalRange) ![]volatile u8 {
        if (range.base != FakeMemory.range.base or range.length != FakeMemory.arena.len) return error.InvalidMapping;
        return FakeMemory.arena[0 .. FakeMemory.arena.len - @intFromBool(cast(context).bad_mapping)];
    }
    fn config(self: *Fake) pci.Config {
        return .{ .context = self, .read32 = read, .write32 = write };
    }
    fn platform(self: *Fake) transport.Platform {
        return .{ .context = self, .bar_address = self.bar, .mmio = .{ .context = self, .span = transport.bar_span, .begin = begin, .end = end, .read32 = readMmio, .write32 = writeMmio, .fence = fence }, .clock = .{ .context = self, .delayUs = delay }, .dma = .{ .context = self, .toDevice = maintain, .fromDevice = maintain, .delayUs = delay }, .mapDma = map };
    }
};
const device: pci.Device = .{ .bdf = .{ .bus = 1, .device = 0, .function = 0 }, .vendor = 0x14c3, .product = 0x0616, .class = 2, .subclass = 0x80, .programming_interface = 0, .revision = 0, .header = 0 };

test "owned firmware transport preparation retains disjoint zeroed buffers without hardware writes" {
    FakeMemory.reset();
    var fake: Fake = .{};
    var port: Port = .{};
    try port.prepare(fake.config(), device, fake.platform());
    try std.testing.expectEqual(transport.State.prepared, port.state);
    try std.testing.expect(FakeMemory.live and !port.lease.exposed);
    try std.testing.expectEqual(@as(usize, 0), fake.config_writes + fake.mmio_reads + fake.mmio_writes);
    for (FakeMemory.arena) |b| try std.testing.expectEqual(@as(u8, 0), b);
    for (0..transport.ring_count) |i| try (mt.dma.Config{ .register_base = if (i == 3) mt.regs.mcu_second_event_base else if (i == 2) mt.regs.event_ring_base else try mt.regs.txRing(if (i == 0) 17 else 16), .descriptors = port.descriptors[i], .buffers = &port.buffers[i], .direction = if (i >= 2) .rx else .tx }).validate();
    try std.testing.expectError(error.WrongFirmware, port.start(.{ .patch = &.{}, .ram = &.{} }));
    try std.testing.expectEqual(transport.State.prepared, port.state);
    try std.testing.expectEqual(@as(usize, 0), fake.config_writes + fake.mmio_writes);
    try port.stop();
    try port.stop();
    try std.testing.expect(!FakeMemory.live and FakeMemory.frees == 1);
}
test "transport rejects active old bus mastering, changed identity and BAR before allocation" {
    FakeMemory.reset();
    var fake: Fake = .{ .command = 6 };
    var port: Port = .{};
    try std.testing.expectError(error.DeviceStillBusMastering, port.prepare(fake.config(), device, fake.platform()));
    fake.command = 2;
    fake.identity = 0xffffffff;
    try std.testing.expectError(error.DeviceChanged, port.prepare(fake.config(), device, fake.platform()));
    fake.identity = 0x061614c3;
    var platform = fake.platform();
    platform.bar_address += 4096;
    try std.testing.expectError(error.DeviceChanged, port.prepare(fake.config(), device, platform));
    try std.testing.expect(FakeMemory.allocations == 0 and fake.config_writes == 0);
}
test "transport mapping error rolls back memory and free failure remains retryable" {
    FakeMemory.reset();
    var fake: Fake = .{ .bad_mapping = true };
    var port: Port = .{};
    try std.testing.expectError(error.InvalidDmaMapping, port.prepare(fake.config(), device, fake.platform()));
    try std.testing.expect(!FakeMemory.live and FakeMemory.frees == 1);
    FakeMemory.reset();
    port = .{};
    FakeMemory.fail_free = true;
    try std.testing.expectError(error.ResourceCleanupFailed, port.prepare(fake.config(), device, fake.platform()));
    try std.testing.expect(FakeMemory.live and port.state == .reset_required and !port.lease.exposed);
    FakeMemory.fail_free = false;
    try port.stop();
    try std.testing.expect(!FakeMemory.live and fake.config_writes == 0 and fake.mmio_writes == 0);
}
test "transport copies cannot publish DMA or stop the real owner" {
    FakeMemory.reset();
    var fake: Fake = .{};
    var owner: Port = .{};
    try owner.prepare(fake.config(), device, fake.platform());
    var copy = owner;
    try std.testing.expectError(error.MovedTransport, copy.start(.{ .patch = &.{}, .ram = &.{} }));
    try std.testing.expectError(error.MovedTransport, copy.stop());
    try std.testing.expect(FakeMemory.live and FakeMemory.frees == 0 and fake.config_writes == 0);
    try owner.stop();
}
test "transport failed DMA stop retains exposed storage and only a confirmed reset frees it" {
    FakeMemory.reset();
    var fake: Fake = .{};
    var port: Port = .{};
    try port.prepare(fake.config(), device, fake.platform());
    // Fault fixture at the post-publication boundary, without running firmware.
    _ = try port.lease.publish();
    port.command_changed = true;
    port.state = .reset_required;
    fake.command = 6;
    fake.fail_mmio = true;
    try std.testing.expectError(error.DeviceTimeout, port.stop());
    try std.testing.expect(FakeMemory.live and port.lease.exposed and !port.quiescent and FakeMemory.frees == 0);
    try std.testing.expectEqual(@as(u16, 0), fake.command & 4);
    fake.fail_mmio = false;
    try port.stop();
    try std.testing.expect(!FakeMemory.live and port.quiescent and port.state == .stopped);
    try std.testing.expectEqual(port.original_command & ~@as(u16, 4), fake.command);
}
test "transport retired tickets cannot free a new owner's memory" {
    FakeMemory.reset();
    var fake: Fake = .{};
    var old: Port = .{};
    try old.prepare(fake.config(), device, fake.platform());
    try FakeMemory.freeKernel(old.lease.ticket.?);
    const replacement = try FakeMemory.allocateKernel(transport.allocation_size, 4096);
    try std.testing.expectError(error.StaleAllocation, old.stop());
    try std.testing.expect(FakeMemory.live and FakeMemory.frees == 1);
    try FakeMemory.freeKernel(replacement);
}
fn postedFixture(port: *Port) !void {
    // Model only the retained CPU objects at the post-ring publication point.
    // No DMA completion or firmware success is synthesized by this fixture.
    for (0..transport.ring_count) |i| {
        port.rings[i] = .{ .registers = &port.driver.registers, .config = .{ .register_base = if (i == 3) mt.regs.mcu_second_event_base else if (i == 2) mt.regs.event_ring_base else try mt.regs.txRing(if (i == 0) 17 else 16), .descriptors = port.descriptors[i], .buffers = &port.buffers[i], .direction = if (i >= 2) .rx else .tx }, .hooks = port.dmaHooks(), .head = 0 };
    }
    port.initialized_rings = transport.ring_count;
    port.channel = .{ .wm = &port.rings[0], .fwdl = &port.rings[1], .event = &port.rings[2] };
    port.mcu.init(port.channel.channel());
    port.mcu_initialized = true;
    _ = try port.lease.publish();
    port.command_changed = true;
    port.state = .reset_required;
}
test "retained MCU and ring references reject work before freed DMA is reused" {
    FakeMemory.reset();
    var fake: Fake = .{};
    var port: Port = .{};
    try port.prepare(fake.config(), device, fake.platform());
    try postedFixture(&port);
    var copied_ring = port.rings[0];
    var copied_rx = port.rings[3];
    var copied_mcu = port.mcu;
    try port.stop();
    const writes = fake.mmio_writes;
    const replacement = try FakeMemory.allocateKernel(transport.allocation_size, 4096);
    @memset(&FakeMemory.arena, 0x5a);
    try std.testing.expectError(error.McuStopped, port.mcu.request(.start, &.{}));
    try std.testing.expectError(error.DmaStopped, port.rings[0].send(&.{1}, 1));
    var output: [16]u8 = undefined;
    try std.testing.expectError(error.DmaStopped, port.rings[3].receive(&output));
    try std.testing.expectError(error.DmaStopped, copied_ring.send(&.{1}, 1));
    try std.testing.expectError(error.DmaStopped, copied_rx.receive(&output));
    try std.testing.expectError(error.DmaStopped, copied_mcu.request(.start, &.{}));
    try std.testing.expectEqual(writes, fake.mmio_writes);
    for (FakeMemory.arena) |b| try std.testing.expectEqual(@as(u8, 0x5a), b);
    try FakeMemory.freeKernel(replacement);
}
test "transport reentrant stop cannot retire or free an active MCU or ring call" {
    FakeMemory.reset();
    var fake: Fake = .{};
    var port: Port = .{};
    try port.prepare(fake.config(), device, fake.platform());
    try postedFixture(&port);
    port.mcu.busy = true;
    try std.testing.expectError(error.TransportBusy, port.stop());
    port.mcu.busy = false;
    port.rings[1].busy = true;
    try std.testing.expectError(error.TransportBusy, port.stop());
    try std.testing.expect(FakeMemory.live and FakeMemory.frees == 0 and !port.mcu.stopped and !port.rings[0].stopped);
    port.rings[1].busy = false;
    try port.stop();
}
test "copied live ring callbacks cannot stop the owner while borrowing DMA" {
    FakeMemory.reset();
    var fake: Fake = .{};
    var port: Port = .{};
    try port.prepare(fake.config(), device, fake.platform());
    try postedFixture(&port);
    port.state = .firmware_ready;
    fake.reentrant = &port;
    var copy = port.rings[0];
    try std.testing.expectError(error.DmaTimeout, copy.send(&.{1}, 1));
    try std.testing.expect(fake.denied_stops != 0 and FakeMemory.live and FakeMemory.frees == 0);
    try std.testing.expectEqual(@as(usize, 0), port.active_io);
    try std.testing.expectEqual(@as(usize, 0), fake.config_writes);
    fake.reentrant = null;
    try port.stop();
}
test "activation and nested shutdown reject teardown before any hardware or memory change" {
    FakeMemory.reset();
    var fake: Fake = .{};
    var port: Port = .{};
    try port.prepare(fake.config(), device, fake.platform());
    port.state = .activating;
    try std.testing.expectError(error.TransportBusy, port.stop());
    port.state = .prepared;
    port.stopping = true;
    try std.testing.expectError(error.TransportBusy, port.stop());
    try std.testing.expect(FakeMemory.live and FakeMemory.frees == 0 and fake.config_writes == 0);
    port.stopping = false;
    try port.stop();
}
