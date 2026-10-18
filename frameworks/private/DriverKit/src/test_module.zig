//! Explicit QEMU acceptance fixture, never included in ordinary images or
//! installable catalogues. It validates execution and host-token lifetimes.
const builtin = @import("builtin");
const abi = @import("driver_abi");
const marker = "DriverModuleLifecycleVerified";
pub export const bedrock_driver_note: abi.Note linksection(".note.bedrock") = .{ .descriptor = .{
    .vendor = 0x1af4,
    .product = 0x1041,
    .architecture = switch (builtin.cpu.arch) {
        .x86_64 => 62,
        .aarch64 => 183,
        .riscv64 => 243,
        else => @compileError("unsupported driver fixture architecture"),
    },
    .capabilities = 0,
    .id = "org.bedrock.test-driver\x00".*,
} };
const State = struct {
    host: ?*const abi.Host = null,
    allocation: abi.Allocation = .{ .token = 0, .base = 0, .length = 0 },
    report: abi.Report = .{},
};
var state: State = .{};
fn code(value: abi.Status) u32 {
    return @backingInt(value);
}
fn failure() u32 {
    state.report.status = code(.failed);
    if (state.allocation.token != 0) {
        const host = state.host.?;
        if (host.release(host.context, state.allocation.token) == code(.ok)) {
            state.allocation = .{ .token = 0, .base = 0, .length = 0 };
        } else {
            state.report.flags |= abi.ReportFlags.dma_retained;
        }
    }
    return code(.failed);
}
pub export fn bedrock_driver_entry(host: *const abi.Host, out: *abi.Radio) callconv(.c) u32 {
    if (!host.validate() or state.host != null) return code(.invalid_abi);
    state.host = host;
    state.report = .{ .stage = 1, .flags = abi.ReportFlags.attempted, .status = code(.failed) };
    out.* = .{ .context = &state, .capabilities = 0, .enable = enable, .scan = scan, .join = join, .cancel = cancel, .disconnect = disconnect, .poll = poll, .send = send, .connected = connected, .mac = mac, .stop = stop, .report = report };
    if (host.allocate(host.context, 4096, 4096, &state.allocation) != code(.ok)) return failure();
    state.report.stage = 2;
    if (state.allocation.token == 0 or state.allocation.base == 0 or state.allocation.base % 4096 != 0 or
        state.allocation.length < 4096) return failure();
    var resolved: abi.Allocation = undefined;
    if (host.resolve(host.context, state.allocation.token, &resolved) != code(.ok) or
        resolved.token != state.allocation.token or resolved.base != state.allocation.base or
        resolved.length != state.allocation.length) return failure();
    // Exercise caller-owned mapped RAM without retaining its pointer.
    const words: *volatile [2]u64 = @ptrFromInt(resolved.base);
    words[0] = 0x424452564c4f4144;
    words[1] = ~words[0];
    if (words[0] != 0x424452564c4f4144 or words[1] != ~@as(u64, 0x424452564c4f4144)) return failure();
    state.report.stage = 3;
    if (host.release(host.context, state.allocation.token) != code(.ok)) return failure();
    const released_token = state.allocation.token;
    state.allocation = .{ .token = 0, .base = 0, .length = 0 };
    if (host.resolve(host.context, released_token, &resolved) == code(.ok) or
        host.release(host.context, released_token) == code(.ok)) return failure();
    state.report.stage = 4;
    state.report.status = code(.ok);
    state.report.error_length = marker.len;
    @memcpy(state.report.error_text[0..marker.len], marker);
    return code(.ok);
}
fn enable(_: *anyopaque, _: u8) callconv(.c) u32 {
    return code(.unavailable);
}
fn scan(_: *anyopaque, _: u64) callconv(.c) u32 {
    return code(.unavailable);
}
fn join(_: *anyopaque, _: u64, _: *const abi.Bss, _: [*]const u8, _: u32, _: u64) callconv(.c) u32 {
    return code(.unavailable);
}
fn cancel(_: *anyopaque, _: u64) callconv(.c) u32 {
    return code(.ok);
}
fn disconnect(_: *anyopaque) callconv(.c) u32 {
    return code(.ok);
}
fn poll(_: *anyopaque, _: u64, out: *abi.Event) callconv(.c) u32 {
    out.* = .{};
    return code(.no_event);
}
fn send(_: *anyopaque, _: [*]const u8, _: u32) callconv(.c) u32 {
    return code(.unavailable);
}
fn connected(_: *anyopaque) callconv(.c) u8 {
    return 0;
}
fn mac(_: *anyopaque, out: *[6]u8) callconv(.c) u32 {
    out.* = .{ 2, 0, 0, 0, 0, 1 };
    return code(.ok);
}
fn stop(_: *anyopaque) callconv(.c) u32 {
    if (state.allocation.token != 0) {
        const host = state.host orelse return code(.invalid_abi);
        if (host.release(host.context, state.allocation.token) != code(.ok)) return code(.failed);
        state.allocation = .{ .token = 0, .base = 0, .length = 0 };
        state.report.flags &= ~abi.ReportFlags.dma_retained;
    }
    return code(.ok);
}
fn report(_: *anyopaque, out: *abi.Report) callconv(.c) u32 {
    out.* = state.report;
    return code(.ok);
}

const FixtureHost = struct {
    pages: [4096]u8 align(4096) = @splat(0),
    live: bool = false,
    release_fails: bool = false,
    allocations: u32 = 0,
    releases: u32 = 0,
    fn table(self: *FixtureHost) abi.Host {
        return .{ .context = self, .boot_info = self, .boot_info_size = 1, .now_ms = 0, .allocate = allocate, .resolve = resolve, .release = release };
    }
    fn cast(context: *anyopaque) *FixtureHost {
        return @ptrCast(@alignCast(context));
    }
    fn allocate(context: *anyopaque, bytes: u64, alignment: u64, out: *abi.Allocation) callconv(.c) u32 {
        const self = cast(context);
        if (self.live or bytes != 4096 or alignment != 4096) return code(.failed);
        self.live = true;
        self.allocations += 1;
        out.* = .{ .token = 1, .base = @intFromPtr(&self.pages), .length = self.pages.len };
        return code(.ok);
    }
    fn resolve(context: *anyopaque, token: u64, out: *abi.Allocation) callconv(.c) u32 {
        const self = cast(context);
        if (!self.live or token != 1) return code(.retired);
        out.* = .{ .token = 1, .base = @intFromPtr(&self.pages), .length = self.pages.len };
        return code(.ok);
    }
    fn release(context: *anyopaque, token: u64) callconv(.c) u32 {
        const self = cast(context);
        if (!self.live or token != 1) return code(.retired);
        if (self.release_fails) return code(.failed);
        self.live = false;
        self.releases += 1;
        return code(.ok);
    }
};
test "acceptance entry executes stable C imports and returns every allocation" {
    const std = @import("std");
    state = .{};
    defer state = .{};
    var fixture: FixtureHost = .{};
    const host = fixture.table();
    var radio: abi.Radio = .{};
    try std.testing.expectEqual(code(.ok), bedrock_driver_entry(&host, &radio));
    try std.testing.expect(radio.validate());
    try std.testing.expectEqual(@as(u32, 1), fixture.allocations);
    try std.testing.expectEqual(@as(u32, 1), fixture.releases);
    try std.testing.expect(!fixture.live);
    var received: abi.Report = undefined;
    try std.testing.expectEqual(code(.ok), radio.report.?(radio.context.?, &received));
    try std.testing.expectEqual(@as(u32, 4), received.stage);
    try std.testing.expectEqualStrings(marker, received.error_text[0..received.error_length]);
    try std.testing.expectEqual(code(.ok), radio.stop.?(radio.context.?));
    try std.testing.expectEqual(code(.invalid_abi), bedrock_driver_entry(&host, &radio));
}
test "failed quiescence retains ownership until stop succeeds" {
    const std = @import("std");
    state = .{};
    defer state = .{};
    var fixture: FixtureHost = .{ .release_fails = true };
    const host = fixture.table();
    var radio: abi.Radio = .{};
    try std.testing.expectEqual(code(.failed), bedrock_driver_entry(&host, &radio));
    try std.testing.expect(fixture.live);
    try std.testing.expect(state.report.flags & abi.ReportFlags.dma_retained != 0);
    try std.testing.expectEqual(code(.failed), radio.stop.?(radio.context.?));
    fixture.release_fails = false;
    try std.testing.expectEqual(code(.ok), radio.stop.?(radio.context.?));
    try std.testing.expect(!fixture.live);
    try std.testing.expectEqual(@as(u64, 0), state.allocation.token);
    try std.testing.expectEqual(@as(u32, 0), state.report.flags & abi.ReportFlags.dma_retained);
}
test "unsupported host ABI has no allocation or output side effects" {
    const std = @import("std");
    state = .{};
    defer state = .{};
    var fixture: FixtureHost = .{};
    var host = fixture.table();
    host.abi_major = 2;
    var radio: abi.Radio = .{};
    try std.testing.expectEqual(code(.invalid_abi), bedrock_driver_entry(&host, &radio));
    try std.testing.expectEqual(@as(u32, 0), fixture.allocations);
    try std.testing.expect(radio.context == null);
}
