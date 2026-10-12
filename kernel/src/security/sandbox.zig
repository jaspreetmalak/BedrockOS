//! Portable app grant policy. Inputs describing object provenance come only
//! from trusted kernel resolution/brokers, never from an app's request fields.
//! This policy does not create processes or enforce hardware memory isolation.
const std = @import("std");
const handles = @import("handles.zig");

pub const Mask = u32;
pub const Permission = enum(u8) {
    user_file_read,
    user_file_write,
    network_client,
    network_server,
    ipc_service,
    camera,
    microphone,
    wifi_observe,
    wifi_control,
};
pub const known_permissions: Mask = (1 << 9) - 1;

pub fn bit(permission: Permission) Mask {
    return @as(Mask, 1) << @as(u5, @intCast(@backingInt(permission)));
}

pub const Error = error{ InvalidAppIdentity, InvalidPermissions, PermissionDenied, InvalidGrant };

/// Kernel-established origin of a resolved object. Selecting a file means the
/// broker has approved this particular object, not every path an app names.
pub const Source = union(enum) {
    app_bundle: u64,
    private_container: u64,
    selected_file,
    network_client,
    network_server,
    ipc_service,
    /// Trusted launcher's already-approved standard-stream rights. Application
    /// request text cannot manufacture this provenance or increase its mask.
    inherited_stream: handles.Rights,
};

/// App identities are assigned by the trusted launcher and shared by its child
/// tree; they are independent of Unix user IDs, process IDs and manifest text.
pub const Profile = struct {
    app_id: u64,
    permissions: Mask = 0,

    /// A manifest requests privileges; only trusted approval can grant them.
    pub fn init(app_id: u64, requested: Mask, approved: Mask) Error!Profile {
        if (app_id == 0) return error.InvalidAppIdentity;
        try validateMask(requested);
        try validateMask(approved);
        return .{ .app_id = app_id, .permissions = requested & approved };
    }

    /// Eligibility to request a resource from a broker, not an object grant.
    pub fn mayRequest(self: Profile, permission: Permission) bool {
        self.validate() catch return false;
        return self.permissions & bit(permission) != 0;
    }

    /// A child keeps its app identity and may retain or reduce permissions.
    pub fn deriveChild(self: Profile, retained: Mask) Error!Profile {
        try self.validate();
        try validateMask(retained);
        if (retained & ~self.permissions != 0) return error.PermissionDenied;
        return .{ .app_id = self.app_id, .permissions = retained };
    }

    /// Check before trusted insertion into the receiving process's handle
    /// table. Object lifetimes, VFS traversal, peer authentication and actual
    /// broker approval must already be established by their owning subsystem.
    pub fn authorizeGrant(self: Profile, grant: handles.Grant, source: Source) Error!void {
        try self.validate();
        if (grant.object_id == 0 or grant.rights & ~handles.allowedRights(grant.kind) != 0)
            return error.InvalidGrant;
        const allowed: handles.Rights = switch (source) {
            .app_bundle => |owner| blk: {
                if (owner != self.app_id) return error.PermissionDenied;
                break :blk switch (grant.kind) {
                    .file => handles.rights.read | handles.rights.seek,
                    .directory => handles.rights.enumerate,
                    else => return error.PermissionDenied,
                };
            },
            .private_container => |owner| blk: {
                if (owner != self.app_id) return error.PermissionDenied;
                break :blk switch (grant.kind) {
                    .file, .directory => handles.allowedRights(grant.kind),
                    else => return error.PermissionDenied,
                };
            },
            .selected_file => blk: {
                if (grant.kind != .file) return error.PermissionDenied;
                var mask: handles.Rights = 0;
                if (self.mayRequest(.user_file_read)) mask |= handles.rights.read | handles.rights.seek;
                if (self.mayRequest(.user_file_write)) mask |= handles.rights.write | handles.rights.seek;
                if (mask == 0) return error.PermissionDenied;
                break :blk mask;
            },
            .network_client => blk: {
                if (grant.kind != .socket or !self.mayRequest(.network_client)) return error.PermissionDenied;
                break :blk handles.rights.connect | handles.rights.send | handles.rights.receive;
            },
            .network_server => blk: {
                if (grant.kind != .socket or !self.mayRequest(.network_server)) return error.PermissionDenied;
                break :blk handles.rights.accept | handles.rights.send | handles.rights.receive;
            },
            .ipc_service => blk: {
                if (grant.kind != .ipc or !self.mayRequest(.ipc_service)) return error.PermissionDenied;
                break :blk handles.rights.send | handles.rights.receive;
            },
            .inherited_stream => |approved| blk: {
                if (grant.kind != .file or approved & ~(handles.rights.read | handles.rights.write) != 0)
                    return error.InvalidGrant;
                break :blk approved;
            },
        };
        if (grant.rights & ~allowed != 0) return error.PermissionDenied;
    }

    fn validate(self: Profile) Error!void {
        if (self.app_id == 0) return error.InvalidAppIdentity;
        try validateMask(self.permissions);
    }
};

fn validateMask(mask: Mask) Error!void {
    if (mask & ~known_permissions != 0) return error.InvalidPermissions;
}

test "inherited streams authorize only the launcher's existing stream rights" {
    const profile = try Profile.init(7, 0, 0);
    try profile.authorizeGrant(fileGrant(handles.rights.write), .{ .inherited_stream = handles.rights.write });
    try std.testing.expectError(error.PermissionDenied, profile.authorizeGrant(fileGrant(handles.rights.read), .{ .inherited_stream = handles.rights.write }));
    try std.testing.expectError(error.InvalidGrant, profile.authorizeGrant(fileGrant(handles.rights.write), .{ .inherited_stream = handles.rights.seek }));
    try std.testing.expectError(error.InvalidGrant, profile.authorizeGrant(.{ .kind = .ipc, .object_id = 1, .rights = handles.rights.send }, .{ .inherited_stream = handles.rights.write }));
}

fn fileGrant(rights: handles.Rights) handles.Grant {
    return .{ .kind = .file, .object_id = 10, .rights = rights };
}

test "manifest requests cannot grant authority without trusted approval" {
    const requested = bit(.network_client) | bit(.camera);
    const approved = bit(.network_client) | bit(.microphone);
    const profile = try Profile.init(7, requested, approved);
    try std.testing.expect(profile.mayRequest(.network_client));
    try std.testing.expect(!profile.mayRequest(.camera));
    try std.testing.expect(!profile.mayRequest(.microphone));
    try std.testing.expectEqual(@as(Mask, 0), (try Profile.init(7, known_permissions, 0)).permissions);
    try std.testing.expectError(error.InvalidAppIdentity, Profile.init(0, 0, 0));
    try std.testing.expectError(error.InvalidPermissions, Profile.init(7, 1 << 31, 0));
    try std.testing.expectError(error.InvalidPermissions, Profile.init(7, 0, 1 << 31));
}

test "default profile has only its own read-only bundle and private container" {
    const profile = try Profile.init(7, 0, 0);
    try profile.authorizeGrant(fileGrant(handles.rights.read | handles.rights.seek), .{ .app_bundle = 7 });
    try std.testing.expectError(error.PermissionDenied, profile.authorizeGrant(fileGrant(handles.rights.write), .{ .app_bundle = 7 }));
    try profile.authorizeGrant(fileGrant(handles.rights.read | handles.rights.write), .{ .private_container = 7 });
    try std.testing.expectError(error.PermissionDenied, profile.authorizeGrant(fileGrant(handles.rights.read), .{ .private_container = 8 }));
    try std.testing.expectError(error.PermissionDenied, profile.authorizeGrant(fileGrant(handles.rights.read), .{ .app_bundle = 8 }));
    try std.testing.expectError(error.PermissionDenied, profile.authorizeGrant(fileGrant(handles.rights.read), .selected_file));
    try profile.authorizeGrant(.{ .kind = .directory, .object_id = 11, .rights = handles.rights.enumerate }, .{ .app_bundle = 7 });
    try std.testing.expectError(error.PermissionDenied, profile.authorizeGrant(.{ .kind = .directory, .object_id = 11, .rights = handles.rights.create }, .{ .app_bundle = 7 }));
}

test "selected-file read and write permissions are independent and object-scoped" {
    const read = try Profile.init(7, bit(.user_file_read), bit(.user_file_read));
    try read.authorizeGrant(fileGrant(handles.rights.read | handles.rights.seek), .selected_file);
    try std.testing.expectError(error.PermissionDenied, read.authorizeGrant(fileGrant(handles.rights.write), .selected_file));
    try std.testing.expectError(error.PermissionDenied, read.authorizeGrant(.{ .kind = .directory, .object_id = 12, .rights = handles.rights.enumerate }, .selected_file));
    const write = try Profile.init(7, bit(.user_file_write), bit(.user_file_write));
    try write.authorizeGrant(fileGrant(handles.rights.write | handles.rights.seek), .selected_file);
    try std.testing.expectError(error.PermissionDenied, write.authorizeGrant(fileGrant(handles.rights.read), .selected_file));
}

test "network and IPC grants require the corresponding entitlement and kind" {
    const none = try Profile.init(7, 0, 0);
    const client = try Profile.init(7, bit(.network_client), bit(.network_client));
    const socket: handles.Grant = .{ .kind = .socket, .object_id = 13, .rights = handles.rights.connect | handles.rights.send | handles.rights.receive };
    try std.testing.expectError(error.PermissionDenied, none.authorizeGrant(socket, .network_client));
    try client.authorizeGrant(socket, .network_client);
    try std.testing.expectError(error.PermissionDenied, client.authorizeGrant(.{ .kind = .socket, .object_id = 13, .rights = handles.rights.accept }, .network_client));
    try std.testing.expectError(error.PermissionDenied, client.authorizeGrant(socket, .network_server));
    try std.testing.expectError(error.PermissionDenied, client.authorizeGrant(fileGrant(handles.rights.read), .network_client));
    const server = try Profile.init(7, bit(.network_server), bit(.network_server));
    try server.authorizeGrant(.{ .kind = .socket, .object_id = 14, .rights = handles.rights.accept }, .network_server);
    const ipc: handles.Grant = .{ .kind = .ipc, .object_id = 15, .rights = handles.rights.send };
    try std.testing.expectError(error.PermissionDenied, none.authorizeGrant(ipc, .ipc_service));
    const service = try Profile.init(7, bit(.ipc_service), bit(.ipc_service));
    try service.authorizeGrant(ipc, .ipc_service);
}

test "children retain identity and cannot widen permissions" {
    const parent = try Profile.init(7, bit(.network_client) | bit(.camera), known_permissions);
    const child = try parent.deriveChild(bit(.network_client));
    try std.testing.expectEqual(@as(u64, 7), child.app_id);
    try std.testing.expect(!child.mayRequest(.camera));
    try std.testing.expectError(error.PermissionDenied, child.deriveChild(bit(.camera)));
    try std.testing.expectError(error.InvalidPermissions, child.deriveChild(1 << 31));
    try std.testing.expectEqual(@as(Mask, 0), (try child.deriveChild(0)).permissions);
}

test "corrupt profiles and malformed grants fail closed" {
    const corrupt: Profile = .{ .app_id = 0, .permissions = known_permissions };
    try std.testing.expect(!corrupt.mayRequest(.network_client));
    try std.testing.expectError(error.InvalidAppIdentity, corrupt.authorizeGrant(fileGrant(handles.rights.read), .{ .private_container = 0 }));
    const unknown: Profile = .{ .app_id = 7, .permissions = 1 << 31 };
    try std.testing.expect(!unknown.mayRequest(.camera));
    const profile = try Profile.init(7, 0, 0);
    try std.testing.expectError(error.InvalidGrant, profile.authorizeGrant(fileGrant(handles.rights.connect), .{ .private_container = 7 }));
    try std.testing.expectError(error.InvalidGrant, profile.authorizeGrant(fileGrant(1 << 63), .{ .private_container = 7 }));
    try std.testing.expectError(error.InvalidGrant, profile.authorizeGrant(.{ .kind = .file, .object_id = 0, .rights = handles.rights.read }, .{ .private_container = 7 }));
}
