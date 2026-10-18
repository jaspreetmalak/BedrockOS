//! Private HMAC-DRBG SHA-256 (SP 800-90A rev.1, no additional input).
//! The seed must be 64 fresh bytes from the trusted EFI RNG protocol. Time,
//! MAC addresses and firmware bytes are never accepted as replacement entropy.
const std = @import("std");
const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
pub const Generator = struct {
    owner_address: usize = 0,
    key: [32]u8 = @splat(0),
    value: [32]u8 = @splat(0),
    requests: u64 = 0,
    busy: bool = false,
    retired: bool = false,

    pub fn init(self: *Generator, seed: *[64]u8) !void {
        if (self.owner_address != 0) return error.EntropyAlreadyInitialized;
        if (aliases(self, seed)) return error.AliasedEntropy;
        defer std.crypto.secureZero(u8, seed);
        if (std.mem.allEqual(u8, seed, 0)) return error.MissingEntropy;
        self.* = .{ .owner_address = @intFromPtr(self), .value = @splat(1), .requests = 1 };
        self.update(seed);
    }
    fn aliases(self: *const Generator, bytes: []const u8) bool {
        const a = @intFromPtr(self);
        const b = @intFromPtr(bytes.ptr);
        return bytes.len != 0 and (if (b >= a) b - a < @sizeOf(Generator) else a - b < bytes.len);
    }
    fn owner(self: *const Generator) !void {
        if (self.owner_address == 0 or self.owner_address != @intFromPtr(self)) return error.MovedEntropy;
        if (self.retired) return error.EntropyRetired;
        if (self.busy) return error.EntropyBusy;
    }
    fn hash(self: *Generator, marker: ?u8, input: []const u8) void {
        var ctx = Hmac.init(&self.key);
        defer std.crypto.secureZero(u8, std.mem.asBytes(&ctx));
        ctx.update(&self.value);
        if (marker) |byte| ctx.update(&.{byte});
        ctx.update(input);
        var result: [32]u8 = undefined;
        defer std.crypto.secureZero(u8, &result);
        ctx.final(&result);
        if (marker != null) self.key = result else self.value = result;
    }
    fn update(self: *Generator, input: []const u8) void {
        self.hash(0, input);
        self.hash(null, &.{});
        if (input.len != 0) {
            self.hash(1, input);
            self.hash(null, &.{});
        }
    }
    pub fn fill(self: *Generator, output: []u8) !void {
        try self.owner();
        if (output.len == 0 or output.len > 1024) return error.InvalidEntropyRequest;
        if (aliases(self, output)) return error.AliasedEntropy;
        // This boot-scoped generator deliberately requires reseeding earlier
        // than the standard's 2^48 bound. Exhaustion retires it immediately.
        if (self.requests > 0xffffffff) {
            self.deinit();
            return error.EntropyReseedRequired;
        }
        self.busy = true;
        defer self.busy = false;
        var offset: usize = 0;
        while (offset < output.len) {
            self.hash(null, &.{});
            const count = @min(self.value.len, output.len - offset);
            @memcpy(output[offset..][0..count], self.value[0..count]);
            offset += count;
        }
        self.update(&.{});
        self.requests += 1;
    }
    pub fn nonce(context: *anyopaque, output: *[32]u8) !void {
        const self: *Generator = @ptrCast(@alignCast(context));
        try self.fill(output);
    }
    pub fn deinit(self: *Generator) void {
        if (self.owner_address != @intFromPtr(self) or self.busy) return;
        std.crypto.secureZero(u8, &self.key);
        std.crypto.secureZero(u8, &self.value);
        self.retired = true;
        self.requests = 0;
    }
};

test "DRBG agrees with independent Python HMAC reference across two requests" {
    var seed: [64]u8 = undefined;
    for (&seed, 0..) |*byte, i| byte.* = @intCast(i);
    var state: Generator = .{};
    defer state.deinit();
    try state.init(&seed);
    var first: [64]u8 = undefined;
    var expected: [64]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "acb4c0527346343f45266a99a5ea86e9493b69635f509ed6871d4c871f93613b70af78045a86189e93f2adcbd7f4533c1bf27f60b443c1f0514ffaaf3102514a");
    try state.fill(&first);
    try std.testing.expectEqualSlices(u8, &expected, &first);
    var second: [32]u8 = undefined;
    var expected_second: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected_second, "0f055feef08cabf74ed01d5e95c50cbe136a4c28e65ff1bacc733b556d31f3ec");
    try state.fill(&second);
    try std.testing.expectEqualSlices(u8, &expected_second, &second);
}

test "DRBG rejects missing moved aliased retired and exhausted state and erases seed" {
    var state: Generator = .{};
    var missing: [64]u8 = @splat(0);
    try std.testing.expectError(error.MissingEntropy, state.init(&missing));
    var seed: [64]u8 = @splat(0xa5);
    try state.init(&seed);
    try std.testing.expect(std.mem.allEqual(u8, &seed, 0));
    var output: [32]u8 = undefined;
    var copy = state;
    try std.testing.expectError(error.MovedEntropy, copy.fill(&output));
    try std.testing.expectError(error.AliasedEntropy, state.fill(&state.key));
    try std.testing.expectError(error.InvalidEntropyRequest, state.fill(&.{}));
    state.requests = 0x100000000;
    try std.testing.expectError(error.EntropyReseedRequired, state.fill(&output));
    try std.testing.expect(std.mem.allEqual(u8, &state.key, 0) and std.mem.allEqual(u8, &state.value, 0));
    try std.testing.expectError(error.EntropyRetired, state.fill(&output));
}
