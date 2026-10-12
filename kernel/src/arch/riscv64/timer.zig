//! SBI TIME owns the machine timer. This supervisor driver discovers the clock
//! from the retained DTB and enables only STIE for a bounded user quantum.
const std = @import("std");

pub const interrupt_cause: u64 = (@as(u64, 1) << 63) | 5;
pub const interrupt_number: u64 = 5;
const stie: u64 = 1 << 5;
var quantum_ticks: u64 = 0;
var deadline: u64 = 0;

extern fn bedrock_riscv_sbi_probe_time() callconv(.c) i64;
extern fn bedrock_riscv_sbi_set_timer(value: u64) callconv(.c) i64;
extern fn bedrock_riscv_read_time() callconv(.c) u64;

pub fn prepare(blob: []const u8) !void {
    if (quantum_ticks != 0) return error.TimerAlreadyPrepared;
    const frequency = try timebaseFrequency(blob);
    if (bedrock_riscv_sbi_probe_time() <= 0) return error.SbiTimeUnavailable;
    // Round up: even a low-frequency clock provides a nonzero ~10 ms slice.
    const ticks = (@as(u64, frequency) + 99) / 100;
    try quiesce();
    // Probe the individual enable while SIE is clear, then leave it masked.
    asm volatile ("csrs sie, %[bit]"
        :
        : [bit] "r" (stie),
        : .{ .memory = true });
    const enabled = asm volatile ("csrr %[value], sie"
        : [value] "=r" (-> u64),
        :
        : .{ .memory = true });
    mask();
    if (enabled & stie == 0) return error.SupervisorTimerUnavailable;
    quantum_ticks = ticks;
}

pub fn arm() !void {
    if (quantum_ticks == 0) return error.TimerNotPrepared;
    mask();
    if (deadline == 0) {
        const next = @addWithOverflow(bedrock_riscv_read_time(), quantum_ticks);
        if (next[1] != 0) return error.TimerDeadlineOverflow;
        deadline = next[0];
    }
    try set(deadline);
    // Entry assembly enables STIE after installing the trusted trap vector.
}

pub fn expired() bool {
    return deadline != 0 and bedrock_riscv_read_time() >= deadline;
}

/// A posted interrupt may take time to fall after moving the compare value.
/// Re-arm an early interrupt without publishing a scheduling event.
pub fn resumeEarly() !void {
    if (deadline == 0 or quantum_ticks == 0) return error.TimerNotArmed;
    try set(deadline);
    asm volatile ("csrs sie, %[bit]"
        :
        : [bit] "r" (stie),
        : .{ .memory = true });
}

pub fn quiesce() !void {
    mask();
    try set(std.math.maxInt(u64));
    // Suppress delivery, retaining the unfinished absolute quantum. A saved
    // past deadline will post a real interrupt when arm() restores it.
}

/// Only an observed expired hardware timer consumes the current quantum.
pub fn acknowledge() !void {
    if (!expired()) return error.TimerNotExpired;
    try quiesce();
    deadline = 0;
}

fn mask() void {
    asm volatile ("csrc sie, %[bit]"
        :
        : [bit] "r" (stie),
        : .{ .memory = true });
}

fn set(value: u64) !void {
    // SBI TIME set_timer accepts an absolute time and clears pending delivery;
    // UINT64_MAX is the specification's request to suppress the next interrupt.
    if (bedrock_riscv_sbi_set_timer(value) != 0) return error.SbiTimerFailed;
}

fn be32(bytes: []const u8, at: usize) !u32 {
    if (at > bytes.len or bytes.len - at < 4) return error.TruncatedDtb;
    return (@as(u32, bytes[at]) << 24) | (@as(u32, bytes[at + 1]) << 16) |
        (@as(u32, bytes[at + 2]) << 8) | bytes[at + 3];
}

fn block(bytes: []const u8, offset: u32, size: u32) ![]const u8 {
    if (offset < 40 or offset > bytes.len or size > bytes.len - offset)
        return error.InvalidDtbBlock;
    return bytes[offset..][0..size];
}

fn string(bytes: []const u8, at: usize) ![]const u8 {
    if (at >= bytes.len) return error.InvalidDtbString;
    const length = std.mem.indexOfScalar(u8, bytes[at..], 0) orelse return error.InvalidDtbString;
    return bytes[at..][0..length];
}

fn aligned(value: usize, limit: usize) !usize {
    if (value > limit or limit - value < (4 - value % 4) % 4) return error.TruncatedDtb;
    return (value + 3) & ~@as(usize, 3);
}

/// The loader already validates the complete FDT. This allocation-free bounded
/// pass additionally requires one unambiguous /cpus/timebase-frequency cell.
pub fn timebaseFrequency(blob: []const u8) !u32 {
    if (blob.len < 40 or try be32(blob, 0) != 0xd00dfeed or try be32(blob, 4) != blob.len or
        try be32(blob, 20) != 17 or try be32(blob, 24) > 17)
        return error.InvalidDtbHeader;
    const structure_offset = try be32(blob, 8);
    const strings_offset = try be32(blob, 12);
    const strings_size = try be32(blob, 32);
    const structure_size = try be32(blob, 36);
    if (structure_offset % 4 != 0 or structure_size % 4 != 0) return error.InvalidDtbBlock;
    const structure = try block(blob, structure_offset, structure_size);
    const strings = try block(blob, strings_offset, strings_size);
    if (structure_offset < @as(u64, strings_offset) + strings_size and
        strings_offset < @as(u64, structure_offset) + structure_size) return error.InvalidDtbBlock;
    var depth: usize = 0;
    var root_seen = false;
    var cpus_seen = false;
    var cpus_depth: usize = 0;
    var children_started: [32]bool = @splat(false);
    var frequency: ?u32 = null;
    var at: usize = 0;
    while (at < structure.len) {
        const token = try be32(structure, at);
        at += 4;
        switch (token) {
            1 => {
                if (depth == children_started.len) return error.DtbDepthExceeded;
                const name = try string(structure, at);
                at = try aligned(at + name.len + 1, structure.len);
                if (depth == 0) {
                    if (root_seen or name.len != 0) return error.InvalidDtbStructure;
                    root_seen = true;
                } else children_started[depth - 1] = true;
                if (depth == 1 and std.mem.eql(u8, name, "cpus")) {
                    if (cpus_seen) return error.DuplicateCpusNode;
                    cpus_seen = true;
                    cpus_depth = 2;
                }
                children_started[depth] = false;
                depth += 1;
            },
            2 => {
                if (depth == 0) return error.InvalidDtbStructure;
                if (depth == cpus_depth) cpus_depth = 0;
                depth -= 1;
            },
            3 => {
                if (depth == 0 or children_started[depth - 1]) return error.InvalidDtbStructure;
                const length = try be32(structure, at);
                const name_offset = try be32(structure, at + 4);
                at += 8;
                if (at > structure.len or length > structure.len - at) return error.TruncatedDtb;
                const name = try string(strings, name_offset);
                if (depth == cpus_depth and std.mem.eql(u8, name, "timebase-frequency")) {
                    if (frequency != null) return error.DuplicateTimebaseFrequency;
                    if (length != 4) return error.InvalidTimebaseFrequency;
                    const value = try be32(structure, at);
                    if (value == 0) return error.InvalidTimebaseFrequency;
                    frequency = value;
                }
                at = try aligned(at + length, structure.len);
            },
            4 => {},
            9 => {
                if (depth != 0 or !root_seen or at != structure.len) return error.InvalidDtbStructure;
                return frequency orelse error.MissingTimebaseFrequency;
            },
            else => return error.InvalidDtbStructure,
        }
    }
    return error.InvalidDtbStructure;
}

fn fixture() [123]u8 {
    var result: [123]u8 = @splat(0);
    const words = [_]struct { at: usize, value: u32 }{
        .{ .at = 0, .value = 0xd00dfeed }, .{ .at = 4, .value = 123 },
        .{ .at = 8, .value = 56 },         .{ .at = 12, .value = 104 },
        .{ .at = 16, .value = 40 },        .{ .at = 20, .value = 17 },
        .{ .at = 24, .value = 16 },        .{ .at = 32, .value = 19 },
        .{ .at = 36, .value = 48 },        .{ .at = 56, .value = 1 },
        .{ .at = 64, .value = 1 },         .{ .at = 76, .value = 3 },
        .{ .at = 80, .value = 4 },         .{ .at = 88, .value = 10_000_000 },
        .{ .at = 92, .value = 2 },         .{ .at = 96, .value = 2 },
        .{ .at = 100, .value = 9 },
    };
    for (words) |word| put32(&result, word.at, word.value);
    result[68..73].* = "cpus\x00".*;
    result[104..123].* = "timebase-frequency\x00".*;
    return result;
}
fn put32(bytes: []u8, at: usize, value: u32) void {
    for (0..4) |i| bytes[at + i] = @truncate(value >> @as(u5, @intCast((3 - i) * 8)));
}

test "timebase discovery reads a bounded big-endian /cpus cell" {
    const bytes = fixture();
    try std.testing.expectEqual(@as(u32, 10_000_000), try timebaseFrequency(&bytes));
}
test "timebase discovery rejects truncation, zero and unsupported cell widths" {
    var bytes = fixture();
    try std.testing.expectError(error.InvalidDtbHeader, timebaseFrequency(bytes[0..100]));
    put32(&bytes, 88, 0);
    try std.testing.expectError(error.InvalidTimebaseFrequency, timebaseFrequency(&bytes));
    put32(&bytes, 80, 8);
    try std.testing.expectError(error.InvalidTimebaseFrequency, timebaseFrequency(&bytes));
}
test "timebase discovery rejects properties outside /cpus and malformed structure" {
    var bytes = fixture();
    bytes[68..72].* = "fake".*;
    try std.testing.expectError(error.MissingTimebaseFrequency, timebaseFrequency(&bytes));
    put32(&bytes, 92, 0xdeadbeef);
    try std.testing.expectError(error.InvalidDtbStructure, timebaseFrequency(&bytes));
}
test "timebase discovery bounds property values and string references" {
    var bytes = fixture();
    put32(&bytes, 80, 0xfffffff0);
    try std.testing.expectError(error.TruncatedDtb, timebaseFrequency(&bytes));
    put32(&bytes, 80, 4);
    put32(&bytes, 84, 19);
    try std.testing.expectError(error.InvalidDtbString, timebaseFrequency(&bytes));
}
