//! TEST ONLY: explicitly supplied local linux-firmware reference files.
//! No network access, implicit fetch, firmware download, MMIO or PCI operations.
//! Build supplies the native wifi_drivers module; pass --reference-files PATCH RAM.
//! Without --reference-files this optional check skips without opening files.
const std = @import("std");
const Firmware = @import("wifi_drivers").mt7922_transport.Firmware;
const max_file_bytes = 8 * 1024 * 1024;
const usage = "usage: firmware_reference_check --reference-files PATCH RAM\n";

pub fn main(init: std.process.Init) !void {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    if (arguments.len == 1) {
        return std.Io.File.stdout().writeStreamingAll(init.io, "SKIP: explicit --reference-files PATCH RAM required; no files opened\n");
    }
    if (arguments.len != 4 or !std.mem.eql(u8, arguments[1], "--reference-files")) {
        try std.Io.File.stderr().writeStreamingAll(init.io, usage);
        return error.InvalidArguments;
    }
    const patch = try std.Io.Dir.cwd().readFileAlloc(init.io, arguments[2], init.gpa, .limited(max_file_bytes));
    defer init.gpa.free(patch);
    const ram = try std.Io.Dir.cwd().readFileAlloc(init.io, arguments[3], init.gpa, .limited(max_file_bytes));
    defer init.gpa.free(ram);
    try validateReferences(init.gpa, patch, ram);
    try std.Io.File.stdout().writeStreamingAll(init.io, "PASS: pinned MT7922 patch/RAM hashes and formats accepted; 17 mutation/truncation/extension/cross-pair rejections; originals revalidated (19 checks). No device operations.\n");
}

fn rejected(firmware: Firmware) !void {
    firmware.validate() catch |err| {
        if (err != error.WrongFirmware) return error.UnexpectedRejection;
        return;
    };
    return error.InvalidReferenceAccepted;
}

/// Mutate only caller-owned temporary RAM, restoring every byte. The actual
/// transport's intact-file validator is used, not a duplicate hash policy.
pub fn validateReferences(allocator: std.mem.Allocator, patch: []u8, ram: []u8) !void {
    try (Firmware{ .patch = patch, .ram = ram }).validate();
    for ([_]usize{ 0, 96, patch.len / 2, patch.len - 1 }) |index| {
        const saved = patch[index];
        patch[index] ^= 1;
        defer patch[index] = saved;
        try rejected(.{ .patch = patch, .ram = ram });
    }
    for ([_]usize{ 0, ram.len / 2, ram.len - 36, ram.len - 1 }) |index| {
        const saved = ram[index];
        ram[index] ^= 1;
        defer ram[index] = saved;
        try rejected(.{ .patch = patch, .ram = ram });
    }
    for ([_]usize{ 0, 1, patch.len - 1 }) |length| try rejected(.{ .patch = patch[0..length], .ram = ram });
    for ([_]usize{ 0, 1, ram.len - 1 }) |length| try rejected(.{ .patch = patch, .ram = ram[0..length] });
    const extended_patch = try allocator.alloc(u8, patch.len + 1);
    defer allocator.free(extended_patch);
    @memcpy(extended_patch[0..patch.len], patch);
    extended_patch[patch.len] = 0;
    try rejected(.{ .patch = extended_patch, .ram = ram });
    const extended_ram = try allocator.alloc(u8, ram.len + 1);
    defer allocator.free(extended_ram);
    @memcpy(extended_ram[0..ram.len], ram);
    extended_ram[ram.len] = 0;
    try rejected(.{ .patch = patch, .ram = extended_ram });
    try rejected(.{ .patch = ram, .ram = patch });
    try (Firmware{ .patch = patch, .ram = ram }).validate();
}
