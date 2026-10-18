//! Original CCMP-128 wire protection and bounded station Ethernet bridge.
//! Input excludes radio metadata/FCS. No DMA, association or RF readiness.
const std = @import("std");
const secrets = @import("wpa2.zig");
const Ccm = std.crypto.aead.aes_ccm.Aes128Ccm8;
comptime {
    if (std.options.side_channels_mitigations == .none) @compileError("CCMP requires Zig AES side-channel mitigations");
}
pub const header_length = 24;
pub const ccmp_header_length = 8;
pub const mic_length = 8;
pub const max_payload = 2304;
pub const max_frame = header_length + ccmp_header_length + max_payload + mic_length;
pub const max_ethernet = 1514;
pub const max_pn: u64 = 0xffff_ffff_ffff;
pub const max_key_history = 16;
pub const Error = error{
    InvalidLength,
    UnsupportedHeader,
    InvalidAddress,
    InvalidPacketNumber,
    InvalidCcmpHeader,
    BufferTooSmall,
    BufferOverlap,
    AuthenticationFailed,
    UnsupportedProtocol,
    InvalidSnap,
    InvalidOwner,
    AlreadyInitialized,
    NotInitialized,
    InvalidKey,
    StaleEpoch,
    KeyReuse,
    KeyHistoryCapacity,
    PeerMismatch,
    KeyMismatch,
    ReplayDetected,
    PacketNumberExhausted,
};
pub const Direction = enum { direct, to_ds, from_ds };
pub const DataHeader = struct {
    direction: Direction,
    receiver: [6]u8,
    transmitter: [6]u8,
    address3: [6]u8,
    sequence: u12 = 0,
    duration: u16 = 0,
    retry: bool = false,
    power_mgmt: bool = false,
    more_data: bool = false,
};
pub const Opened = struct { header: DataHeader, pn: u64, key_id: u2, length: usize };
pub const Packet = struct { header: DataHeader, pn: u64, key_id: u2, ciphertext: []const u8, mic: [8]u8 };
fn unicast(address: [6]u8) bool {
    return address[0] & 1 == 0 and !std.mem.allEqual(u8, &address, 0);
}
fn addressValid(address: [6]u8) bool {
    return !std.mem.allEqual(u8, &address, 0);
}
fn equal(a: [6]u8, b: [6]u8) bool {
    return std.mem.eql(u8, &a, &b);
}
fn validateHeader(header: DataHeader) Error!void {
    if (!unicast(header.transmitter) or !addressValid(header.receiver) or !addressValid(header.address3)) return error.InvalidAddress;
    if (header.direction == .to_ds and !unicast(header.receiver)) return error.InvalidAddress;
    if (header.direction == .from_ds and !unicast(header.address3)) return error.InvalidAddress;
}
fn fc(header: DataHeader) u16 {
    return 0x4008 | @as(u16, switch (header.direction) {
        .direct => 0,
        .to_ds => 0x100,
        .from_ds => 0x200,
    }) |
        (if (header.retry) @as(u16, 0x800) else 0) |
        (if (header.power_mgmt) @as(u16, 0x1000) else 0) |
        (if (header.more_data) @as(u16, 0x2000) else 0);
}
/// Non-QoS data only: no fragments, A4/WDS, HT-control, null/CF frames or A-MSDU.
pub fn parseHeader(frame: []const u8) Error!DataHeader {
    if (frame.len < header_length) return error.InvalidLength;
    const control = std.mem.readInt(u16, frame[0..2], .little);
    if (control & 0x00ff != 0x08 or control & 0x4000 == 0 or control & 0x8400 != 0 or control & 0x300 == 0x300) return error.UnsupportedHeader;
    const sc = std.mem.readInt(u16, frame[22..24], .little);
    if (sc & 0xf != 0) return error.UnsupportedHeader;
    const header: DataHeader = .{
        .direction = switch (control & 0x300) {
            0 => .direct,
            0x100 => .to_ds,
            0x200 => .from_ds,
            else => unreachable,
        },
        .receiver = frame[4..10].*,
        .transmitter = frame[10..16].*,
        .address3 = frame[16..22].*,
        .sequence = @intCast(sc >> 4),
        .duration = std.mem.readInt(u16, frame[2..4], .little),
        .retry = control & 0x800 != 0,
        .power_mgmt = control & 0x1000 != 0,
        .more_data = control & 0x2000 != 0,
    };
    try validateHeader(header);
    return header;
}
fn writeHeader(header: DataHeader, output: *[24]u8) void {
    std.mem.writeInt(u16, output[0..2], fc(header), .little);
    std.mem.writeInt(u16, output[2..4], header.duration, .little);
    @memcpy(output[4..10], &header.receiver);
    @memcpy(output[10..16], &header.transmitter);
    @memcpy(output[16..22], &header.address3);
    std.mem.writeInt(u16, output[22..24], @as(u16, header.sequence) << 4, .little);
}
/// Priority is zero; PN is most-significant-byte first in the nonce.
pub fn nonce(header: DataHeader, pn: u64) Error![13]u8 {
    try validateHeader(header);
    if (pn == 0 or pn > max_pn) return error.InvalidPacketNumber;
    var result: [13]u8 = undefined;
    result[0] = 0;
    @memcpy(result[1..7], &header.transmitter);
    std.mem.writeInt(u48, result[7..13], @intCast(pn), .big);
    return result;
}
/// CCM supplies its own AAD length prefix. Duration/sequence and mutable FC
/// Retry/PwrMgt/MoreData bits are excluded, as required by the CCMP format.
pub fn aad(header: DataHeader) Error![22]u8 {
    try validateHeader(header);
    var result: [22]u8 = undefined;
    std.mem.writeInt(u16, result[0..2], fc(header) & ~@as(u16, 0x3870), .little);
    @memcpy(result[2..8], &header.receiver);
    @memcpy(result[8..14], &header.transmitter);
    @memcpy(result[14..20], &header.address3);
    result[20] = 0;
    result[21] = 0;
    return result;
}
fn separate(output: []u8, input: []const u8) Error!void {
    if (output.len == 0 or input.len == 0) return;
    const a = @intFromPtr(output.ptr);
    const b = @intFromPtr(input.ptr);
    const ae = @addWithOverflow(a, output.len);
    const be = @addWithOverflow(b, input.len);
    if (ae[1] != 0 or be[1] != 0 or (a < be[0] and b < ae[0])) return error.BufferOverlap;
}
pub fn parsePacket(frame: []const u8) Error!Packet {
    if (frame.len < header_length + ccmp_header_length + mic_length or frame.len > max_frame) return error.InvalidLength;
    const header = try parseHeader(frame);
    const iv = frame[24..32];
    if (iv[2] != 0 or iv[3] & 0x3f != 0x20) return error.InvalidCcmpHeader;
    const pn = @as(u64, iv[0]) | (@as(u64, iv[1]) << 8) | (@as(u64, iv[4]) << 16) |
        (@as(u64, iv[5]) << 24) | (@as(u64, iv[6]) << 32) | (@as(u64, iv[7]) << 40);
    if (pn == 0) return error.InvalidPacketNumber;
    return .{ .header = header, .pn = pn, .key_id = @intCast(iv[3] >> 6), .ciphertext = frame[32 .. frame.len - 8], .mic = frame[frame.len - 8 ..][0..8].* };
}
/// Pure primitive: caller MUST own a unique PN for this key/A2. No replay ledger.
/// output is a full MPDU without FCS. Preflight errors leave output unchanged.
pub fn seal(key: *const [16]u8, header: DataHeader, pn: u64, key_id: u2, plaintext: []const u8, output: []u8) Error!usize {
    if (plaintext.len > max_payload) return error.InvalidLength;
    const n = try nonce(header, pn);
    const associated = try aad(header);
    const length = header_length + ccmp_header_length + plaintext.len + mic_length;
    if (output.len < length) return error.BufferTooSmall;
    try separate(output, plaintext);
    try separate(output, key);
    var copy = key.*;
    defer secrets.clear(&copy);
    var tag: [8]u8 = undefined;
    defer secrets.clear(&tag);
    writeHeader(header, output[0..24]);
    const iv = output[24..32];
    iv[0] = @truncate(pn);
    iv[1] = @truncate(pn >> 8);
    iv[2] = 0;
    iv[3] = 0x20 | (@as(u8, key_id) << 6);
    for (4..8) |i| iv[i] = @truncate(pn >> @as(u6, @intCast((i - 2) * 8)));
    Ccm.encrypt(output[32..][0..plaintext.len], &tag, plaintext, &associated, n, copy);
    @memcpy(output[length - 8 ..][0..8], &tag);
    return length;
}
/// No plaintext is copied to output before CCM authentication succeeds.
/// Pure primitive has no replay policy; Station owns that policy separately.
pub fn open(key: *const [16]u8, frame: []const u8, output: []u8) Error!Opened {
    const packet = try parsePacket(frame);
    if (output.len < packet.ciphertext.len) return error.BufferTooSmall;
    try separate(output, frame);
    try separate(output, key);
    var plaintext: [max_payload]u8 = undefined;
    defer secrets.clear(&plaintext);
    var copy = key.*;
    defer secrets.clear(&copy);
    const n = try nonce(packet.header, packet.pn);
    const associated = try aad(packet.header);
    Ccm.decrypt(plaintext[0..packet.ciphertext.len], packet.ciphertext, packet.mic, &associated, n, copy) catch return error.AuthenticationFailed;
    @memcpy(output[0..packet.ciphertext.len], plaintext[0..packet.ciphertext.len]);
    return .{ .header = packet.header, .pn = packet.pn, .key_id = packet.key_id, .length = packet.ciphertext.len };
}
const snap = [_]u8{ 0xaa, 0xaa, 0x03, 0, 0, 0 };
fn protocol(value: u16) Error!void {
    // AARP/IPX require a different bridge-tunnel encapsulation. EAPOL belongs
    // solely to the pinned handshake path, never to the protected data bridge.
    if (value < 0x600 or value == 0x888e or value == 0x80f3 or value == 0x8137) return error.UnsupportedProtocol;
}
fn ethernetHeader(ethernet: []const u8) Error!void {
    if (ethernet.len < 14 or ethernet.len > max_ethernet) return error.InvalidLength;
    if (!addressValid(ethernet[0..6].*) or !unicast(ethernet[6..12].*)) return error.InvalidAddress;
    try protocol(std.mem.readInt(u16, ethernet[12..14], .big));
}
/// Convert Ethernet II to RFC1042 SNAP MSDU (addresses are in DataHeader).
pub fn encodeEthernet(ethernet: []const u8, output: []u8) Error!usize {
    try ethernetHeader(ethernet);
    const length = ethernet.len - 6;
    if (output.len < length) return error.BufferTooSmall;
    try separate(output, ethernet);
    @memcpy(output[0..6], &snap);
    @memcpy(output[6..length], ethernet[12..]);
    return length;
}
pub fn decodeEthernet(header: DataHeader, plaintext: []const u8, output: []u8) Error!usize {
    try validateHeader(header);
    if (header.direction == .direct) return error.UnsupportedHeader;
    if (plaintext.len < 8 or plaintext.len > max_ethernet - 6) return error.InvalidLength;
    if (!std.mem.eql(u8, plaintext[0..6], &snap)) return error.InvalidSnap;
    try protocol(std.mem.readInt(u16, plaintext[6..8], .big));
    const length = plaintext.len + 6;
    if (output.len < length) return error.BufferTooSmall;
    try separate(output, plaintext);
    const destination = if (header.direction == .to_ds) header.address3 else header.receiver;
    const source = if (header.direction == .to_ds) header.transmitter else header.address3;
    @memcpy(output[0..6], &destination);
    @memcpy(output[6..12], &source);
    @memcpy(output[12..length], plaintext[6..]);
    return length;
}
pub const GroupKey = struct { id: u2, key: *const [16]u8, rx_pn: u64 = 0 };
pub const Config = struct {
    peer: [6]u8,
    station: [6]u8,
    epoch: u64,
    pairwise: *const [16]u8,
    pairwise_rx_pn: u64 = 0,
    group: ?GroupKey = null,
};
const Role = enum { pairwise, group };
const Ledger = struct { digest: [32]u8 = @splat(0), role: Role = .pairwise, peer: [6]u8 = @splat(0), rx_pn: u64 = 0 };
/// Trusted serialized in-place owner. Do not move/copy or reset with `.{}'
/// after initialization. Clear wipes keys but retains epoch/PN/key history.
/// Fresh owners require genuinely fresh keys; durable key/counter restore is
/// a backend responsibility. Eight to sixteen rekeys fit the bounded ledger.
pub const Station = struct {
    owner_address: usize = 0,
    active: bool = false,
    peer: [6]u8 = @splat(0),
    station: [6]u8 = @splat(0),
    epoch: u64 = 0,
    tx_pn: u64 = 0,
    pairwise_key: [16]u8 = @splat(0),
    group_key: [16]u8 = @splat(0),
    group_id: ?u2 = null,
    pairwise_ledger: usize = 0,
    group_ledger: usize = 0,
    history_count: usize = 0,
    history: [max_key_history]Ledger = @splat(.{}),
    fn checkOwner(self: *Station) Error!void {
        if (self.owner_address != 0 and self.owner_address != @intFromPtr(self)) {
            self.wipeKeys();
            return error.InvalidOwner;
        }
    }
    fn wipeKeys(self: *Station) void {
        secrets.clear(&self.pairwise_key);
        secrets.clear(&self.group_key);
        self.active = false;
        self.group_id = null;
    }
    fn digest(key: *const [16]u8) [32]u8 {
        var result: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(key, &result, .{});
        return result;
    }
    fn find(self: *const Station, hash: [32]u8) ?usize {
        for (self.history[0..self.history_count], 0..) |entry, i| if (std.crypto.timing_safe.eql([32]u8, hash, entry.digest)) return i;
        return null;
    }
    pub fn init(self: *Station, config: Config) Error!void {
        try self.checkOwner();
        if (self.active) return error.AlreadyInitialized;
        if (!unicast(config.peer) or !unicast(config.station) or equal(config.peer, config.station)) return error.InvalidAddress;
        if (config.epoch == 0 or config.epoch <= self.epoch) return error.StaleEpoch;
        if (config.pairwise_rx_pn > max_pn) return error.InvalidPacketNumber;
        try separate(std.mem.asBytes(self), config.pairwise);
        if (std.mem.allEqual(u8, config.pairwise, 0)) return error.InvalidKey;
        const pairwise_hash = digest(config.pairwise);
        if (self.find(pairwise_hash) != null) return error.KeyReuse;
        var group_hash: [32]u8 = @splat(0);
        var old_group: ?usize = null;
        if (config.group) |group| {
            try separate(std.mem.asBytes(self), group.key);
            if (group.rx_pn > max_pn) return error.InvalidPacketNumber;
            if (std.mem.allEqual(u8, group.key, 0)) return error.InvalidKey;
            group_hash = digest(group.key);
            if (std.crypto.timing_safe.eql([32]u8, pairwise_hash, group_hash)) return error.KeyReuse;
            old_group = self.find(group_hash);
            if (old_group) |slot| {
                if (self.history[slot].role != .group or !equal(self.history[slot].peer, config.peer)) return error.KeyReuse;
            }
        }
        const needed: usize = 1 + @as(usize, if (config.group != null and old_group == null) 1 else 0);
        if (self.history_count + needed > max_key_history) return error.KeyHistoryCapacity;
        self.owner_address = @intFromPtr(self);
        self.peer = config.peer;
        self.station = config.station;
        self.epoch = config.epoch;
        self.pairwise_ledger = self.history_count;
        self.history[self.history_count] = .{ .digest = pairwise_hash, .role = .pairwise, .peer = config.peer, .rx_pn = config.pairwise_rx_pn };
        self.history_count += 1;
        self.pairwise_key = config.pairwise.*;
        if (config.group) |group| {
            self.group_id = group.id;
            self.group_key = group.key.*;
            if (old_group) |slot| {
                self.group_ledger = slot;
                self.history[slot].rx_pn = @max(self.history[slot].rx_pn, group.rx_pn);
            } else {
                self.group_ledger = self.history_count;
                self.history[self.history_count] = .{ .digest = group_hash, .role = .group, .peer = config.peer, .rx_pn = group.rx_pn };
                self.history_count += 1;
            }
        }
        self.active = true;
    }
    pub fn clear(self: *Station) Error!void {
        try self.checkOwner();
        self.wipeKeys();
    }
    fn ready(self: *Station) Error!void {
        try self.checkOwner();
        if (!self.active) return error.NotInitialized;
    }
    pub fn sealEthernet(self: *Station, ethernet: []const u8, sequence: u12, output: []u8) Error!usize {
        try self.ready();
        try ethernetHeader(ethernet);
        if (!equal(ethernet[6..12].*, self.station)) return error.PeerMismatch;
        const length = ethernet.len - 6;
        if (output.len < header_length + ccmp_header_length + length + mic_length) return error.BufferTooSmall;
        try separate(output, ethernet);
        try separate(output, std.mem.asBytes(self));
        if (self.tx_pn == max_pn) return error.PacketNumberExhausted;
        var plaintext: [max_ethernet - 6]u8 = undefined;
        defer secrets.clear(&plaintext);
        _ = try encodeEthernet(ethernet, &plaintext);
        const header: DataHeader = .{ .direction = .to_ds, .receiver = self.peer, .transmitter = self.station, .address3 = ethernet[0..6].*, .sequence = sequence };
        // Consumed before publishing ciphertext; a failed device send must NOT
        // roll this back. Retransmit the exact sealed MPDU or consume a new PN.
        self.tx_pn += 1;
        return seal(&self.pairwise_key, header, self.tx_pn, 0, plaintext[0..length], output);
    }
    pub fn openEthernet(self: *Station, frame: []const u8, output: []u8) Error!usize {
        try self.ready();
        try separate(output, frame);
        try separate(output, std.mem.asBytes(self));
        const packet = try parsePacket(frame);
        if (packet.header.direction != .from_ds or !equal(packet.header.transmitter, self.peer)) return error.PeerMismatch;
        const group = packet.header.receiver[0] & 1 != 0;
        if (!group and !equal(packet.header.receiver, self.station)) return error.PeerMismatch;
        const slot = if (group) self.group_ledger else self.pairwise_ledger;
        if (group) {
            if (self.group_id == null or packet.key_id != self.group_id.?) return error.KeyMismatch;
        } else if (packet.key_id != 0) return error.KeyMismatch;
        if (packet.pn <= self.history[slot].rx_pn) return error.ReplayDetected;
        if (packet.ciphertext.len < 8 or packet.ciphertext.len > max_ethernet - 6) return error.InvalidLength;
        if (output.len < packet.ciphertext.len + 6) return error.BufferTooSmall;
        var plaintext: [max_payload]u8 = undefined;
        defer secrets.clear(&plaintext);
        const key = if (group) &self.group_key else &self.pairwise_key;
        const opened = try open(key, frame, &plaintext);
        const length = try decodeEthernet(opened.header, plaintext[0..opened.length], output);
        // An unauthenticated high PN and malformed/EAPOL plaintext never advance
        // replay state; rejected capacity/aliases never publish or consume it.
        self.history[slot].rx_pn = packet.pn;
        return length;
    }
};
