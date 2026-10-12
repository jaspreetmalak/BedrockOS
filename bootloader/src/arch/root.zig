pub const selected = switch (@import("builtin").cpu.arch) {
    .x86_64 => @import("x86_64/root.zig"),
    .aarch64 => @import("aarch64/root.zig"),
    .riscv64 => @import("riscv64/root.zig"),
    else => @compileError("Bedrock bootloader supports x86_64, aarch64, and riscv64."),
};
pub const kind = selected.kind;
