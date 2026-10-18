//! Force the complete EFI application asset path through all target compilers.
const std = @import("std");
const bundles = @import("app_bundles");
const assets = @import("app_assets.zig");
const architecture: bundles.Architecture = switch (@import("builtin").cpu.arch) {
    .x86_64 => .x86_64,
    .aarch64 => .aarch64,
    .riscv64 => .riscv64,
    else => @compileError("Bedrock supports x86_64, ARM64 and RV64"),
};
export fn bedrock_app_assets_compile_check(bs: *std.os.uefi.tables.BootServices, image: std.os.uefi.Handle) void {
    if (assets.stage(bs, image, architecture, 0x1_0000_0000) catch null) |retained| {
        var allocation = retained;
        allocation.release(bs) catch {};
    }
}
