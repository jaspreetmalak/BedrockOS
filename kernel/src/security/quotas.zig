//! Portable bookkeeping for a trusted kernel's per-application resource budget.
//! This does not allocate resources, enforce sandbox isolation, or track CPUs.
//! The caller must serialize changes and keep the budget alive for every charge.
//! Future children must charge the same app-tree instance, not copied budgets.
const std = @import("std");

pub const Resources = struct {
    memory_pages: u64 = 0,
    handles: u64 = 0,
    processes: u64 = 0,
    ipc_bytes: u64 = 0,
};

pub const Error = error{
    CounterOverflow,
    ResourceLimitExceeded,
    CounterUnderflow,
};

pub const Budget = struct {
    limits: Resources,
    used: Resources = .{},

    /// Zero permits no consumption of that resource. Exact limits are allowed.
    pub fn init(limits: Resources) Budget {
        return .{ .limits = limits };
    }

    /// Charge all requested resources together or leave every counter unchanged.
    /// The trusted caller performs the resource operation only after success
    /// and releases the charge if that later operation fails.
    pub fn reserve(self: *Budget, delta: Resources) Error!void {
        const next: Resources = .{
            .memory_pages = try add(self.used.memory_pages, delta.memory_pages),
            .handles = try add(self.used.handles, delta.handles),
            .processes = try add(self.used.processes, delta.processes),
            .ipc_bytes = try add(self.used.ipc_bytes, delta.ipc_bytes),
        };
        if (next.memory_pages > self.limits.memory_pages or
            next.handles > self.limits.handles or
            next.processes > self.limits.processes or
            next.ipc_bytes > self.limits.ipc_bytes)
            return error.ResourceLimitExceeded;
        self.used = next;
    }

    /// Release a previously charged amount. Bookkeeping alone cannot prove
    /// which caller owns a charge; resource ownership stays with the kernel.
    pub fn release(self: *Budget, delta: Resources) Error!void {
        const next: Resources = .{
            .memory_pages = try subtract(self.used.memory_pages, delta.memory_pages),
            .handles = try subtract(self.used.handles, delta.handles),
            .processes = try subtract(self.used.processes, delta.processes),
            .ipc_bytes = try subtract(self.used.ipc_bytes, delta.ipc_bytes),
        };
        self.used = next;
    }

    /// Valid while callers preserve used <= limits through reserve/release.
    pub fn remaining(self: *const Budget) Resources {
        return .{
            .memory_pages = self.limits.memory_pages - self.used.memory_pages,
            .handles = self.limits.handles - self.used.handles,
            .processes = self.limits.processes - self.used.processes,
            .ipc_bytes = self.limits.ipc_bytes - self.used.ipc_bytes,
        };
    }
};

fn add(current: u64, delta: u64) Error!u64 {
    const next = @addWithOverflow(current, delta);
    if (next[1] != 0) return error.CounterOverflow;
    return next[0];
}

fn subtract(current: u64, delta: u64) Error!u64 {
    if (delta > current) return error.CounterUnderflow;
    return current - delta;
}

test "exact limits are allowed and released resources can be reused" {
    const limits: Resources = .{ .memory_pages = 16, .handles = 8, .processes = 2, .ipc_bytes = 4096 };
    var budget = Budget.init(limits);
    try std.testing.expectEqualDeep(Resources{}, budget.used);
    try std.testing.expectEqualDeep(limits, budget.remaining());
    try budget.reserve(limits);
    try std.testing.expectEqualDeep(limits, budget.used);
    try std.testing.expectEqualDeep(Resources{}, budget.remaining());
    try budget.release(limits);
    try std.testing.expectEqualDeep(Resources{}, budget.used);
    try std.testing.expectEqualDeep(limits, budget.remaining());
    try budget.reserve(limits);
    try std.testing.expectEqualDeep(limits, budget.used);
}

test "each resource limit rejects atomically after other counters could advance" {
    const limits: Resources = .{ .memory_pages = 10, .handles = 10, .processes = 10, .ipc_bytes = 10 };
    const deltas = [_]Resources{
        .{ .memory_pages = 11, .handles = 1, .processes = 1, .ipc_bytes = 1 },
        .{ .memory_pages = 1, .handles = 11, .processes = 1, .ipc_bytes = 1 },
        .{ .memory_pages = 1, .handles = 1, .processes = 11, .ipc_bytes = 1 },
        .{ .memory_pages = 1, .handles = 1, .processes = 1, .ipc_bytes = 11 },
    };
    for (deltas) |delta| {
        var budget = Budget.init(limits);
        try budget.reserve(.{ .memory_pages = 2, .handles = 2, .processes = 2, .ipc_bytes = 2 });
        const before = budget;
        try std.testing.expectError(error.ResourceLimitExceeded, budget.reserve(delta));
        try std.testing.expectEqualDeep(before, budget);
    }
}

test "overflow in any resource leaves the entire budget unchanged" {
    const max = std.math.maxInt(u64);
    const limits: Resources = .{ .memory_pages = max, .handles = max, .processes = max, .ipc_bytes = max };
    const charges = [_]Resources{
        .{ .memory_pages = max },
        .{ .handles = max },
        .{ .processes = max },
        .{ .ipc_bytes = max },
    };
    for (charges) |charge| {
        var budget = Budget.init(limits);
        try budget.reserve(charge);
        const before = budget;
        try std.testing.expectError(error.CounterOverflow, budget.reserve(.{
            .memory_pages = 1,
            .handles = 1,
            .processes = 1,
            .ipc_bytes = 1,
        }));
        try std.testing.expectEqualDeep(before, budget);
    }
}

test "underflow in any release leaves every counter unchanged" {
    const limits: Resources = .{ .memory_pages = 10, .handles = 10, .processes = 10, .ipc_bytes = 10 };
    const releases = [_]Resources{
        .{ .memory_pages = 3, .handles = 1, .processes = 1, .ipc_bytes = 1 },
        .{ .memory_pages = 1, .handles = 3, .processes = 1, .ipc_bytes = 1 },
        .{ .memory_pages = 1, .handles = 1, .processes = 3, .ipc_bytes = 1 },
        .{ .memory_pages = 1, .handles = 1, .processes = 1, .ipc_bytes = 3 },
    };
    for (releases) |delta| {
        var budget = Budget.init(limits);
        try budget.reserve(.{ .memory_pages = 2, .handles = 2, .processes = 2, .ipc_bytes = 2 });
        const before = budget;
        try std.testing.expectError(error.CounterUnderflow, budget.release(delta));
        try std.testing.expectEqualDeep(before, budget);
    }
}

test "zero limits deny each resource while zero changes are allowed" {
    var budget = Budget.init(.{});
    try budget.reserve(.{});
    try budget.release(.{});
    for ([_]Resources{
        .{ .memory_pages = 1 },
        .{ .handles = 1 },
        .{ .processes = 1 },
        .{ .ipc_bytes = 1 },
    }) |delta| {
        try std.testing.expectError(error.ResourceLimitExceeded, budget.reserve(delta));
        try std.testing.expectError(error.CounterUnderflow, budget.release(delta));
        try std.testing.expectEqualDeep(Resources{}, budget.used);
    }
    try std.testing.expectEqualDeep(Resources{}, budget.remaining());
}

test "partial releases restore only their exact resource amounts" {
    var budget = Budget.init(.{ .memory_pages = 20, .handles = 10, .processes = 4, .ipc_bytes = 8192 });
    try budget.reserve(.{ .memory_pages = 10, .handles = 6, .processes = 2, .ipc_bytes = 4096 });
    try budget.release(.{ .memory_pages = 4, .handles = 1, .ipc_bytes = 1024 });
    try std.testing.expectEqualDeep(Resources{ .memory_pages = 6, .handles = 5, .processes = 2, .ipc_bytes = 3072 }, budget.used);
    try std.testing.expectEqualDeep(Resources{ .memory_pages = 14, .handles = 5, .processes = 2, .ipc_bytes = 5120 }, budget.remaining());
}
