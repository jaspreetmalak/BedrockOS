const std = @import("std");
const assets = @import("wifi_assets.zig");
const patch = "patch-v1";
const ram = "ram-v1-verified";
var arena: [49152]u8 align(4096) = undefined;

const Fake = struct {
    present: [3]bool = .{ true, true, false },
    contents: [3][]const u8 = .{ patch, ram, "board" },
    declared: [3]?u64 = .{ null, null, null },
    position: [3]usize = .{ 0, 0, 0 },
    chunk: usize = 1024,
    opens: usize = 0,
    closes: usize = 0,
    allocations: usize = 0,
    frees: usize = 0,
    entropy_calls: usize = 0,
    rng: enum { ready, absent, failed } = .ready,
    overreport: bool = false,
    allocation_fail: bool = false,
    profile_invalid: bool = false,
    directory: bool = false,
    freed_clean: bool = false,

    fn index(path: []const u8) !usize {
        if (std.mem.eql(u8, path, assets.patch_path)) return 0;
        if (std.mem.eql(u8, path, assets.ram_path)) return 1;
        if (std.mem.eql(u8, path, assets.profile_path)) return 2;
        return error.WrongPath;
    }
    fn cast(context: *anyopaque) *Fake {
        return @ptrCast(@alignCast(context));
    }
    fn open(context: *anyopaque, path: []const u8) !?assets.File {
        const self = cast(context);
        const id = try index(path);
        if (!self.present[id]) return null;
        self.opens += 1;
        return .{ .token = id + 1, .length = self.declared[id] orelse self.contents[id].len, .directory = self.directory };
    }
    fn read(context: *anyopaque, file: assets.File, output: []u8) !usize {
        const self = cast(context);
        if (self.overreport) return output.len + 1;
        const id = file.token - 1;
        const start = self.position[id];
        const count = @min(@min(output.len, self.chunk), self.contents[id].len - start);
        @memcpy(output[0..count], self.contents[id][start .. start + count]);
        self.position[id] += count;
        return count;
    }
    fn close(context: *anyopaque, _: assets.File) !void {
        cast(context).closes += 1;
    }
    fn allocate(context: *anyopaque, capacity: usize) ![]align(4096) u8 {
        const self = cast(context);
        self.allocations += 1;
        if (self.allocation_fail) return error.OutOfResources;
        if (capacity > arena.len) return error.TestArenaTooSmall;
        @memset(&arena, 0xa5);
        return arena[0..capacity];
    }
    fn free(context: *anyopaque, bytes: []align(4096) u8) !void {
        const self = cast(context);
        self.frees += 1;
        self.freed_clean = true;
        for (bytes) |byte| if (byte != 0) {
            self.freed_clean = false;
        };
    }
    fn entropy(context: *anyopaque, seed: *[64]u8) !bool {
        const self = cast(context);
        self.entropy_calls += 1;
        @memset(seed, 0x5a);
        return switch (self.rng) {
            .ready => true,
            .absent => false,
            .failed => error.DeviceError,
        };
    }
    fn validateProfile(bytes: []const u8) !void {
        if (!std.mem.eql(u8, bytes, "board")) return error.InvalidBoardProfile;
    }
    fn provider(self: *Fake) assets.Provider {
        return .{ .context = self, .open = open, .read = read, .close = close, .allocate = allocate, .free = free, .entropy = entropy, .validate_profile = validateProfile };
    }
    fn stage(self: *Fake) !assets.Outcome {
        return assets.testing.stage(self.provider(), std.math.maxInt(u64), patch, ram);
    }
};

test "Wi-Fi assets absent on loaded volume allocate nothing and request no entropy" {
    var fake: Fake = .{ .present = .{ false, false, false } };
    const result = try fake.stage();
    try std.testing.expect(result.assets == null);
    try std.testing.expectEqual(.absent, result.firmware);
    try std.testing.expectEqual(@as(usize, 0), fake.allocations);
    try std.testing.expectEqual(@as(usize, 0), fake.entropy_calls);
}
test "partial firmware and wrong metadata fail before page allocation" {
    var fake: Fake = .{ .present = .{ true, false, false } };
    try std.testing.expectError(error.PartialFirmwareAssets, fake.stage());
    try std.testing.expectEqual(fake.opens, fake.closes);
    fake = .{ .declared = .{ patch.len + 1, null, null } };
    try std.testing.expectError(error.FirmwareLengthMismatch, fake.stage());
    try std.testing.expectEqual(@as(usize, 0), fake.allocations);
    fake = .{ .directory = true };
    try std.testing.expectError(error.AssetIsDirectory, fake.stage());
}
test "exact assets partial reads profile and RNG publish bounded retained handoff" {
    var fake: Fake = .{ .present = .{ true, true, true }, .chunk = 2 };
    const result = try fake.stage();
    var retained = result.assets.?;
    const handoff = retained.handoff();
    try std.testing.expectEqual(@as(u32, 1), handoff.version);
    try std.testing.expectEqual(@as(u32, 7), handoff.flags);
    try std.testing.expectEqual(@as(u64, patch.len), handoff.patch.length);
    try std.testing.expectEqual(@as(u64, ram.len), handoff.ram.length);
    try std.testing.expectEqual(@as(u64, 5), handoff.profile.length);
    for ([_]@TypeOf(handoff.patch){ handoff.patch, handoff.ram, handoff.profile }) |range| {
        try std.testing.expect(range.base >= handoff.reservation.base);
        try std.testing.expect(try range.endExclusive() <= try handoff.reservation.endExclusive());
    }
    for (handoff.seed) |byte| try std.testing.expectEqual(@as(u8, 0x5a), byte);
    for (retained.allocation[0..assets.seed_size]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    const repeated = retained.handoff();
    try std.testing.expectEqual(@as(u32, 5), repeated.flags);
    for (repeated.seed) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    try std.testing.expectEqual(fake.opens, fake.closes);
    try std.testing.expectEqual(@as(usize, 0), fake.frees);
}
test "short changed oversize and wrong hash reads wipe and release retained pages" {
    var fake: Fake = .{ .contents = .{ "patch", ram, "board" }, .declared = .{ patch.len, null, null } };
    try std.testing.expectError(error.TruncatedAsset, fake.stage());
    try std.testing.expect(fake.freed_clean);
    try std.testing.expectEqual(fake.opens, fake.closes);
    fake = .{ .contents = .{ "patch-v1-more", ram, "board" }, .declared = .{ patch.len, null, null } };
    try std.testing.expectError(error.TrailingAssetBytes, fake.stage());
    try std.testing.expect(fake.freed_clean);
    fake = .{ .overreport = true };
    try std.testing.expectError(error.InvalidReadCount, fake.stage());
    try std.testing.expect(fake.freed_clean);
    fake = .{ .contents = .{ "patch-v2", ram, "board" } };
    try std.testing.expectError(error.FirmwareHashMismatch, fake.stage());
    try std.testing.expect(fake.freed_clean);
    try std.testing.expectEqual(@as(usize, 0), fake.entropy_calls);
}
test "RNG absent and partial failure have zero seed with no deterministic fallback" {
    for ([_]@FieldType(Fake, "rng"){ .absent, .failed }) |mode| {
        var fake: Fake = .{ .rng = mode };
        var result = try fake.stage();
        const handoff = result.assets.?.handoff();
        try std.testing.expectEqual(@as(u32, 1), handoff.flags);
        for (handoff.seed) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
        for (arena[0..64]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
        try std.testing.expectEqual(@as(usize, 1), fake.entropy_calls);
        try std.testing.expectEqual(if (mode == .failed) assets.EntropyStatus.failed else .unavailable, result.entropy);
    }
}
test "publish writes seed directly to caller handoff and consumes staging once" {
    var fake: Fake = .{};
    var outcome = try fake.stage();
    var handoff: @import("boot_protocol").WifiBoot = undefined;
    outcome.assets.?.publish(&handoff);
    try std.testing.expectEqual(@as(u32, 3), handoff.flags);
    for (handoff.seed) |byte| try std.testing.expectEqual(@as(u8, 0x5a), byte);
    for (outcome.assets.?.allocation[0..assets.seed_size]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    try std.testing.expect(!outcome.assets.?.has_entropy);
    // Repeat publication cannot reissue entropy or leave an old destination's
    // seed bytes behind when used for a subsequent seed-less handoff.
    outcome.assets.?.publish(&handoff);
    try std.testing.expectEqual(@as(u32, 1), handoff.flags);
    for (handoff.seed) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}
test "invalid optional profile is wiped while valid firmware is retained" {
    var fake: Fake = .{ .present = .{ true, true, true }, .contents = .{ patch, ram, "bad!!" } };
    var result = try fake.stage();
    try std.testing.expectEqual(.invalid, result.profile);
    try std.testing.expectEqual(@as(u32, 3), result.assets.?.handoff().flags);
    try std.testing.expectEqual(@as(u64, 0), result.assets.?.profile.length);
    // Small test firmware uses pages 1/2, leaving the profile at page 3.
    for (arena[12288 .. 12288 + assets.profile_capacity]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    try std.testing.expectEqual(fake.opens, fake.closes);
}
test "allocation failure and physical address bound fail without exposing assets" {
    var fake: Fake = .{ .allocation_fail = true };
    try std.testing.expectError(error.OutOfResources, fake.stage());
    try std.testing.expectEqual(fake.opens, fake.closes);
    fake = .{};
    try std.testing.expectError(error.AssetOutsideAddressableRange, assets.testing.stage(fake.provider(), 1, patch, ram));
    try std.testing.expect(fake.freed_clean);
    try std.testing.expectEqual(@as(usize, 1), fake.frees);
    try std.testing.expectEqual(@as(usize, 0), fake.entropy_calls);
}
test "production digest and path policy are pinned and readonly" {
    try std.testing.expectEqual(@as(usize, 137632), assets.patch_size);
    try std.testing.expectEqual(@as(usize, 1231252), assets.ram_size);
    try std.testing.expectEqual(@as(u8, 0x7f), assets.patch_sha256[0]);
    try std.testing.expectEqual(@as(u8, 0xd1), assets.ram_sha256[0]);
    var fake: Fake = .{};
    try std.testing.expectError(error.FirmwareLengthMismatch, assets.stageWithProvider(fake.provider(), std.math.maxInt(u64)));
    try std.testing.expectEqual(@as(usize, 0), fake.allocations);
}
