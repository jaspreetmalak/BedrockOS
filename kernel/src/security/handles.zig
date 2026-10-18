//! Bounded, task-local authority handles for future process sandboxing.
//!
//! This table is a foundation, not an active process sandbox: the kernel must
//! select the current task's table, validate grants against its policy, and
//! enforce resolution at each future I/O boundary. Tokens carry no authority
//! outside that table and are not globally unique or secret. Do not expose
//! insert or direct table mutation to applications. Object lifetime, transfers,
//! revocation broadcasts, I/O and synchronization remain separate concerns.

/// An opaque 64-bit handle. The low half is a one-based slot; the high half is
/// its nonzero generation. Application input is untrusted, including this type.
pub const Token = enum(u64) { _ };

pub const ObjectKind = enum { file, directory, socket, ipc, surface, service };
pub const Rights = u64;

pub const rights = struct {
    pub const read: Rights = 1 << 0;
    pub const write: Rights = 1 << 1;
    pub const seek: Rights = 1 << 2;
    pub const enumerate: Rights = 1 << 3;
    pub const create: Rights = 1 << 4;
    pub const remove: Rights = 1 << 5;
    pub const connect: Rights = 1 << 6;
    pub const accept: Rights = 1 << 7;
    pub const send: Rights = 1 << 8;
    pub const receive: Rights = 1 << 9;
};

/// Kernel-issued object identity and its permitted operations. Identity zero
/// is reserved as unissued. Identity alone is never an application authority.
pub const Grant = struct {
    kind: ObjectKind,
    object_id: u64,
    rights: Rights,
};

pub const Error = error{
    InvalidToken,
    StaleToken,
    WrongObjectKind,
    InvalidRights,
    PermissionDenied,
    InvalidObjectIdentity,
    TableFull,
};

pub fn allowedRights(kind: ObjectKind) Rights {
    return switch (kind) {
        .file => rights.read | rights.write | rights.seek,
        .directory => rights.enumerate | rights.create | rights.remove,
        .socket => rights.connect | rights.accept | rights.send | rights.receive,
        .ipc => rights.send | rights.receive,
        .surface => rights.read | rights.write | rights.send,
        .service => rights.send | rights.receive,
    };
}

/// Reject unknown bits and operations that do not belong to this object kind.
/// Zero rights are valid and do not grant any operation.
pub fn validateRights(kind: ObjectKind, requested: Rights) Error!void {
    if (requested & ~allowedRights(kind) != 0) return error.InvalidRights;
}

/// A bounded per-task table. The kernel owns this storage and serializes all
/// access. Retain one instance for a task's lifetime: replacing or copying it
/// must not let that task reuse tokens from a previous table incarnation.
pub fn Table(comptime capacity: usize) type {
    return GenerationTable(capacity, 0xffff_ffff);
}

/// A caller may reserve high token bits for descriptor namespaces by bounding
/// the generation. Exhaustion retires a slot without crossing that boundary.
/// The full-width Table wrapper retains its existing token/API contract.
pub fn GenerationTable(comptime capacity: usize, comptime max_generation: u32) type {
    if (capacity > 0xffffffff) @compileError("Handle capacity exceeds the 32-bit slot encoding");
    if (max_generation == 0) @compileError("Handle generation limit must be nonzero");
    return struct {
        const Self = @This();
        const Slot = struct {
            grant: ?Grant = null,
            generation: u32 = 1,
            retired: bool = false,
        };

        slots: [capacity]Slot = @splat(Slot{}),

        /// Trusted kernel entry only. Policy checks and object lifetime must
        /// precede insertion; this table cannot determine grant provenance.
        pub fn insert(self: *Self, grant: Grant) Error!Token {
            if (grant.object_id == 0) return error.InvalidObjectIdentity;
            try validateRights(grant.kind, grant.rights);
            for (&self.slots, 0..) |*slot, index| {
                if (slot.retired or slot.grant != null) continue;
                if (slot.generation == 0 or slot.generation > max_generation) return error.InvalidToken;
                slot.grant = grant;
                return encode(index, slot.generation);
            }
            return error.TableFull;
        }

        /// Resolve only in the current task's table. Required operations must
        /// be valid for the expected kind and included in this handle's rights.
        pub fn resolve(self: *const Self, token: Token, expected_kind: ObjectKind, required: Rights) Error!Grant {
            if (capacity == 0) return error.InvalidToken;
            const index = try self.slotIndex(token);
            const grant = self.slots[index].grant.?;
            if (grant.kind != expected_kind) return error.WrongObjectKind;
            try validateRights(expected_kind, required);
            if (required & ~grant.rights != 0) return error.PermissionDenied;
            return grant;
        }

        /// Reduce this handle's rights in place. Other duplicates retain their
        /// own rights. Failure leaves this handle and the table unchanged.
        pub fn restrict(self: *Self, token: Token, retained: Rights) Error!void {
            if (capacity == 0) return error.InvalidToken;
            const index = try self.slotIndex(token);
            const grant = try attenuate(self.slots[index].grant.?, retained);
            self.slots[index].grant = grant;
        }

        /// Duplicate into another slot of the same table with equal or fewer
        /// rights. This does not create an inter-task transfer or global token.
        pub fn duplicate(self: *Self, token: Token, retained: Rights) Error!Token {
            if (capacity == 0) return error.InvalidToken;
            const index = try self.slotIndex(token);
            const grant = try attenuate(self.slots[index].grant.?, retained);
            return self.insert(grant);
        }

        /// Invalidate a live token. A generation never wraps: the last close
        /// permanently retires its slot, even if this eventually fills a table.
        pub fn close(self: *Self, token: Token) Error!void {
            if (capacity == 0) return error.InvalidToken;
            const index = try self.slotIndex(token);
            const slot = &self.slots[index];
            slot.grant = null;
            if (slot.generation == max_generation) {
                slot.retired = true;
            } else {
                slot.generation += 1;
            }
        }

        fn slotIndex(self: *const Self, token: Token) Error!usize {
            if (capacity == 0) return error.InvalidToken;
            const value = @backingInt(token);
            const one_based: u32 = @truncate(value);
            const generation: u32 = @intCast(value >> 32);
            if (one_based == 0 or generation == 0 or generation > max_generation or one_based > capacity)
                return error.InvalidToken;
            const index: usize = one_based - 1;
            const slot = &self.slots[index];
            if (slot.retired or slot.generation != generation or slot.grant == null) return error.StaleToken;
            return index;
        }

        fn encode(index: usize, generation: u32) Token {
            return @fromBackingInt(@intCast((@as(u64, generation) << 32) | (@as(u64, @intCast(index)) + 1)));
        }

        fn attenuate(grant: Grant, retained: Rights) Error!Grant {
            try validateRights(grant.kind, retained);
            if (retained & ~grant.rights != 0) return error.PermissionDenied;
            return .{ .kind = grant.kind, .object_id = grant.object_id, .rights = retained };
        }
    };
}

test "read-only file grant permits reads and denies writes and other kinds" {
    const testing = @import("std").testing;
    var table: Table(2) = .{};
    const token = try table.insert(.{ .kind = .file, .object_id = 37, .rights = rights.read });
    const grant = try table.resolve(token, .file, rights.read);
    try testing.expectEqual(@as(u64, 37), grant.object_id);
    try testing.expectEqual(rights.read, grant.rights);
    try testing.expectError(error.PermissionDenied, table.resolve(token, .file, rights.write));
    try testing.expectError(error.WrongObjectKind, table.resolve(token, .socket, rights.receive));
    try testing.expectError(error.InvalidRights, table.resolve(token, .file, rights.connect));
}

test "close rejects stale tokens before and after slot reuse" {
    const testing = @import("std").testing;
    var table: Table(1) = .{};
    const old = try table.insert(.{ .kind = .file, .object_id = 1, .rights = rights.read });
    try table.close(old);
    try testing.expectError(error.StaleToken, table.close(old));
    try testing.expectError(error.StaleToken, table.resolve(old, .file, 0));
    const fresh = try table.insert(.{ .kind = .file, .object_id = 2, .rights = rights.write });
    try testing.expect(old != fresh);
    try testing.expectError(error.StaleToken, table.resolve(old, .file, rights.read));
    try testing.expectError(error.StaleToken, table.restrict(old, 0));
    try testing.expectError(error.StaleToken, table.duplicate(old, 0));
    try testing.expectEqual(@as(u64, 2), (try table.resolve(fresh, .file, rights.write)).object_id);
}

test "restrict and duplicate only attenuate with independent rights" {
    const testing = @import("std").testing;
    var table: Table(3) = .{};
    const source = try table.insert(.{ .kind = .file, .object_id = 11, .rights = rights.read | rights.write });
    const read_only = try table.duplicate(source, rights.read);
    try testing.expectEqual(@as(u64, 11), (try table.resolve(read_only, .file, rights.read)).object_id);
    try testing.expectError(error.PermissionDenied, table.duplicate(read_only, rights.read | rights.write));
    try testing.expectError(error.PermissionDenied, table.restrict(read_only, rights.write));
    try testing.expectError(error.InvalidRights, table.restrict(source, rights.connect));
    try testing.expectError(error.InvalidRights, table.duplicate(source, rights.send));
    _ = try table.resolve(source, .file, rights.write);
    try table.restrict(source, rights.read);
    try testing.expectError(error.PermissionDenied, table.resolve(source, .file, rights.write));
    _ = try table.resolve(read_only, .file, rights.read);
    const inert = try table.duplicate(read_only, 0);
    try testing.expectEqual(@as(Rights, 0), (try table.resolve(inert, .file, 0)).rights);
    try testing.expectError(error.PermissionDenied, table.resolve(inert, .file, rights.read));
    try table.restrict(read_only, 0);
    try testing.expectError(error.PermissionDenied, table.resolve(read_only, .file, rights.read));
}

test "empty and full tables fail without consuming or changing authority" {
    const testing = @import("std").testing;
    const grant: Grant = .{ .kind = .ipc, .object_id = 8, .rights = rights.send };
    var empty: Table(0) = .{};
    try testing.expectError(error.TableFull, empty.insert(grant));
    try testing.expectError(error.InvalidToken, empty.resolve(@fromBackingInt(@intCast(0x100000001)), .ipc, rights.send));
    try testing.expectError(error.InvalidToken, empty.restrict(@fromBackingInt(@intCast(0x100000001)), 0));
    try testing.expectError(error.InvalidToken, empty.duplicate(@fromBackingInt(@intCast(0x100000001)), 0));
    try testing.expectError(error.InvalidToken, empty.close(@fromBackingInt(@intCast(0x100000001))));
    var table: Table(1) = .{};
    const token = try table.insert(grant);
    try testing.expectError(error.TableFull, table.insert(grant));
    try testing.expectError(error.TableFull, table.duplicate(token, 0));
    try testing.expectEqualDeep(grant, try table.resolve(token, .ipc, rights.send));
    try table.close(token);
    _ = try table.insert(grant);
}

test "rights validation rejects unknown and mismatched operations for all kinds" {
    const testing = @import("std").testing;
    for ([_]ObjectKind{ .file, .directory, .socket, .ipc }) |kind| {
        try validateRights(kind, allowedRights(kind));
        try validateRights(kind, 0);
        try testing.expectError(error.InvalidRights, validateRights(kind, @as(Rights, 1) << 63));
    }
    try testing.expectError(error.InvalidRights, validateRights(.file, rights.enumerate));
    try testing.expectError(error.InvalidRights, validateRights(.directory, rights.seek));
    try testing.expectError(error.InvalidRights, validateRights(.socket, rights.create));
    try testing.expectError(error.InvalidRights, validateRights(.ipc, rights.connect));
    var table: Table(1) = .{};
    try testing.expectError(error.InvalidRights, table.insert(.{ .kind = .file, .object_id = 9, .rights = rights.read | rights.accept }));
    try testing.expectError(error.InvalidObjectIdentity, table.insert(.{ .kind = .file, .object_id = 0, .rights = 0 }));
    const token = try table.insert(.{ .kind = .directory, .object_id = 9, .rights = rights.enumerate });
    try testing.expectError(error.InvalidRights, table.resolve(token, .directory, @as(Rights, 1) << 20));
    _ = try table.resolve(token, .directory, rights.enumerate);
}

test "generation exhaustion retires the slot rather than reviving old tokens" {
    const testing = @import("std").testing;
    var table: Table(1) = .{};
    // Reach the boundary directly, rather than performing 2^32 closes.
    table.slots[0].generation = 0xfffffffe;
    const grant: Grant = .{ .kind = .file, .object_id = 5, .rights = rights.read };
    const penultimate = try table.insert(grant);
    try table.close(penultimate);
    const last = try table.insert(grant);
    try testing.expectEqual(@as(u64, 0xffffffff00000001), @backingInt(last));
    try testing.expectError(error.StaleToken, table.resolve(penultimate, .file, rights.read));
    try table.close(last);
    try testing.expect(table.slots[0].retired);
    try testing.expectEqual(@as(u32, 0xffffffff), table.slots[0].generation);
    try testing.expectError(error.StaleToken, table.close(last));
    try testing.expectError(error.StaleToken, table.resolve(@fromBackingInt(@intCast(0x100000001)), .file, 0));
    try testing.expectError(error.TableFull, table.insert(grant));
}

test "bounded handle generations reserve descriptor tags and retire before entering them" {
    const testing = @import("std").testing;
    const limit: u32 = 0x3fff_ffff;
    var table: GenerationTable(1, limit) = .{};
    table.slots[0].generation = limit - 1;
    const grant: Grant = .{ .kind = .ipc, .object_id = 5, .rights = rights.send };
    const previous = try table.insert(grant);
    try testing.expectEqual(@as(u64, 0), @backingInt(previous) & (@as(u64, 3) << 62));
    const before = table;
    for ([_]u64{
        0x4000_0000_0000_0001,
        0x8000_0000_0000_0001,
        0xc000_0000_0000_0001,
        @backingInt(previous) | (@as(u64, 1) << 62),
        @backingInt(previous) | (@as(u64, 1) << 63),
    }) |raw| {
        try testing.expectError(error.InvalidToken, table.resolve(@fromBackingInt(raw), .ipc, rights.send));
        try testing.expectError(error.InvalidToken, table.close(@fromBackingInt(raw)));
    }
    try testing.expectEqualDeep(before, table);
    try table.close(previous);
    const last = try table.insert(grant);
    try testing.expectEqual(@as(u64, 0x3fff_ffff_0000_0001), @backingInt(last));
    try testing.expectEqual(@as(u64, 0), @backingInt(last) & (@as(u64, 3) << 62));
    try table.close(last);
    try testing.expect(table.slots[0].retired);
    try testing.expectEqual(limit, table.slots[0].generation);
    try testing.expectError(error.StaleToken, table.resolve(last, .ipc, rights.send));
    try testing.expectError(error.TableFull, table.insert(grant));
}

test "malformed and invented token values never resolve authority" {
    const testing = @import("std").testing;
    var table: Table(2) = .{};
    const token = try table.insert(.{ .kind = .socket, .object_id = 12, .rights = rights.send });
    for ([_]u64{ 0, 1, 0x100000000, 0x100000003, 0xffffffffffffffff }) |value| {
        const invalid: Token = @fromBackingInt(@intCast(value));
        try testing.expectError(error.InvalidToken, table.resolve(invalid, .socket, rights.send));
        try testing.expectError(error.InvalidToken, table.close(invalid));
    }
    try testing.expectError(error.StaleToken, table.resolve(@fromBackingInt(@intCast(0x200000001)), .socket, rights.send));
    try testing.expectError(error.StaleToken, table.resolve(@fromBackingInt(@intCast(0x100000002)), .socket, rights.send));
    _ = try table.resolve(token, .socket, rights.send);
}

test "tokens are scoped by the table selected by the kernel" {
    const testing = @import("std").testing;
    var first: Table(1) = .{};
    var second: Table(1) = .{};
    const first_token = try first.insert(.{ .kind = .file, .object_id = 100, .rights = rights.read });
    try testing.expectError(error.StaleToken, second.resolve(first_token, .file, rights.read));
    const second_token = try second.insert(.{ .kind = .file, .object_id = 200, .rights = rights.write });
    // Equal numeric tokens identify only each table's local grant. A caller
    // cannot select another task's table through this token value.
    try testing.expectEqual(first_token, second_token);
    try testing.expectEqual(@as(u64, 100), (try first.resolve(first_token, .file, rights.read)).object_id);
    try testing.expectEqual(@as(u64, 200), (try second.resolve(first_token, .file, rights.write)).object_id);
    try testing.expectError(error.PermissionDenied, second.resolve(first_token, .file, rights.read));
}

test "equal duplication survives local restriction and closure of its source" {
    const testing = @import("std").testing;
    var table: Table(2) = .{};
    const original: Grant = .{ .kind = .file, .object_id = 91, .rights = rights.read | rights.write };
    const source = try table.insert(original);
    const copy = try table.duplicate(source, original.rights);
    try table.restrict(source, 0);
    try testing.expectError(error.PermissionDenied, table.resolve(source, .file, rights.read));
    try testing.expectEqualDeep(original, try table.resolve(copy, .file, original.rights));
    try table.close(source);
    try testing.expectError(error.StaleToken, table.resolve(source, .file, 0));
    try testing.expectEqualDeep(original, try table.resolve(copy, .file, original.rights));
    try table.close(copy);
}
