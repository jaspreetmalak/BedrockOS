const protocol = @import("boot_protocol");

/// Compile probe only; this is not a supported runtime C interface.
export fn bedrock_boot_protocol_compile_check(arch_tag: u32, base: u64, length: u64) callconv(.c) u32 {
    const arch: protocol.Architecture = switch (arch_tag) {
        @backingInt(protocol.Architecture.x86_64) => .x86_64,
        @backingInt(protocol.Architecture.aarch64) => .aarch64,
        @backingInt(protocol.Architecture.riscv64) => .riscv64,
        else => return 1,
    };
    const header = protocol.Header.init(arch);
    header.validate(@sizeOf(protocol.Header), arch) catch return 2;
    const range = protocol.PhysicalRange{ .base = base, .length = length };
    _ = range.endExclusive() catch return 3;
    return 0;
}
