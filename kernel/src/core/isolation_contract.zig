//! The architecture boundary for protected probes and saved user contexts.
//! These records carry trusted kernel state; they are not a public app ABI.
pub const page_size: u64 = 4096;
pub const user_base: u64 = 0x20_0000_0000;
pub const user_code: u64 = user_base;
pub const user_data: u64 = user_base + page_size;
pub const user_guard: u64 = user_base + 2 * page_size;
pub const user_stack: u64 = user_base + 3 * page_size;
pub const user_stack_top: u64 = user_base + 4 * page_size;

pub const KernelLayout = struct {
    kernel_start: u64,
    text_start: u64,
    text_end: u64,
    rodata_start: u64,
    rodata_end: u64,
    data_start: u64,
    data_end: u64,
    allocated_end: u64,
    stack_bottom: u64,
    stack_top: u64,
    stack_guard: u64,
};
pub const desktop_code: u64 = user_base + 0x10000;
pub const desktop_data: u64 = user_base + 0x40000;
pub const desktop_stack: u64 = user_base + 0x1e0000;
pub const user_window_end: u64 = user_base + 0x200000;
pub const Mapping = struct { virtual: u64, physical: u64, pages: u16, writable: bool };
/// Contiguous, owned physical ranges. Only the two kernel-defined layouts are
/// accepted; applications cannot choose mappings, permissions or addresses.
pub const TaskMemory = struct {
    code: u64,
    data: u64,
    stack: u64,
    code_pages: u16 = 1,
    data_pages: u16 = 1,
    stack_pages: u16 = 1,
    desktop: bool = false,

    pub fn mappings(self: TaskMemory) [3]Mapping {
        return .{
            .{ .virtual = self.codeVirtual(), .physical = self.code, .pages = self.code_pages, .writable = false },
            .{ .virtual = self.dataVirtual(), .physical = self.data, .pages = self.data_pages, .writable = true },
            .{ .virtual = self.stackVirtual(), .physical = self.stack, .pages = self.stack_pages, .writable = true },
        };
    }
    pub fn codeVirtual(self: TaskMemory) u64 {
        return if (self.desktop) desktop_code else user_code;
    }
    pub fn dataVirtual(self: TaskMemory) u64 {
        return if (self.desktop) desktop_data else user_data;
    }
    pub fn stackVirtual(self: TaskMemory) u64 {
        return if (self.desktop) desktop_stack else user_stack;
    }
    pub fn codeEnd(self: TaskMemory) u64 {
        return self.codeVirtual() + @as(u64, self.code_pages) * page_size;
    }
    pub fn stackTop(self: TaskMemory) u64 {
        return self.stackVirtual() + @as(u64, self.stack_pages) * page_size;
    }
    pub fn guard(self: TaskMemory) u64 {
        return self.stackVirtual() - page_size;
    }
    pub fn validate(self: TaskMemory) !void {
        if (self.desktop) {
            if (self.code_pages == 0 or self.code_pages > 32 or self.data_pages == 0 or self.data_pages > 256 or
                self.stack_pages == 0 or self.stack_pages > 16) return error.InvalidTaskMemory;
        } else if (self.code_pages != 1 or self.data_pages != 1 or self.stack_pages != 1) return error.InvalidTaskMemory;
        const ranges = self.mappings();
        for (ranges, 0..) |range, i| {
            const bytes = @as(u64, range.pages) * page_size;
            const limit = @addWithOverflow(range.physical, bytes);
            if (range.physical == 0 or range.physical % page_size != 0 or limit[1] != 0) return error.InvalidTaskMemory;
            for (ranges[0..i]) |earlier| {
                if (range.physical < earlier.physical + @as(u64, earlier.pages) * page_size and earlier.physical < limit[0])
                    return error.InvalidTaskMemory;
            }
        }
    }
};
/// Kernel-only identity; a recycled root must never revive a stale reference.
pub const AddressSpace = struct { root: u64, generation: u64 = 0 };
/// Opaque kernel-only reference to a saved native context. Apps never supply it.
pub const ContextHandle = enum(u64) { _ };
pub const Invocation = extern struct { entry: u64, user_sp: u64, arg0: u64, arg1: u64, arg2: u64 };
pub const Event = extern struct {
    kind: u64,
    number: u64,
    arg0: u64,
    arg1: u64,
    arg2: u64,
    pc: u64,
    fault_address: u64,
    syndrome: u64,
};
pub const Reply = extern struct { action: u64, result: u64 };
pub const event_syscall: u64 = 1;
pub const event_fault: u64 = 2;
pub const event_timer: u64 = 3;
pub const action_resume: u64 = 0;
pub const action_terminate: u64 = 1;
pub const action_suspend: u64 = 2;
pub const syscall_report: u64 = 0;
pub const syscall_exit: u64 = 1;
pub const syscall_write_handle: u64 = 2;
pub const syscall_unknown: u64 = 0xffff;
pub const errno_fault: u64 = @bitCast(@as(i64, -14));
pub const errno_access: u64 = @bitCast(@as(i64, -13));
pub const errno_unknown: u64 = @bitCast(@as(i64, -38));

pub const Probe = enum(u64) { normal, kernel_read, peer_read, code_write, stack_execute, guard_read, spin };

comptime {
    if (@sizeOf(Event) != 64 or @sizeOf(Reply) != 16 or @sizeOf(Invocation) != 40)
        @compileError("User transition assembly contract changed");
}

test "desktop layout remains bounded and fixture pages cannot widen" {
    const t = @import("std").testing;
    const wide: TaskMemory = .{ .code = 0x100000, .data = 0x200000, .stack = 0x400000, .desktop = true, .code_pages = 32, .data_pages = 256, .stack_pages = 16 };
    try wide.validate();
    try t.expect(wide.codeEnd() < wide.dataVirtual());
    try t.expect(wide.dataVirtual() + @as(u64, wide.data_pages) * page_size < wide.guard());
    try t.expect(wide.stackTop() <= user_window_end);
    var bad = wide;
    bad.desktop = false;
    try t.expectError(error.InvalidTaskMemory, bad.validate());
    bad = wide;
    bad.code_pages = 33;
    try t.expectError(error.InvalidTaskMemory, bad.validate());
    bad = wide;
    bad.data_pages = 257;
    try t.expectError(error.InvalidTaskMemory, bad.validate());
}
test "task ranges reject interior overlap wraparound and zero lengths" {
    const t = @import("std").testing;
    var task: TaskMemory = .{ .code = 0x100000, .data = 0x101000, .stack = 0x400000, .desktop = true, .code_pages = 2 };
    try t.expectError(error.InvalidTaskMemory, task.validate());
    task.data = 0x200000;
    task.stack = 0xfffffffffffff000;
    task.stack_pages = 2;
    try t.expectError(error.InvalidTaskMemory, task.validate());
    task.stack = 0x400000;
    task.stack_pages = 0;
    try t.expectError(error.InvalidTaskMemory, task.validate());
}
