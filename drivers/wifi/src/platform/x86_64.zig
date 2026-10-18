//! Opt-in, exclusive MT7922 takeover for a named coherent x86 UEFI platform.
//! The caller attests IOMMU-disabled coherent identity DMA and serializes on
//! one CPU with interrupts masked. Assets/PCI IDs alone never enable hardware.
const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("boot_protocol");
const pci = @import("pci");
const pci_native = @import("pci_native");
const memory = @import("memory_init");
const transport = @import("../mt7922_transport.zig");
const resources = @import("../resources.zig");
const mt = @import("../mediatek/root.zig");
pub const cache = @import("cache.zig");
pub const clock = @import("clock.zig");
pub const Identity = struct {
    vendor: u16,
    product: u16,
    subsystem_vendor: u16,
    subsystem_product: u16,
    revision: u8,
};
pub const Options = struct {
    opt_in: bool = false,
    coherent_identity_dma: bool = false,
    iommu_disabled: bool = false,
    exclusive_takeover: bool = false,
    identity: Identity,
    first_bus: u8 = 0,
    last_bus: u8 = 255,
    fn validate(self: Options) !void {
        if (!self.opt_in) return error.PhysicalWifiDisabled;
        if (!self.coherent_identity_dma or !self.iommu_disabled or !self.exclusive_takeover) return error.UnsupportedDmaPlatform;
        if (!supported(self.identity.vendor, self.identity.product) or self.identity.subsystem_vendor == 0 or self.identity.subsystem_vendor == 0xffff or self.identity.subsystem_product == 0xffff or self.first_bus > self.last_bus) return error.InvalidBoardIdentity;
    }
};
pub const Cpu = struct { cache_policy: cache.Snapshot = .{}, ratio: clock.Ratio = undefined };
/// Injection boundary for native tests: no privileged instructions or host
/// MMIO are reached when these callbacks are supplied by a fake platform.
pub const Hardware = struct {
    context: *anyopaque,
    config: pci.Config,
    mmio: mt.Mmio,
    checkContext: *const fn (*anyopaque) anyerror!void,
    snapshot: *const fn (*anyopaque, *Cpu) anyerror!void,
    readTable: *const fn (*anyopaque, u64) anyerror!u64,
    currentRoot: *const fn (*anyopaque) anyerror!u64,
    readTsc: *const fn (*anyopaque) anyerror!u64,
    fence: *const fn (*anyopaque) void,
};
pub const State = enum { empty, prepared, taking_over, quiescent, failed };
pub const Provider = Owned(memory);
fn supported(vendor: u16, product: u16) bool {
    return (vendor == 0x14c3 and (product == 0x0616 or product == 0x7922)) or (vendor == 0x0b48 and product == 0x7922);
}
fn validateInfo(info: *const protocol.BootInfo) !void {
    if (info.header.architecture != @backingInt(protocol.Architecture.x86_64) or info.boot_environment != @backingInt(protocol.BootEnvironment.uefi)) return error.UnsupportedNativePlatform;
    if (info.memory_region_count == 0 or info.memory_region_count > protocol.max_memory_regions or info.mapped_range_count == 0 or info.mapped_range_count > protocol.max_mapped_ranges) return error.InvalidBootMap;
    var previous: u64 = 0;
    for (info.memory_regions[0..info.memory_region_count], 0..) |r, i| {
        const high = try r.range.endExclusive();
        if (r.range.length == 0 or (i != 0 and r.range.base < previous)) return error.InvalidBootMap;
        previous = high;
    }
    previous = 0;
    for (info.mapped_ranges[0..info.mapped_range_count], 0..) |r, i| {
        const high = try r.endExclusive();
        if (r.length == 0 or (i != 0 and r.base < previous)) return error.InvalidBootMap;
        previous = high;
    }
}
fn matches(config: pci.Config, device: pci.Device, identity: Identity) !bool {
    if (device.vendor != identity.vendor or device.product != identity.product or device.revision != identity.revision or !device.wireless() or device.header & 0x7f != 0 or device.bdf.segment != 0) return false;
    if (try config.read(device.bdf, 0) != @as(u32, identity.vendor) | @as(u32, identity.product) << 16) return error.DeviceChanged;
    const class = try config.read(device.bdf, 8);
    if (@as(u8, @truncate(class)) != identity.revision or @as(u8, @truncate(class >> 24)) != 2 or @as(u8, @truncate(class >> 16)) != 0x80) return error.DeviceChanged;
    return try config.read(device.bdf, 0x2c) == @as(u32, identity.subsystem_vendor) | @as(u32, identity.subsystem_product) << 16;
}
pub fn selectWith(info: *const protocol.BootInfo, options: Options, config: pci.Config) !pci.Device {
    try options.validate();
    try validateInfo(info);
    const inventory = try pci.wirelessInventory(config, 0, options.first_bus, options.last_bus);
    if (inventory.dropped != 0) return error.IncompleteDeviceInventory;
    var selected: ?pci.Device = null;
    for (inventory.items[0..inventory.count]) |device| if (try matches(config, device, options.identity)) {
        if (selected != null) return error.AmbiguousDevice;
        selected = device;
    };
    return selected orelse error.DeviceNotFound;
}
pub fn select(info: *const protocol.BootInfo, options: Options) !pci.Device {
    try options.validate();
    if (builtin.cpu.arch != .x86_64) return error.UnsupportedNativePlatform;
    try checkMasked();
    return selectWith(info, options, try pci_native.legacy(info));
}
pub fn Owned(comptime Memory: type) type {
    return struct {
        const Self = @This();
        const Port = transport.Owned(Memory);
        state: State = .empty,
        owner_address: usize = 0,
        info: *const protocol.BootInfo = undefined,
        device: pci.Device = undefined,
        options: Options = undefined,
        hardware: Hardware = undefined,
        cpu: Cpu = .{},
        aperture: resources.Mmio = undefined,
        bound: ?*Port = null,
        busy: bool = false,
        mmio_active: bool = false,
        epoch_tsc: u64 = 0,
        last_tsc: u64 = 0,
        fn owner(self: *Self) !void {
            if (self.owner_address == 0 or self.owner_address != @intFromPtr(self)) return error.MovedPlatformProvider;
            try self.hardware.checkContext(self.hardware.context);
        }
        pub fn prepare(self: *Self, info: *const protocol.BootInfo, device: pci.Device, options: Options) !void {
            try options.validate();
            if (builtin.cpu.arch != .x86_64) return error.UnsupportedNativePlatform;
            try checkMasked();
            const hardware: Hardware = .{ .context = self, .config = try pci_native.legacy(info), .mmio = transport.nativeMmio(&self.aperture), .checkContext = nativeMasked, .snapshot = nativeSnapshot, .readTable = nativeTable, .currentRoot = nativeRoot, .readTsc = nativeTsc, .fence = nativeFence };
            try self.prepareWith(info, device, options, hardware);
        }
        pub fn prepareWith(self: *Self, info: *const protocol.BootInfo, device: pci.Device, options: Options, hardware: Hardware) !void {
            try options.validate();
            if (self.state != .empty or self.owner_address != 0) return error.PlatformAlreadyInitialized;
            if (overlap(@intFromPtr(self), @sizeOf(Self), @intFromPtr(info), @sizeOf(protocol.BootInfo))) return error.AliasedPlatformOwner;
            try validateInfo(info);
            try hardware.checkContext(hardware.context);
            if (!try matches(hardware.config, device, options.identity)) return error.WrongBoard;
            const address = try pci.memoryBar(hardware.config, device, 0);
            const aperture = try resources.Mmio.init(info, address, transport.bar_span);
            if (hardware.mmio.span != transport.bar_span) return error.InvalidAperture;
            // Live CPU proof and the complete source EFI MMIO descriptor must
            // agree. A RAM cache policy or a partially described BAR fails.
            self.cpu = .{};
            try hardware.snapshot(hardware.context, &self.cpu);
            _ = try clock.Ratio.init(true, self.cpu.ratio.denominator, self.cpu.ratio.numerator, self.cpu.ratio.crystal_hz);
            try self.cpu.cache_policy.validate();
            try cache.require(&self.cpu.cache_policy, info, .{ .context = hardware.context, .read = hardware.readTable }, aperture.range, .uc);
            try efiMmio(info, aperture.range);
            // Validate PCIe capabilities before mutation: No-Snoop and relaxed
            // ordering are outside this deliberately coherent polling profile.
            try checkPcie(hardware.config, device);
            const tsc = try hardware.readTsc(hardware.context);
            self.info = info;
            self.device = device;
            self.options = options;
            self.hardware = hardware;
            self.aperture = aperture;
            self.epoch_tsc = tsc;
            self.last_tsc = tsc;
            self.owner_address = @intFromPtr(self);
            self.state = .prepared;
        }
        pub fn config(self: *Self) pci.Config {
            return .{ .context = self, .read32 = readConfig, .write32 = writeConfig };
        }
        fn readConfig(context: *anyopaque, bdf: pci.Bdf, offset: u16) !u32 {
            const self: *Self = @ptrCast(@alignCast(context));
            try self.owner();
            if (!bdf.eql(self.device.bdf)) return error.NonOwnedPciFunction;
            return self.hardware.config.read(bdf, offset);
        }
        fn writeConfig(context: *anyopaque, bdf: pci.Bdf, offset: u16, value: u32) !void {
            const self: *Self = @ptrCast(@alignCast(context));
            try self.owner();
            if (!bdf.eql(self.device.bdf) or offset != 4 or value >> 16 != 0) return error.NonOwnedPciWrite;
            if (self.state != .taking_over and self.state != .quiescent) return error.InvalidPlatformState;
            if (value & 4 != 0) {
                const port = self.bound orelse return error.UnboundTransport;
                _ = try self.liveRange();
                if (port.state != .activating or !port.lease.exposed) return error.DmaNotPublished;
            }
            // Status W1C bits are never written. Transport owns BME only after
            // successful platform quiescence and retained descriptor setup.
            try self.hardware.config.write32(self.hardware.config.context, bdf, offset, value);
        }
        pub fn takeover(self: *Self) !void {
            try self.owner();
            if (self.state != .prepared or self.busy) return error.InvalidPlatformState;
            if (!try matches(self.hardware.config, self.device, self.options.identity)) return error.DeviceChanged;
            self.state = .taking_over;
            self.busy = true;
            defer self.busy = false;
            errdefer self.state = .failed;
            const command: u16 = @truncate(try self.config().read(self.device.bdf, 4));
            try pci.writeCommand(self.config(), self.device, (command | @as(u16, 2 | 1024)) & ~@as(u16, 4));
            var driver = mt.Driver.init(try mt.Registers.init(self.mmio()), .{ .context = self, .delayUs = delay });
            try driver.driverOwn();
            try driver.reset();
            try driver.stop();
            if (@as(u16, @truncate(try self.config().read(self.device.bdf, 4))) & 4 != 0) return error.DeviceStillBusMastering;
            self.state = .quiescent;
        }
        /// Bind before Port.prepare so mapDma resolves that exact live ticket.
        /// This provider/transport pair and BootInfo must remain in place.
        pub fn bindTransport(self: *Self, port: *Port) !void {
            try self.owner();
            if (self.state != .quiescent or self.busy or self.bound != null or port.state != .empty or port.owner_address != 0) return error.InvalidPlatformState;
            const p = @intFromPtr(port);
            const s = @intFromPtr(self);
            if (overlap(p, @sizeOf(Port), s, @sizeOf(Self))) return error.AliasedPlatformOwner;
            self.bound = port;
        }
        pub fn platform(self: *Self) transport.Platform {
            return .{ .context = self, .bar_address = self.aperture.range.base, .mmio = self.mmio(), .clock = .{ .context = self, .delayUs = delay }, .dma = .{ .context = self, .validateLease = validateLease, .toDevice = maintain, .fromDevice = maintain, .delayUs = delay }, .mapDma = mapDma };
        }
        fn mmio(self: *Self) mt.Mmio {
            return .{ .context = self, .span = transport.bar_span, .begin = mmioBegin, .end = mmioEnd, .read32 = mmioRead, .write32 = mmioWrite, .fence = mmioFence };
        }
        fn mmioBegin(context: *anyopaque) !void {
            const self: *Self = @ptrCast(@alignCast(context));
            try self.owner();
            if ((self.state != .taking_over and self.state != .quiescent) or self.mmio_active) return error.InvalidRegisterTransaction;
            try self.requireMapping(self.aperture.range, .uc);
            try self.hardware.mmio.begin(self.hardware.mmio.context);
            self.mmio_active = true;
        }
        fn mmioEnd(context: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(context));
            std.debug.assert(self.owner_address == @intFromPtr(self) and self.mmio_active);
            self.hardware.mmio.end(self.hardware.mmio.context);
            self.mmio_active = false;
        }
        fn mmioRead(context: *anyopaque, offset: u32) !u32 {
            const self: *Self = @ptrCast(@alignCast(context));
            try self.owner();
            if (!self.mmio_active or offset % 4 != 0 or offset > transport.bar_span - 4) return error.InvalidRegisterAccess;
            return self.hardware.mmio.read32(self.hardware.mmio.context, offset);
        }
        fn mmioWrite(context: *anyopaque, offset: u32, value: u32) !void {
            const self: *Self = @ptrCast(@alignCast(context));
            try self.owner();
            if (!self.mmio_active or offset % 4 != 0 or offset > transport.bar_span - 4) return error.InvalidRegisterAccess;
            return self.hardware.mmio.write32(self.hardware.mmio.context, offset, value);
        }
        fn mmioFence(context: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(context));
            std.debug.assert(self.owner_address == @intFromPtr(self) and self.mmio_active);
            self.hardware.mmio.fence(self.hardware.mmio.context);
        }
        fn liveRange(self: *Self) !protocol.PhysicalRange {
            try self.owner();
            if (self.state != .quiescent) return error.InvalidPlatformState;
            const port = self.bound orelse return error.UnboundTransport;
            if (port.owner_address != @intFromPtr(port) or port.lease.owner_address != @intFromPtr(&port.lease) or port.lease.released) return error.InvalidDmaLease;
            const block = try Memory.resolveKernel(port.lease.ticket orelse return error.InvalidDmaLease);
            if (block.range.base != port.lease.range.base or block.range.length != port.lease.range.length) return error.InvalidDmaLease;
            try resources.checkDma32(block.range.base, block.range.length);
            if (!cache.ramCovered(self.info, block.range, true)) return error.NonUsableDmaMemory;
            for ([_]protocol.PhysicalRange{
                .{ .base = @intFromPtr(self), .length = @sizeOf(Self) },
                .{ .base = @intFromPtr(port), .length = @sizeOf(Port) },
                .{ .base = @intFromPtr(self.info), .length = @sizeOf(protocol.BootInfo) },
                self.info.firmware_memory_map,
            }) |r| if (overlap(block.range.base, block.range.length, r.base, r.length)) return error.AliasedPlatformOwner;
            for ([_]protocol.PhysicalRange{ self.info.loader_reserved, self.info.kernel_reserved, self.info.wifi.reservation, .{ .base = self.info.framebuffer.base, .length = self.info.framebuffer.size } }) |r| {
                if (r.length != 0 and overlap(block.range.base, block.range.length, r.base, r.length)) return error.ProtectedMemoryAlias;
            }
            return block.range;
        }
        fn validateLease(context: *anyopaque) !void {
            const self: *Self = @ptrCast(@alignCast(context));
            _ = try self.liveRange();
        }
        fn mapDma(context: *anyopaque, range: protocol.PhysicalRange) ![]volatile u8 {
            const self: *Self = @ptrCast(@alignCast(context));
            const live = try self.liveRange();
            if (range.base != live.base or range.length != live.length) return error.InvalidDmaMapping;
            try self.requireMapping(range, .wb);
            const view: [*]volatile u8 = @ptrFromInt(range.base);
            return view[0..@intCast(range.length)];
        }
        fn maintain(context: *anyopaque, buffer: mt.dma.Buffer, length: usize) !void {
            const self: *Self = @ptrCast(@alignCast(context));
            const range = try self.liveRange();
            if (length == 0 or length > buffer.bytes.len or buffer.address != @intFromPtr(buffer.bytes.ptr) or buffer.address < range.base or buffer.address - range.base > range.length or buffer.bytes.len > range.length - (buffer.address - range.base)) return error.InvalidDmaBuffer;
            try self.requireMapping(.{ .base = buffer.address, .length = buffer.bytes.len }, .wb);
            // Coherent x86 memory requires ordering, not a guessed cache flush.
            // The lease is WB, No-Snoop is rejected, and bus=CPU physical.
            self.hardware.fence(self.hardware.context);
        }
        fn requireMapping(self: *Self, range: protocol.PhysicalRange, wanted: cache.Type) !void {
            // The kernel may be executing a syscall under a task root. Inspect
            // that live root instead of reusing prepare's kernel-root proof.
            // PAT/MTRR remain stable under this single-CPU platform contract.
            self.cpu.cache_policy.root = try self.hardware.currentRoot(self.hardware.context);
            try cache.require(&self.cpu.cache_policy, self.info, .{ .context = self.hardware.context, .read = self.hardware.readTable }, range, wanted);
        }
        pub fn nowMicros(self: *Self) !u64 {
            try self.owner();
            const now = try self.hardware.readTsc(self.hardware.context);
            if (now < self.last_tsc or now < self.epoch_tsc) return error.ClockRegressed;
            self.last_tsc = now;
            return self.cpu.ratio.microsForTicks(now - self.epoch_tsc);
        }
        fn delay(context: *anyopaque, micros: u32) !void {
            const self: *Self = @ptrCast(@alignCast(context));
            try self.owner();
            const ticks = try self.cpu.ratio.ticksForMicros(micros);
            const start = try self.hardware.readTsc(self.hardware.context);
            if (start < self.last_tsc) return error.ClockRegressed;
            self.last_tsc = start;
            // A hard iteration bound detects stalled/emulated/broken TSCs.
            // It is a failure bound, never a cycle-frequency approximation.
            var polls: usize = 0;
            while (polls < 100_000_000) : (polls += 1) {
                const now = try self.hardware.readTsc(self.hardware.context);
                if (now < self.last_tsc) return error.ClockRegressed;
                self.last_tsc = now;
                if (now - start >= ticks) return;
            }
            return error.ClockStalled;
        }
    };
}
fn overlap(a: u64, al: u64, b: u64, bl: u64) bool {
    if (al == 0 or bl == 0) return false;
    const ae = @addWithOverflow(a, al);
    const be = @addWithOverflow(b, bl);
    return ae[1] != 0 or be[1] != 0 or (a < be[0] and b < ae[0]);
}
fn checkPcie(config: pci.Config, device: pci.Device) !void {
    if ((try config.read(device.bdf, 4)) & (1 << 20) == 0) return error.MissingPcieCapability;
    var at = try config.byte(device.bdf, 0x34);
    var seen: [64]bool = @splat(false);
    for (0..48) |_| {
        if (at == 0) return error.MissingPcieCapability;
        if (at < 0x40 or at > 0xfc or at % 4 != 0 or seen[at / 4]) return error.InvalidPciCapabilities;
        seen[at / 4] = true;
        const value = try config.read(device.bdf, at);
        if (@as(u8, @truncate(value)) == 0x10) {
            if (at > 0xf4) return error.InvalidPciCapabilities;
            const control: u16 = @truncate(try config.read(device.bdf, @as(u16, at) + 8));
            if (control & ((1 << 11) | (1 << 4)) != 0) return error.UnsupportedPcieOrdering;
            return;
        }
        at = @truncate(value >> 8);
    }
    return error.InvalidPciCapabilities;
}
fn efiMmio(info: *const protocol.BootInfo, range: protocol.PhysicalRange) !void {
    const raw = info.firmware_memory_map;
    const size = info.firmware_descriptor_size;
    if (raw.length == 0 or size < 40 or raw.length % size != 0 or raw.length / size > 4096 or !info.isMapped(raw) or raw.base < info.loader_reserved.base or try raw.endExclusive() > try info.loader_reserved.endExclusive()) return error.InvalidFirmwareMemoryMap;
    const bytes: [*]const volatile u8 = @ptrFromInt(raw.base);
    const end = try range.endExclusive();
    var cursor = range.base;
    // EFI maps need not be sorted. Every byte must be covered by MMIO type11;
    // ambiguous overlapping RAM descriptors are rejected, never overridden.
    for (0..4096) |_| {
        var next = cursor;
        var offset: u64 = 0;
        while (offset < raw.length) : (offset += size) {
            const b = bytes + @as(usize, @intCast(offset));
            const kind = le(b, 4);
            const base = le(b + 8, 8);
            const pages = le(b + 24, 8);
            const len = @mulWithOverflow(pages, @as(u64, 4096));
            const high = @addWithOverflow(base, len[0]);
            if (len[1] != 0 or high[1] != 0 or base % 4096 != 0) return error.InvalidFirmwareMemoryMap;
            if (len[0] == 0 or base >= end or high[0] <= range.base) continue;
            if (kind != 11) return error.FirmwareMmioAlias;
            if (base <= cursor and high[0] > cursor) next = @max(next, @min(end, high[0]));
        }
        if (next == cursor) return error.IncompleteFirmwareMmio;
        cursor = next;
        if (cursor == end) return;
    }
    return error.InvalidFirmwareMemoryMap;
}
fn le(bytes: [*]const volatile u8, length: usize) u64 {
    var value: u64 = 0;
    for (0..length) |i| value |= @as(u64, bytes[i]) << @intCast(i * 8);
    return value;
}
const Registers = struct { eax: u32, ebx: u32, ecx: u32, edx: u32 };
fn cpuid(leaf: u32, subleaf: u32) Registers {
    if (builtin.cpu.arch != .x86_64) unreachable;
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [a] "={eax}" (eax),
          [b] "={ebx}" (ebx),
          [c] "={ecx}" (ecx),
          [d] "={edx}" (edx),
        : [leaf] "{eax}" (leaf),
          [sub] "{ecx}" (subleaf),
        : .{ .memory = true });
    return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
}
fn msr(number: u32) u64 {
    if (builtin.cpu.arch != .x86_64) unreachable;
    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile ("rdmsr"
        : [lo] "={eax}" (low),
          [hi] "={edx}" (high),
        : [n] "{ecx}" (number),
    );
    return @as(u64, high) << 32 | low;
}
fn nativeMasked(_: *anyopaque) !void {
    return checkMasked();
}
fn checkMasked() !void {
    if (builtin.cpu.arch != .x86_64) return error.UnsupportedNativePlatform;
    const flags = asm volatile ("pushfq; popq %[flags]"
        : [flags] "=r" (-> u64),
    );
    if (flags & (1 << 9) != 0) return error.InterruptsMustBeMasked;
}
fn nativeSnapshot(_: *anyopaque, output: *Cpu) !void {
    if (builtin.cpu.arch != .x86_64) return error.UnsupportedNativePlatform;
    const basic = cpuid(0, 0).eax;
    const extended = cpuid(0x80000000, 0).eax;
    if (basic < 0x15 or extended < 0x80000008) return error.UnsupportedClock;
    const features = cpuid(1, 0);
    if (features.edx & ((1 << 4) | (1 << 12) | (1 << 16)) != ((1 << 4) | (1 << 12) | (1 << 16))) return error.UnsupportedCpuCache;
    const tsc = cpuid(0x15, 0);
    output.ratio = try clock.Ratio.init(cpuid(0x80000007, 0).edx & (1 << 8) != 0, tsc.eax, tsc.ebx, tsc.ecx);
    const cr4 = asm volatile ("movq %%cr4, %[value]"
        : [value] "=r" (-> u64),
    );
    if (cr4 & ((1 << 12) | (1 << 17) | (1 << 24)) != 0) return error.UnsupportedPagingMode;
    const cr3 = asm volatile ("movq %%cr3, %[value]"
        : [value] "=r" (-> u64),
    );
    if (cr3 & 4095 != 0) return error.UnsupportedPageTableCache;
    const cr0 = asm volatile ("movq %%cr0, %[value]"
        : [value] "=r" (-> u64),
    );
    if (cr0 & (1 << 31) == 0 or cr0 & ((1 << 30) | (1 << 29)) != 0) return error.UnsupportedCpuCache;
    const caps = msr(0xfe);
    const count: usize = @intCast(caps & 0xff);
    if (count > cache.max_variables) return error.UnsupportedMtrrCount;
    const default = msr(0x2ff);
    output.cache_policy = .{ .root = cr3 & ~@as(u64, 4095), .physical_bits = @truncate(cpuid(0x80000008, 0).eax), .pat = msr(0x277), .mtrr_enabled = default & (1 << 11) != 0, .default_type = try cache.cacheType(@truncate(default), false) };
    for (0..count) |i| try output.cache_policy.addMtrr(msr(0x200 + @as(u32, @intCast(i * 2))), msr(0x201 + @as(u32, @intCast(i * 2))));
}
fn nativeTable(_: *anyopaque, address: u64) !u64 {
    if (builtin.cpu.arch != .x86_64) return error.UnsupportedNativePlatform;
    if (address & 7 != 0) return error.InvalidPageTable;
    const pointer: *const volatile u64 = @ptrFromInt(address);
    return pointer.*;
}
fn nativeRoot(_: *anyopaque) !u64 {
    if (builtin.cpu.arch != .x86_64) return error.UnsupportedNativePlatform;
    const cr3 = asm volatile ("movq %%cr3, %[value]"
        : [value] "=r" (-> u64),
    );
    if (cr3 & 4095 != 0) return error.UnsupportedPageTableCache;
    return cr3;
}
fn nativeTsc(_: *anyopaque) !u64 {
    if (builtin.cpu.arch != .x86_64) return error.UnsupportedNativePlatform;
    var low: u32 = undefined;
    var high: u32 = undefined;
    asm volatile ("lfence; rdtsc; lfence"
        : [lo] "={eax}" (low),
          [hi] "={edx}" (high),
        :
        : .{ .memory = true });
    return @as(u64, high) << 32 | low;
}
fn nativeFence(_: *anyopaque) void {
    if (builtin.cpu.arch == .x86_64) asm volatile ("mfence" ::: .{ .memory = true });
}
test {
    _ = @import("x86_64_tests.zig");
    _ = cache;
    _ = clock;
}
