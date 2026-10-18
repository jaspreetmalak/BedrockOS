//! Trusted, in-place country/device policy snapshot and MediaTek adapter.
//! This does not activate a radio or confer application country authority.
//! Board capabilities and CLC/rate data must come from actual hardware setup.
const std = @import("std");
const rules = @import("regulatory/root.zig");
const mt = @import("mediatek/root.zig");
const fw = mt.regulatory;
pub const Snapshot = struct { device_epoch: u64, generation: u64, country: [2]u8, environment: rules.Environment, firmware_submitted: bool };
pub const FirmwareInputs = struct { clc: fw.Clc, board: fw.Board, power: []const fw.PowerChannel };
fn overlap(start: usize, size: usize, pointer: usize, length: usize) bool {
    if (size == 0 or length == 0) return false;
    return if (pointer >= start) pointer - start < size else start - pointer < length;
}
pub const Authority = struct {
    owner_address: usize = 0,
    device_epoch: u64 = 0,
    generation: u64 = 0,
    country: [2]u8 = .{ '0', '0' },
    environment: rules.Environment = .unknown,
    selected: bool = false,
    busy: bool = false,
    reset_pending: bool = false,
    caps: [rules.max_channel_caps]rules.ChannelCap = undefined,
    cap_count: usize = 0,
    firmware: fw.Session = .{},
    domain_channels: [fw.max_channels]fw.ChannelLimit = undefined,
    firmware_caps: [fw.max_channels]fw.ChannelCapability = undefined,
    /// A nonzero epoch represents a trusted completed device reset. Capabilities
    /// are copied; changing the caller's source cannot silently widen this policy.
    pub fn init(self: *Authority, epoch: u64, capabilities: []const rules.ChannelCap) !void {
        if (self.owner_address != 0) return error.PolicyAlreadyInitialized;
        if (epoch == 0) return error.InvalidDeviceEpoch;
        try self.validateReplacement(capabilities);
        self.* = .{ .owner_address = @intFromPtr(self), .device_epoch = epoch, .generation = 1, .cap_count = capabilities.len, .selected = true };
        @memcpy(self.caps[0..capabilities.len], capabilities);
        try self.firmware.init(epoch);
    }
    fn aliases(self: *const Authority, bytes: []const u8) bool {
        return overlap(@intFromPtr(self), @sizeOf(Authority), @intFromPtr(bytes.ptr), bytes.len);
    }
    fn validateReplacement(self: *const Authority, capabilities: []const rules.ChannelCap) !void {
        if (capabilities.len > rules.max_channel_caps) return error.TooManyChannels;
        if (self.aliases(std.mem.sliceAsBytes(capabilities))) return error.AliasedCapabilities;
        try rules.validateCaps(capabilities);
    }
    fn owner(self: *const Authority) !void {
        if (self.owner_address == 0 or self.owner_address != @intFromPtr(self)) return error.MovedPolicyAuthority;
    }
    fn current(self: *const Authority, generation: u64) !void {
        try self.owner();
        if (!self.selected) return error.PolicyUnavailable;
        if (self.firmware.stage == .failed) return error.DeviceResetRequired;
        if (generation == 0 or generation != self.generation) return error.StalePolicyGeneration;
    }
    fn idle(self: *const Authority) !void {
        try self.owner();
        if (self.busy or self.firmware.stage == .submitting) return error.PolicyBusy;
        if (self.reset_pending) return error.DeviceResetRequired;
        if (self.firmware.stage == .failed) return error.DeviceResetRequired;
    }
    pub fn snapshot(self: *const Authority) !Snapshot {
        try self.current(self.generation);
        return .{ .device_epoch = self.device_epoch, .generation = self.generation, .country = self.country, .environment = self.environment, .firmware_submitted = self.firmware.isSubmitted(self.device_epoch, self.generation) };
    }
    /// Select only while the prior hardware policy is quiescent/unsubmitted.
    /// No timezone, GPS, AP country hint or application can select this value.
    pub fn select(self: *Authority, country: [2]u8, environment: rules.Environment) !u64 {
        try self.idle();
        if (self.firmware.stage == .policy_submitted) return error.PolicyNeedsQuiescence;
        const entry = rules.lookup(country) orelse return error.UnknownCountry;
        for (self.caps[0..self.cap_count]) |cap| _ = try rules.evaluate(entry, cap, environment, .{ .band = cap.band, .channel = cap.channel });
        if (self.generation == std.math.maxInt(u64)) {
            self.selected = false;
            return error.PolicyGenerationExhausted;
        }
        try self.firmware.invalidate();
        self.generation += 1;
        self.country = country;
        self.environment = environment;
        self.selected = true;
        return self.generation;
    }
    /// Caller must first stop RF operations and drain/revoke outstanding traffic.
    /// Matching epoch/generation alone does not prove physical quiescence.
    pub fn invalidateAfterQuiescence(self: *Authority, epoch: u64, generation: u64) !void {
        try self.idle();
        try self.current(generation);
        if (epoch != self.device_epoch) return error.StaleDeviceEpoch;
        try self.firmware.invalidate();
        self.selected = false;
    }
    /// Requires independent real reset evidence. Generation highwater survives.
    /// The replacement snapshot starts in passive-only world policy again.
    pub fn afterDeviceReset(self: *Authority, epoch: u64, capabilities: []const rules.ChannelCap) !void {
        try self.owner();
        if (self.busy or self.firmware.stage == .submitting) return error.PolicyBusy;
        if (epoch < self.device_epoch or (epoch == self.device_epoch and !self.reset_pending)) return error.StaleDeviceEpoch;
        // The new epoch describes a physical change that already happened.
        // Retire pre-reset permissions even if replacement data is malformed.
        if (epoch > self.device_epoch) {
            self.selected = false;
            try self.firmware.afterDeviceReset(epoch);
            self.device_epoch = epoch;
            self.reset_pending = true;
        }
        try self.validateReplacement(capabilities);
        if (self.generation == std.math.maxInt(u64)) return error.PolicyGenerationExhausted;
        @memcpy(self.caps[0..capabilities.len], capabilities);
        self.cap_count = capabilities.len;
        self.device_epoch = epoch;
        self.generation += 1;
        self.country = .{ '0', '0' };
        self.environment = .unknown;
        self.selected = true;
        self.reset_pending = false;
    }
    pub fn decision(self: *const Authority, generation: u64, request: rules.Request) !rules.Decision {
        try self.current(generation);
        const country = rules.lookup(self.country) orelse return error.UnknownCountry;
        for (self.caps[0..self.cap_count]) |cap| if (cap.band == request.band and cap.channel == request.channel)
            return rules.evaluate(country, cap, self.environment, request);
        return error.UnsupportedDeviceChannel;
    }
    fn band(value: rules.Band) mt.mac.Band {
        return @fromBackingInt(@intCast(@backingInt(value)));
    }
    fn environmentValue(value: rules.Environment) fw.Environment {
        return switch (value) {
            .unknown => .any,
            .indoor => .indoor,
            .outdoor => .outdoor,
        };
    }
    fn buildDomain(self: *Authority) !fw.Domain {
        var count: usize = 0;
        for (self.caps[0..self.cap_count]) |cap| {
            const permit = try self.decision(self.generation, .{ .band = cap.band, .channel = cap.channel });
            if (!permit.allow_passive_scan) continue;
            if (count == fw.max_channels) return error.TooManyFirmwareChannels;
            if (cap.channel > 255 or !fw.channelValid(band(cap.band), @intCast(cap.channel))) return error.UnsupportedFirmwareChannel;
            // A passive scan decision does not invent missing TX calibration.
            const ceiling = permit.max_conducted_power_mbm orelse return error.MissingPowerCalibration;
            const hardware = cap.max_conducted_power_mbm orelse return error.MissingPowerCalibration;
            self.domain_channels[count] = .{ .band = band(cap.band), .number = @intCast(cap.channel), .max_power_mbm = @min(ceiling, 6350), .no_ir = !permit.allow_initiate_tx, .dfs = permit.flags & rules.Flags.dfs != 0, .indoor_only = permit.flags & rules.Flags.no_outdoor != 0 };
            self.firmware_caps[count] = .{ .band = band(cap.band), .number = @intCast(cap.channel), .max_power_mbm = @min(hardware, 6350) };
            count += 1;
        }
        if (count == 0) return error.NoApprovedChannels;
        return .{ .country = self.country, .environment = environmentValue(self.environment), .channels = self.domain_channels[0..count] };
    }
    /// Real CE command submission with caller-provided authentic CLC and rate
    /// tables. Success means DMA consumption only, never firmware/RF readiness.
    /// Borrowed inputs remain immutable throughout this serialized operation.
    pub fn submit(self: *Authority, generation: u64, mcu: *mt.Mcu, inputs: FirmwareInputs) !void {
        try self.idle();
        try self.current(generation);
        if (self.firmware.stage != .idle) return error.PolicyAlreadySubmitted;
        if (inputs.power.len > fw.max_channels) return error.InvalidPowerBatch;
        const power_bytes = std.mem.sliceAsBytes(inputs.power);
        if (self.aliases(power_bytes) or overlap(@intFromPtr(mcu), @sizeOf(mt.Mcu), @intFromPtr(power_bytes.ptr), power_bytes.len)) return error.AliasedFirmwareInputs;
        for (inputs.clc.blocks) |block| if (block) |bytes| {
            if (self.aliases(bytes) or overlap(@intFromPtr(mcu), @sizeOf(mt.Mcu), @intFromPtr(bytes.ptr), bytes.len)) return error.AliasedFirmwareInputs;
        };
        self.busy = true;
        defer self.busy = false;
        const domain = try self.buildDomain();
        try self.firmware.submit(mcu, .{ .device_epoch = self.device_epoch, .generation = self.generation, .domain = domain, .capabilities = .{ .channels = self.firmware_caps[0..domain.channels.len] }, .clc = inputs.clc, .board = inputs.board, .power = inputs.power });
    }
    /// Packet construction only. An operational backend must separately prove
    /// NIC/MAC setup, ordered firmware policy and actual scan completion.
    pub fn encodeScan(self: *const Authority, generation: u64, options: mt.scan.Options, output: []u8) ![]const u8 {
        try self.current(generation);
        if (self.aliases(output)) return error.AliasedOutput;
        if (options.channels.len > 64 or options.ssids.len > 4 or options.ies.len > 600) return error.InvalidScanRequest;
        const out_start = @intFromPtr(output.ptr);
        for ([_][]const u8{ std.mem.sliceAsBytes(options.channels), std.mem.sliceAsBytes(options.ssids), options.ies }) |bytes|
            if (overlap(out_start, output.len, @intFromPtr(bytes.ptr), bytes.len)) return error.AliasedOutput;
        for (options.ssids) |ssid| if (overlap(out_start, output.len, @intFromPtr(ssid.ptr), ssid.len)) return error.AliasedOutput;
        for (options.channels) |channel| {
            const permit = try self.decision(generation, .{ .band = @fromBackingInt(@intCast(@backingInt(channel.band))), .channel = channel.number });
            if (!permit.allow_passive_scan) return error.ChannelDenied;
            if (options.active and !permit.allow_initiate_tx) return error.TransmissionDenied;
        }
        return mt.scan.encode(options, output);
    }
    /// Policy-checked descriptor candidate, not a hardware transmission grant.
    /// Firmware must enforce actual calibrated SKU limits before backend TX.
    pub fn encodeTransmit(self: *const Authority, generation: u64, request: rules.Request, frame: []const u8, address: u64, options: mt.mac.TxOptions, output: []u8) ![]const u8 {
        if (self.aliases(output) or overlap(@intFromPtr(output.ptr), output.len, @intFromPtr(frame.ptr), frame.len)) return error.AliasedOutput;
        const permit = try self.decision(generation, request);
        if (!permit.allow_initiate_tx) return error.TransmissionDenied;
        return mt.mac.transmit(frame, address, options, output);
    }
};
test {
    _ = @import("radio_policy_tests.zig");
}
