//! One-CPU GICv2 + EL1 non-secure physical timer, discovered through the FDT.
//! This binding subset rejects translated buses, GIC security extensions and
//! unsupported timer interrupt encodings. No firmware addresses are guessed.
const std = @import("std");
const protocol = @import("boot_protocol");

pub const Description = struct {
    distributor: protocol.PhysicalRange,
    cpu_interface: protocol.PhysicalRange,
    interrupt_id: u32,
    clock_hz: ?u32 = null,
};

var description: Description = undefined;
var ready = false;
var armed = false;
var quantum_ticks: u32 = 0;
var deadline: u64 = 0;

extern fn bedrock_arm_timer_initialize() callconv(.c) u64;
extern fn bedrock_arm_timer_stop() callconv(.c) void;
extern fn bedrock_arm_timer_status() callconv(.c) u64;
extern fn bedrock_arm_timer_now() callconv(.c) u64;
extern fn bedrock_arm_device_barrier() callconv(.c) void;

pub fn initialize(value: Description) !void {
    if (ready) return error.TimerAlreadyInitialized;
    if (value.interrupt_id < 16 or value.interrupt_id > 31 or
        value.distributor.length < 0x1000 or value.cpu_interface.length < 0x100)
        return error.TruncatedGicRegisters;
    description = value;
    const frequency = bedrock_arm_timer_initialize();
    if (frequency < 100 or frequency / 100 > 0x7fff_ffff or
        (value.clock_hz != null and value.clock_hz.? != frequency)) return error.UnsupportedTimerFrequency;
    quantum_ticks = @intCast(frequency / 100); // approximately 10 ms
    const typer = read(value.distributor.base + 4);
    // The supported named profile has no Secure-world controller ownership.
    if (typer & (1 << 10) != 0) return error.UnsupportedGicSecurityExtensions;
    const banks: u32 = (typer & 31) + 1;
    write(value.distributor.base, 0);
    write(value.cpu_interface.base, 0);
    for (0..banks) |bank| {
        const offset = bank * 4;
        write(value.distributor.base + 0x180 + offset, 0xffff_ffff);
        write(value.distributor.base + 0x280 + offset, 0xffff_ffff);
        write(value.distributor.base + 0x380 + offset, 0xffff_ffff);
    }
    const bit = @as(u32, 1) << @as(u5, @intCast(value.interrupt_id));
    // Group0 is IRQ (FIQEn=0) on a GICv2 without Security Extensions.
    write(value.distributor.base + 0x80, read(value.distributor.base + 0x80) & ~bit);
    const priority_address = value.distributor.base + 0x400 + (value.interrupt_id & ~@as(u32, 3));
    const priority_shift: u5 = @intCast((value.interrupt_id & 3) * 8);
    write(priority_address, (read(priority_address) & ~(@as(u32, 255) << priority_shift)) | (@as(u32, 0x80) << priority_shift));
    const configuration = value.distributor.base + 0xc04; // banked PPIs16..31
    const edge_bit = @as(u32, 2) << @as(u5, @intCast((value.interrupt_id - 16) * 2));
    write(configuration, read(configuration) & ~edge_bit);
    if (read(configuration) & edge_bit != 0) return error.UnsupportedTimerTrigger;
    write(value.cpu_interface.base + 4, 255); // priority mask
    write(value.cpu_interface.base + 8, 0); // binary point
    write(value.distributor.base + 0x100, bit);
    write(value.distributor.base, 1);
    write(value.cpu_interface.base, 1); // EOImode=0: EOIR also deactivates
    if (read(value.distributor.base + 0x100) & bit == 0 or
        read(value.distributor.base) & 1 == 0 or read(value.cpu_interface.base) & 1 == 0)
        return error.GicTimerEnableFailed;
    ready = true;
}

/// Assembly restores this absolute CVAL just before ERET. Quiescing delivery
/// retains an unfinished quantum across cooperative returns and idle waits.
pub fn beginQuantum() u64 {
    if (!ready or armed) @panic("invalid ARM timer quantum");
    if (deadline == 0) {
        const next = @addWithOverflow(bedrock_arm_timer_now(), @as(u64, quantum_ticks));
        if (next[1] != 0) @panic("ARM timer deadline overflow");
        deadline = next[0];
    }
    armed = true;
    return deadline;
}

/// A masked kernel wait may observe the pending source without acknowledging
/// it. HPPIR avoids consuming a spurious IAR before the GIC posts the timer.
pub fn pending() bool {
    return ready and armed and bedrock_arm_timer_status() & 7 == 5 and
        read(description.cpu_interface.base + 0x18) & 1023 == description.interrupt_id;
}

/// IRQ authority comes from the controller's IAR and the expired CNTP source.
pub fn acknowledge() !u32 {
    if (!ready or !armed) return error.UnexpectedTimerInterrupt;
    const acknowledge_word = read(description.cpu_interface.base + 0xc);
    const id = acknowledge_word & 1023;
    if (id != description.interrupt_id or bedrock_arm_timer_status() & 7 != 5)
        return error.UnexpectedTimerInterrupt;
    bedrock_arm_timer_stop();
    write(description.distributor.base + 0x280, @as(u32, 1) << @as(u5, @intCast(id)));
    write(description.cpu_interface.base + 0x10, acknowledge_word);
    armed = false;
    deadline = 0;
    return id;
}

pub fn quiesce() void {
    if (!ready) return;
    bedrock_arm_timer_stop();
    write(description.distributor.base + 0x280, @as(u32, 1) << @as(u5, @intCast(description.interrupt_id)));
    armed = false;
}
pub fn isQuiescent() bool {
    return ready and !armed and bedrock_arm_timer_status() & 3 == 2;
}

fn read(address: u64) u32 {
    bedrock_arm_device_barrier();
    const value = @as(*volatile u32, @ptrFromInt(address)).*;
    bedrock_arm_device_barrier();
    return value;
}
fn write(address: u64, value: u32) void {
    bedrock_arm_device_barrier();
    @as(*volatile u32, @ptrFromInt(address)).* = value;
    bedrock_arm_device_barrier();
}

const Node = struct {
    parent_address_cells: u32 = 2,
    parent_size_cells: u32 = 1,
    address_cells: u32 = 2,
    size_cells: u32 = 1,
    interrupt_parent: u32 = 0,
    phandle: u32 = 0,
    interrupt_cells: u32 = 0,
    enabled: bool = true,
    identity: bool = true,
    ranges_identity: bool = false,
    controller: bool = false,
    children: bool = false,
    seen: u32 = 0,
    compatible: ?[]const u8 = null,
    reg: ?[]const u8 = null,
    interrupts: ?[]const u8 = null,
    names: ?[]const u8 = null,
    extended: bool = false,
    clock: ?u32 = null,
};
const Controller = struct { ranges: [2]protocol.PhysicalRange, phandle: u32 };
const TimerNode = struct { parent: u32, interrupts: []const u8, names: ?[]const u8, clock: ?u32 };

/// Allocation-free FDT discovery, with bounded nodes/depth/property counts.
/// Parent properties must precede children, as required by the FDT structure.
pub fn discover(blob: []const u8) !Description {
    if (blob.len < 40 or try be32(blob, 0) != 0xd00dfeed or try be32(blob, 4) != blob.len or
        try be32(blob, 20) != 17 or try be32(blob, 24) > 17) return error.InvalidDeviceTreeHeader;
    const structure_offset = try be32(blob, 8);
    const strings_offset = try be32(blob, 12);
    const reservations_offset = try be32(blob, 16);
    const strings = try slice(blob, strings_offset, try be32(blob, 32));
    const structure = try slice(blob, structure_offset, try be32(blob, 36));
    if (structure_offset < 40 or strings_offset < 40 or reservations_offset < 40 or
        structure_offset % 4 != 0 or reservations_offset % 8 != 0 or structure.len == 0 or
        overlap(structure_offset, structure.len, strings_offset, strings.len)) return error.InvalidDeviceTreeHeader;
    var reservation: usize = reservations_offset;
    var terminated = false;
    for (0..65) |_| {
        const record = try slice(blob, reservation, 16);
        if (overlap(reservation, 16, structure_offset, structure.len) or overlap(reservation, 16, strings_offset, strings.len))
            return error.InvalidDeviceTreeReservations;
        reservation += 16;
        const address = try cells(record[0..8], 2);
        const length = try cells(record[8..16], 2);
        if (address == 0 and length == 0) {
            terminated = true;
            break;
        }
        if (@addWithOverflow(address, length)[1] != 0) return error.InvalidDeviceTreeReservations;
    }
    if (!terminated) return error.InvalidDeviceTreeReservations;
    var stack: [32]Node = undefined;
    var phandles: [256]u32 = undefined;
    var phandle_count: usize = 0;
    var depth: usize = 0;
    var nodes: usize = 0;
    var properties: usize = 0;
    var cursor: usize = 0;
    var root_seen = false;
    var done = false;
    var controller: ?Controller = null;
    var timer_node: ?TimerNode = null;
    while (cursor < structure.len) {
        const token = try be32(structure, cursor);
        cursor += 4;
        switch (token) {
            1 => {
                if (depth == stack.len or nodes == 256 or (depth == 0 and root_seen)) return error.DeviceTreeNodeCapacity;
                const name = try cString(structure[cursor..]);
                cursor = try padded(cursor + name.len + 1, structure.len);
                var node: Node = .{};
                if (depth == 0) {
                    if (name.len != 0) return error.InvalidDeviceTreeStructure;
                    root_seen = true;
                } else {
                    const parent = &stack[depth - 1];
                    parent.children = true;
                    node.parent_address_cells = parent.address_cells;
                    node.parent_size_cells = parent.size_cells;
                    node.interrupt_parent = parent.interrupt_parent;
                    node.enabled = parent.enabled;
                    node.identity = parent.identity and (depth == 1 or parent.ranges_identity);
                }
                stack[depth] = node;
                depth += 1;
                nodes += 1;
            },
            2 => {
                if (depth == 0) return error.InvalidDeviceTreeStructure;
                depth -= 1;
                const node = stack[depth];
                if (node.phandle != 0) {
                    for (phandles[0..phandle_count]) |old| if (old == node.phandle) return error.DuplicateDeviceTreePhandle;
                    phandles[phandle_count] = node.phandle;
                    phandle_count += 1;
                }
                if (!node.enabled or node.compatible == null) continue;
                const gic = try listContains(node.compatible.?, "arm,cortex-a15-gic") or try listContains(node.compatible.?, "arm,gic-400");
                if (gic) {
                    if (controller != null or !node.identity or !node.controller or node.interrupt_cells != 3 or
                        node.phandle == 0 or node.extended) return error.UnsupportedInterruptController;
                    const reg = node.reg orelse return error.MissingGicRegisters;
                    if ((node.parent_address_cells != 1 and node.parent_address_cells != 2) or
                        (node.parent_size_cells != 1 and node.parent_size_cells != 2))
                        return error.UnsupportedGicRegisters;
                    const tuple_bytes: usize = @intCast((node.parent_address_cells + node.parent_size_cells) * 4);
                    if (reg.len < tuple_bytes * 2 or reg.len % tuple_bytes != 0 or reg.len > tuple_bytes * 4)
                        return error.UnsupportedGicRegisters;
                    var ranges: [2]protocol.PhysicalRange = undefined;
                    for (&ranges, 0..) |*range, i| {
                        const tuple = reg[i * tuple_bytes .. (i + 1) * tuple_bytes];
                        const address_bytes: usize = @intCast(node.parent_address_cells * 4);
                        range.* = .{ .base = try cells(tuple[0..address_bytes], node.parent_address_cells), .length = try cells(tuple[address_bytes..], node.parent_size_cells) };
                        _ = try range.endExclusive();
                        if (range.base == 0 or range.base % 4096 != 0 or range.length < 0x100 or range.length > 0x10000)
                            return error.UnsupportedGicRegisters;
                    }
                    if (overlap(ranges[0].base, ranges[0].length, ranges[1].base, ranges[1].length)) return error.UnsupportedGicRegisters;
                    controller = .{ .ranges = ranges, .phandle = node.phandle };
                }
                if (try listContains(node.compatible.?, "arm,armv8-timer")) {
                    if (timer_node != null or node.extended or node.interrupt_parent == 0) return error.UnsupportedArchitecturalTimer;
                    timer_node = .{ .parent = node.interrupt_parent, .interrupts = node.interrupts orelse return error.MissingTimerInterrupts, .names = node.names, .clock = node.clock };
                }
            },
            3 => {
                if (depth == 0 or stack[depth - 1].children or properties == 4096) return error.InvalidDeviceTreeStructure;
                properties += 1;
                const length = try be32(structure, cursor);
                const name_offset = try be32(structure, cursor + 4);
                cursor += 8;
                if (name_offset >= strings.len) return error.InvalidDeviceTreeString;
                const name = try cString(strings[name_offset..]);
                if (name.len == 0) return error.InvalidDeviceTreeString;
                const value = try slice(structure, cursor, length);
                cursor = try padded(cursor + length, structure.len);
                try property(&stack[depth - 1], name, value);
            },
            4 => {},
            9 => {
                if (depth != 0 or !root_seen) return error.InvalidDeviceTreeStructure;
                done = true;
                break;
            },
            else => return error.InvalidDeviceTreeStructure,
        }
    }
    if (!done) return error.InvalidDeviceTreeStructure;
    const gic = controller orelse return error.UnsupportedInterruptController;
    const t = timer_node orelse return error.MissingArchitecturalTimer;
    if (t.parent != gic.phandle or t.interrupts.len % 12 != 0 or t.interrupts.len > 60) return error.UnsupportedTimerInterrupts;
    var selected: usize = 1; // unnamed legacy binding: secure, non-secure, virtual, hypervisor
    if (t.names) |names| {
        selected = try listIndex(names, "phys") orelse return error.UnsupportedTimerInterrupts;
        if (try listCount(names) != t.interrupts.len / 12) return error.UnsupportedTimerInterrupts;
    } else if (t.interrupts.len < 36) return error.UnsupportedTimerInterrupts;
    if (selected >= t.interrupts.len / 12) return error.UnsupportedTimerInterrupts;
    const irq = t.interrupts[selected * 12 .. (selected + 1) * 12];
    const kind = try be32(irq, 0);
    const number = try be32(irq, 4);
    const flags = try be32(irq, 8);
    if (kind != 1 or number > 15 or flags & 15 != 4 or flags & ~@as(u32, 0xff0f) != 0 or
        ((flags >> 8) != 0 and (flags >> 8) & 1 == 0)) return error.UnsupportedTimerInterrupts;
    return .{ .distributor = gic.ranges[0], .cpu_interface = gic.ranges[1], .interrupt_id = number + 16, .clock_hz = t.clock };
}

fn property(node: *Node, name: []const u8, value: []const u8) !void {
    const id: u5 = if (std.mem.eql(u8, name, "#address-cells")) 0 else if (std.mem.eql(u8, name, "#size-cells")) 1 else if (std.mem.eql(u8, name, "interrupt-parent")) 2 else if (std.mem.eql(u8, name, "phandle")) 3 else if (std.mem.eql(u8, name, "linux,phandle")) 4 else if (std.mem.eql(u8, name, "#interrupt-cells")) 5 else if (std.mem.eql(u8, name, "status")) 6 else if (std.mem.eql(u8, name, "ranges")) 7 else if (std.mem.eql(u8, name, "interrupt-controller")) 8 else if (std.mem.eql(u8, name, "compatible")) 9 else if (std.mem.eql(u8, name, "reg")) 10 else if (std.mem.eql(u8, name, "interrupts")) 11 else if (std.mem.eql(u8, name, "interrupt-names")) 12 else if (std.mem.eql(u8, name, "interrupts-extended")) 13 else if (std.mem.eql(u8, name, "clock-frequency")) 14 else return;
    const bit = @as(u32, 1) << id;
    if (node.seen & bit != 0) return error.DuplicateDeviceTreeProperty;
    node.seen |= bit;
    switch (id) {
        0 => node.address_cells = try oneCell(value),
        1 => node.size_cells = try oneCell(value),
        2 => node.interrupt_parent = try oneCell(value),
        3, 4 => {
            const phandle = try oneCell(value);
            if (phandle == 0 or phandle == 0xffff_ffff or (node.phandle != 0 and node.phandle != phandle)) return error.InvalidDeviceTreePhandle;
            node.phandle = phandle;
        },
        5 => node.interrupt_cells = try oneCell(value),
        6 => {
            const text = try cString(value);
            if (text.len + 1 != value.len) return error.InvalidDeviceTreeString;
            node.enabled = node.enabled and (std.mem.eql(u8, text, "okay") or std.mem.eql(u8, text, "ok"));
        },
        7 => node.ranges_identity = value.len == 0,
        8 => {
            if (value.len != 0) return error.InvalidDeviceTreeProperty;
            node.controller = true;
        },
        9 => {
            _ = try listCount(value);
            node.compatible = value;
        },
        10 => node.reg = value,
        11 => node.interrupts = value,
        12 => {
            _ = try listCount(value);
            node.names = value;
        },
        13 => node.extended = true,
        14 => {
            const hz = try oneCell(value);
            if (hz == 0) return error.UnsupportedTimerFrequency;
            node.clock = hz;
        },
        else => unreachable,
    }
}
fn overlap(a: u64, length: u64, b: u64, other_length: u64) bool {
    return a < b + other_length and b < a + length;
}
fn slice(blob: []const u8, offset: usize, length: usize) ![]const u8 {
    if (offset > blob.len or length > blob.len - offset) return error.TruncatedDeviceTree;
    return blob[offset .. offset + length];
}
fn be32(blob: []const u8, offset: usize) !u32 {
    const v = try slice(blob, offset, 4);
    return @as(u32, v[0]) << 24 | @as(u32, v[1]) << 16 | @as(u32, v[2]) << 8 | v[3];
}
fn oneCell(value: []const u8) !u32 {
    if (value.len != 4) return error.InvalidDeviceTreeProperty;
    return be32(value, 0);
}
fn cells(value: []const u8, count: u32) !u64 {
    if ((count != 1 and count != 2) or value.len != count * 4) return error.UnsupportedDeviceTreeCells;
    if (count == 1) return try be32(value, 0);
    return @as(u64, try be32(value, 0)) << 32 | try be32(value, 4);
}
fn padded(value: usize, limit: usize) !usize {
    if (value > limit or limit - value < ((4 - value % 4) % 4)) return error.TruncatedDeviceTree;
    return (value + 3) & ~@as(usize, 3);
}
fn cString(value: []const u8) ![]const u8 {
    const end = std.mem.indexOfScalar(u8, value, 0) orelse return error.InvalidDeviceTreeString;
    return value[0..end];
}
fn listIndex(value: []const u8, wanted: []const u8) !?usize {
    var at: usize = 0;
    var count: usize = 0;
    var found: ?usize = null;
    while (at < value.len) {
        const text = try cString(value[at..]);
        if (text.len == 0 or count == 32) return error.InvalidDeviceTreeString;
        if (std.mem.eql(u8, text, wanted)) {
            if (found != null) return error.InvalidDeviceTreeString;
            found = count;
        }
        at += text.len + 1;
        count += 1;
    }
    if (count == 0) return error.InvalidDeviceTreeString;
    return found;
}
fn listContains(value: []const u8, wanted: []const u8) !bool {
    return try listIndex(value, wanted) != null;
}
fn listCount(value: []const u8) !usize {
    _ = try listIndex(value, "");
    var count: usize = 0;
    for (value) |byte| if (byte == 0) {
        count += 1;
    };
    return count;
}

const Fixture = struct {
    bytes: [2048]u8 = @splat(0),
    names: [512]u8 = @splat(0),
    cursor: usize = 56,
    names_len: usize = 0,
    fn u32be(self: *Fixture, value: u32) void {
        self.set32(self.cursor, value);
        self.cursor += 4;
    }
    fn set32(self: *Fixture, at: usize, value: u32) void {
        for (0..4) |i| self.bytes[at + i] = @truncate(value >> @as(u5, @intCast((3 - i) * 8)));
    }
    fn begin(self: *Fixture, name: []const u8) void {
        self.u32be(1);
        @memcpy(self.bytes[self.cursor..][0..name.len], name);
        self.cursor = (self.cursor + name.len + 4) & ~@as(usize, 3);
    }
    fn prop(self: *Fixture, name: []const u8, value: []const u8) void {
        self.u32be(3);
        self.u32be(@intCast(value.len));
        self.u32be(@intCast(self.names_len));
        @memcpy(self.names[self.names_len..][0..name.len], name);
        self.names_len += name.len + 1;
        @memcpy(self.bytes[self.cursor..][0..value.len], value);
        self.cursor = (self.cursor + value.len + 3) & ~@as(usize, 3);
    }
    fn cell(self: *Fixture, name: []const u8, value: u32) void {
        const v: [4]u8 = .{ @truncate(value >> 24), @truncate(value >> 16), @truncate(value >> 8), @truncate(value) };
        self.prop(name, &v);
    }
    fn finish(self: *Fixture) []u8 {
        self.u32be(9);
        const structure_size = self.cursor - 56;
        const strings_at = self.cursor;
        @memcpy(self.bytes[self.cursor..][0..self.names_len], self.names[0..self.names_len]);
        self.cursor += self.names_len;
        for ([_]u32{ 0xd00dfeed, @intCast(self.cursor), 56, @intCast(strings_at), 40, 17, 16, 0, @intCast(self.names_len), @intCast(structure_size) }, 0..) |value, i| self.set32(i * 4, value);
        return self.bytes[0..self.cursor];
    }
    fn hardware(self: *Fixture, parent: u32, flags: u32, compatible: []const u8, named: bool) []u8 {
        self.begin("");
        self.cell("#address-cells", 2);
        self.cell("#size-cells", 2);
        self.cell("interrupt-parent", parent);
        self.begin("intc@8000000");
        self.prop("compatible", compatible);
        self.prop("interrupt-controller", "");
        self.cell("#interrupt-cells", 3);
        self.cell("phandle", 7);
        self.prop("reg", &.{ 0, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 8, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0 });
        self.u32be(2);
        self.begin("timer");
        self.prop("compatible", "arm,armv8-timer\x00arm,armv7-timer\x00");
        var irq: [48]u8 = @splat(0);
        for ([_]u32{ 13, 14, 11, 10 }, 0..) |number, i| {
            irq[i * 12 + 3] = 1;
            irq[i * 12 + 7] = @intCast(number);
            irq[i * 12 + 10] = @truncate(flags >> 8);
            irq[i * 12 + 11] = @truncate(flags);
        }
        self.prop("interrupts", &irq);
        if (named) self.prop("interrupt-names", "sec-phys\x00phys\x00virt\x00hyp-phys\x00");
        self.u32be(2);
        self.u32be(2);
        return self.finish();
    }
};

test "GICv2 physical timer is discovered from inherited parent and unnamed or named PPIs" {
    for ([_]bool{ false, true }) |named| {
        var fixture: Fixture = .{};
        const d = try discover(fixture.hardware(7, 0x104, "arm,cortex-a15-gic\x00", named));
        try std.testing.expectEqual(@as(u64, 0x08000000), d.distributor.base);
        try std.testing.expectEqual(@as(u64, 0x08010000), d.cpu_interface.base);
        try std.testing.expectEqual(@as(u32, 30), d.interrupt_id);
    }
}
test "discovery rejects an unrelated parent unsupported GIC and invalid timer trigger" {
    var fixture: Fixture = .{};
    try std.testing.expectError(error.UnsupportedTimerInterrupts, discover(fixture.hardware(8, 0x104, "arm,cortex-a15-gic\x00", false)));
    fixture = .{};
    try std.testing.expectError(error.UnsupportedInterruptController, discover(fixture.hardware(7, 0x104, "arm,gic-v3\x00", false)));
    fixture = .{};
    try std.testing.expectError(error.UnsupportedTimerInterrupts, discover(fixture.hardware(7, 0x101, "arm,cortex-a15-gic\x00", false)));
    fixture = .{};
    try std.testing.expectError(error.UnsupportedTimerInterrupts, discover(fixture.hardware(7, 0x204, "arm,cortex-a15-gic\x00", false)));
}
test "discovery bounds malformed header structure property strings and reservations" {
    var fixture: Fixture = .{};
    var blob = fixture.hardware(7, 0x104, "arm,cortex-a15-gic\x00", false);
    fixture.set32(8, 0xffff_fffc);
    try std.testing.expectError(error.TruncatedDeviceTree, discover(blob));
    fixture = .{};
    blob = fixture.hardware(7, 0x104, "arm,cortex-a15-gic\x00", false);
    fixture.set32(56, 2);
    try std.testing.expectError(error.InvalidDeviceTreeStructure, discover(blob));
    fixture = .{};
    blob = fixture.hardware(7, 0x104, "arm,cortex-a15-gic\x00", false);
    const strings_at = try be32(blob, 12);
    @memset(blob[strings_at..], 'x');
    try std.testing.expectError(error.InvalidDeviceTreeString, discover(blob));
    fixture = .{};
    blob = fixture.hardware(7, 0x104, "arm,cortex-a15-gic\x00", false);
    fixture.set32(40, 1);
    try std.testing.expectError(error.InvalidDeviceTreeReservations, discover(blob));
}
