//! Trusted installed-app catalogue. Archive metadata never assigns permissions.
const std = @import("std");
const security = @import("security");
pub const init_id: u64 = 101;
pub const observer_id: u64 = 102;
pub const worker_id: u64 = 103;
pub const display_server_id: u64 = 104;
pub const surface_one_id: u64 = 105;
pub const surface_two_id: u64 = 106;
pub const shell_id: u64 = 107;
pub const files_id: u64 = 2;
pub const notes_id: u64 = 108;
pub const Package = struct {
    id: u64,
    name: []const u8,
    role: []const u8,
    path: []const u8 = "/bundle/main.elf",
    code_pages: u16 = 32,
    data_pages: u16 = 32,
    stack_pages: u16 = 4,
    heap_pages: u16 = 8,
    permissions: security.sandbox.Mask = 0,
    pub fn profile(self: Package) !security.sandbox.Profile {
        return security.sandbox.Profile.init(self.id, self.permissions, self.permissions);
    }
};
pub fn lookup(id: u64) !Package {
    return switch (id) {
        init_id => .{ .id = init_id, .name = "org.bedrock.init", .role = "init", .permissions = security.sandbox.bit(.app_launch) },
        observer_id => .{ .id = observer_id, .name = "org.bedrock.observer", .role = "observer" },
        worker_id => .{ .id = worker_id, .name = "org.bedrock.worker", .role = "worker" },
        display_server_id => .{ .id = display_server_id, .name = "org.bedrock.display-server", .role = "display-server", .data_pages = 128, .permissions = security.sandbox.bit(.display_service) },
        surface_one_id => .{ .id = surface_one_id, .name = "org.bedrock.surface-one", .role = "surface-client", .permissions = security.sandbox.bit(.display_client) },
        surface_two_id => .{ .id = surface_two_id, .name = "org.bedrock.surface-two", .role = "surface-client", .permissions = security.sandbox.bit(.display_client) },
        shell_id => .{ .id = shell_id, .name = "org.bedrock.shell", .role = "shell", .data_pages = 128, .permissions = security.sandbox.bit(.display_client) },
        files_id => .{ .id = files_id, .name = "org.bedrock.files", .role = "files", .data_pages = 128, .permissions = security.sandbox.bit(.display_client) },
        notes_id => .{ .id = notes_id, .name = "org.bedrock.notes", .role = "notes", .data_pages = 128, .permissions = security.sandbox.bit(.display_client) },
        else => error.ApplicationNotInstalled,
    };
}
pub fn validateIdentity(id: u64, name: []const u8, path: []const u8) !void {
    const package = try lookup(id);
    if (!std.mem.eql(u8, name, package.name) or !std.mem.eql(u8, path, package.path)) return error.InvalidInstalledIdentity;
}
pub fn authorizeLaunch(parent: security.sandbox.Profile, id: u64) !security.sandbox.Profile {
    if (!parent.mayRequest(.app_launch) or parent.app_id != init_id) return error.PermissionDenied;
    if (id == init_id) return error.PermissionDenied;
    return (try lookup(id)).profile();
}
test "installed identities and permissions come from trusted catalogue" {
    const init = try (try lookup(init_id)).profile();
    try std.testing.expect(init.mayRequest(.app_launch));
    const observer = try authorizeLaunch(init, observer_id);
    try std.testing.expectEqual(observer_id, observer.app_id);
    try std.testing.expectEqual(@as(u32, 0), observer.permissions);
    try std.testing.expectError(error.PermissionDenied, authorizeLaunch(observer, worker_id));
    try std.testing.expectError(error.PermissionDenied, authorizeLaunch(init, init_id));
    try std.testing.expectError(error.ApplicationNotInstalled, authorizeLaunch(init, 999));
    try std.testing.expectError(error.InvalidInstalledIdentity, validateIdentity(observer_id, "org.bedrock.init", "/bundle/main.elf"));
    try std.testing.expectError(error.InvalidInstalledIdentity, validateIdentity(observer_id, "org.bedrock.observer", "/container/main.elf"));
}

test "desktop clients retain private identities and cannot acquire service or launch authority" {
    const init = try (try lookup(init_id)).profile();
    const service = try authorizeLaunch(init, display_server_id);
    try std.testing.expect(service.mayRequest(.display_service));
    try std.testing.expect(!service.mayRequest(.app_launch));
    for ([_]u64{ files_id, shell_id, notes_id }) |id| {
        const package = try lookup(id);
        const client = try authorizeLaunch(init, id);
        try std.testing.expectEqual(id, client.app_id);
        try std.testing.expect(client.mayRequest(.display_client));
        for ([_]security.sandbox.Permission{ .display_service, .app_launch, .network_client, .network_server, .wifi_observe, .wifi_control }) |permission|
            try std.testing.expect(!client.mayRequest(permission));
        try std.testing.expectError(error.PermissionDenied, authorizeLaunch(client, files_id));
        try std.testing.expectEqual(@as(u16, 128), package.data_pages);
    }
    try std.testing.expectEqualStrings("org.bedrock.files", (try lookup(2)).name);
    try std.testing.expectError(error.InvalidInstalledIdentity, validateIdentity(files_id, "org.bedrock.display-server", "/bundle/main.elf"));
}
