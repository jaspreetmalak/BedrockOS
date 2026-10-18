const std = @import("std");
const t = std.testing;
const data = @import("mt7922_data.zig");
const mt = @import("mediatek/root.zig");
const w = @import("mediatek/wire.zig");
const stride = 4096 + data.max_pending * 8192;
const Fixture = struct {
    // Native synthetic NIC register/descriptor traces, never a production
    // completion source or a claim that physical DMA/ACKs were observed.
    arena: [3 * stride]u8 = undefined,
    buffers: [3][data.max_pending]mt.dma.Buffer = undefined,
    rings: [3]mt.dma.Ring = undefined,
    registers: mt.Registers = undefined,
    path: data.Path = .{},
    live: bool = true,
    auto_consume: bool = false,
    hardware_index: u32 = 0,
    reads: usize = 0,
    writes: usize = 0,
    maintenance: usize = 0,
    reenter: bool = false,
    denied_retire: usize = 0,
    fn cast(context: *anyopaque) *Fixture {
        return @ptrCast(@alignCast(context));
    }
    fn begin(_: *anyopaque) !void {}
    fn end(_: *anyopaque) void {}
    fn fence(_: *anyopaque) void {}
    fn read(context: *anyopaque, address: u32) !u32 {
        const self = cast(context);
        self.reads += 1;
        return if (address == data.tx_ring_base + 12) self.hardware_index else 0;
    }
    fn write(context: *anyopaque, address: u32, value: u32) !void {
        const self = cast(context);
        self.writes += 1;
        if (address == data.tx_ring_base + 8 and self.auto_consume) {
            self.hardware_index = value;
            const index = (value + data.max_pending - 1) % data.max_pending;
            const offset = index * 16;
            const descriptor = self.arena[offset..][0..16];
            w.put32(descriptor[4..], w.le32(descriptor[4..]) | mt.dma.done);
        }
    }
    fn validate(context: *anyopaque) !void {
        if (!cast(context).live) return error.StaleAllocation;
    }
    fn maintain(context: *anyopaque, _: mt.dma.Buffer, _: usize) !void {
        const self = cast(context);
        self.maintenance += 1;
        if (self.reenter) {
            self.path.retire() catch |err| {
                if (err != error.DataBusy) return err;
                self.denied_retire += 1;
                return;
            };
            return error.RetiredActiveData;
        }
    }
    fn delay(_: *anyopaque, _: u32) !void {}
    fn init(self: *Fixture) !void {
        self.* = .{};
        @memset(&self.arena, 0);
        self.registers = try mt.Registers.init(.{ .context = self, .span = 0x100000, .begin = begin, .end = end, .read32 = read, .write32 = write, .fence = fence });
        const hooks: mt.dma.Hooks = .{ .context = self, .validateLease = validate, .toDevice = maintain, .fromDevice = maintain, .delayUs = delay };
        for (0..3) |i| {
            const base = i * stride;
            for (0..data.max_pending) |j| {
                const offset = base + 4096 + j * 8192;
                self.buffers[i][j] = .{ .address = 0x100000 + offset, .bytes = self.arena[offset..][0..8192] };
            }
            self.rings[i] = try mt.dma.Ring.init(&self.registers, .{ .register_base = ([_]u32{ data.tx_ring_base, data.rx_ring_base, data.event_ring_base })[i], .descriptors = .{ .address = 0x100000 + base, .bytes = self.arena[base..][0 .. data.max_pending * 16] }, .buffers = &self.buffers[i], .direction = if (i == 0) .tx else .rx }, hooks);
        }
        try self.path.init(&self.rings[0], &self.rings[1], &self.rings[2], 1);
    }
    fn inject(self: *Fixture, ring_index: usize, packet: []const u8) !void {
        const ring = &self.rings[ring_index];
        const index = ring.tail;
        const buffer = ring.config.buffers[index];
        for (packet, 0..) |byte, i| buffer.bytes[i] = byte;
        var descriptor = try mt.dma.Descriptor.receive(buffer.address, packet.len);
        descriptor.ctrl |= mt.dma.done | mt.dma.last;
        const encoded = descriptor.encode();
        for (encoded, 0..) |byte, i| ring.config.descriptors.bytes[index * 16 + i] = byte;
    }
};
fn frame(protected: bool) [48]u8 {
    var bytes: [48]u8 = @splat(0);
    w.put16(&bytes, if (protected) 0x4108 else 0x0108);
    bytes[4] = 2;
    bytes[10] = 2;
    bytes[16] = 2;
    @memset(bytes[24..], 0x5a);
    return bytes;
}
const options: data.TxOptions = .{ .wlan_index = 1, .fixed_rate = 0x4b, .polls = 2 };
fn completion(tokens: []const u16, output: []u8) []const u8 {
    const bytes = output[0 .. 8 + tokens.len * 4];
    @memset(bytes, 0);
    w.put32(bytes, @as(u32, 6 << 27) | @as(u32, @intCast(tokens.len)) << 16 | @as(u32, @intCast(bytes.len)));
    for (tokens, 0..) |token, index| w.put32(bytes[8 + index * 4 ..], @as(u32, token) << 16 | 1);
    return bytes;
}
test "data DMA consumption retains TXWI and payload until exact TX_FREE" {
    var fixture: Fixture = undefined;
    try fixture.init();
    fixture.auto_consume = true;
    const input = frame(false);
    const token = try fixture.path.sendData(&input, options);
    try t.expectEqual(@as(u16, 1), token);
    try t.expectEqual(@as(usize, 1), try fixture.path.outstanding());
    try t.expectEqualSlices(u8, &input, fixture.arena[4096 + 64 ..][0..input.len]);
    try t.expectEqual(@as(u32, 0x101040), w.le32(fixture.arena[4096 + 40 ..]));
    var raw: [16]u8 = undefined;
    try fixture.inject(2, completion(&.{token}, &raw));
    var output: [64]u8 = undefined;
    const event = (try fixture.path.pollEvent(&output)).?;
    try t.expectEqual(@as(usize, 1), event.tx_free.count);
    try t.expectEqual(token, event.tx_free.entries[0].token);
    try t.expectEqual(@as(usize, 0), try fixture.path.outstanding());
}
test "pending payloads apply bounded backpressure and never reuse wire tokens" {
    var fixture: Fixture = undefined;
    try fixture.init();
    fixture.auto_consume = true;
    const input = frame(false);
    for (1..5) |token| try t.expectEqual(@as(u16, @intCast(token)), try fixture.path.sendData(&input, options));
    const writes = fixture.writes;
    try t.expectError(error.WouldBlock, fixture.path.sendData(&input, options));
    try t.expectEqual(writes, fixture.writes);
    var raw: [16]u8 = undefined;
    try fixture.inject(1, completion(&.{1}, &raw));
    var output: [64]u8 = undefined;
    _ = try fixture.path.pollData(&output);
    try t.expectEqual(@as(u16, 5), try fixture.path.sendData(&input, options));
    fixture.path.issued = 0x7fff;
    try t.expectError(error.TxTokenExhausted, fixture.path.sendData(&input, options));
}
test "mixed stale duplicate and malformed TX_FREE batches never partially release" {
    var fixture: Fixture = undefined;
    try fixture.init();
    fixture.auto_consume = true;
    const input = frame(false);
    _ = try fixture.path.sendData(&input, options);
    _ = try fixture.path.sendData(&input, options);
    var raw: [16]u8 = undefined;
    var output: [64]u8 = undefined;
    try fixture.inject(2, completion(&.{ 1, 99 }, &raw));
    try t.expectError(error.StaleTxFree, fixture.path.pollEvent(&output));
    try t.expectEqual(@as(usize, 2), try fixture.path.outstanding());
    try fixture.inject(2, completion(&.{ 1, 1 }, &raw));
    try t.expectError(error.DuplicateTxCompletion, fixture.path.pollEvent(&output));
    try t.expectEqual(@as(usize, 2), try fixture.path.outstanding());
    try fixture.inject(2, completion(&.{ 1, 2 }, &raw));
    _ = try fixture.path.pollEvent(&output);
    try t.expectEqual(@as(usize, 0), try fixture.path.outstanding());
    try fixture.inject(2, completion(&.{1}, &raw));
    try t.expectError(error.StaleTxFree, fixture.path.pollEvent(&output));
}
test "timeout quarantines retained payload until stopped quiescent reclaim" {
    var fixture: Fixture = undefined;
    try fixture.init();
    const input = frame(false);
    try t.expectError(error.DmaTimeout, fixture.path.sendData(&input, options));
    try t.expectEqual(@as(usize, 1), try fixture.path.outstanding());
    try t.expect(fixture.path.stopped and !fixture.path.pending[0].consumed);
    try t.expectError(error.DataStopped, fixture.path.sendData(&input, options));
    try fixture.path.reclaimAfterQuiescence();
    try t.expectEqual(@as(usize, 0), try fixture.path.outstanding());
    try t.expectEqual(@as(u16, 1), fixture.path.issued);
}
test "unconsumed TX_FREE cannot reclaim submitted DMA ownership" {
    var fixture: Fixture = undefined;
    try fixture.init();
    fixture.path.pending[0] = .{ .token = 7 }; // Synthetic pre-DDONE boundary.
    var raw: [16]u8 = undefined;
    try fixture.inject(2, completion(&.{7}, &raw));
    var output: [64]u8 = undefined;
    try t.expectError(error.UnconsumedTxFree, fixture.path.pollEvent(&output));
    try t.expectEqual(@as(usize, 1), try fixture.path.outstanding());
}
test "data copy stale lease aliases and reentrant retirement cannot touch DMA" {
    var fixture: Fixture = undefined;
    try fixture.init();
    fixture.auto_consume = true;
    const input = frame(false);
    var copy = fixture.path;
    try t.expectError(error.MovedDataPath, copy.sendData(&input, options));
    try t.expectError(error.MovedDataPath, copy.retire());
    const payload: []const u8 = fixture.arena[4096..][0..48];
    try t.expectError(error.AliasedDataInput, fixture.path.sendData(payload, options));
    try t.expectError(error.AliasedDataOutput, fixture.path.pollData(fixture.arena[0..64]));
    fixture.reenter = true;
    _ = try fixture.path.sendData(&input, options);
    try t.expect(fixture.denied_retire != 0 and !fixture.path.stopped);
    fixture.reenter = false;
    fixture.live = false;
    const before = fixture.arena;
    const writes = fixture.writes;
    try t.expectError(error.StaleAllocation, fixture.path.sendData(&input, options));
    try t.expectEqual(writes, fixture.writes);
    try t.expectEqualSlices(u8, &before, &fixture.arena);
}
test "raw RX and MCU events copy into caller storage and short output preserves packet" {
    var fixture: Fixture = undefined;
    try fixture.init();
    var packet: [72]u8 = @splat(0);
    w.put32(&packet, (2 << 27) | packet.len);
    w.put32(packet[12..], 1 << 8);
    const plain = frame(false);
    @memcpy(packet[24..], &plain);
    w.put16(packet[24..], 0x0208);
    try fixture.inject(1, &packet);
    var short: [16]u8 = @splat(0xaa);
    try t.expectError(error.OutputTooSmall, fixture.path.pollData(&short));
    try t.expectEqual(@as(usize, 0), fixture.rings[1].tail);
    for (short) |byte| try t.expectEqual(@as(u8, 0xaa), byte);
    var output: [128]u8 = undefined;
    const event = (try fixture.path.pollData(&output)).?;
    try t.expectEqual(@as(u16, 1), event.frame.channel);
    try t.expectEqual(@intFromPtr(output[24..].ptr), @intFromPtr(event.frame.frame.ptr));
    var mcu: [36]u8 = @splat(0);
    w.put32(&mcu, (7 << 27) | mcu.len);
    try fixture.inject(2, &mcu);
    try t.expectEqual(@as(usize, 36), (try fixture.path.pollEvent(&output)).?.event.len);
}
test "software CCMP ciphertext uses retained payload with hardware cipher bit clear" {
    var fixture: Fixture = undefined;
    try fixture.init();
    fixture.auto_consume = true;
    const input = frame(true);
    var software = options;
    software.software_encrypted = true;
    _ = try fixture.path.sendData(&input, software);
    try t.expectEqual(@as(u32, 0), w.le32(fixture.arena[4096 + 12 ..]) & 2);
    try t.expectEqualSlices(u8, &input, fixture.arena[4096 + 64 ..][0..input.len]);
    var packet: [72]u8 = @splat(0);
    w.put32(&packet, (2 << 27) | packet.len);
    w.put32(packet[12..], 1 << 8);
    @memcpy(packet[24..], &input);
    w.put16(packet[24..], 0x4208);
    try fixture.inject(1, &packet);
    var output: [128]u8 = undefined;
    const raw = (try fixture.path.pollData(&output)).?.frame;
    try t.expectEqual(@as(u16, 0x4208), w.le16(raw.frame));
    try t.expectEqualSlices(u8, input[24..], raw.frame[24..]);
    w.put32(packet[4..], 4 << 16); // Hardware decryption/stripped IV is inadmissible.
    try t.expectError(error.HardwareDecryptedFrame, mt.mac.raw(&packet, 1));
    try fixture.inject(1, &packet);
    try t.expectEqual(@as(usize, packet.len), (try fixture.path.pollData(&output)).?.other.len);
}
fn statusPacket(pid: u8, wcid: u16, sequence: u16, errors: u32) [40]u8 {
    var bytes: [40]u8 = @splat(0);
    w.put32(&bytes, bytes.len); // PKT_TYPE_TXS=0
    w.put32(bytes[8..], errors | (1 << 15));
    w.put32(bytes[12..], @as(u32, sequence) << 20);
    w.put32(bytes[16..], @as(u32, wcid) << 16);
    w.put32(bytes[20..], @as(u32, pid) << 24);
    return bytes;
}
test "TXS correlation proves ACK separately and survives earlier TX_FREE" {
    var fixture: Fixture = undefined;
    try fixture.init();
    fixture.auto_consume = true;
    const input = frame(false);
    var requested = options;
    requested.request_status = true;
    const token = try fixture.path.sendData(&input, requested);
    try t.expectEqual(@as(u32, 3 | (1 << 10)), w.le32(fixture.arena[4096 + 20 ..]));
    var raw: [16]u8 = undefined;
    const tail_before = fixture.rings[2].tail;
    const release = try fixture.path.route(completion(&.{token}, &raw));
    try t.expectEqual(@as(u8, 0), release.tx_free.entries[0].status);
    try t.expectEqual(tail_before, fixture.rings[2].tail); // Already-received event, no second dequeue.
    try t.expectEqual(@as(usize, 0), try fixture.path.outstanding());
    var wrong = statusPacket(3, 2, 0, 0);
    try t.expectError(error.StaleTxStatus, fixture.path.route(&wrong));
    wrong = statusPacket(3, 1, 1, 0);
    try t.expectError(error.StaleTxStatus, fixture.path.route(&wrong));
    const acknowledged = statusPacket(3, 1, 0, 0);
    const proof = (try fixture.path.route(&acknowledged)).tx_status.entries[0];
    try t.expect(proof.acknowledged and proof.token == token);
    try t.expectError(error.StaleTxStatus, fixture.path.route(&acknowledged));
    _ = try fixture.path.sendData(&input, requested);
    const failed = statusPacket(4, 1, 0, 1 << 16);
    const failed_proof = (try fixture.path.route(&failed)).tx_status.entries[0];
    try t.expect(!failed_proof.acknowledged and failed_proof.error_bits == 1 << 16);
    try t.expectEqual(@as(usize, 1), try fixture.path.outstanding()); // TXS is not payload-release authority.
}
test "TXS malformed duplicate PPDU and exhausted PID reject without new publication" {
    var fixture: Fixture = undefined;
    try fixture.init();
    fixture.auto_consume = true;
    const input = frame(false);
    var requested = options;
    requested.request_status = true;
    _ = try fixture.path.sendData(&input, requested);
    const ppdu = statusPacket(3, 1, 0, 2 << 23);
    try t.expectError(error.UnsupportedTxStatus, fixture.path.route(&ppdu));
    var duplicate: [72]u8 = @splat(0);
    const valid = statusPacket(3, 1, 0, 0);
    w.put32(&duplicate, duplicate.len);
    @memcpy(duplicate[8..40], valid[8..40]);
    @memcpy(duplicate[40..72], valid[8..40]);
    try t.expectError(error.DuplicateTxStatus, fixture.path.route(&duplicate));
    try t.expect(fixture.path.statuses[3].active);
    fixture.path.issued_pid = 255;
    const writes = fixture.writes;
    const issued = fixture.path.issued;
    try t.expectError(error.TxStatusIdExhausted, fixture.path.sendData(&input, requested));
    try t.expectEqual(writes, fixture.writes);
    try t.expectEqual(issued, fixture.path.issued);
}
test "data initialization rejects virtual aliases and DMA-owned control metadata before pinning" {
    var fixture: Fixture = undefined;
    try fixture.init();
    var control_storage: [8192]u8 align(@alignOf(data.Path)) = @splat(0);
    const replacement: *data.Path = @ptrCast(&control_storage);
    const original = fixture.buffers[0][0];
    // Different physical identities do not make one shared CPU view safe.
    fixture.buffers[0][0].bytes = fixture.rings[0].config.descriptors.bytes.ptr[0..8192];
    try t.expectError(error.AliasedDataRing, replacement.init(&fixture.rings[0], &fixture.rings[1], &fixture.rings[2], 1));
    try t.expectEqual(@as(usize, 0), replacement.owner_address);
    fixture.buffers[0][0] = original;
    fixture.buffers[0][0].bytes = &control_storage;
    try t.expectError(error.AliasedDataControl, replacement.init(&fixture.rings[0], &fixture.rings[1], &fixture.rings[2], 1));
    try t.expectEqual(@as(usize, 0), replacement.owner_address);
    fixture.buffers[0][0] = original;
    fixture.rings[1].config.descriptors.bytes = std.mem.asBytes(&fixture.rings[0]).ptr[0..64];
    try t.expectError(error.AliasedDataControl, replacement.init(&fixture.rings[0], &fixture.rings[1], &fixture.rings[2], 1));
    try t.expectEqual(@as(usize, 0), replacement.owner_address);
}
test "bad FCS and unsupported normal MPDUs are bounded drops without retiring live DMA" {
    var fixture: Fixture = undefined;
    try fixture.init();
    var packet: [72]u8 = @splat(0);
    w.put32(&packet, (2 << 27) | packet.len);
    w.put32(packet[4..], 1 << 27); // Hardware FCS rejection.
    w.put32(packet[12..], 1 << 8);
    const input = frame(false);
    @memcpy(packet[24..], &input);
    w.put16(packet[24..], 0x0208);
    var output: [128]u8 = undefined;
    try t.expectError(error.BadRxFrame, mt.mac.raw(&packet, 1));
    try fixture.inject(1, &packet);
    try t.expectEqual(@as(usize, packet.len), (try fixture.path.pollData(&output)).?.other.len);
    try t.expect(!fixture.path.stopped and fixture.live);
    w.put32(packet[4..], 0);
    w.put16(packet[24..], 0x0288); // QoS is outside the profile, not device loss.
    try fixture.inject(1, &packet);
    try t.expectEqual(@as(usize, packet.len), (try fixture.path.pollData(&output)).?.other.len);
    try t.expect(!fixture.path.stopped);
    w.put32(&packet, (2 << 27) | 100); // Corrupt DMA envelope remains fatal to caller.
    try fixture.inject(1, &packet);
    try t.expectError(error.InvalidRxLength, fixture.path.pollData(&output));
}
