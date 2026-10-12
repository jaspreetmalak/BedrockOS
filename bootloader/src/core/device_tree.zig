//! Bounded, allocation-free discovery for the flattened Devicetree v17 format.
//! All wire integers are read as bytes: the blob need not be naturally aligned.
//! Only identity bus ranges and static reservations are supported. UART baud
//! defaults to the Bedrock boot-console policy (115200), never its address/clock.
const std = @import("std");

pub const max_ranges = 64;
pub const max_nodes = 256;
pub const max_depth = 32;
const max_properties = 128;
const max_total_properties = 4096;

pub const Error = error{
    Truncated,
    InvalidHeader,
    UnsupportedVersion,
    InvalidStructure,
    InvalidString,
    DuplicateProperty,
    CapacityExceeded,
    UnsupportedCells,
    InvalidRange,
    OverlappingMemory,
    MissingMemory,
    UnsupportedReservation,
    MissingConsole,
    UnsupportedConsole,
    UnsupportedBus,
    MissingClock,
};

pub const Range = struct {
    base: u64,
    length: u64,

    pub fn end(self: Range) Error!u64 {
        const sum = @addWithOverflow(self.base, self.length);
        if (self.length == 0 or sum[1] != 0) return error.InvalidRange;
        return sum[0];
    }

    pub fn contains(self: Range, other: Range) bool {
        const self_end = self.end() catch return false;
        const other_end = other.end() catch return false;
        return other.base >= self.base and other_end <= self_end;
    }

    pub fn overlaps(self: Range, other: Range) bool {
        const self_end = self.end() catch return true;
        const other_end = other.end() catch return true;
        return self.base < other_end and other.base < self_end;
    }
};

pub const ConsoleKind = enum { pl011, ns16550_mmio };
pub const Console = struct {
    kind: ConsoleKind,
    range: Range,
    register_stride: u32,
    clock_hz: u32,
    baud_rate: u32,
};

pub const Discovery = struct {
    memory: [max_ranges]Range = undefined,
    memory_count: usize = 0,
    reserved: [max_ranges]Range = undefined,
    reserved_count: usize = 0,
    /// Only parse() resolves this descriptor; parseHardware() leaves it unused.
    console_available: bool = false,
    console: Console = undefined,
    total_size: usize = 0,

    pub fn memoryBanks(self: *const Discovery) []const Range {
        return self.memory[0..self.memory_count];
    }

    pub fn reservations(self: *const Discovery) []const Range {
        return self.reserved[0..self.reserved_count];
    }

    pub fn containingBank(self: *const Discovery, range: Range) ?Range {
        for (self.memoryBanks()) |bank| if (bank.contains(range)) return bank;
        return null;
    }

    pub fn conflicts(self: *const Discovery, range: Range) bool {
        for (self.reservations()) |reserved| if (range.overlaps(reserved)) return true;
        return false;
    }
};

const Node = struct {
    name: []const u8,
    parent: ?u16,
    properties_start: usize,
    properties_end: usize,
};
const Frame = struct { index: u16, children_started: bool = false, property_count: usize = 0 };
const Property = struct { name: []const u8, value: []const u8, next: usize };

const Tree = struct {
    structure: []const u8,
    strings: []const u8,
    nodes: [max_nodes]Node = undefined,
    node_count: usize = 0,
    phandles: [max_nodes]u32 = @splat(0),

    fn stringAt(self: *const Tree, offset: usize) Error![]const u8 {
        if (offset >= self.strings.len) return error.InvalidString;
        const remaining = self.strings[offset..];
        const length = std.mem.indexOfScalar(u8, remaining, 0) orelse return error.InvalidString;
        if (length == 0) return error.InvalidString;
        return remaining[0..length];
    }

    fn propertyAt(self: *const Tree, cursor: usize) Error!Property {
        if (cursor > self.structure.len or self.structure.len - cursor < 12) return error.Truncated;
        if (be32(self.structure, cursor) != 3) return error.InvalidStructure;
        const length: usize = be32(self.structure, cursor + 4);
        const name = try self.stringAt(be32(self.structure, cursor + 8));
        const start = cursor + 12;
        if (length > self.structure.len - start) return error.Truncated;
        const end = start + length;
        const next = try align4(end);
        if (next > self.structure.len) return error.Truncated;
        // Alignment padding has no defined value; libfdt may retain old bytes.
        return .{ .name = name, .value = self.structure[start..end], .next = next };
    }

    fn property(self: *const Tree, node_index: usize, name: []const u8) ?[]const u8 {
        const node = self.nodes[node_index];
        var cursor = node.properties_start;
        while (cursor < node.properties_end) {
            if (be32(self.structure, cursor) == 4) {
                cursor += 4;
                continue;
            }
            const prop = self.propertyAt(cursor) catch unreachable; // Validated once by walk.
            if (std.mem.eql(u8, prop.name, name)) return prop.value;
            cursor = prop.next;
        }
        return null;
    }

    fn walk(self: *Tree) Error!void {
        var frames: [max_depth]Frame = undefined;
        var depth: usize = 0;
        var total_properties: usize = 0;
        var cursor: usize = 0;
        var root_closed = false;
        while (cursor < self.structure.len) {
            if (self.structure.len - cursor < 4) return error.Truncated;
            const token = be32(self.structure, cursor);
            const token_start = cursor;
            cursor += 4;
            switch (token) {
                1 => {
                    if (root_closed or self.node_count == max_nodes or depth == max_depth)
                        return if (root_closed) error.InvalidStructure else error.CapacityExceeded;
                    const remaining = self.structure[cursor..];
                    const length = std.mem.indexOfScalar(u8, remaining, 0) orelse return error.InvalidString;
                    const name = remaining[0..length];
                    if ((depth == 0 and (self.node_count != 0 or length != 0)) or
                        (depth != 0 and (length == 0 or length > 127 or std.mem.indexOfScalar(u8, name, '/') != null)))
                        return error.InvalidStructure;
                    const name_end = cursor + length + 1;
                    cursor = try align4(name_end);
                    if (cursor > self.structure.len) return error.Truncated;
                    // Padding bytes are ignored, not interpreted as content.
                    const parent: ?u16 = if (depth == 0) null else frames[depth - 1].index;
                    if (depth != 0 and !frames[depth - 1].children_started) {
                        frames[depth - 1].children_started = true;
                        self.nodes[parent.?].properties_end = token_start;
                    }
                    for (self.nodes[0..self.node_count]) |previous| {
                        if (previous.parent == parent and std.mem.eql(u8, previous.name, name))
                            return error.InvalidStructure;
                    }
                    self.nodes[self.node_count] = .{
                        .name = name,
                        .parent = parent,
                        .properties_start = cursor,
                        .properties_end = cursor,
                    };
                    frames[depth] = .{ .index = @intCast(self.node_count) };
                    self.node_count += 1;
                    depth += 1;
                },
                2 => {
                    if (depth == 0) return error.InvalidStructure;
                    depth -= 1;
                    if (!frames[depth].children_started) self.nodes[frames[depth].index].properties_end = token_start;
                    if (depth == 0) root_closed = true;
                },
                3 => {
                    if (depth == 0 or frames[depth - 1].children_started) return error.InvalidStructure;
                    const frame = &frames[depth - 1];
                    if (frame.property_count == max_properties or total_properties == max_total_properties)
                        return error.CapacityExceeded;
                    const prop = try self.propertyAt(token_start);
                    var prior = self.nodes[frame.index].properties_start;
                    while (prior < token_start) {
                        if (be32(self.structure, prior) == 4) {
                            prior += 4;
                            continue;
                        }
                        const previous = try self.propertyAt(prior);
                        if (std.mem.eql(u8, previous.name, prop.name)) return error.DuplicateProperty;
                        prior = previous.next;
                    }
                    frame.property_count += 1;
                    total_properties += 1;
                    cursor = prop.next;
                },
                4 => {},
                9 => {
                    if (depth != 0 or !root_closed or cursor != self.structure.len) return error.InvalidStructure;
                    return;
                },
                else => return error.InvalidStructure,
            }
        }
        return error.InvalidStructure;
    }

    fn child(self: *const Tree, parent: usize, name: []const u8) ?usize {
        for (self.nodes[0..self.node_count], 0..) |node, index| {
            if (node.parent != null and node.parent.? == parent and std.mem.eql(u8, node.name, name)) return index;
        }
        return null;
    }

    fn validateHandles(self: *Tree) Error!void {
        for (0..self.node_count) |index| {
            const modern = self.property(index, "phandle");
            const legacy = self.property(index, "linux,phandle");
            if (modern == null and legacy == null) continue;
            const handle = try scalar(modern orelse legacy.?);
            if (handle == 0 or handle == 0xffffffff) return error.InvalidStructure;
            if (modern != null and legacy != null and try scalar(legacy.?) != handle)
                return error.InvalidStructure;
            for (self.phandles[0..index]) |previous| if (previous == handle) return error.InvalidStructure;
            self.phandles[index] = handle;
        }
    }

    fn path(self: *const Tree, absolute: []const u8) Error!usize {
        if (absolute.len == 0 or absolute[0] != '/' or absolute.len > 1024) return error.InvalidString;
        if (absolute.len == 1) return 0;
        var index: usize = 0;
        var parts = std.mem.splitScalar(u8, absolute[1..], '/');
        while (parts.next()) |part| {
            if (part.len == 0) return error.InvalidString;
            index = self.child(index, part) orelse return error.MissingConsole;
        }
        return index;
    }

    fn cells(self: *const Tree, index: usize, name: []const u8, default: u32) Error!u32 {
        const value = self.property(index, name) orelse return default;
        return scalar(value);
    }

    fn enabled(self: *const Tree, index: usize) Error!bool {
        const raw = self.property(index, "status") orelse return true;
        const status = try singleString(raw);
        if (std.mem.eql(u8, status, "okay") or std.mem.eql(u8, status, "ok")) return true;
        if (std.mem.eql(u8, status, "disabled") or std.mem.eql(u8, status, "reserved") or
            std.mem.eql(u8, status, "fail") or std.mem.startsWith(u8, status, "fail-")) return false;
        return error.InvalidString;
    }

    fn clock(self: *const Tree, index: usize) Error!u32 {
        if (self.property(index, "clock-frequency")) |value| {
            const frequency = try scalar(value);
            if (frequency == 0) return error.MissingClock;
            return frequency;
        }
        const clocks = self.property(index, "clocks") orelse return error.MissingClock;
        if (clocks.len == 0 or clocks.len % 4 != 0) return error.MissingClock;
        var frequency: ?u32 = null;
        var cursor: usize = 0;
        while (cursor < clocks.len) : (cursor += 4) {
            const phandle = be32(clocks, cursor);
            if (phandle == 0 or phandle == 0xffffffff) return error.MissingClock;
            var matched: ?usize = null;
            for (self.phandles[0..self.node_count], 0..) |handle, candidate| {
                if (handle == phandle) matched = candidate;
            }
            const provider = matched orelse return error.MissingClock;
            if (!(try self.enabled(provider)) or try self.cells(provider, "#clock-cells", 1) != 0)
                return error.MissingClock;
            const compatible = self.property(provider, "compatible") orelse return error.MissingClock;
            if (!(try compatibleHas(compatible, "fixed-clock"))) return error.MissingClock;
            const current = try scalar(self.property(provider, "clock-frequency") orelse return error.MissingClock);
            if (current == 0 or (frequency != null and frequency.? != current)) return error.MissingClock;
            frequency = current;
        }
        return frequency orelse error.MissingClock;
    }

    fn console(self: *const Tree) Error!Console {
        const chosen = self.child(0, "chosen") orelse return error.MissingConsole;
        const raw = self.property(chosen, "stdout-path") orelse
            self.property(chosen, "linux,stdout-path") orelse return error.MissingConsole;
        const stdout = try singleString(raw);
        const colon = std.mem.indexOfScalar(u8, stdout, ':') orelse stdout.len;
        var address = stdout[0..colon];
        if (address.len == 0) return error.InvalidString;
        if (address[0] != '/') {
            if (address.len > 31) return error.InvalidString;
            for (address) |byte| if (!(byte >= 'a' and byte <= 'z') and !(byte >= '0' and byte <= '9') and byte != '-')
                return error.InvalidString;
            const aliases = self.child(0, "aliases") orelse return error.MissingConsole;
            address = try singleString(self.property(aliases, address) orelse return error.MissingConsole);
        }
        const index = try self.path(address);
        var ancestor = index;
        while (true) {
            if (!(try self.enabled(ancestor))) return error.UnsupportedConsole;
            const parent = self.nodes[ancestor].parent orelse break;
            if (ancestor != index and ancestor != 0) {
                const ranges = self.property(ancestor, "ranges") orelse return error.UnsupportedBus;
                if (ranges.len != 0) return error.UnsupportedBus;
            }
            ancestor = parent;
        }
        const parent = self.nodes[index].parent orelse return error.UnsupportedConsole;
        const reg = self.property(index, "reg") orelse return error.UnsupportedConsole;
        const address_cells = try self.cells(parent, "#address-cells", 2);
        const size_cells = try self.cells(parent, "#size-cells", 1);
        const width = try tupleWidth(address_cells, size_cells);
        if (reg.len != width) return error.UnsupportedConsole;
        const range = try rangeAt(reg, 0, address_cells, size_cells);
        const compatible = self.property(index, "compatible") orelse return error.UnsupportedConsole;
        const is_pl011 = try compatibleHas(compatible, "arm,pl011");
        const is_16550 = try compatibleHas(compatible, "ns16550a") or try compatibleHas(compatible, "ns16550");
        if (is_pl011 == is_16550) return error.UnsupportedConsole;
        var baud: u32 = if (self.property(index, "current-speed")) |value| try scalar(value) else 115200;
        if (colon != stdout.len) baud = try baudOption(stdout[colon + 1 ..]);
        if (baud == 0) return error.UnsupportedConsole;
        var stride: u32 = 4;
        if (is_pl011) {
            if (range.base % 4 != 0 or range.length < 0x48) return error.UnsupportedConsole;
        } else {
            const shift = try self.cells(index, "reg-shift", 0);
            if (shift > 3 or try self.cells(index, "reg-io-width", 1) != 1) return error.UnsupportedConsole;
            stride = @as(u32, 1) << @as(u5, @intCast(shift));
            if (range.length < @as(u64, stride) * 8) return error.UnsupportedConsole;
        }
        return .{
            .kind = if (is_pl011) .pl011 else .ns16550_mmio,
            .range = range,
            .register_stride = stride,
            .clock_hz = try self.clock(index),
            .baud_rate = baud,
        };
    }
};

/// Discover hardware and a required supported serial stdout descriptor.
pub fn parse(blob: []const u8) Error!Discovery {
    return parseImpl(blob, true);
}

/// Discover memory and reservations without selecting a serial console.
/// Firmware may supply GOP instead of a UART. Header, complete structure,
/// phandles, memory banks and reservations receive the same validation as parse.
/// The returned console is unused and console_available is false.
pub fn parseHardware(blob: []const u8) Error!Discovery {
    return parseImpl(blob, false);
}

fn parseImpl(blob: []const u8, comptime resolve_console: bool) Error!Discovery {
    if (blob.len < 40) return error.Truncated;
    if (be32(blob, 0) != 0xd00dfeed) return error.InvalidHeader;
    const total: usize = be32(blob, 4);
    if (total < 40) return error.InvalidHeader;
    if (total > blob.len) return error.Truncated;
    const version = be32(blob, 20);
    const compatible_version = be32(blob, 24);
    if (version < 17 or compatible_version > 17 or compatible_version < 16 or compatible_version > version)
        return error.UnsupportedVersion;
    const structure_offset: usize = be32(blob, 8);
    const strings_offset: usize = be32(blob, 12);
    const reserve_offset: usize = be32(blob, 16);
    const strings_size: usize = be32(blob, 32);
    const structure_size: usize = be32(blob, 36);
    if (structure_offset % 4 != 0 or reserve_offset % 8 != 0 or structure_size == 0 or structure_size % 4 != 0)
        return error.InvalidHeader;
    try blockBounds(structure_offset, structure_size, total);
    try blockBounds(strings_offset, strings_size, total);
    try blockBounds(reserve_offset, 16, total);
    if (blocksOverlap(structure_offset, structure_size, strings_offset, strings_size)) return error.InvalidHeader;
    var result: Discovery = .{ .total_size = total };
    var cursor = reserve_offset;
    while (true) {
        if (cursor > total or total - cursor < 16) return error.Truncated;
        if (blocksOverlap(cursor, 16, structure_offset, structure_size) or
            blocksOverlap(cursor, 16, strings_offset, strings_size)) return error.InvalidHeader;
        const range: Range = .{ .base = be64(blob, cursor), .length = be64(blob, cursor + 8) };
        cursor += 16;
        if (range.base == 0 and range.length == 0) break;
        try appendRange(&result.reserved, &result.reserved_count, range);
    }
    var tree: Tree = .{
        .structure = blob[structure_offset..][0..structure_size],
        .strings = blob[strings_offset..][0..strings_size],
    };
    try tree.walk();
    try tree.validateHandles();
    const address_cells = try tree.cells(0, "#address-cells", 2);
    const size_cells = try tree.cells(0, "#size-cells", 1);
    _ = try tupleWidth(address_cells, size_cells);
    for (tree.nodes[1..tree.node_count], 1..) |node, index| {
        const device_type = tree.property(index, "device_type") orelse continue;
        if (!std.mem.eql(u8, try singleString(device_type), "memory")) continue;
        if (node.parent != 0) return error.UnsupportedBus;
        if (!(try tree.enabled(index))) continue;
        if (!std.mem.eql(u8, node.name, "memory") and !std.mem.startsWith(u8, node.name, "memory@"))
            return error.InvalidStructure;
        try appendRegisters(&result.memory, &result.memory_count, tree.property(index, "reg") orelse return error.InvalidRange, address_cells, size_cells);
    }
    if (result.memory_count == 0) return error.MissingMemory;
    for (result.memoryBanks(), 0..) |bank, index| {
        for (result.memoryBanks()[0..index]) |previous| if (bank.overlaps(previous)) return error.OverlappingMemory;
    }
    if (tree.child(0, "reserved-memory")) |reserved_node| {
        if (try tree.enabled(reserved_node)) {
            if (try tree.cells(reserved_node, "#address-cells", 2) != address_cells or
                try tree.cells(reserved_node, "#size-cells", 1) != size_cells) return error.UnsupportedCells;
            const ranges = tree.property(reserved_node, "ranges") orelse return error.UnsupportedReservation;
            if (ranges.len != 0) return error.UnsupportedReservation;
            for (tree.nodes[1..tree.node_count], 1..) |node, index| {
                if (node.parent == null or node.parent.? != reserved_node or !(try tree.enabled(index))) continue;
                if (tree.property(index, "size") != null or tree.property(index, "alignment") != null or
                    tree.property(index, "alloc-ranges") != null) return error.UnsupportedReservation;
                if (tree.property(index, "no-map")) |value| {
                    if (value.len != 0 or tree.property(index, "reusable") != null) return error.UnsupportedReservation;
                }
                if (tree.property(index, "reusable")) |value| if (value.len != 0) return error.UnsupportedReservation;
                try appendRegisters(&result.reserved, &result.reserved_count, tree.property(index, "reg") orelse return error.UnsupportedReservation, address_cells, size_cells);
            }
        }
    }
    if (resolve_console) {
        result.console = try tree.console();
        result.console_available = true;
    }
    return result;
}

fn be32(bytes: []const u8, offset: usize) u32 {
    // Volatile byte reads also prevent load coalescing into unaligned words on
    // ARM before caches/MMU are enabled; all bounds are checked by the caller.
    const raw: [*]const volatile u8 = bytes.ptr;
    return (@as(u32, raw[offset]) << 24) | (@as(u32, raw[offset + 1]) << 16) |
        (@as(u32, raw[offset + 2]) << 8) | @as(u32, raw[offset + 3]);
}
fn be64(bytes: []const u8, offset: usize) u64 {
    return (@as(u64, be32(bytes, offset)) << 32) | be32(bytes, offset + 4);
}
fn align4(value: usize) Error!usize {
    const sum = @addWithOverflow(value, @as(usize, 3));
    if (sum[1] != 0) return error.Truncated;
    return sum[0] & ~@as(usize, 3);
}
fn blockBounds(offset: usize, length: usize, total: usize) Error!void {
    if (offset < 40 or offset > total or length > total - offset) return error.InvalidHeader;
}
fn blocksOverlap(a: usize, a_length: usize, b: usize, b_length: usize) bool {
    return a_length != 0 and b_length != 0 and a < b + b_length and b < a + a_length;
}
fn scalar(bytes: []const u8) Error!u32 {
    if (bytes.len != 4) return error.InvalidStructure;
    return be32(bytes, 0);
}
fn singleString(bytes: []const u8) Error![]const u8 {
    if (bytes.len == 0 or bytes[bytes.len - 1] != 0) return error.InvalidString;
    if (std.mem.indexOfScalar(u8, bytes[0 .. bytes.len - 1], 0) != null) return error.InvalidString;
    return bytes[0 .. bytes.len - 1];
}
fn compatibleHas(bytes: []const u8, expected: []const u8) Error!bool {
    if (bytes.len == 0 or bytes[bytes.len - 1] != 0) return error.InvalidString;
    var found = false;
    var parts = std.mem.splitScalar(u8, bytes[0 .. bytes.len - 1], 0);
    while (parts.next()) |part| {
        if (part.len == 0) return error.InvalidString;
        if (std.mem.eql(u8, part, expected)) found = true;
    }
    return found;
}
fn tupleWidth(address_cells: u32, size_cells: u32) Error!usize {
    if (address_cells < 1 or address_cells > 2 or size_cells < 1 or size_cells > 2) return error.UnsupportedCells;
    return (address_cells + size_cells) * 4;
}
fn cellValue(bytes: []const u8, cursor: usize, cells: u32) u64 {
    return if (cells == 2) be64(bytes, cursor) else be32(bytes, cursor);
}
fn rangeAt(reg: []const u8, cursor: usize, address_cells: u32, size_cells: u32) Error!Range {
    const range: Range = .{
        .base = cellValue(reg, cursor, address_cells),
        .length = cellValue(reg, cursor + address_cells * 4, size_cells),
    };
    _ = try range.end();
    return range;
}
fn appendRange(ranges: *[max_ranges]Range, count: *usize, range: Range) Error!void {
    _ = try range.end();
    if (count.* == max_ranges) return error.CapacityExceeded;
    ranges[count.*] = range;
    count.* += 1;
}
fn appendRegisters(ranges: *[max_ranges]Range, count: *usize, reg: []const u8, address_cells: u32, size_cells: u32) Error!void {
    const width = try tupleWidth(address_cells, size_cells);
    if (reg.len == 0 or reg.len % width != 0) return error.InvalidRange;
    var cursor: usize = 0;
    while (cursor < reg.len) : (cursor += width) try appendRange(ranges, count, try rangeAt(reg, cursor, address_cells, size_cells));
}
fn baudOption(options: []const u8) Error!u32 {
    var baud: u32 = 0;
    var cursor: usize = 0;
    while (cursor < options.len and options[cursor] >= '0' and options[cursor] <= '9') : (cursor += 1) {
        const product = @mulWithOverflow(baud, @as(u32, 10));
        const sum = @addWithOverflow(product[0], @as(u32, options[cursor] - '0'));
        if (product[1] != 0 or sum[1] != 0) return error.UnsupportedConsole;
        baud = sum[0];
    }
    if (cursor == 0 or baud == 0 or !(cursor == options.len or std.mem.eql(u8, options[cursor..], "n8")))
        return error.UnsupportedConsole;
    return baud;
}

// Small synthetic hardware fixtures exercise wire format and discovery together.
// The writer is test-only and deliberately keeps the production parser allocator-free.
const Fixture = struct {
    structure: [4096]u8 = undefined,
    structure_size: usize = 0,
    strings: [1024]u8 = undefined,
    strings_size: usize = 0,

    fn word(self: *Fixture, value: u32) void {
        write32(&self.structure, self.structure_size, value);
        self.structure_size += 4;
    }
    fn begin(self: *Fixture, name: []const u8) void {
        self.word(1);
        self.bytes(name);
        self.bytes(&.{0});
        self.pad();
    }
    fn finishNode(self: *Fixture) void {
        self.word(2);
    }
    fn bytes(self: *Fixture, value: []const u8) void {
        @memcpy(self.structure[self.structure_size..][0..value.len], value);
        self.structure_size += value.len;
    }
    fn pad(self: *Fixture) void {
        while (self.structure_size % 4 != 0) self.bytes(&.{0});
    }
    fn property(self: *Fixture, name: []const u8, value: []const u8) void {
        const offset = self.strings_size;
        @memcpy(self.strings[offset..][0..name.len], name);
        self.strings[offset + name.len] = 0;
        self.strings_size += name.len + 1;
        self.word(3);
        self.word(@intCast(value.len));
        self.word(@intCast(offset));
        self.bytes(value);
        self.pad();
    }
    fn cell(self: *Fixture, name: []const u8, value: u32) void {
        var raw: [4]u8 = undefined;
        write32(&raw, 0, value);
        self.property(name, &raw);
    }
    fn registers(self: *Fixture, name: []const u8, ranges: []const Range) void {
        var raw: [max_ranges * 16 + 16]u8 = undefined;
        for (ranges, 0..) |range, index| {
            write64(&raw, index * 16, range.base);
            write64(&raw, index * 16 + 8, range.length);
        }
        self.property(name, raw[0 .. ranges.len * 16]);
    }
    fn build(self: *Fixture, output: []u8, reservation: ?Range) []u8 {
        self.word(9);
        const structure_offset: usize = if (reservation == null) 56 else 72;
        const strings_offset = structure_offset + self.structure_size;
        const total = strings_offset + self.strings_size;
        @memset(output[0..total], 0);
        write32(output, 0, 0xd00dfeed);
        write32(output, 4, @intCast(total));
        write32(output, 8, @intCast(structure_offset));
        write32(output, 12, @intCast(strings_offset));
        write32(output, 16, 40);
        write32(output, 20, 17);
        write32(output, 24, 16);
        write32(output, 32, @intCast(self.strings_size));
        write32(output, 36, @intCast(self.structure_size));
        if (reservation) |range| {
            write64(output, 40, range.base);
            write64(output, 48, range.length);
        }
        @memcpy(output[structure_offset..][0..self.structure_size], self.structure[0..self.structure_size]);
        @memcpy(output[strings_offset..][0..self.strings_size], self.strings[0..self.strings_size]);
        return output[0..total];
    }
};
fn write32(bytes: []u8, offset: usize, value: u32) void {
    bytes[offset] = @truncate(value >> 24);
    bytes[offset + 1] = @truncate(value >> 16);
    bytes[offset + 2] = @truncate(value >> 8);
    bytes[offset + 3] = @truncate(value);
}
fn write64(bytes: []u8, offset: usize, value: u64) void {
    write32(bytes, offset, @truncate(value >> 32));
    write32(bytes, offset + 4, @truncate(value));
}
const FixtureOptions = struct {
    pl011: bool = false,
    translated_bus: bool = false,
    dynamic_reservation: bool = false,
    duplicate_memory_reg: bool = false,
    missing_clock: bool = false,
    excessive_banks: bool = false,
    disabled_reservation: bool = false,
    duplicate_phandle: bool = false,
    legacy_stdout: bool = false,
    stdout: []const u8 = "serial0:57600n8\x00",
    reg_shift: u32 = 0,
};
fn hardwareFixture(output: []u8, options: FixtureOptions) []u8 {
    var fixture: Fixture = .{};
    fixture.begin("");
    fixture.cell("#address-cells", 2);
    fixture.cell("#size-cells", 2);
    fixture.begin("memory@80000000");
    fixture.property("device_type", "memory\x00");
    if (options.excessive_banks) {
        var ranges: [max_ranges + 1]Range = undefined;
        for (&ranges, 0..) |*range, index| range.* = .{ .base = 0x80000000 + index * 0x100000, .length = 0x100000 };
        fixture.registers("reg", &ranges);
    } else {
        fixture.registers("reg", &.{ .{ .base = 0x80000000, .length = 0x04000000 }, .{ .base = 0x90000000, .length = 0x01000000 } });
    }
    if (options.duplicate_memory_reg) fixture.registers("reg", &.{.{ .base = 0xa0000000, .length = 0x1000 }});
    fixture.finishNode();
    fixture.begin("reserved-memory");
    fixture.cell("#address-cells", 2);
    fixture.cell("#size-cells", 2);
    fixture.property("ranges", &.{});
    fixture.begin("secure@80700000");
    if (options.disabled_reservation) fixture.property("status", "disabled\x00");
    if (options.dynamic_reservation) fixture.registers("size", &.{.{ .base = 0, .length = 0x1000 }}) else fixture.registers("reg", &.{.{ .base = 0x80700000, .length = 0x1000 }});
    fixture.property("no-map", &.{});
    fixture.finishNode();
    fixture.finishNode();
    fixture.begin("chosen");
    fixture.property(if (options.legacy_stdout) "linux,stdout-path" else "stdout-path", options.stdout);
    fixture.finishNode();
    fixture.begin("aliases");
    fixture.property("serial0", "/soc/serial@10000000\x00");
    fixture.finishNode();
    if (options.pl011) {
        fixture.begin("clock");
        fixture.property("compatible", "fixed-clock\x00");
        fixture.cell("phandle", 7);
        fixture.cell("#clock-cells", 0);
        fixture.cell("clock-frequency", 24000000);
        fixture.finishNode();
    }
    if (options.duplicate_phandle) {
        fixture.begin("unused-device");
        fixture.cell("phandle", 7);
        fixture.finishNode();
    }
    fixture.begin("soc");
    fixture.cell("#address-cells", 2);
    fixture.cell("#size-cells", 2);
    fixture.property("ranges", if (options.translated_bus) &.{ 0, 0, 0, 1 } else &.{});
    fixture.begin("serial@10000000");
    fixture.property("compatible", if (options.pl011) "arm,pl011\x00arm,primecell\x00" else "ns16550a\x00");
    fixture.registers("reg", &.{.{ .base = 0x10000000, .length = 0x1000 }});
    if (options.reg_shift != 0) fixture.cell("reg-shift", options.reg_shift);
    if (!options.missing_clock) {
        if (options.pl011) fixture.property("clocks", &.{ 0, 0, 0, 7, 0, 0, 0, 7 }) else fixture.cell("clock-frequency", 3686400);
    }
    fixture.finishNode();
    fixture.finishNode();
    fixture.finishNode();
    return fixture.build(output, .{ .base = 0x80600000, .length = 0x1000 });
}

test "hardware discovery uses multiple banks, both reservation tables and aliased stdout" {
    var output: [8192]u8 = undefined;
    const blob = hardwareFixture(&output, .{});
    const discovery = try parse(blob);
    try std.testing.expectEqual(@as(usize, 2), discovery.memory_count);
    try std.testing.expectEqual(@as(u64, 0x04000000), discovery.memory[0].length);
    try std.testing.expectEqual(@as(usize, 2), discovery.reserved_count);
    try std.testing.expectEqual(@as(u64, 0x80600000), discovery.reserved[0].base);
    try std.testing.expectEqual(@as(u64, 0x80700000), discovery.reserved[1].base);
    try std.testing.expectEqual(ConsoleKind.ns16550_mmio, discovery.console.kind);
    try std.testing.expectEqual(@as(u64, 0x10000000), discovery.console.range.base);
    try std.testing.expectEqual(@as(u32, 3686400), discovery.console.clock_hz);
    try std.testing.expectEqual(@as(u32, 57600), discovery.console.baud_rate);
    try std.testing.expect(discovery.containingBank(.{ .base = 0x80200000, .length = 0x200000 }) != null);
    try std.testing.expect(discovery.containingBank(.{ .base = 0x83f00000, .length = 0x200000 }) == null);
    try std.testing.expect(discovery.conflicts(.{ .base = 0x80600080, .length = 16 }));
}
test "PL011 resolves a shared fixed-clock phandle and parses an unaligned blob" {
    var output: [8193]u8 = undefined;
    const discovery = try parse(hardwareFixture(output[1..], .{ .pl011 = true }));
    try std.testing.expectEqual(ConsoleKind.pl011, discovery.console.kind);
    try std.testing.expectEqual(@as(u32, 24000000), discovery.console.clock_hz);
    try std.testing.expectEqual(@as(u32, 4), discovery.console.register_stride);
}
test "malformed header and overlapping tables fail before discovery" {
    var output: [8192]u8 = undefined;
    var blob = hardwareFixture(&output, .{});
    try std.testing.expectError(error.Truncated, parse(blob[0 .. blob.len - 1]));
    write32(blob, 8, 41);
    try std.testing.expectError(error.InvalidHeader, parse(blob));
    blob = hardwareFixture(&output, .{});
    write32(blob, 12, be32(blob, 8));
    try std.testing.expectError(error.InvalidHeader, parse(blob));
    blob = hardwareFixture(&output, .{});
    write32(blob, 24, 18);
    try std.testing.expectError(error.UnsupportedVersion, parse(blob));
}
test "malformed property names, duplicate properties and token nesting are rejected" {
    var output: [8192]u8 = undefined;
    var blob = hardwareFixture(&output, .{});
    const structure: usize = be32(blob, 8);
    write32(blob, structure + 16, 0xffffffff); // Root's first property string offset.
    try std.testing.expectError(error.InvalidString, parse(blob));
    blob = hardwareFixture(&output, .{ .duplicate_memory_reg = true });
    try std.testing.expectError(error.DuplicateProperty, parse(blob));
    blob = hardwareFixture(&output, .{});
    write32(blob, be32(blob, 8), 2); // End without root.
    try std.testing.expectError(error.InvalidStructure, parse(blob));
}
test "overflowing reservations and excessive discovery counts are rejected" {
    var output: [8192]u8 = undefined;
    const blob = hardwareFixture(&output, .{});
    write64(blob, 40, std.math.maxInt(u64) - 1);
    write64(blob, 48, 4);
    try std.testing.expectError(error.InvalidRange, parse(blob));
    try std.testing.expectError(error.CapacityExceeded, parse(hardwareFixture(&output, .{ .excessive_banks = true })));
}
test "unsupported translations, dynamic reservations and missing UART clocks fail explicitly" {
    var output: [8192]u8 = undefined;
    try std.testing.expectError(error.UnsupportedBus, parse(hardwareFixture(&output, .{ .translated_bus = true })));
    try std.testing.expectError(error.UnsupportedReservation, parse(hardwareFixture(&output, .{ .dynamic_reservation = true })));
    try std.testing.expectError(error.MissingClock, parse(hardwareFixture(&output, .{ .missing_clock = true })));
}
test "structure nesting has a fixed depth limit" {
    var output: [8192]u8 = undefined;
    var fixture: Fixture = .{};
    fixture.begin("");
    for (0..max_depth) |_| fixture.begin("nested");
    for (0..max_depth + 1) |_| fixture.finishNode();
    try std.testing.expectError(error.CapacityExceeded, parse(fixture.build(&output, null)));
}

fn propertyToken(blob: []const u8, path: []const u8, name: []const u8) Error!usize {
    const offset: usize = be32(blob, 8);
    var tree: Tree = .{
        .structure = blob[offset..][0..be32(blob, 36)],
        .strings = blob[be32(blob, 12)..][0..be32(blob, 32)],
    };
    try tree.walk();
    const node = tree.nodes[try tree.path(path)];
    var cursor = node.properties_start;
    while (cursor < node.properties_end) {
        if (be32(tree.structure, cursor) == 4) {
            cursor += 4;
            continue;
        }
        const property = try tree.propertyAt(cursor);
        if (std.mem.eql(u8, property.name, name)) return offset + cursor;
        cursor = property.next;
    }
    return error.InvalidStructure;
}

test "alignment padding may retain nonzero bytes as real libfdt blobs do" {
    var output: [8192]u8 = undefined;
    const blob = hardwareFixture(&output, .{});
    const root: usize = be32(blob, 8);
    @memset(blob[root + 5 .. root + 8], 0xa5); // Root node-name padding.
    const token = try propertyToken(blob, "/memory@80000000", "device_type");
    blob[token + 12 + 7] = 0xf1; // Seven-byte "memory\0" property padding.
    _ = try parse(blob);
}
test "disabled static reservation children are skipped while enabled dynamic ones fail" {
    var output: [8192]u8 = undefined;
    const discovery = try parse(hardwareFixture(&output, .{ .disabled_reservation = true, .dynamic_reservation = true }));
    try std.testing.expectEqual(@as(usize, 1), discovery.reserved_count); // Memreserve remains active.
}
test "global phandles are unique and nonzero, including unused providers" {
    var output: [8192]u8 = undefined;
    try std.testing.expectError(error.InvalidStructure, parse(hardwareFixture(&output, .{ .pl011 = true, .duplicate_phandle = true })));
    const blob = hardwareFixture(&output, .{ .pl011 = true });
    const token = try propertyToken(blob, "/clock", "phandle");
    write32(blob, token + 12, 0);
    try std.testing.expectError(error.InvalidStructure, parse(blob));
}
test "legacy stdout and byte-register strides work while unsupported serial options fail" {
    var output: [8192]u8 = undefined;
    const discovery = try parse(hardwareFixture(&output, .{ .legacy_stdout = true, .reg_shift = 2 }));
    try std.testing.expectEqual(@as(u32, 4), discovery.console.register_stride);
    try std.testing.expectError(error.UnsupportedConsole, parse(hardwareFixture(&output, .{ .stdout = "serial0:9600e7\x00" })));
    try std.testing.expectError(error.UnsupportedConsole, parse(hardwareFixture(&output, .{ .reg_shift = 4 })));
}
test "malformed memory tuple sizes, overflowing banks and overlapping banks fail" {
    var output: [8192]u8 = undefined;
    var blob = hardwareFixture(&output, .{});
    var token = try propertyToken(blob, "/memory@80000000", "reg");
    write32(blob, token + 4, 31);
    try std.testing.expectError(error.InvalidRange, parse(blob));
    blob = hardwareFixture(&output, .{});
    token = try propertyToken(blob, "/memory@80000000", "reg");
    write64(blob, token + 12, std.math.maxInt(u64) - 1);
    write64(blob, token + 20, 4);
    try std.testing.expectError(error.InvalidRange, parse(blob));
    blob = hardwareFixture(&output, .{});
    token = try propertyToken(blob, "/memory@80000000", "reg");
    write64(blob, token + 28, 0x80001000);
    try std.testing.expectError(error.OverlappingMemory, parse(blob));
    blob = hardwareFixture(&output, .{});
    token = try propertyToken(blob, "/", "#address-cells");
    write32(blob, token + 12, 3);
    try std.testing.expectError(error.UnsupportedCells, parse(blob));
}
test "one-cell root addresses and sizes decode their declared reg tuple width" {
    var output: [8192]u8 = undefined;
    var fixture: Fixture = .{};
    fixture.begin("");
    fixture.cell("#address-cells", 1);
    fixture.cell("#size-cells", 1);
    fixture.begin("memory@80000000");
    fixture.property("device_type", "memory\x00");
    fixture.property("reg", &.{ 0x80, 0, 0, 0, 0x04, 0, 0, 0 });
    fixture.finishNode();
    fixture.begin("serial@10000000");
    fixture.property("compatible", "ns16550a\x00");
    fixture.property("reg", &.{ 0x10, 0, 0, 0, 0, 0, 0x10, 0 });
    fixture.cell("clock-frequency", 3686400);
    fixture.finishNode();
    fixture.begin("chosen");
    fixture.property("stdout-path", "/serial@10000000\x00");
    fixture.finishNode();
    fixture.finishNode();
    const discovery = try parse(fixture.build(&output, null));
    try std.testing.expectEqual(@as(u64, 0x80000000), discovery.memory[0].base);
    try std.testing.expectEqual(@as(u64, 0x04000000), discovery.memory[0].length);
    try std.testing.expectEqual(@as(u32, 115200), discovery.console.baud_rate);
}

test "hardware-only GOP discovery preserves both reservation sources without chosen or UART" {
    var output: [8192]u8 = undefined;
    var fixture: Fixture = .{};
    fixture.begin("");
    fixture.cell("#address-cells", 2);
    fixture.cell("#size-cells", 2);
    fixture.begin("memory@80000000");
    fixture.property("device_type", "memory\x00");
    fixture.registers("reg", &.{.{ .base = 0x80000000, .length = 0x4000000 }});
    fixture.finishNode();
    fixture.begin("reserved-memory");
    fixture.cell("#address-cells", 2);
    fixture.cell("#size-cells", 2);
    fixture.property("ranges", &.{});
    fixture.begin("secure@80700000");
    fixture.registers("reg", &.{.{ .base = 0x80700000, .length = 0x1000 }});
    fixture.property("no-map", &.{});
    fixture.finishNode();
    fixture.finishNode();
    fixture.finishNode();
    const blob = fixture.build(&output, .{ .base = 0x80600000, .length = 0x1000 });
    try std.testing.expectError(error.MissingConsole, parse(blob));
    const discovery = try parseHardware(blob);
    try std.testing.expect(!discovery.console_available);
    try std.testing.expectEqual(blob.len, discovery.total_size);
    try std.testing.expectEqual(@as(usize, 1), discovery.memory_count);
    try std.testing.expectEqual(Range{ .base = 0x80000000, .length = 0x4000000 }, discovery.memory[0]);
    try std.testing.expectEqual(@as(usize, 2), discovery.reserved_count);
    try std.testing.expect(discovery.conflicts(.{ .base = 0x80600800, .length = 16 }));
    try std.testing.expect(discovery.conflicts(.{ .base = 0x80700800, .length = 16 }));
    // Optional console selection never skips the structure walk.
    write32(blob, be32(blob, 8), 2);
    try std.testing.expectError(error.InvalidStructure, parseHardware(blob));
}

test "hardware-only discovery skips serial requirements but still rejects malformed reservations and phandles" {
    var output: [8192]u8 = undefined;
    const hardware = try parseHardware(hardwareFixture(&output, .{ .missing_clock = true, .stdout = "unsupported:9600e7\x00" }));
    try std.testing.expect(!hardware.console_available);
    try std.testing.expectEqual(@as(usize, 2), hardware.reserved_count);
    try std.testing.expectError(error.UnsupportedReservation, parseHardware(hardwareFixture(&output, .{ .dynamic_reservation = true })));
    try std.testing.expectError(error.InvalidStructure, parseHardware(hardwareFixture(&output, .{ .pl011 = true, .duplicate_phandle = true })));
    const serial = try parse(hardwareFixture(&output, .{}));
    try std.testing.expect(serial.console_available);
}
