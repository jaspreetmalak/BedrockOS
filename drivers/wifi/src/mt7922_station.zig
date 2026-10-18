//! Actual polling glue between owned MT7922 DMA, NIC commands, surveys and the
//! original station security engine. No simulated provider or RF qualification
//! is supplied here. A platform must first boot firmware and establish real
//! board calibration, country policy, coherent DMA and secure entropy.
const std = @import("std");
const mt = @import("mediatek/root.zig");
const transport_api = @import("mt7922_transport.zig");
const policy = @import("radio_policy.zig");
const rules = @import("regulatory/root.zig");
const connection = @import("station_link.zig");
const observation = @import("observation.zig");
const wifi = @import("networkkit").wifi;
pub const Config = struct {
    device_epoch: u64,
    /// A real rate qualified by the hardware/platform. No guessed PHY fallback.
    fixed_rate: u16,
    bss_index: u8 = 0,
    own_mac: u8 = 0,
    wlan_index: u16 = 1,
    entropy_context: *anyopaque,
    entropy: *const fn (*anyopaque, *[32]u8) anyerror!void,
};
pub const Event = union(enum) {
    scan_result: struct { operation: u64, bss: wifi.Bss },
    scan_complete: struct { operation: u64 },
    link: connection.Event,
    /// Borrow until the next public mutating call; consume/copy synchronously.
    ethernet: []const u8,
};
const Deferred = struct { token: u16 = 0, acknowledged: ?bool = null };
const SavedFrame = struct { length: usize = 0, channel: u16 = 0, band: mt.mac.Band = .ghz2, signal: ?i16 = null, bytes: [4096]u8 = @splat(0) };
pub const max_ethernet = 1280; // conservative initial raw RX1536 profile
pub const Binding = struct {
    owner_address: usize = 0,
    busy: bool = false,
    stopped: bool = false,
    transport: *transport_api.Transport = undefined,
    authority: *const policy.Authority = undefined,
    nic: *mt.nic.Client = undefined,
    config: Config = undefined,
    capabilities: mt.nic.Capabilities = undefined,
    link: connection.Link = .{},
    selected: observation.Observation = undefined,
    scan: mt.scan.Session = .{},
    scan_operation: u64 = 0,
    operation_highwater: u64 = 0,
    generation: u64 = 0,
    observations: [wifi.max_scan_results]observation.Observation = undefined,
    observation_count: usize = 0,
    deferred: [32]Deferred = @splat(.{}),
    deferred_count: usize = 0,
    saved: [4]SavedFrame = @splat(.{}),
    saved_count: usize = 0,
    dropped_frames: u64 = 0,
    receive: [8192]u8 = undefined,
    routed: [8192]u8 = undefined,
    ethernet: [1514]u8 = undefined,

    /// Borrow stable owners for the complete binding lifetime. This makes real
    /// firmware/register calls; init is not an identification-only operation.
    pub fn init(self: *Binding, transport: *transport_api.Transport, authority: *const policy.Authority, nic: *mt.nic.Client, config: Config) !void {
        if (self.owner_address != 0) return error.AlreadyInitialized;
        if (transport.owner_address != @intFromPtr(transport) or transport.state != .firmware_ready or
            nic.owner_address != @intFromPtr(nic) or nic.mcu != &transport.mcu or nic.device_epoch != config.device_epoch or
            nic.events != null or config.device_epoch == 0 or config.fixed_rate >= 0x4000 or config.bss_index >= 4 or config.own_mac >= 4 or config.wlan_index == 0 or config.wlan_index >= 20) return error.UnpreparedHardware;
        const snapshot = try authority.snapshot();
        if (snapshot.device_epoch != config.device_epoch or !snapshot.firmware_submitted) return error.UnsubmittedPolicy;
        for ([_]struct { p: usize, n: usize }{ .{ .p = @intFromPtr(transport), .n = @sizeOf(transport_api.Transport) }, .{ .p = @intFromPtr(authority), .n = @sizeOf(policy.Authority) }, .{ .p = @intFromPtr(nic), .n = @sizeOf(mt.nic.Client) } }) |other|
            if (overlaps(@intFromPtr(self), @sizeOf(Binding), other.p, other.n)) return error.BufferOverlap;
        self.owner_address = @intFromPtr(self);
        self.busy = true;
        defer self.busy = false;
        self.transport = transport;
        self.authority = authority;
        self.nic = nic;
        self.config = config;
        self.generation = snapshot.generation;
        self.nic.events = .{ .context = self, .other = otherEvent };
        errdefer {
            self.stopped = true;
            transport.stop() catch {};
            self.detachEvents();
        }
        self.capabilities = try nic.capabilities();
        if (self.capabilities.phy.antenna_mask & ~@as(u8, 3) != 0) return error.UnsupportedPhy;
        transport.data.antenna_mask = self.capabilities.phy.antenna_mask;
        _ = try nic.useEfuse(); // actual factory mode; does not invent power facts
        if (!transport.driver.snapshot().mac_initialized) try transport.driver.initMac();
        _ = try nic.device(.{ .omac_index = config.own_mac, .address = self.capabilities.address, .enabled = true });
        _ = try nic.macEnable(true);
        try self.link.init(.{ .station_mac = self.capabilities.address, .device_epoch = config.device_epoch }, authority, .{ .context = self, .prepare = prepare, .associated = associated, .authorized = authorized, .transmit = transmit, .quiesce = quiesce, .entropy = entropy });
    }
    fn owner(self: *const Binding) !void {
        if (self.owner_address != @intFromPtr(self)) return error.InvalidOwner;
    }
    fn enter(self: *Binding) !void {
        try self.owner();
        if (self.busy) return error.BindingBusy;
        self.busy = true;
    }
    fn live(self: *const Binding) !void {
        if (self.stopped or self.transport.state != .firmware_ready or self.transport.mcu.stopped) return error.HardwareUnavailable;
        const snapshot = try self.authority.snapshot();
        if (snapshot.device_epoch != self.config.device_epoch or snapshot.generation != self.generation or !snapshot.firmware_submitted) return error.StaleHardwarePolicy;
    }
    fn cast(p: *anyopaque) *Binding {
        return @ptrCast(@alignCast(p));
    }
    fn overlaps(a: usize, an: usize, b: usize, bn: usize) bool {
        if (an == 0 or bn == 0) return false;
        return if (a >= b) a - b < bn else b - a < an;
    }
    fn band(channel: u16) mt.mac.Band {
        return if (channel <= 14) .ghz2 else .ghz5;
    }
    fn rateMask(self: *const Binding, channel: u16) !u16 {
        if (channel <= 14 and self.capabilities.phy.has_2ghz) return 0x0fff;
        if (channel >= 32 and channel <= 177 and self.capabilities.phy.has_5ghz) return 0x00ff;
        return error.UnsupportedChannel;
    }
    fn peer(self: *Binding, state: mt.nic.PeerState, aid: u16, secured: bool) !void {
        _ = try self.nic.station(.{ .bss_index = self.config.bss_index, .omac_index = self.config.own_mac, .wlan_index = self.config.wlan_index, .peer = self.selected.bss.bssid, .aid = aid, .band = band(self.selected.bss.channel), .supported_rates = self.selected.supported_rates, .basic_rates = self.selected.basic_rates, .rcpi = @intCast(@max(0, @min(220, 220 + 2 * @as(i32, self.selected.bss.signal_dbm)))), .state = state, .secured = secured, .newly = state == .authenticated });
    }
    fn prepare(p: *anyopaque, request: rules.Request, generation: u64, _: wifi.Bss, _: @import("ieee80211/station.zig").Rates) !void {
        const self = cast(p);
        try self.owner();
        try self.live();
        if (!self.busy or generation != self.generation) return error.StaleHardwarePolicy;
        if (!(try self.authority.decision(generation, request)).allow_initiate_tx) return error.TransmissionDenied;
        const channel: mt.nic.Channel20 = .{ .band = band(request.channel), .number = @intCast(request.channel), .antenna_mask = self.capabilities.phy.antenna_mask, .passive = false };
        _ = try self.nic.channel(channel);
        _ = try self.nic.rxPath(channel);
        _ = try self.nic.bss(.{ .bss_index = self.config.bss_index, .omac_index = self.config.own_mac, .wmm_index = 0, .wlan_index = self.config.wlan_index, .band = channel.band, .bssid = self.selected.bss.bssid, .connected = false, .beacon_interval = self.selected.beacon_interval, .dtim_period = self.selected.dtim_period, .basic_rates = self.selected.basic_rates });
        _ = try self.nic.rlm(self.config.bss_index, channel);
        try self.peer(.authenticated, 0, false);
    }
    fn associated(p: *anyopaque, aid: u16) !void {
        const self = cast(p);
        try self.live();
        try self.peer(.associated, aid, false);
    }
    fn authorized(p: *anyopaque) !void {
        const self = cast(p);
        try self.live();
        try self.peer(.authorized, self.link.mac.association_id, true);
    }
    fn entropy(p: *anyopaque, out: *[32]u8) !void {
        const self = cast(p);
        try self.config.entropy(self.config.entropy_context, out);
    }
    fn transmit(p: *anyopaque, bytes: []const u8, kind: connection.Kind) !u64 {
        const self = cast(p);
        try self.live();
        var options: transport_api.data_api.TxOptions = .{ .wlan_index = self.config.wlan_index, .own_mac = self.config.own_mac, .fixed_rate = self.config.fixed_rate, .software_encrypted = kind == .data, .request_status = kind == .message2 or kind == .message4 };
        options.request_status = options.request_status or kind == .authentication or kind == .association;
        return if (kind == .authentication or kind == .association) try self.transport.sendManagement(bytes, options) else try self.transport.sendData(bytes, options);
    }
    fn quiesce(p: *anyopaque) !void {
        const self = cast(p);
        self.stopped = true;
        self.scan.active = null;
        self.scan_operation = 0;
        self.detachEvents();
        try self.transport.stop(); // actual bus-master/DMA stop, not cancel submission
        self.deferred_count = 0;
        self.saved_count = 0;
    }
    fn detachEvents(self: *Binding) void {
        // The shared MCU caller is serialized. Never detach another owner's
        // hook, and never retire this context during an active NIC receive.
        if (self.transport.mcu.busy) return;
        if (self.nic.events) |events| if (events.context == @as(*anyopaque, @ptrCast(self)) and events.other == otherEvent) {
            self.nic.events = null;
        };
    }
    pub fn isConnected(self: *const Binding) bool {
        self.owner() catch return false;
        self.live() catch return false;
        return self.link.state == .connected;
    }
    fn deferTx(self: *Binding, token: u16, acknowledged: ?bool) !void {
        if (self.deferred_count == self.deferred.len) return error.EventCapacity;
        self.deferred[self.deferred_count] = .{ .token = token, .acknowledged = acknowledged };
        self.deferred_count += 1;
    }
    fn otherEvent(p: *anyopaque, packet: []const u8) !void {
        const self = cast(p);
        try self.owner();
        if (packet.len > self.routed.len) return error.EventCapacity;
        // MCU RX scratch is part of Transport's control owner and is overwritten
        // by its next receive. Route only a separate, Binding-owned copy.
        @memcpy(self.routed[0..packet.len], packet);
        const event = try self.transport.routeEvent(self.routed[0..packet.len]);
        switch (event) {
            .tx_free => |freed| for (freed.entries[0..freed.count]) |entry| try self.deferTx(entry.token, null),
            .tx_status => |statuses| for (statuses.entries[0..statuses.count]) |entry| try self.deferTx(entry.token, entry.acknowledged),
            .frame => |received| {
                // Broadcast surveys/unrelated data during a synchronous NIC
                // call must not poison MCU control or retain borrowed scratch.
                if (self.link.state == .empty or self.link.state == .idle or self.link.state == .failed or
                    received.band == .ghz6 or received.band != band(received.channel) or received.channel != self.link.mac.selected.channel or
                    received.frame.len < 24 or !std.mem.eql(u8, received.frame[10..16], &self.link.mac.selected.bssid)) return;
                if (self.saved_count == self.saved.len or received.frame.len > self.saved[0].bytes.len) {
                    self.dropped_frames +|= 1;
                    return;
                }
                const saved = &self.saved[self.saved_count];
                saved.length = received.frame.len;
                saved.channel = received.channel;
                saved.band = received.band;
                saved.signal = received.signal_dbm;
                @memcpy(saved.bytes[0..saved.length], received.frame);
                self.saved_count += 1;
            },
            else => {},
        }
    }
    fn flushTx(self: *Binding, now: u64) !void {
        var index: usize = 0;
        while (index < self.deferred_count) : (index += 1) {
            const entry = self.deferred[index];
            if (entry.acknowledged) |ack| try self.link.completeTx(.{ .device_epoch = self.config.device_epoch, .policy_generation = self.generation, .ticket = entry.token, .acknowledged = ack, .now = now }) else _ = try self.link.releaseData(self.config.device_epoch, self.generation, entry.token);
        }
        self.deferred_count = 0;
    }
    pub fn startScan(self: *Binding, operation: u64) !void {
        try self.enter();
        defer self.busy = false;
        try self.live();
        if (self.link.state != .idle or self.scan.active != null) return error.RadioBusy;
        if (self.link.pending != null) return error.PendingEvent;
        if (self.transport.mcu.busy) return error.McuBusy;
        if (self.scan.sequence.issued == 127) return error.ScanSequenceExhausted;
        if (operation == 0 or operation <= self.operation_highwater) return error.ReusedOperation;
        var channels: [64]mt.scan.Channel = undefined;
        var count: usize = 0;
        for (self.authority.caps[0..self.authority.cap_count]) |cap| {
            const allowed = try self.authority.decision(self.generation, .{ .band = cap.band, .channel = cap.channel });
            if (!allowed.allow_passive_scan or cap.band == .ghz6) continue;
            _ = self.rateMask(cap.channel) catch continue;
            if (count == channels.len) return error.ChannelCapacity;
            channels[count] = .{ .band = band(cap.channel), .number = @intCast(cap.channel) };
            count += 1;
        }
        if (count == 0) return error.NoApprovedChannels;
        const options: mt.scan.Options = .{ .sequence = 1, .bss_index = self.config.bss_index, .channels = channels[0..count] };
        var candidate: [mt.scan.request_size]u8 = undefined;
        _ = try self.authority.encodeScan(self.generation, options, &candidate);
        self.operation_highwater = operation;
        self.scan_operation = operation;
        self.observation_count = 0;
        errdefer {
            self.stopped = true;
            self.transport.stop() catch {};
        }
        _ = try self.scan.start(&self.transport.mcu, options);
    }
    pub fn join(self: *Binding, operation: u64, selected: wifi.Bss, passphrase: []const u8, now: u64) !void {
        try self.enter();
        defer self.busy = false;
        try self.live();
        if (self.scan.active != null) return error.RadioBusy;
        if (self.link.state != .idle and self.link.state != .failed) return error.RadioBusy;
        if (self.link.pending != null) return error.PendingEvent;
        if (self.transport.mcu.busy) return error.McuBusy;
        if (operation == 0 or operation <= self.operation_highwater) return error.ReusedOperation;
        if (overlaps(@intFromPtr(self), @sizeOf(Binding), @intFromPtr(passphrase.ptr), passphrase.len)) return error.BufferOverlap;
        for (self.observations[0..self.observation_count]) |found| {
            var expected = found.bss;
            expected.signal_dbm = selected.signal_dbm;
            if (!std.meta.eql(expected, selected)) continue;
            if (found.supported_rates & try observation.hardwareRateMask(self.config.fixed_rate, selected.channel) == 0)
                return error.UnsupportedPeerRate;
            self.selected = found;
            self.operation_highwater = operation;
            try self.link.join(operation, selected, found.rates, found.rsnBody(), passphrase, now);
            return;
        }
        return error.InvalidSelection;
    }
    fn handleFrame(self: *Binding, bytes: []const u8, channel: u16, received_band: mt.mac.Band, signal: ?i16, now: u64) !?Event {
        if (received_band == .ghz6 or received_band != band(channel)) return null;
        if (self.scan.active != null) {
            const mask = self.rateMask(channel) catch return null;
            const found = observation.parse(bytes, channel, signal orelse return null, mask) catch return null;
            const decision = self.authority.decision(self.generation, .{ .band = if (channel <= 14) .ghz2 else .ghz5, .channel = channel }) catch return null;
            if (!decision.allow_passive_scan) return null;
            for (self.observations[0..self.observation_count]) |previous| if (std.mem.eql(u8, &previous.bss.bssid, &found.bss.bssid)) return null;
            if (self.observation_count == self.observations.len) return null;
            self.observations[self.observation_count] = found;
            self.observation_count += 1;
            return .{ .scan_result = .{ .operation = self.scan_operation, .bss = found.bss } };
        }
        if (bytes.len < 24 or self.link.state == .idle or self.link.state == .failed) return null;
        const received: connection.Received = .{ .device_epoch = self.config.device_epoch, .policy_generation = self.generation, .channel = channel, .frame = bytes };
        if (bytes[1] & 0x40 != 0 and self.link.state == .connected) {
            const size = self.link.receiveEthernet(received, &self.ethernet) catch return null;
            if (size > max_ethernet) return null;
            return .{ .ethernet = self.ethernet[0..size] };
        }
        self.link.ingest(received, now) catch |err| {
            if (err != error.UnsupportedFrame and err != error.WrongPeer) return err;
        };
        return null;
    }
    pub fn poll(self: *Binding, now: u64) !?Event {
        try self.enter();
        defer self.busy = false;
        if (self.stopped) return if (try self.link.takeEvent()) |event| .{ .link = event } else null;
        errdefer self.link.deviceLost() catch {};
        try self.live();
        try self.link.poll(now);
        if (self.stopped) return if (try self.link.takeEvent()) |event| .{ .link = event } else null;
        try self.flushTx(now);
        if (try self.link.takeEvent()) |event| return .{ .link = event };
        if (self.stopped) return null;
        if (self.saved_count != 0) {
            const saved = self.saved[0];
            for (1..self.saved_count) |i| self.saved[i - 1] = self.saved[i];
            self.saved_count -= 1;
            if (try self.handleFrame(saved.bytes[0..saved.length], saved.channel, saved.band, saved.signal, now)) |event| return event;
        }
        for (0..16) |index| {
            const incoming = (if (index % 2 == 0) try self.transport.pollData(&self.receive) else try self.transport.pollEvent(&self.receive)) orelse continue;
            switch (incoming) {
                .frame => |received| if (try self.handleFrame(received.frame, received.channel, received.band, received.signal_dbm, now)) |event| return event,
                .tx_free => |freed| for (freed.entries[0..freed.count]) |entry| {
                    _ = try self.link.releaseData(self.config.device_epoch, self.generation, entry.token);
                },
                .tx_status => |statuses| for (statuses.entries[0..statuses.count]) |entry| {
                    try self.link.completeTx(.{ .device_epoch = self.config.device_epoch, .policy_generation = self.generation, .ticket = entry.token, .acknowledged = entry.acknowledged, .now = now });
                },
                .event => |packet| if (self.scan.active != null and packet.len >= 36 and packet[28] == 0x0d) {
                    _ = try self.scan.completed(packet);
                    const operation = self.scan_operation;
                    self.scan_operation = 0;
                    return .{ .scan_complete = .{ .operation = operation } };
                },
                .other => {},
            }
            try self.flushTx(now);
            if (try self.link.takeEvent()) |event| return .{ .link = event };
            if (self.stopped) return null;
        }
        return null;
    }
    pub fn sendEthernet(self: *Binding, bytes: []const u8) !void {
        try self.enter();
        defer self.busy = false;
        try self.live();
        if (bytes.len > max_ethernet) return error.FrameTooLarge;
        _ = try self.link.sendEthernet(bytes);
    }
    pub fn setEnabled(self: *Binding, enabled: bool) !void {
        try self.enter();
        defer self.busy = false;
        if (!enabled and self.transport.state == .stopped) return;
        try self.live();
        if (!enabled and (self.scan.active != null or self.link.state != .idle or try self.transport.data.outstanding() != 0)) {
            try self.link.disconnect();
            return;
        }
        _ = try self.nic.macEnable(enabled);
    }
    pub fn cancel(self: *Binding, operation: u64) !void {
        try self.enter();
        defer self.busy = false;
        if (operation == 0) return error.StaleOperation;
        if (self.scan_operation == operation or self.link.operation == operation) {
            try self.link.disconnect();
            return error.HardwareRetired;
        }
        return error.StaleOperation;
    }
    pub fn disconnect(self: *Binding) !void {
        try self.enter();
        defer self.busy = false;
        if (self.stopped) return error.HardwareRetired;
        if (self.link.state == .idle and self.scan.active == null) return;
        try self.link.disconnect();
        return error.HardwareRetired;
    }
    /// Explicit full retirement for failed attachment. A failed device stop
    /// still retains Transport/DMA owners, but no NIC callback retains Binding.
    pub fn retire(self: *Binding) !void {
        try self.enter();
        defer self.busy = false;
        self.stopped = true;
        self.detachEvents();
        self.link.deviceLost() catch {};
        try self.transport.stop();
    }
};
test {
    _ = @import("mt7922_station_tests.zig");
}
