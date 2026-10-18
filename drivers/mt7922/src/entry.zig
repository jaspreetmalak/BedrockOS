//! Separately linked, polling-only MT7922 module. All chipset owners remain in
//! this image. The kernel sees only versioned C records and copied events.
const std = @import("std");
const builtin = @import("builtin");
const abi = @import("driver_abi");
const protocol = @import("boot_protocol");
const drivers = @import("wifi_drivers");
const memory = @import("memory_init");
const boot = @import("boot.zig");
const wire = @import("wire.zig");
var owner_tag: u8 = 0;
var started = false;
var retired = false;
var radio: ?*drivers.mt7922_station.Binding = null;

const architecture: protocol.Architecture = switch (builtin.cpu.arch) {
    .x86_64 => .x86_64,
    .aarch64 => .aarch64,
    .riscv64 => .riscv64,
    else => @compileError("unsupported driver module architecture"),
};
const elf_machine: u16 = switch (builtin.cpu.arch) {
    .x86_64 => 62,
    .aarch64 => 183,
    .riscv64 => 243,
    else => unreachable,
};
fn identity() [24]u8 {
    var result: [24]u8 = @splat(0);
    @memcpy(result[0.."org.bedrock.mt7922".len], "org.bedrock.mt7922");
    return result;
}
fn note(vendor: u16, product: u16) abi.Note {
    return .{ .descriptor = .{ .vendor = vendor, .product = product, .architecture = elf_machine, .capabilities = abi.Capabilities.scan | abi.Capabilities.wpa2_psk, .id = identity() } };
}
pub export const bedrock_driver_note: [3]abi.Note linksection(".note.bedrock") = .{
    note(0x14c3, 0x0616),
    note(0x14c3, 0x7922),
    note(0x0b48, 0x7922),
};
fn code(value: abi.Status) u32 {
    return @backingInt(value);
}
fn owner(context: *anyopaque) bool {
    return started and context == @as(*anyopaque, @ptrCast(&owner_tag));
}
fn device(context: *anyopaque) !*drivers.mt7922_station.Binding {
    if (!owner(context)) return error.InvalidModuleContext;
    if (retired) return error.HardwareRetired;
    return radio orelse error.RadioUnavailable;
}
fn failure(err: anyerror) u32 {
    return switch (err) {
        error.HardwareRetired => result: {
            retired = true;
            break :result code(.retired);
        },
        error.InvalidModuleContext, error.InvalidBss, error.InvalidSsid => code(.invalid_abi),
        error.RadioUnavailable => code(.unavailable),
        else => code(.failed),
    };
}
pub export fn bedrock_driver_entry(host: *const abi.Host, output: *abi.Radio) callconv(.c) u32 {
    if (started or !host.validate() or host.boot_info_size < @sizeOf(protocol.BootInfo) or @intFromPtr(host.boot_info) % @alignOf(protocol.BootInfo) != 0)
        return code(.invalid_abi);
    const info: *const protocol.BootInfo = @ptrCast(@alignCast(host.boot_info));
    info.validate(host.boot_info_size, architecture) catch return code(.invalid_abi);
    memory.install(host) catch return code(.invalid_abi);
    started = true;
    output.* = .{
        .context = &owner_tag,
        .capabilities = abi.Capabilities.scan | abi.Capabilities.wpa2_psk,
        .enable = enable,
        .scan = scan,
        .join = join,
        .cancel = cancel,
        .disconnect = disconnect,
        .poll = poll,
        .send = send,
        .connected = connected,
        .mac = mac,
        .stop = stop,
        .report = report,
    };
    radio = boot.initialize(info) catch return code(.failed);
    return code(if (radio != null) .ok else .unavailable);
}
fn enable(context: *anyopaque, value: u8) callconv(.c) u32 {
    if (value > 1) return code(.invalid_abi);
    const binding = device(context) catch |err| return failure(err);
    binding.setEnabled(value != 0) catch |err| return failure(err);
    return code(.ok);
}
fn scan(context: *anyopaque, operation: u64) callconv(.c) u32 {
    const binding = device(context) catch |err| return failure(err);
    binding.startScan(operation) catch |err| return failure(err);
    return code(.ok);
}
fn join(context: *anyopaque, operation: u64, selected: *const abi.Bss, secret: [*]const u8, length: u32, now: u64) callconv(.c) u32 {
    if (length > 63) return code(.invalid_abi);
    const value = wire.decode(selected) catch |err| return failure(err);
    const binding = device(context) catch |err| return failure(err);
    binding.join(operation, value, secret[0..length], now) catch |err| return failure(err);
    return code(.ok);
}
fn cancel(context: *anyopaque, operation: u64) callconv(.c) u32 {
    const binding = device(context) catch |err| return failure(err);
    binding.cancel(operation) catch |err| return failure(err);
    return code(.ok);
}
fn disconnect(context: *anyopaque) callconv(.c) u32 {
    const binding = device(context) catch |err| return failure(err);
    binding.disconnect() catch |err| return failure(err);
    return code(.ok);
}
fn poll(context: *anyopaque, now: u64, output: *abi.Event) callconv(.c) u32 {
    output.* = .{};
    const binding = device(context) catch |err| return failure(err);
    const event = (binding.poll(now) catch |err| return failure(err)) orelse return code(.no_event);
    switch (event) {
        .scan_result => |found| output.* = .{ .kind = @backingInt(abi.EventKind.scan_result), .operation = found.operation, .bss = wire.encode(found.bss) },
        .scan_complete => |done| output.* = .{ .kind = @backingInt(abi.EventKind.scan_complete), .operation = done.operation },
        .link => |state| switch (state) {
            .joined => |joined| output.* = .{ .kind = @backingInt(abi.EventKind.joined), .operation = joined.operation, .bssid = joined.bssid, .security = @backingInt(joined.security), .authenticated = @intFromBool(joined.authenticated) },
            .failed => |failed| output.* = .{ .kind = @backingInt(abi.EventKind.failed), .operation = failed.operation, .failure = @backingInt(failed.failure) },
            .link_lost => |lost| output.* = .{ .kind = @backingInt(abi.EventKind.link_lost), .operation = lost.operation },
        },
        .ethernet => |frame| {
            if (frame.len > output.ethernet.len) return code(.failed);
            output.kind = @backingInt(abi.EventKind.ethernet);
            output.length = @intCast(frame.len);
            @memcpy(output.ethernet[0..frame.len], frame);
        },
    }
    return code(.ok);
}
fn send(context: *anyopaque, bytes: [*]const u8, length: u32) callconv(.c) u32 {
    if (length > 1280) return code(.invalid_abi);
    const binding = device(context) catch |err| return failure(err);
    binding.sendEthernet(bytes[0..length]) catch |err| return failure(err);
    return code(.ok);
}
fn connected(context: *anyopaque) callconv(.c) u8 {
    const binding = device(context) catch return 0;
    return @intFromBool(binding.isConnected());
}
fn mac(context: *anyopaque, output: *[6]u8) callconv(.c) u32 {
    const binding = device(context) catch |err| return failure(err);
    output.* = binding.capabilities.address;
    return code(.ok);
}
fn stop(context: *anyopaque) callconv(.c) u32 {
    if (!owner(context)) return code(.invalid_abi);
    retired = true;
    boot.retire();
    radio = null;
    return code(if (boot.status().dma_retained) .failed else .retired);
}
fn report(context: *anyopaque, output: *abi.Report) callconv(.c) u32 {
    if (!owner(context)) return code(.invalid_abi);
    const value = boot.status();
    output.* = .{
        .stage = @backingInt(value.stage),
        .status = code(if (retired) .retired else if (value.failure != null) .failed else if (value.stage == .ready) .ok else .unavailable),
        .flags = (if (value.attempted) abi.ReportFlags.attempted else @as(u32, 0)) |
            (if (value.factory_power_intersected) abi.ReportFlags.factory_power_intersected else @as(u32, 0)) |
            (if (value.dma_retained) abi.ReportFlags.dma_retained else @as(u32, 0)),
    };
    if (value.failure) |err| {
        const name = @errorName(err);
        const length = @min(name.len, output.error_text.len);
        @memcpy(output.error_text[0..length], name[0..length]);
        output.error_length = @intCast(length);
    }
    return code(.ok);
}

const RejectAllocator = struct {
    calls: usize = 0,
    fn allocate(context: *anyopaque, _: u64, _: u64, _: *abi.Allocation) callconv(.c) u32 {
        const self: *RejectAllocator = @ptrCast(@alignCast(context));
        self.calls += 1;
        return code(.failed);
    }
    fn resolve(_: *anyopaque, _: u64, _: *abi.Allocation) callconv(.c) u32 {
        return code(.failed);
    }
    fn release(_: *anyopaque, _: u64) callconv(.c) u32 {
        return code(.failed);
    }
};
test "module C entry validates bootstrap and reports absent assets without allocation or hardware" {
    var header = protocol.Header.init(architecture);
    header.header_size = @sizeOf(protocol.BootInfo);
    var info: protocol.BootInfo = .{
        .header = header,
        .uart_base = 0,
        .dtb = .{ .base = 0, .length = 0 },
        .kernel_image = .{ .base = 0x300000, .length = 0x10000 },
        .ram = .{ .base = 0x100000, .length = 0x1000000 },
        .loader_reserved = .{ .base = 0x100000, .length = 0x200000 },
        .kernel_reserved = .{ .base = 0x300000, .length = 0x200000 },
        .flags = 0,
        .entry_state = switch (architecture) {
            .x86_64 => @backingInt(protocol.EntryState.x86_64_long_mode),
            .aarch64 => @backingInt(protocol.EntryState.aarch64_el1),
            .riscv64 => @backingInt(protocol.EntryState.riscv64_s),
        },
        .boot_environment = @backingInt(protocol.BootEnvironment.uefi),
        .firmware_memory_map = .{ .base = 0x110000, .length = 80 },
        .firmware_descriptor_size = 40,
        .firmware_descriptor_version = 1,
        .physical_address_bits = 48,
        .mapped_range_count = 2,
    };
    info.mapped_ranges[0] = info.loader_reserved;
    info.mapped_ranges[1] = info.kernel_reserved;
    var map: protocol.MemoryMap = .{};
    try map.addRam(info.ram);
    try map.addReservation(info.loader_reserved, .loader_reclaimable);
    try map.addReservation(info.kernel_reserved, .kernel);
    try map.finalize(&info);
    var allocator: RejectAllocator = .{};
    var host: abi.Host = .{ .context = &allocator, .boot_info = &info, .boot_info_size = @sizeOf(protocol.BootInfo), .now_ms = 0, .allocate = RejectAllocator.allocate, .resolve = RejectAllocator.resolve, .release = RejectAllocator.release };
    var table: abi.Radio = .{};
    host.abi_major = 2;
    try std.testing.expectEqual(code(.invalid_abi), bedrock_driver_entry(&host, &table));
    try std.testing.expect(!table.validate());
    host.abi_major = abi.major;
    try std.testing.expectEqual(code(.unavailable), bedrock_driver_entry(&host, &table));
    try std.testing.expect(table.validate());
    var status: abi.Report = undefined;
    try std.testing.expectEqual(code(.ok), table.report.?(table.context.?, &status));
    try std.testing.expectEqual(code(.unavailable), status.status);
    try std.testing.expectEqual(@as(u32, abi.ReportFlags.attempted), status.flags);
    try std.testing.expectEqual(@as(usize, 0), allocator.calls);
    try std.testing.expectEqual(code(.retired), table.stop.?(table.context.?));
    try std.testing.expectEqual(code(.retired), table.scan.?(table.context.?, 1));
}
