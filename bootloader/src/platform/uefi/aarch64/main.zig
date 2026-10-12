//! Standard AArch64 UEFI application; all allocations use firmware services.
const std = @import("std");
const common = @import("uefi_common");
const protocol = @import("boot_protocol");
const options = @import("boot_options");
const uart = @import("uart.zig");
extern var bedrock_uefi_transition_start: u8;
extern var bedrock_uefi_transition_end: u8;
extern fn bedrock_uefi_current_el() callconv(.c) u64;
extern fn bedrock_uefi_physical_bits() callconv(.c) u32;
extern fn bedrock_uefi_halt() callconv(.c) noreturn;
extern fn bedrock_uefi_smoke_exit(status: u32) callconv(.c) noreturn;
extern fn bedrock_uefi_publish_code(address: usize, length: usize) callconv(.c) void;
extern fn bedrock_uefi_run_on_stack(callback: *const fn (*anyopaque) callconv(.c) usize, context: *anyopaque, stack_top: usize) callconv(.c) usize;

const Arch = struct {
    pub const cpu_arch = std.Target.Cpu.Arch.aarch64;
    pub const architecture = protocol.Architecture.aarch64;
    pub const entry_state = protocol.EntryState.aarch64_el1;
    pub const name = "ARM64";
    pub fn physicalBits() !u32 {
        const level = bedrock_uefi_current_el();
        if (level != 1 and level != 2) return error.UnsupportedPrivilege;
        const bits = bedrock_uefi_physical_bits();
        if (bits == 0) return error.UnsupportedAddressWidth;
        return bits;
    }
    pub fn configure(console: protocol.Console) !void {
        try uart.configure(console);
    }
    pub fn write(bytes: []const u8) void {
        uart.write(bytes);
    }
    pub fn publishCode(address: usize, length: usize) void {
        bedrock_uefi_publish_code(address, length);
    }
    pub fn runOnStack(callback: *const fn (*anyopaque) callconv(.c) usize, context: *anyopaque, stack_top: usize) usize {
        return bedrock_uefi_run_on_stack(callback, context, stack_top);
    }
    pub fn transitionBytes() []const u8 {
        const start = @intFromPtr(&bedrock_uefi_transition_start);
        return @as([*]const u8, @ptrFromInt(start))[0 .. @intFromPtr(&bedrock_uefi_transition_end) - start];
    }
    pub fn stop(status: u32) noreturn {
        if (options.smoke_test) bedrock_uefi_smoke_exit(status);
        bedrock_uefi_halt();
    }
};
pub const panic = common.Panic(Arch);
pub fn main() std.os.uefi.Status {
    return common.main(Arch);
}
