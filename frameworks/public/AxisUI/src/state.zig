//! Explicit revision-based state. The host routes events, observes revisions
//! and schedules rendering; this is not implicit binding or reconciliation.
const std = @import("std");
pub fn State(comptime T: type) type {
    return struct {
        const Self = @This();
        value: T,
        revision: u64 = 0,
        pub fn set(self: *Self, value: T) error{RevisionExhausted}!bool {
            if (std.meta.eql(self.value, value)) return false;
            if (self.revision == std.math.maxInt(u64)) return error.RevisionExhausted;
            self.value = value;
            self.revision += 1;
            return true;
        }
        pub fn changedSince(self: *const Self, revision: u64) bool {
            return self.revision != revision;
        }
    };
}
test "state invalidation changes only for new values and exhaustion is atomic" {
    var s: State(u8) = .{ .value = 1 };
    try std.testing.expect(!try s.set(1));
    try std.testing.expect(try s.set(2));
    try std.testing.expect(s.changedSince(0));
    try std.testing.expect(!s.changedSince(1));
    s.revision = std.math.maxInt(u64);
    try std.testing.expectError(error.RevisionExhausted, s.set(3));
    try std.testing.expectEqual(@as(u8, 2), s.value);
}
