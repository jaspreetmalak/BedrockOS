//! Owned, polling-only MT7922 firmware transport. This stage never advertises
//! a usable radio. Platform clock, DMA mapping and cache maintenance are trusted
//! dependencies; no architecture-wide identity/coherency assumption is made.
const std = @import("std");
const protocol = @import("boot_protocol");
const memory = @import("memory_init");
const pci = @import("pci");
const resources = @import("resources.zig");
const mt = @import("mediatek/root.zig");
pub const data_api = @import("mt7922_data.zig");
pub const bar_span: u32 = 0x100000;
pub const ring_slots = 4;
pub const ring_count = 6;
pub const data_tx_ring = 4;
pub const data_rx_ring = 5;
pub const buffer_size = 8192;
const ring_stride = 4096 + ring_slots * buffer_size;
pub const allocation_size = ring_count * ring_stride;
pub fn ringBase(index: usize) !u32 {
    return switch (index) {
        0 => mt.regs.txRing(17),
        1 => mt.regs.txRing(16),
        2 => mt.regs.event_ring_base,
        3 => mt.regs.mcu_second_event_base,
        data_tx_ring => data_api.tx_ring_base,
        data_rx_ring => data_api.rx_ring_base,
        else => error.InvalidRing,
    };
}
pub fn ringDirection(index: usize) mt.dma.Direction {
    return if (index == 0 or index == 1 or index == data_tx_ring) .tx else .rx;
}
pub const State = enum { empty, prepared, activating, firmware_ready, reset_required, stopped };
pub const Firmware = struct {
    patch: []const u8,
    ram: []const u8,
    /// Only these intact files from the documented linux-firmware pin are
    /// accepted. Structural parsing alone cannot authorize a device download.
    pub fn validate(self: Firmware) !void {
        if (self.patch.len != 137632 or self.ram.len != 1231252) return error.WrongFirmware;
        const Sha256 = std.crypto.hash.sha2.Sha256;
        var digest: [32]u8 = undefined;
        Sha256.hash(self.patch, &digest, .{});
        if (!std.mem.eql(u8, &digest, &patch_sha256)) return error.WrongFirmware;
        Sha256.hash(self.ram, &digest, .{});
        if (!std.mem.eql(u8, &digest, &ram_sha256)) return error.WrongFirmware;
        _ = try mt.firmware.parsePatch(self.patch);
        const ram = try mt.firmware.parseRam(self.ram);
        if (ram.chip_id != 0x10) return error.WrongFirmware;
    }
};
fn digestBytes(comptime hex: []const u8) [32]u8 {
    var result: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&result, hex) catch @compileError("invalid pinned firmware hash");
    return result;
}
pub const patch_sha256 = digestBytes("7fc9075d6d54b31e0539734614ca971fa52caf41b642a3000c8a4501591a4d98");
pub const ram_sha256 = digestBytes("d100e5e04c324fc8da6302112d1e0b4fac952286447d2419eabcd8fb0a1f5b93");
pub const Platform = struct {
    context: *anyopaque,
    bar_address: u64,
    mmio: mt.Mmio,
    clock: mt.Clock,
    dma: mt.dma.Hooks,
    /// Borrow a CPU view of a retained lease, with its bus address equal to the
    /// lease physical address. An IOMMU/nonidentity platform needs another port.
    /// The returned view must cover the entire range and remain valid until free.
    mapDma: *const fn (*anyopaque, protocol.PhysicalRange) anyerror![]volatile u8,
};
/// The mapped aperture owner must remain in place for the complete transport
/// lifetime. Mmio.init performs the protected-RAM and mapped-coverage checks.
pub fn nativeMmio(aperture: *resources.Mmio) mt.Mmio {
    return .{ .context = aperture, .span = @intCast(aperture.range.length), .begin = resources.Mmio.begin, .end = resources.Mmio.end, .read32 = resources.Mmio.read, .write32 = resources.Mmio.write, .fence = resources.Mmio.fence };
}
pub const Transport = Owned(memory);
pub fn Owned(comptime Memory: type) type {
    return struct {
        const Self = @This();
        const Lease = resources.DmaLease(Memory);
        state: State = .empty,
        owner_address: usize = 0,
        config: pci.Config = undefined,
        device: pci.Device = undefined,
        original_command: u16 = 0,
        platform: Platform = undefined,
        lease: Lease = .{},
        driver: mt.Driver = undefined,
        buffers: [ring_count][ring_slots]mt.dma.Buffer = undefined,
        descriptors: [ring_count]mt.dma.Buffer = undefined,
        rings: [ring_count]mt.dma.Ring = undefined,
        channel: mt.mcu.DmaChannel = undefined,
        mcu: mt.Mcu = undefined,
        data: data_api.Path = .{},
        data_initialized: bool = false,
        cpu_view: []volatile u8 = &.{},
        command_changed: bool = false,
        quiescent: bool = false,
        initialized_rings: usize = 0,
        mcu_initialized: bool = false,
        active_io: usize = 0,
        stopping: bool = false,
        fn owner(self: *Self) !void {
            if (self.owner_address == 0 or self.owner_address != @intFromPtr(self)) return error.MovedTransport;
        }
        fn retireIo(self: *Self) void {
            if (self.data_initialized) self.data.retire() catch unreachable;
            if (self.mcu_initialized) self.mcu.stopped = true;
            for (self.rings[0..self.initialized_rings]) |*ring| ring.stopped = true;
        }
        fn validateIo(context: *anyopaque) !void {
            const self: *Self = @ptrCast(@alignCast(context));
            try self.owner();
            if (self.state != .activating and self.state != .firmware_ready) return error.DmaStopped;
            if (self.lease.released or self.lease.owner_address != @intFromPtr(&self.lease)) return error.InvalidDmaLease;
            const live = try Memory.resolveKernel(self.lease.ticket orelse return error.InvalidDmaLease);
            if (live.range.base != self.lease.range.base or live.range.length != self.lease.range.length) return error.InvalidDmaLease;
            try resources.checkDma32(live.range.base, live.range.length);
        }
        fn toDevice(context: *anyopaque, buffer: mt.dma.Buffer, length: usize) !void {
            const self = try beginIo(context);
            defer self.active_io -= 1;
            try self.platform.dma.toDevice(self.platform.dma.context, buffer, length);
        }
        fn fromDevice(context: *anyopaque, buffer: mt.dma.Buffer, length: usize) !void {
            const self = try beginIo(context);
            defer self.active_io -= 1;
            try self.platform.dma.fromDevice(self.platform.dma.context, buffer, length);
        }
        fn delayIo(context: *anyopaque, us: u32) !void {
            const self = try beginIo(context);
            defer self.active_io -= 1;
            try self.platform.dma.delayUs(self.platform.dma.context, us);
        }
        fn beginIo(context: *anyopaque) !*Self {
            try validateIo(context);
            const self: *Self = @ptrCast(@alignCast(context));
            if (self.active_io == std.math.maxInt(usize)) return error.TransportBusy;
            self.active_io += 1;
            return self;
        }
        /// Copies retain this owner's validating context. Validation precedes
        /// buffer access, so old Ring values cannot touch a recycled allocation.
        pub fn dmaHooks(self: *Self) mt.dma.Hooks {
            return .{ .context = self, .toDevice = toDevice, .fromDevice = fromDevice, .delayUs = delayIo, .validateLease = validateIo };
        }
        /// Prepare retained memory with read-only PCI checks. No config/MMIO
        /// writes, bus mastering or firmware execution take place here.
        pub fn prepare(self: *Self, config: pci.Config, device: pci.Device, platform: Platform) !void {
            if (self.state != .empty or self.owner_address != 0) return error.TransportAlreadyInitialized;
            if (device.class != 2 or device.subclass != 0x80 or !((device.vendor == 0x14c3 and (device.product == 0x0616 or device.product == 0x7922)) or (device.vendor == 0x0b48 and device.product == 0x7922))) return error.WrongDevice;
            if (platform.mmio.span != bar_span or platform.bar_address == 0 or platform.bar_address % 4096 != 0) return error.InvalidAperture;
            if (try config.read(device.bdf, 0) != @as(u32, device.vendor) | @as(u32, device.product) << 16) return error.DeviceChanged;
            if (try pci.memoryBar(config, device, 0) != platform.bar_address) return error.DeviceChanged;
            const command: u16 = @truncate(try config.read(device.bdf, 4));
            // Existing firmware DMA must not race allocation/clearing of RAM.
            // A separate platform takeover must quiesce an already active card.
            if (command & 4 != 0) return error.DeviceStillBusMastering;
            const registers = try mt.Registers.init(platform.mmio);
            self.config = config;
            self.device = device;
            self.original_command = command;
            self.platform = platform;
            self.driver = mt.Driver.init(registers, platform.clock);
            self.owner_address = @intFromPtr(self);
            self.lease.init(allocation_size, 4096) catch |err| {
                self.state = .stopped;
                return err;
            };
            self.prepareBuffers() catch |err| {
                self.lease.releaseUnexposed() catch {
                    self.state = .reset_required;
                    return error.ResourceCleanupFailed;
                };
                self.state = .stopped;
                return err;
            };
            self.state = .prepared;
        }
        fn prepareBuffers(self: *Self) !void {
            const view = try self.platform.mapDma(self.platform.context, self.lease.range);
            if (view.len != self.lease.range.length or view.len < allocation_size) return error.InvalidDmaMapping;
            self.cpu_view = view;
            // DMA is not enabled. Clear the complete borrowed allocation before
            // any descriptors or register bases can become device-visible.
            for (view) |*byte| byte.* = 0;
            for (0..ring_count) |i| {
                const offset = i * ring_stride;
                self.descriptors[i] = .{ .address = self.lease.range.base + offset, .bytes = view[offset..][0 .. ring_slots * 16] };
                for (0..ring_slots) |j| {
                    const at = offset + 4096 + j * buffer_size;
                    self.buffers[i][j] = .{ .address = self.lease.range.base + at, .bytes = view[at..][0..buffer_size] };
                }
            }
        }
        /// Caller owns this PCI function exclusively. Disable old bus mastering
        /// first, reset, publish all rings, then enable polling DMA and download.
        /// Failure retains memory; stop() must confirm quiescence before free.
        pub fn start(self: *Self, firmware: Firmware) !void {
            try self.owner();
            if (self.state != .prepared) return error.InvalidTransportState;
            try firmware.validate();
            // Revalidate the live generational lease before any hardware write.
            const live = try Memory.resolveKernel(self.lease.ticket orelse return error.InvalidDmaLease);
            if (live.range.base != self.lease.range.base or live.range.length != self.lease.range.length) return error.InvalidDmaLease;
            try resources.checkDma32(live.range.base, live.range.length);
            self.state = .activating;
            errdefer {
                self.retireIo();
                self.state = .reset_required;
            }
            const command = (self.original_command | @as(u16, 2 | 1024)) & ~@as(u16, 4);
            self.command_changed = true; // write/readback can fail after mutation
            try pci.writeCommand(self.config, self.device, command);
            try self.driver.driverOwn();
            try self.driver.reset();
            _ = try self.lease.publish();
            for (0..ring_count) |i| {
                self.rings[i] = try mt.dma.Ring.init(&self.driver.registers, .{ .register_base = try ringBase(i), .descriptors = self.descriptors[i], .buffers = &self.buffers[i], .direction = ringDirection(i) }, self.dmaHooks());
                self.initialized_rings += 1;
            }
            try self.data.init(&self.rings[data_tx_ring], &self.rings[data_rx_ring], &self.rings[3], 1);
            self.data_initialized = true;
            self.channel = .{ .wm = &self.rings[0], .fwdl = &self.rings[1], .event = &self.rings[2] };
            self.mcu.init(self.channel.channel());
            self.mcu_initialized = true;
            try pci.writeCommand(self.config, self.device, command | 4);
            try self.driver.configureDma(&self.rings[0], &self.rings[1], &self.rings[2]);
            try self.driver.loadFirmware(&self.mcu, firmware.patch, firmware.ram);
            // Linux mt7921 uses RX queue0 for boot-ROM replies and RX queue2
            // after firmware start. Both were posted before enabling DMA.
            self.channel.event = &self.rings[3];
            self.state = .firmware_ready;
        }
        fn dataReady(self: *Self, bytes: []const u8) !void {
            try self.owner();
            if (self.state != .firmware_ready or !self.data_initialized) return error.DataUnavailable;
            if (self.active_io != 0 or self.mcu.busy or self.stopping) return error.TransportBusy;
            const pointer = @intFromPtr(bytes.ptr);
            const owner_pointer = @intFromPtr(self);
            const dma_pointer = @intFromPtr(self.cpu_view.ptr);
            if (dataOverlap(pointer, bytes.len, owner_pointer, @sizeOf(Self)) or dataOverlap(pointer, bytes.len, dma_pointer, self.cpu_view.len)) return error.AliasedDataBuffer;
        }
        fn dataFailure(self: *Self) void {
            if (self.data.stopped) self.state = .reset_required;
        }
        /// Channel/MAC/association/security authority remains with the trusted
        /// caller. These methods submit real descriptors, not a readiness claim.
        pub fn sendManagement(self: *Self, frame: []const u8, options: data_api.TxOptions) !u16 {
            try self.dataReady(frame);
            return self.data.sendManagement(frame, options) catch |err| {
                self.dataFailure();
                return err;
            };
        }
        pub fn sendData(self: *Self, frame: []const u8, options: data_api.TxOptions) !u16 {
            try self.dataReady(frame);
            return self.data.sendData(frame, options) catch |err| {
                self.dataFailure();
                return err;
            };
        }
        pub fn pollData(self: *Self, output: []u8) !?data_api.Event {
            try self.dataReady(output);
            return self.data.pollData(output) catch |err| {
                self.dataFailure();
                return err;
            };
        }
        /// Serial caller must demultiplex asynchronous events before initiating
        /// the next synchronous MCU operation; the same RX queue is borrowed.
        pub fn pollEvent(self: *Self, output: []u8) !?data_api.Event {
            try self.dataReady(output);
            if (self.mcu.busy) return error.TransportBusy;
            return self.data.pollEvent(output) catch |err| {
                self.dataFailure();
                return err;
            };
        }
        /// NIC's serialized unsolicited-event callback may route its already
        /// copied packet while MCU waiting is active. No RX queue is read again.
        pub fn routeEvent(self: *Self, packet: []const u8) !data_api.Event {
            try self.owner();
            if (self.state != .firmware_ready or !self.data_initialized or self.stopping) return error.DataUnavailable;
            if (self.active_io != 0) return error.TransportBusy;
            const pointer = @intFromPtr(packet.ptr);
            if (dataOverlap(pointer, packet.len, @intFromPtr(self), @sizeOf(Self)) or dataOverlap(pointer, packet.len, @intFromPtr(self.cpu_view.ptr), self.cpu_view.len)) return error.AliasedDataBuffer;
            return self.data.route(packet) catch |err| {
                self.dataFailure();
                return err;
            };
        }
        /// An exclusive ownership handoff never restores a prior bus-master bit:
        /// the prior function's addresses may refer to memory this OS now owns.
        /// Failed stop/free leaves reset_required and the live owner retryable.
        pub fn stop(self: *Self) !void {
            try self.owner();
            if (self.state == .stopped) return;
            if (self.state == .empty) return error.InvalidTransportState;
            if (self.state == .activating or self.stopping or self.active_io != 0) return error.TransportBusy;
            // A retained channel/ring reference must not access recycled DMA
            // after stop, and a reentrant callback cannot free an active call.
            if (self.mcu_initialized and self.mcu.busy) return error.TransportBusy;
            if (self.data_initialized and self.data.busy) return error.TransportBusy;
            for (self.rings[0..self.initialized_rings]) |ring| if (ring.busy) return error.TransportBusy;
            self.stopping = true;
            defer self.stopping = false;
            self.retireIo();
            errdefer self.state = .reset_required;
            if (self.command_changed and !self.quiescent) {
                const command: u16 = @truncate(try self.config.read(self.device.bdf, 4));
                try pci.writeCommand(self.config, self.device, (command | 1024) & ~@as(u16, 4));
                try self.driver.stop();
                self.quiescent = true;
            }
            if (self.data_initialized and self.quiescent) try self.data.reclaimAfterQuiescence();
            if (!self.lease.released) {
                if (self.lease.exposed) {
                    if (!self.quiescent) return error.DmaStillExposed;
                    try self.lease.releaseAfterQuiescence();
                } else try self.lease.releaseUnexposed();
            }
            if (self.command_changed) try pci.writeCommand(self.config, self.device, self.original_command & ~@as(u16, 4));
            self.state = .stopped;
        }
    };
}
fn dataOverlap(a: usize, an: usize, b: usize, bn: usize) bool {
    if (an == 0 or bn == 0) return false;
    return if (a >= b) a - b < bn else b - a < an;
}

test "firmware transport rejects arbitrary or cross-family files before hardware work" {
    try std.testing.expectError(error.WrongFirmware, (Firmware{ .patch = &.{}, .ram = &.{} }).validate());
}
test {
    _ = @import("mt7922_transport_tests.zig");
}
