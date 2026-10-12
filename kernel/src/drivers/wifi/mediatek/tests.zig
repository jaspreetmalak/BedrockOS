// SPDX-License-Identifier: ISC
// Copyright (C) 2026 Bedrock contributors
const std = @import("std");
const t = std.testing;
const mt = @import("root.zig");
const w = @import("wire.zig");
const firmware = mt.firmware;
fn patchFixture() [164]u8 {
    var b: [164]u8 = @splat(0);
    w.putBe32(b[44..], 1);
    w.putBe32(b[96..], 0x40002);
    w.putBe32(b[100..], 160);
    w.putBe32(b[104..], 4);
    w.putBe32(b[108..], 0x900000);
    w.putBe32(b[112..], 4);
    w.putBe32(b[116..], 0x01000000);
    @memcpy(b[160..], "ABCD");
    return b;
}
fn ramFixture() [80]u8 {
    var b: [80]u8 = @splat(0);
    @memcpy(b[0..4], "RAM!");
    w.put32(b[20..], 0x91b000);
    w.put32(b[24..], 4);
    b[28] = 0x21;
    b[44] = 0x10;
    b[46] = 1;
    b[47] = 2;
    b[48] = 1;
    return b;
}
test "patch golden mixed-endian section and encrypted download mode" {
    const b = patchFixture();
    const image = try firmware.parsePatch(&b);
    const r = try image.region(0);
    try t.expectEqual(@as(u32, 0x900000), r.address);
    try t.expectEqualStrings("ABCD", r.data);
    try t.expectEqual(@as(u32, 0x80000009), r.download_mode);
    try t.expectError(error.InvalidRegion, image.region(1));
}
test "patch truncation table payload and source-region overlap are rejected" {
    var b = patchFixture();
    try t.expectError(error.InvalidFirmwareSize, firmware.parsePatch(b[0..40]));
    try t.expectError(error.TruncatedFirmware, firmware.parsePatch(b[0..163]));
    w.putBe32(b[100..], 159);
    try t.expectError(error.InvalidFirmwareRegion, firmware.parsePatch(&b));
    var two: [232]u8 = @splat(0);
    @memcpy(two[0..160], b[0..160]);
    w.putBe32(two[44..], 2);
    w.putBe32(two[100..], 224);
    @memcpy(two[160..224], two[96..160]);
    try t.expectError(error.OverlappingFirmwareRegions, firmware.parsePatch(&two));
}
test "patch target wrap unsupported section encryption and region count fail preflight" {
    var b = patchFixture();
    w.putBe32(b[108..], 0xfffffffe);
    try t.expectError(error.InvalidFirmwareAddress, firmware.parsePatch(&b));
    b = patchFixture();
    w.putBe32(b[96..], 3);
    try t.expectError(error.UnsupportedPatchSection, firmware.parsePatch(&b));
    b = patchFixture();
    w.putBe32(b[116..], 0x03000000);
    try t.expectError(error.UnsupportedEncryption, firmware.parsePatch(&b));
    b = patchFixture();
    w.putBe32(b[44..], 33);
    try t.expectError(error.InvalidRegionCount, firmware.parsePatch(&b));
}
test "RAM golden trailer and region lengths modes override flag" {
    const b = ramFixture();
    const image = try firmware.parseRam(&b);
    const r = try image.region(0);
    try t.expectEqual(@as(u8, 0x10), image.chip_id);
    try t.expectEqualStrings("RAM!", r.data);
    try t.expect(r.download);
    try t.expectEqual(@as(u32, 0x80000009), r.download_mode);
}
test "RAM preserves auxiliary metadata and exposes nondownload CLC" {
    const base = ramFixture();
    var b: [84]u8 = @splat(0);
    @memcpy(b[0..4], base[0..4]);
    @memcpy(b[4..8], "META");
    @memcpy(b[8..], base[4..]);
    b[32] = 0x40;
    b[33] = 2;
    w.put32(b[24..], 0);
    const image = try firmware.parseRam(&b);
    const r = try image.region(0);
    try t.expectEqualStrings("META", image.metadata);
    try t.expect(!r.download);
    try t.expectEqual(@as(u8, 2), r.kind);
}
test "RAM malformed length compression format and feature cannot cross footer" {
    var b = ramFixture();
    w.put32(b[24..], 5);
    try t.expectError(error.TruncatedFirmware, firmware.parseRam(&b));
    b = ramFixture();
    w.put32(b[8..], 4);
    try t.expectError(error.UnsupportedCompression, firmware.parseRam(&b));
    b = ramFixture();
    b[47] = 3;
    try t.expectError(error.UnsupportedFirmwareFormat, firmware.parseRam(&b));
    b = ramFixture();
    b[28] = 0x80;
    try t.expectError(error.UnsupportedFirmwareFeature, firmware.parseRam(&b));
}
const Replay = struct {
    const Entry = struct { offset: u32 = 0, value: u32 = 0 };
    entries: [96]Entry = @splat(.{}),
    count: usize = 0,
    locked: bool = false,
    begins: u32 = 0,
    ends: u32 = 0,
    writes: u32 = 0,
    fences: u32 = 0,
    bad_remap: bool = false,
    fail_write: bool = false,
    delay_total: u64 = 0,
    complete_tx: bool = false,
    ownership_success: bool = false,
    lease_live: bool = true,
    lease_checks: u32 = 0,
    synchronizations: u32 = 0,
    tx_base: u32 = 0,
    desc: []volatile u8 = &.{},
    tx_slot: usize = 0,
    fn cast(p: *anyopaque) *Replay {
        return @ptrCast(@alignCast(p));
    }
    fn entry(self: *Replay, offset: u32) *Entry {
        for (self.entries[0..self.count]) |*e| if (e.offset == offset) return e;
        std.debug.assert(self.count < self.entries.len);
        const i = self.count;
        self.count += 1;
        self.entries[i] = .{ .offset = offset };
        return &self.entries[i];
    }
    fn begin(p: *anyopaque) !void {
        const self = cast(p);
        if (self.locked) return error.AlreadyLocked;
        self.locked = true;
        self.begins += 1;
    }
    fn end(p: *anyopaque) void {
        const self = cast(p);
        std.debug.assert(self.locked);
        self.locked = false;
        self.ends += 1;
    }
    fn read(p: *anyopaque, o: u32) !u32 {
        const self = cast(p);
        std.debug.assert(self.locked);
        const value = self.entry(o).value;
        return if (self.bad_remap and o == mt.regs.remap_l1) value ^ 1 else value;
    }
    fn write(p: *anyopaque, o: u32, v: u32) !void {
        const self = cast(p);
        std.debug.assert(self.locked);
        if (self.fail_write) return error.InjectedIO;
        self.entry(o).value = v;
        if (self.ownership_success and o == 0xe0010) self.entry(o).value = if (v == 1) 4 else if (v == 2) 0 else v;
        self.writes += 1;
        if (self.complete_tx and o == self.tx_base + 8 and self.desc.len > 0) {
            const off = self.tx_slot * 16 + 4;
            self.desc[off + 3] |= 0x80;
            self.entry(self.tx_base + 12).value = v;
        }
    }
    fn fence(p: *anyopaque) void {
        cast(p).fences += 1;
    }
    fn delay(p: *anyopaque, us: u32) !void {
        cast(p).delay_total += us;
    }
    fn sync(p: *anyopaque, _: mt.dma.Buffer, _: usize) !void {
        cast(p).synchronizations += 1;
    }
    fn validateLease(p: *anyopaque) !void {
        const self = cast(p);
        self.lease_checks += 1;
        if (!self.lease_live) return error.RetiredDmaLease;
    }
    fn provider(self: *Replay) mt.Mmio {
        return .{ .context = self, .span = 0x100000, .begin = begin, .end = end, .read32 = read, .write32 = write, .fence = fence };
    }
    fn hooks(self: *Replay) mt.dma.Hooks {
        return .{ .context = self, .toDevice = sync, .fromDevice = sync, .delayUs = delay };
    }
    fn leasedHooks(self: *Replay) mt.dma.Hooks {
        var result = self.hooks();
        result.validateLease = validateLease;
        return result;
    }
};
test "fixed register remap golden addresses and one-past boundary" {
    try t.expectEqual(@as(?u32, 0x31000), try mt.registers.fixedOffset(0x820d1000));
    try t.expectEqual(@as(?u32, 0x24800), try mt.registers.fixedOffset(0x820ed000));
    try t.expectEqual(@as(?u32, 0xd4208), try mt.registers.fixedOffset(0xd4208));
    try t.expectEqual(@as(?u32, null), try mt.registers.fixedOffset(0x820e0000 + 0x100000));
    try t.expectError(error.UnalignedRegister, mt.registers.fixedOffset(3));
}
test "dynamic remap preserves upper bits readbacks and locks target access" {
    var replay: Replay = .{};
    replay.entry(mt.regs.remap_l1).value = 0xabcd1111;
    replay.entry(0x40010).value = 0x12345678;
    var regs = try mt.Registers.init(replay.provider());
    try t.expectEqual(@as(u32, 0x12345678), try regs.read(0x18060010));
    try t.expectEqual(@as(u32, 0xabcd1806), replay.entry(mt.regs.remap_l1).value);
    try t.expectEqual(@as(u32, 1), replay.begins);
    try t.expectEqual(replay.begins, replay.ends);
    try t.expect(!replay.locked);
    try regs.write(0x70010200, 7);
    try t.expectEqual(@as(u32, 7), replay.entry(0x40200).value);
}
test "remap failure unsupported addresses and IO failures unlock safely" {
    var replay: Replay = .{};
    var regs = try mt.Registers.init(replay.provider());
    replay.bad_remap = true;
    try t.expectError(error.RemapFailed, regs.read(0x18060010));
    replay.bad_remap = false;
    try t.expectError(error.UnsupportedRegister, regs.read(0x50000000));
    replay.fail_write = true;
    try t.expectError(error.InjectedIO, regs.write(0x200, 1));
    try t.expect(!regs.busy and !replay.locked);
    try t.expectEqual(replay.begins, replay.ends);
}
test "register update masks bits and rejects values outside mask" {
    var replay: Replay = .{};
    var regs = try mt.Registers.init(replay.provider());
    replay.entry(0x200).value = 0xabcdef00;
    try t.expectEqual(@as(u32, 0xabcdef05), try regs.update(0x200, 0xff, 5));
    try t.expectError(error.InvalidRegisterValue, regs.update(0x200, 1, 2));
}
test "DMA descriptor golden little endian layout and length/address checks" {
    const d = try mt.dma.Descriptor.transmit(0x12345678, 0x1234);
    const b = d.encode();
    try t.expectEqualSlices(u8, &.{ 0x78, 0x56, 0x34, 0x12, 0, 0, 0x34, 0x52, 0, 0, 0, 0, 0, 0, 0, 0 }, &b);
    try t.expectEqual(d, try mt.dma.Descriptor.decode(&b));
    try t.expectError(error.InvalidDmaAddress, mt.dma.Descriptor.transmit(0x100000000, 1));
    try t.expectError(error.InvalidDmaAddress, mt.dma.Descriptor.transmit(0xfffffff0, 32));
    try t.expectError(error.InvalidDmaLength, mt.dma.Descriptor.transmit(0x1000, 16384));
}
const RingMemory = struct {
    desc: [64]u8 = @splat(0),
    payload: [4][64]u8 = @splat(@splat(0)),
    buffers: [4]mt.dma.Buffer = undefined,
    fn config(self: *RingMemory, direction: mt.dma.Direction, base: u32) mt.dma.Config {
        for (&self.buffers, 0..) |*b, i| b.* = .{ .address = 0x2000 + i * 0x1000, .bytes = &self.payload[i] };
        return .{ .register_base = base, .descriptors = .{ .address = 0x1000, .bytes = &self.desc }, .buffers = &self.buffers, .direction = direction };
    }
};
test "DMA ring validates all ranges before any hardware publication" {
    var replay: Replay = .{};
    var regs = try mt.Registers.init(replay.provider());
    var memory: RingMemory = .{};
    const c = memory.config(.tx, 0xd4410);
    memory.buffers[1].address = memory.buffers[0].address;
    try t.expectError(error.InvalidDmaBuffers, mt.dma.Ring.init(&regs, c, replay.hooks()));
    try t.expectEqual(@as(u32, 0), replay.writes);
}
test "DMA retired lease blocks initialization before descriptor writes or hooks" {
    var replay: Replay = .{ .lease_live = false };
    var regs = try mt.Registers.init(replay.provider());
    var memory: RingMemory = .{};
    @memset(&memory.desc, 0xa5);
    for (&memory.payload) |*buffer| @memset(buffer, 0x5a);
    const config = memory.config(.tx, 0xd4410);
    try t.expectError(error.RetiredDmaLease, mt.dma.Ring.init(&regs, config, replay.leasedHooks()));
    for (memory.desc) |b| try t.expectEqual(@as(u8, 0xa5), b);
    for (memory.payload) |buffer| for (buffer) |b| try t.expectEqual(@as(u8, 0x5a), b);
    try t.expectEqual(@as(u32, 0), replay.writes);
    try t.expectEqual(@as(u32, 0), replay.synchronizations);
}
test "DMA copied TX and RX rings reject retired leases before recycled RAM access" {
    inline for (.{ mt.dma.Direction.tx, mt.dma.Direction.rx }) |direction| {
        var replay: Replay = .{};
        var regs = try mt.Registers.init(replay.provider());
        var memory: RingMemory = .{};
        var original = try mt.dma.Ring.init(&regs, memory.config(direction, if (direction == .tx) 0xd4410 else 0xd4500), replay.leasedHooks());
        var copied = original;
        original.stopped = true;
        replay.lease_live = false;
        // Model the allocator assigning these same bytes to an unrelated owner.
        @memset(&memory.desc, 0xa5);
        for (&memory.payload) |*buffer| @memset(buffer, 0x5a);
        const writes = replay.writes;
        const synchronizations = replay.synchronizations;
        if (direction == .tx) {
            try t.expectError(error.RetiredDmaLease, copied.send("must not overwrite replacement owner", 3));
        } else {
            var output: [64]u8 = @splat(0xcc);
            try t.expectError(error.RetiredDmaLease, copied.receive(&output));
            for (output) |b| try t.expectEqual(@as(u8, 0xcc), b);
        }
        for (memory.desc) |b| try t.expectEqual(@as(u8, 0xa5), b);
        for (memory.payload) |buffer| for (buffer) |b| try t.expectEqual(@as(u8, 0x5a), b);
        try t.expectEqual(writes, replay.writes);
        try t.expectEqual(synchronizations, replay.synchronizations);
    }
}
test "DMA TX requires actual descriptor completion and stops on timeout" {
    var replay: Replay = .{};
    var regs = try mt.Registers.init(replay.provider());
    var memory: RingMemory = .{};
    var ring = try mt.dma.Ring.init(&regs, memory.config(.tx, 0xd4410), replay.hooks());
    replay.tx_base = 0xd4410;
    replay.desc = &memory.desc;
    replay.complete_tx = true;
    try ring.send("PACKET", 3);
    try t.expectEqualStrings("PACKET", memory.payload[0][0..6]);
    try t.expectEqual(@as(usize, 1), ring.head);
    replay.complete_tx = false;
    try t.expectError(error.DmaTimeout, ring.send("second", 3));
    try t.expect(ring.stopped);
    try t.expectError(error.DmaStopped, ring.send("third", 3));
}
test "DMA RX short output retains completion then repost rotates safely" {
    var replay: Replay = .{};
    var regs = try mt.Registers.init(replay.provider());
    var memory: RingMemory = .{};
    var ring = try mt.dma.Ring.init(&regs, memory.config(.rx, 0xd4500), replay.hooks());
    @memcpy(memory.payload[0][0..4], "RXD!");
    const d = (mt.dma.Descriptor{ .buf0 = 0x2000, .ctrl = mt.dma.done | mt.dma.last | (4 << 16) }).encode();
    @memcpy(memory.desc[0..16], &d);
    var small: [3]u8 = @splat(0xff);
    try t.expectError(error.OutputTooSmall, ring.receive(&small));
    try t.expectEqual(@as(usize, 0), ring.tail);
    try t.expectEqualSlices(u8, &.{ 0xff, 0xff, 0xff }, &small);
    var output: [8]u8 = undefined;
    try t.expectEqual(@as(?usize, 4), try ring.receive(&output));
    try t.expectEqualStrings("RXD!", output[0..4]);
    try t.expectEqual(@as(usize, 1), ring.tail);
    try t.expectEqual(@as(u32, 3), replay.entry(0xd4508).value);
}
test "DMA RX foreign buffer and oversized completion stop before copy" {
    var replay: Replay = .{};
    var regs = try mt.Registers.init(replay.provider());
    var memory: RingMemory = .{};
    var ring = try mt.dma.Ring.init(&regs, memory.config(.rx, 0xd4500), replay.hooks());
    const d = (mt.dma.Descriptor{ .buf0 = 0x3000, .ctrl = mt.dma.done | mt.dma.last | (4 << 16) }).encode();
    @memcpy(memory.desc[0..16], &d);
    var output: [8]u8 = @splat(0xaa);
    try t.expectError(error.InvalidDmaCompletion, ring.receive(&output));
    try t.expect(ring.stopped);
    for (output) |b| try t.expectEqual(@as(u8, 0xaa), b);
}
fn event(command: mt.mcu.Command, seq: u8, status: u8) [36]u8 {
    var b: [36]u8 = @splat(0);
    w.put32(&b, (7 << 27) | 36);
    w.put16(b[24..], 12);
    b[28] = if (command == .patch_semaphore) 4 else 1;
    b[29] = seq;
    b[32] = status;
    return b;
}
test "MCU command golden TXD and boot ROM status offsets" {
    var b: [76]u8 = undefined;
    const packet = try mt.mcu.encode(.target, 3, &.{ 1, 2, 3, 4 }, &b);
    try t.expectEqual(@as(usize, 68), packet.len);
    try t.expectEqual(@as(u32, 0x41000044), w.le32(packet));
    try t.expectEqual(@as(u32, 0x80010000), w.le32(packet[4..]));
    try t.expectEqualSlices(u8, &.{ 36, 0, 0, 128, 1, 160, 3, 3 }, packet[32..40]);
    const response = event(.patch_semaphore, 3, 2);
    try t.expectEqual(@as(?u8, 2), try mt.mcu.response(&response, .patch_semaphore, 3));
    try t.expectEqual(@as(?u8, null), try mt.mcu.response(&response, .patch_semaphore, 4));
}
test "MCU malformed length sequence and matching unexpected event fail" {
    var b = event(.start, 1, 0);
    try t.expectError(error.MalformedMcuResponse, mt.mcu.response(b[0..35], .start, 1));
    w.put16(b[24..], 13);
    try t.expectError(error.MalformedMcuResponse, mt.mcu.response(&b, .start, 1));
    b = event(.start, 1, 0);
    b[28] = 4;
    try t.expectError(error.UnexpectedMcuEvent, mt.mcu.response(&b, .start, 1));
    var out: [64]u8 = undefined;
    try t.expectError(error.InvalidMcuSequence, mt.mcu.encode(.start, 0, &.{}, &out));
}
const McuReplay = struct {
    commands: [32]mt.mcu.Command = undefined,
    count: usize = 0,
    scatter_bytes: usize = 0,
    last_command: mt.mcu.Command = .target,
    last_seq: u8 = 0,
    last_ce: u8 = 0,
    waiting: bool = false,
    semaphore_acquired: bool = false,
    fail_scatter: bool = false,
    no_response: bool = false,
    delays: u32 = 0,
    fn cast(p: *anyopaque) *McuReplay {
        return @ptrCast(@alignCast(p));
    }
    fn submit(p: *anyopaque, queue: mt.mcu.Queue, bytes: []const u8) !void {
        const self = cast(p);
        if (queue == .fwdl) {
            if (self.fail_scatter) return error.InjectedIO;
            self.scatter_bytes += bytes.len;
            return;
        }
        try t.expect(bytes.len >= 64);
        if (bytes[38] == 1) {
            self.last_ce = bytes[36];
            return;
        }
        self.last_command = @fromBackingInt(@intCast(bytes[36]));
        self.last_seq = bytes[39];
        self.waiting = true;
        self.commands[self.count] = self.last_command;
        self.count += 1;
        if (self.last_command == .patch_semaphore) self.semaphore_acquired = w.le32(bytes[64..]) == 1;
    }
    fn receive(p: *anyopaque, out: []u8) !?usize {
        const self = cast(p);
        if (!self.waiting or self.no_response) return null;
        self.waiting = false;
        const status: u8 = if (self.last_command == .patch_semaphore) (if (self.semaphore_acquired) 2 else 3) else 0;
        const b = event(self.last_command, self.last_seq, status);
        @memcpy(out[0..36], &b);
        return 36;
    }
    fn delay(p: *anyopaque, _: u32) !void {
        cast(p).delays += 1;
    }
    fn channel(self: *McuReplay) mt.mcu.Channel {
        return .{ .context = self, .submit = submit, .receive = receive, .delayUs = delay };
    }
};
test "MCU actual patch download handshake and RAM start order" {
    var replay: McuReplay = .{};
    var mcu: mt.Mcu = undefined;
    mcu.init(replay.channel());
    const p = patchFixture();
    const f = ramFixture();
    try mcu.loadPatch(try firmware.parsePatch(&p));
    try mcu.loadRam(try firmware.parseRam(&f));
    try t.expectEqualSlices(mt.mcu.Command, &.{ .patch_semaphore, .patch_start, .patch_finish, .patch_semaphore, .target, .start }, replay.commands[0..replay.count]);
    try t.expectEqual(@as(usize, 8), replay.scatter_bytes);
    try t.expect(!mcu.stopped);
}
test "MCU scatter error stops with no unsafe release submission" {
    var replay: McuReplay = .{ .fail_scatter = true };
    var mcu: mt.Mcu = undefined;
    mcu.init(replay.channel());
    const p = patchFixture();
    try t.expectError(error.InjectedIO, mcu.loadPatch(try firmware.parsePatch(&p)));
    try t.expect(mcu.stopped);
    try t.expectEqual(@as(usize, 2), replay.count);
    try t.expectError(error.McuStopped, mcu.request(.start, &.{}));
}
test "MCU response timeout is bounded and stops further sends" {
    var replay: McuReplay = .{ .no_response = true };
    var mcu: mt.Mcu = undefined;
    mcu.init(replay.channel());
    try t.expectError(error.McuTimeout, mcu.request(.start, &.{}));
    try t.expectEqual(@as(u32, 3000), replay.delays);
    try t.expectError(error.McuStopped, mcu.request(.start, &.{}));
    try t.expectEqual(@as(usize, 1), replay.count);
}
test "driver rejects wrong chip and cannot claim firmware ready on timeout" {
    var replay: Replay = .{};
    var driver = mt.Driver.init(try mt.Registers.init(replay.provider()), .{ .context = &replay, .delayUs = Replay.delay });
    try t.expectError(error.InvalidDriverState, driver.reset());
    replay.entry(0x40200).value = 0x7961;
    try t.expectError(error.WrongChip, driver.identify());
    try t.expectError(error.DeviceTimeout, driver.driverOwn());
    try t.expectEqual(@import("driver.zig").State.failed, driver.state);
}
test "driver staged power reset firmware proof and DMA stop use actual registers" {
    var replay: Replay = .{ .ownership_success = true };
    replay.entry(0x40200).value = 0x7922;
    replay.entry(0x40204).value = 0x82;
    replay.entry(0x40140).value = 0x11;
    var driver = mt.Driver.init(try mt.Registers.init(replay.provider()), .{ .context = &replay, .delayUs = Replay.delay });
    try driver.driverOwn();
    try t.expectEqual(@as(u16, 0x7922), driver.snapshot().identity.?.chip);
    try driver.reset();
    try t.expectEqual(@import("driver.zig").State.reset, driver.state);
    try t.expect(replay.delay_total >= 50000);
    var memories: [3]RingMemory = @splat(.{});
    var rings: [3]mt.dma.Ring = undefined;
    const bases = [_]u32{ 0xd4410, 0xd4400, 0xd4500 };
    for (&rings, 0..) |*ring, i| {
        var config = memories[i].config(if (i == 2) .rx else .tx, bases[i]);
        config.descriptors.address += i * 0x5000;
        for (memories[i].buffers[0..]) |*b| b.address += i * 0x5000;
        ring.* = try mt.dma.Ring.init(&driver.registers, config, replay.hooks());
    }
    try driver.configureDma(&rings[0], &rings[1], &rings[2]);
    try t.expectEqual(@import("driver.zig").State.dma_ready, driver.state);
    var channel: McuReplay = .{};
    var mcu: mt.Mcu = undefined;
    mcu.init(channel.channel());
    const p = patchFixture();
    const f = ramFixture();
    replay.entry(0xe00f0).value = 3;
    try driver.loadFirmware(&mcu, &p, &f);
    try t.expectEqual(@import("driver.zig").State.firmware_ready, driver.state);
    try driver.stop();
    try t.expectEqual(@import("driver.zig").State.stopped, driver.state);
    try t.expect(replay.entry(mt.regs.global_config).value & (mt.regs.tx_enable | mt.regs.rx_enable) == 0);
}
fn managementFixture() [74]u8 {
    var b: [74]u8 = @splat(0);
    w.put32(&b, (2 << 27) | b.len);
    w.put32(b[4..], 1 << 13);
    w.put32(b[12..], 36 << 8);
    w.put32(b[28..], 0x64646464);
    const frame = b[32..];
    w.put16(frame, 0x80);
    @memset(frame[4..10], 0xff);
    @memcpy(frame[10..16], &[_]u8{ 2, 3, 4, 5, 6, 7 });
    @memcpy(frame[16..22], &[_]u8{ 2, 3, 4, 5, 6, 7 });
    w.put16(frame[22..], 0x1230);
    @memcpy(frame[36..], &[_]u8{ 0, 4, 'T', 'E', 'S', 'T' });
    return b;
}
test "MAC actual RX groups produce borrowed IEEE beacon BSSID channel and RCPI" {
    const b = managementFixture();
    const info = try mt.mac.management(&b, 3);
    try t.expectEqual(@as(u16, 36), info.channel);
    try t.expectEqual(mt.mac.Band.ghz5, info.band);
    try t.expectEqual(@as(?i16, -60), info.signal_dbm);
    try t.expectEqualSlices(u8, &.{ 2, 3, 4, 5, 6, 7 }, &info.bssid);
    try t.expectEqualStrings("TEST", info.frame[38..]);
}
test "MAC management rejects FCS translated truncated group and unsupported order" {
    var b = managementFixture();
    w.put32(b[4..], (1 << 13) | (1 << 27));
    try t.expectError(error.BadRxFrame, mt.mac.management(&b, 3));
    b = managementFixture();
    w.put32(b[8..], 1 << 13);
    try t.expectError(error.HeaderTranslated, mt.mac.management(&b, 3));
    b = managementFixture();
    w.put32(b[4..], (1 << 13) | (1 << 15));
    try t.expectError(error.TruncatedRxDescriptor, mt.mac.management(&b, 3));
    b = managementFixture();
    w.put16(b[32..], 0x8080);
    try t.expectError(error.UnsupportedManagementFrame, mt.mac.management(&b, 3));
    try t.expectError(error.InvalidAntennaMask, mt.mac.management(&b, 0));
}
test "MAC RX packet length and 6GHz channel encoding are checked" {
    var b = managementFixture();
    w.put32(b[12..], 181 << 8);
    try t.expectEqual(@as(u16, 1), (try mt.mac.management(&b, 1)).channel);
    w.put32(b[12..], 240 << 8);
    try t.expectError(error.InvalidRxChannel, mt.mac.management(&b, 1));
    w.put32(&b, (2 << 27) | 75);
    try t.expectError(error.InvalidRxLength, mt.mac.management(&b, 1));
}
test "MAC TXWI and hardware TXP golden fields keep payload separately DMA owned" {
    const rx = managementFixture();
    var out: [64]u8 = undefined;
    const packet = try mt.mac.transmit(rx[32..], 0x4000, .{ .token = 7, .wlan_index = 19, .fixed_rate = 0x4b }, &out);
    try t.expectEqual(@as(u32, 0x2000004a), w.le32(packet));
    try t.expectEqual(@as(u32, 0x80026013), w.le32(packet[4..]));
    try t.expectEqual(@as(u32, 0x80002408), w.le32(packet[8..]));
    try t.expectEqual(@as(u32, 0x9123f801), w.le32(packet[12..]));
    try t.expectEqual(@as(u16, 0x8007), w.le16(packet[32..]));
    try t.expectEqual(@as(u32, 0x4000), w.le32(packet[40..]));
    try t.expectEqual(@as(u16, 0x802a), w.le16(packet[44..]));
}
test "MAC TX rejects protected frame high DMA and invalid token before writes" {
    var frame = managementFixture();
    var output: [64]u8 = @splat(0xaa);
    w.put16(frame[32..], 0x4080);
    try t.expectError(error.UnsupportedTxFrame, mt.mac.transmit(frame[32..], 0x4000, .{ .token = 1, .wlan_index = 0, .fixed_rate = 0 }, &output));
    for (output) |value| try t.expectEqual(@as(u8, 0xaa), value);
    frame = managementFixture();
    try t.expectError(error.InvalidDmaAddress, mt.mac.transmit(frame[32..], 0x100000000, .{ .token = 1, .wlan_index = 0, .fixed_rate = 0 }, &output));
    try t.expectError(error.InvalidTxOptions, mt.mac.transmit(frame[32..], 0x4000, .{ .token = 0x8000, .wlan_index = 0, .fixed_rate = 0 }, &output));
}
fn stationEapolFixture() [131]u8 {
    var frame: [131]u8 = @splat(0);
    w.put16(&frame, 0x0108); // unencrypted non-QoS Data, ToDS=1
    @memcpy(frame[4..10], &[_]u8{ 2, 0x11, 0x22, 0x33, 0x44, 0x55 }); // receiver/AP
    @memcpy(frame[10..16], &[_]u8{ 2, 0xaa, 0xbb, 0xcc, 0xdd, 0xee }); // transmitting station
    @memcpy(frame[16..22], frame[4..10]); // MSDU destination/authenticator
    w.put16(frame[22..], 0x3210);
    @memcpy(frame[24..32], &[_]u8{ 0xaa, 0xaa, 3, 0, 0, 0, 0x88, 0x8e }); // LLC/SNAP EAPOL
    @memcpy(frame[32..39], &[_]u8{ 2, 3, 0, 95, 2, 1, 0x0a }); // opaque synthetic key body
    frame[40] = 16;
    frame[48] = 1;
    @memset(frame[49..81], 1);
    return frame;
}
test "MAC ToDS station EAPOL golden TXWI retains24byte header and payload" {
    const frame = stationEapolFixture();
    const expected = frame;
    var out: [64]u8 = undefined;
    const encoded = try mt.mac.transmit(&frame, 0x87650000, .{ .token = 9, .wlan_index = 3, .fixed_rate = 0x4b }, &out);
    try t.expectEqual(@as(u32, 0x200000a3), w.le32(encoded));
    try t.expectEqual(@as(u32, 0x80026003), w.le32(encoded[4..]));
    try t.expectEqual(@as(u32, 0x80002020), w.le32(encoded[8..]));
    try t.expectEqual(@as(u32, 0x93217800), w.le32(encoded[12..]));
    try t.expectEqual(@as(u32, 0x00200000), w.le32(encoded[28..]));
    try t.expectEqual(@as(u16, 0x8009), w.le16(encoded[32..]));
    try t.expectEqual(@as(u32, 0x87650000), w.le32(encoded[40..]));
    try t.expectEqual(@as(u16, 0x8083), w.le16(encoded[44..]));
    try t.expectEqualSlices(u8, &expected, &frame);
    try t.expectEqualSlices(u8, &.{ 0x88, 0x8e }, frame[30..32]);
}
test "MAC station TX rejects FromDS WDS QoS fragmentation protection and invalid management DS atomically" {
    var frame = stationEapolFixture();
    var out: [64]u8 = @splat(0xaa);
    const unsupported = [_]u16{ 0x0208, 0x0308, 0x0188, 0x0508, 0x4108, 0x8108, 0x0180 };
    for (unsupported) |fc| {
        w.put16(&frame, fc);
        try t.expectError(error.UnsupportedTxFrame, mt.mac.transmit(&frame, 0x4000, .{ .token = 1, .wlan_index = 0, .fixed_rate = 0 }, &out));
        for (out) |value| try t.expectEqual(@as(u8, 0xaa), value);
    }
    frame = stationEapolFixture();
    w.put16(frame[22..], 0x3211);
    try t.expectError(error.UnsupportedTxFrame, mt.mac.transmit(&frame, 0x4000, .{ .token = 1, .wlan_index = 0, .fixed_rate = 0 }, &out));
    try t.expectError(error.InvalidTxFrame, mt.mac.transmit(frame[0..23], 0x4000, .{ .token = 1, .wlan_index = 0, .fixed_rate = 0 }, &out));
}
test "MAC TX_FREE pair records and duplicate token completion are bounded" {
    var b: [16]u8 = @splat(0);
    w.put32(&b, (6 << 27) | (1 << 16) | 16);
    w.put32(b[8..], (1 << 31) | (19 << 14));
    w.put32(b[12..], (7 << 16) | (1 << 13) | 2);
    const freed = try mt.mac.transmitFree(&b);
    try t.expectEqual(@as(usize, 1), freed.count);
    try t.expectEqual(@as(u16, 7), freed.entries[0].token);
    try t.expectEqual(@as(u8, 1), freed.entries[0].status);
    w.put32(&b, (6 << 27) | (2 << 16) | 16);
    w.put32(b[8..], 7 << 16);
    w.put32(b[12..], 7 << 16);
    try t.expectError(error.DuplicateTxCompletion, mt.mac.transmitFree(&b));
    w.put32(&b, (6 << 27) | (3 << 16) | 16);
    w.put32(b[12..], 8 << 16);
    try t.expectError(error.TruncatedRxDescriptor, mt.mac.transmitFree(&b));
}
test "scan request golden packed1186B CE layout and explicit channels" {
    var output: [1186]u8 = undefined;
    const request = try mt.scan.encode(.{ .sequence = 7, .bss_index = 2, .active = true, .channels = &.{ .{ .band = .ghz2, .number = 1 }, .{ .band = .ghz5, .number = 36 } }, .ssids = &.{"TEST"}, .ies = &.{ 1, 1, 2 } }, &output);
    try t.expectEqualSlices(u8, &.{ 7, 2, 1, 4, 1, 2, 32, 1 }, request[0..8]);
    try t.expectEqual(@as(u32, 4), w.le32(request[8..]));
    try t.expectEqualSlices(u8, &.{ 4, 2, 1, 1, 2, 36 }, request[158..164]);
    try t.expectEqual(@as(u16, 3), w.le16(request[224..]));
    try t.expectEqual(@as(u8, 1), request[1185]);
    var command: [1250]u8 = undefined;
    const encoded = try mt.mcu.encodeRaw(mt.scan.start_command, 1, true, request, &command);
    try t.expectEqual(@as(u8, 1), encoded[38]);
    try t.expectEqual(@as(usize, 1250), encoded.len);
}
test "scan malformed channel IE and duplicate fail without changing output" {
    var output: [1186]u8 = @splat(0xaa);
    try t.expectError(error.InvalidScanChannel, mt.scan.encode(.{ .sequence = 1, .channels = &.{.{ .band = .ghz2, .number = 0 }} }, &output));
    try t.expectError(error.DuplicateScanChannel, mt.scan.encode(.{ .sequence = 1, .channels = &.{ .{ .band = .ghz2, .number = 1 }, .{ .band = .ghz2, .number = 1 } } }, &output));
    try t.expectError(error.InvalidScanInformationElements, mt.scan.encode(.{ .sequence = 1, .channels = &.{.{ .band = .ghz2, .number = 1 }}, .ies = &.{ 1, 2, 3 } }, &output));
    for (output) |value| try t.expectEqual(@as(u8, 0xaa), value);
}
fn scanDone(sequence: u8) [384]u8 {
    var b: [384]u8 = @splat(0);
    w.put32(&b, (7 << 27) | 384);
    w.put16(b[24..], 360);
    b[28] = 0x0d;
    b[36] = sequence;
    b[40] = 2;
    b[42] = 1;
    w.put32(b[44..], 12);
    return b;
}
test "scan completion matches operation and rejects malformed channel counts" {
    var b = scanDone(7);
    const done = try mt.scan.completion(&b, 7);
    try t.expectEqual(@as(u32, 12), done.beacons);
    try t.expectEqual(@as(u8, 2), done.completed_channels);
    try t.expectError(error.StaleScanCompletion, mt.scan.completion(&b, 8));
    b[40] = 65;
    try t.expectError(error.InvalidScanCompletion, mt.scan.completion(&b, 7));
    b = scanDone(7);
    try t.expectError(error.InvalidRxLength, mt.scan.completion(b[0..383], 7));
}
test "scan session publishes real CE packet and never reuses exhausted sequence" {
    var replay: McuReplay = .{};
    var mcu: mt.Mcu = undefined;
    mcu.init(replay.channel());
    var session: mt.scan.Session = .{};
    try t.expectEqual(@as(u8, 1), try session.start(&mcu, .{ .sequence = 1, .channels = &.{.{ .band = .ghz2, .number = 1 }} }));
    try t.expectEqual(mt.scan.start_command, replay.last_ce);
    try t.expectError(error.ScanBusy, session.start(&mcu, .{ .sequence = 1, .channels = &.{.{ .band = .ghz2, .number = 1 }} }));
    const done = scanDone(1);
    _ = try session.completed(&done);
    try t.expectEqual(@as(?u8, null), session.active);
    session.sequence.issued = 127;
    try t.expectError(error.ScanSequenceExhausted, session.start(&mcu, .{ .sequence = 1, .channels = &.{.{ .band = .ghz2, .number = 1 }} }));
}
