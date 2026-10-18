//! Private loader/lease broker. Optional chipset code lives in retained driver
//! images; this kernel owns ABI validation and all physical allocator tickets.
const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("boot_protocol");
const abi = @import("driver_abi");
const memory = @import("memory_init");
pub const max_leases = 8;
const Lease = struct { token: u64 = 0, ticket: ?memory.heap_api.Ticket = null };
const Owner = struct {
    address: usize = 0,
    record: *const protocol.DriverRecord = undefined,
    leases: [max_leases]Lease = @splat(.{}),
    radio: abi.Radio = .{},
    imports: abi.Host = undefined,
    attempted: bool = false,
};
var owners: [protocol.max_boot_drivers]Owner = @splat(.{});
var token_highwater: u64 = 0;
var initialized = false;
var last_report: abi.Report = .{};
var selected_radio: ?*const abi.Radio = null;

fn status(value: abi.Status) u32 {
    return @backingInt(value);
}
fn owner(context: *anyopaque) ?*Owner {
    for (&owners) |*value| if (@as(*anyopaque, @ptrCast(value)) == context and value.address == @intFromPtr(value) and value.attempted) return value;
    return null;
}
fn allocate(context: *anyopaque, bytes: u64, alignment: u64, output: *abi.Allocation) callconv(.c) u32 {
    const value = owner(context) orelse return status(.invalid_abi);
    if (bytes == 0 or bytes > 0x200000 or alignment == 0 or alignment > 0x200000 or !std.math.isPowerOfTwo(alignment) or token_highwater == std.math.maxInt(u64)) return status(.failed);
    const slot = for (&value.leases) |*lease| {
        if (lease.ticket == null) break lease;
    } else return status(.failed);
    const ticket = memory.allocateKernel(@intCast(bytes), @intCast(alignment)) catch return status(.failed);
    const block = memory.resolveKernel(ticket) catch {
        memory.freeKernel(ticket) catch {};
        return status(.failed);
    };
    token_highwater += 1;
    slot.* = .{ .token = token_highwater, .ticket = ticket };
    output.* = .{ .token = slot.token, .base = block.range.base, .length = block.range.length };
    return status(.ok);
}
fn resolve(context: *anyopaque, token: u64, output: *abi.Allocation) callconv(.c) u32 {
    const value = owner(context) orelse return status(.invalid_abi);
    for (value.leases) |lease| if (lease.token == token and lease.ticket != null) {
        const block = memory.resolveKernel(lease.ticket.?) catch return status(.failed);
        output.* = .{ .token = token, .base = block.range.base, .length = block.range.length };
        return status(.ok);
    };
    return status(.failed);
}
fn release(context: *anyopaque, token: u64) callconv(.c) u32 {
    const value = owner(context) orelse return status(.invalid_abi);
    for (&value.leases) |*lease| if (lease.token == token and lease.ticket != null) {
        // Module.stop/resource lifecycle must prove DMA quiescence first. The
        // broker never force-frees module leases after failure or timeout.
        memory.freeKernel(lease.ticket.?) catch return status(.failed);
        lease.ticket = null;
        return status(.ok);
    };
    return status(.failed);
}
pub fn validateRadio(record: *const protocol.DriverRecord, radio: *const abi.Radio) !void {
    if (!radio.validate() or !record.contains(@intFromPtr(radio.context.?), 1, 6)) return error.InvalidDriverAbi;
    inline for (.{ "enable", "scan", "join", "cancel", "disconnect", "poll", "send", "connected", "mac", "stop", "report" }) |field|
        if (!validCallback(record, @intFromPtr(@field(radio, field).?))) return error.InvalidDriverCallback;
}
fn validCallback(record: *const protocol.DriverRecord, address: u64) bool {
    const alignment: u64 = switch (builtin.cpu.arch) {
        .aarch64 => 4,
        .riscv64 => 2,
        else => 1,
    };
    return address % alignment == 0 and record.contains(address, alignment, 5);
}
pub fn report() abi.Report {
    return last_report;
}
pub fn validateReport(details: *const abi.Report) !void {
    if (details.error_length > details.error_text.len or details.flags & ~@as(u32, 7) != 0 or details.status > @backingInt(abi.Status.retired)) return error.InvalidDriverReport;
    for (details.error_text[0..details.error_length]) |byte| if (byte < 32 or byte > 126) return error.InvalidDriverReport;
}
fn readReport(radio: *const abi.Radio) !void {
    var details: abi.Report = .{};
    if (radio.report.?(radio.context.?, &details) != status(.ok)) return error.InvalidDriverReport;
    try validateReport(&details);
    last_report = details;
}
pub fn loadedCount() usize {
    return if (selected_radio != null) 1 else 0;
}
pub fn initialize(info: *const protocol.BootInfo, now: u64) !?*const abi.Radio {
    return initializeModule(info, now) catch |err| {
        // Format/ABI failures must stay visible even before a valid reporting
        // callback exists. Retain a module's own cleanup report when available.
        if (last_report.error_length == 0) {
            const name = @errorName(err);
            const length = @min(name.len, last_report.error_text.len);
            last_report = .{ .status = status(.failed), .error_length = @intCast(length) };
            @memcpy(last_report.error_text[0..length], name[0..length]);
        }
        return err;
    };
}
fn initializeModule(info: *const protocol.BootInfo, now: u64) !?*const abi.Radio {
    if (initialized) return error.DriverRuntimeAlreadyInitialized;
    initialized = true;
    if (info.drivers.count > owners.len) return error.InvalidDriverRecord;
    var wifi_count: usize = 0;
    for (info.drivers.records[0..info.drivers.count]) |record| if (record.class == abi.wifi_class) {
        wifi_count += 1;
    };
    if (wifi_count > 1) return error.DuplicateWifiModule;
    for (info.drivers.records[0..info.drivers.count], 0..) |*record, i| {
        if (record.class != abi.wifi_class) continue;
        if (selected_radio != null) return error.DuplicateWifiModule;
        try record.validate();
        const image: [*]const u8 = @ptrFromInt(record.image.base);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(image[0..@intCast(record.image.length)], &digest, .{});
        if (!std.crypto.timing_safe.eql([32]u8, digest, record.image_sha256)) return error.DriverImageChanged;
        const value = &owners[i];
        value.address = @intFromPtr(value);
        value.record = record;
        value.attempted = true;
        value.imports = .{ .context = value, .boot_info = info, .boot_info_size = @sizeOf(protocol.BootInfo), .now_ms = now, .allocate = allocate, .resolve = resolve, .release = release };
        const entry: abi.Entry = @ptrFromInt(record.entry);
        const result = entry(&value.imports, &value.radio);
        errdefer {
            if (value.radio.context != null and value.radio.stop != null and record.contains(@intFromPtr(value.radio.context.?), 1, 6) and validCallback(record, @intFromPtr(value.radio.stop.?))) {
                _ = value.radio.stop.?(value.radio.context.?);
                if (value.radio.report != null and validCallback(record, @intFromPtr(value.radio.report.?))) readReport(&value.radio) catch {};
            }
        }
        try validateRadio(record, &value.radio);
        try readReport(&value.radio);
        if (result > status(.retired)) return error.InvalidDriverStatus;
        if (result != status(.ok)) {
            _ = value.radio.stop.?(value.radio.context.?);
            readReport(&value.radio) catch {};
            continue;
        }
        if (last_report.status != status(.ok) or last_report.flags & abi.ReportFlags.dma_retained != 0) return error.InvalidDriverStatus;
        selected_radio = &value.radio;
    }
    return selected_radio;
}

test "module report bounds reject malformed text, flags and statuses" {
    var details: abi.Report = .{ .error_length = 96 };
    @memset(&details.error_text, 'A');
    try validateReport(&details);
    details.error_length = 97;
    try std.testing.expectError(error.InvalidDriverReport, validateReport(&details));
    details.error_length = 1;
    details.error_text[0] = '\n';
    try std.testing.expectError(error.InvalidDriverReport, validateReport(&details));
    details.error_length = 0;
    details.flags = 8;
    try std.testing.expectError(error.InvalidDriverReport, validateReport(&details));
    details.flags = 0;
    details.status = 6;
    try std.testing.expectError(error.InvalidDriverReport, validateReport(&details));
}
test "callback validation rejects data and unmapped pointers without calling them" {
    var record: protocol.DriverRecord = .{ .segment_count = 2 };
    record.segments[0] = .{ .range = .{ .base = 0x100000, .length = 4096 }, .flags = 5 };
    record.segments[1] = .{ .range = .{ .base = 0x101000, .length = 4096 }, .flags = 6 };
    try std.testing.expect(validCallback(&record, 0x100000));
    try std.testing.expect(!validCallback(&record, 0x101000));
    try std.testing.expect(!validCallback(&record, 0x200000));
    try std.testing.expectError(error.InvalidDriverAbi, validateRadio(&record, &abi.Radio{}));
}
pub fn stop() void {
    if (selected_radio) |radio| {
        _ = radio.stop.?(radio.context.?);
        readReport(radio) catch {};
    }
    selected_radio = null;
    // Driver code/data stay reserved until a future unload implementation can
    // revoke every callback and prove all module-owned DMA is quiescent.
}
