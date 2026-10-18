//! Bounded navigation tabs over one active Files Model. Store this beside the
//! Model in caller-owned persistent memory, never on a small userspace stack.
//! Snapshots retain navigation, not directory listings or filesystem authority.
const std = @import("std");
const api = @import("provider.zig");
const controller = @import("model.zig");
const path_edit = @import("path_editor.zig");
const Model = controller.Model;

pub const capacity = 8;
pub const CloseResult = enum { changed, close_window };
pub const Navigation = struct {
    path: [api.max_path_bytes]u8 = undefined,
    path_len: usize = 0,
    selected_name: [api.max_name_bytes]u8 = undefined,
    selected_len: usize = 0,
    selected_kind: api.Kind = .file,
    scroll: usize = 0,
    history: controller.History = .{},
};
pub const Record = struct {
    id: u32 = 0,
    panes: [2]Navigation = .{ .{}, .{} },
    focus: usize = 0,
    split: bool = false,
};

/// One caller-owned transfer may remain frozen while a destination window is
/// created asynchronously. Checked listings stage here, outside every Model's
/// stack, so a failed import changes neither window's navigation nor IDs.
pub const TabTransfer = struct {
    record: Record = undefined,
    source_tab_id: u32 = 0,
    source: ?*const TabStore = null,
    source_generation: u64 = 0,
    destination: ?*const TabStore = null,
    destination_generation: u64 = 0,
    destination_tab_id: u32 = 0,
    valid: bool = false,
    committed: bool = false,
    listings: [2][api.max_entries]api.Entry = undefined,
    counts: [2]usize = .{ 0, 0 },
    truncated: [2]bool = .{ false, false },

    pub fn cancel(self: *TabTransfer) void {
        self.valid = false;
        self.committed = false;
        self.source = null;
        self.destination = null;
        self.source_tab_id = 0;
        self.destination_tab_id = 0;
    }
};

pub const TabStore = struct {
    records: [capacity]Record = undefined,
    count: usize = 0,
    active: usize = 0,
    next_id: u32 = 1,
    generation: u64 = 0,

    pub fn init(self: *TabStore, model: *const Model) !void {
        try ready(model);
        if (self.generation == std.math.maxInt(u64)) return error.TabGenerationExhausted;
        self.generation += 1;
        self.count = 1;
        self.active = 0;
        self.next_id = 2;
        self.records[0].id = 1;
        self.capture(0, model);
    }

    pub fn id(self: *const TabStore, index: usize) ?u32 {
        if (index >= self.count) return null;
        return self.records[index].id;
    }

    /// The active title follows live navigation without requiring a snapshot.
    /// Returned bytes borrow the Model or this store until its next mutation.
    pub fn title(self: *const TabStore, index: usize, model: *const Model) []const u8 {
        if (index >= self.count) return "";
        const path = if (index == self.active)
            model.panes[model.focus].directory()
        else blk: {
            const record = &self.records[index];
            const pane = &record.panes[record.focus];
            break :blk pane.path[0..pane.path_len];
        };
        if (std.mem.eql(u8, path, "/container")) return "Home";
        if (std.mem.eql(u8, path, "/")) return "/";
        const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
        return path[slash + 1 ..];
    }

    /// Start a single-pane tab in the focused folder, with a fresh history.
    /// Capacity/ID errors are atomic. A reload error leaves the new tab active
    /// with an empty failed pane and an error status, so Back/Up can recover.
    pub fn add(self: *TabStore, model: *Model) !void {
        try self.check(model);
        if (self.count == capacity) return error.TabCapacity;
        if (self.next_id == 0) return error.TabIdExhausted;
        self.capture(self.active, model);
        const record = &self.records[self.count];
        const path = model.panes[model.focus].directory();
        record.id = self.next_id;
        record.focus = 0;
        record.split = false;
        for (&record.panes) |*pane| {
            @memcpy(pane.path[0..path.len], path);
            pane.path_len = path.len;
            pane.selected_len = 0;
            pane.scroll = 0;
            pane.history.count = 1;
            pane.history.position = 0;
            @memcpy(pane.history.locations[0].bytes[0..path.len], path);
            pane.history.locations[0].len = path.len;
        }
        self.next_id +%= 1;
        self.active = self.count;
        self.count += 1;
        try self.restore(model);
    }

    /// Switching always relists through the current checked provider. A folder
    /// that disappeared remains navigable as a tab, with no stale entries.
    pub fn select(self: *TabStore, index: usize, model: *Model) !void {
        try self.check(model);
        if (index >= self.count) return error.InvalidTab;
        if (index == self.active) return;
        self.capture(self.active, model);
        self.active = index;
        try self.restore(model);
    }

    /// Rotate records in place without copying a multi-KiB snapshot onto the
    /// stack. Reordering never reloads or changes the active Model's contents.
    pub fn reorder(self: *TabStore, from: usize, to: usize, model: *Model) !void {
        try self.check(model);
        if (from >= self.count or to >= self.count) return error.InvalidTab;
        if (from == to) return;
        const active_id = self.records[self.active].id;
        self.capture(self.active, model);
        for (0..@sizeOf(Record)) |byte| {
            const saved = std.mem.asBytes(&self.records[from])[byte];
            var position = from;
            while (position != to) {
                const next = if (from < to) position + 1 else position - 1;
                std.mem.asBytes(&self.records[position])[byte] = std.mem.asBytes(&self.records[next])[byte];
                position = next;
            }
            std.mem.asBytes(&self.records[to])[byte] = saved;
        }
        self.active = self.find(active_id).?;
        model.revision +|= 1;
    }

    pub fn beginExport(self: *TabStore, index: usize, model: *Model, transfer: *TabTransfer) !void {
        try self.check(model);
        if (index >= self.count) return error.InvalidTab;
        self.capture(self.active, model);
        @memcpy(std.mem.asBytes(&transfer.record), std.mem.asBytes(&self.records[index]));
        transfer.source_tab_id = self.records[index].id;
        transfer.source = self;
        transfer.source_generation = self.generation;
        transfer.destination = null;
        transfer.destination_generation = 0;
        transfer.destination_tab_id = 0;
        transfer.valid = true;
        transfer.committed = false;
    }

    /// Replace a newly created window's one placeholder only after both paths
    /// have been relisted successfully under that window's current provider.
    pub fn importTransfer(self: *TabStore, model: *Model, transfer: *TabTransfer) !void {
        try self.check(model);
        if (!transfer.valid or transfer.committed or transfer.destination != null) return error.InvalidTabTransfer;
        const source = transfer.source orelse return error.InvalidTabTransfer;
        if (source == self) return error.SameTabWindow;
        if (source.generation != transfer.source_generation or source.find(transfer.source_tab_id) == null) return error.StaleTabTransfer;
        if (self.count != 1) return error.TabDestinationBusy;
        if (self.next_id == 0) return error.TabIdExhausted;
        var new_id = self.next_id;
        if (new_id == transfer.source_tab_id) {
            if (new_id == std.math.maxInt(u32)) return error.TabIdExhausted;
            new_id += 1;
        }
        const provider = model.provider.?;
        for (&transfer.record.panes, 0..) |*pane, index| {
            readListing(provider, pane.path[0..pane.path_len], &transfer.listings[index], &transfer.counts[index], &transfer.truncated[index]) catch |err| {
                model.reportError(err);
                return err;
            };
        }
        @memcpy(std.mem.asBytes(&self.records[0]), std.mem.asBytes(&transfer.record));
        self.records[0].id = new_id;
        self.next_id = new_id +% 1;
        self.active = 0;
        const reversed = self.prepareRestore(model);
        const record = &self.records[0];
        for (&model.panes, 0..) |*pane, index| {
            const source_index = if (reversed) 1 - index else index;
            pane.count = transfer.counts[source_index];
            @memcpy(pane.entries[0..pane.count], transfer.listings[source_index][0..pane.count]);
            pane.truncated = transfer.truncated[source_index];
            restoreSelection(&record.panes[source_index], pane);
        }
        model.revision +|= 1;
        transfer.destination = self;
        transfer.destination_generation = self.generation;
        transfer.destination_tab_id = new_id;
    }

    /// Commit only after the destination is created/configured and imported.
    /// If a surviving source pane cannot reload after removal, the error is
    /// returned honestly and committed=true still records the completed move.
    pub fn commitExport(self: *TabStore, model: *Model, transfer: *TabTransfer) !CloseResult {
        try self.check(model);
        if (!transfer.valid or transfer.committed or transfer.source != self) return error.InvalidTabTransfer;
        if (transfer.source_generation != self.generation) return error.StaleTabTransfer;
        const destination = transfer.destination orelse return error.TabTransferNotReady;
        if (destination.generation != transfer.destination_generation or destination.find(transfer.destination_tab_id) == null) return error.StaleTabTransfer;
        const index = self.find(transfer.source_tab_id) orelse return error.StaleTabTransfer;
        self.capture(self.active, model);
        if (!sameNavigation(&self.records[index], &transfer.record)) return error.TabTransferChanged;
        const result = self.close(index, model) catch |err| {
            transfer.committed = self.find(transfer.source_tab_id) == null;
            return err;
        };
        transfer.committed = true;
        return result;
    }

    /// Closing the last tab requests window closure while retaining its valid
    /// record until the host accepts that request. Other records keep their IDs.
    pub fn close(self: *TabStore, index: usize, model: *Model) !CloseResult {
        try self.check(model);
        if (index >= self.count) return error.InvalidTab;
        if (self.count == 1) {
            cancelInteraction(model);
            return .close_window;
        }
        self.capture(self.active, model);
        const closing_active = index == self.active;
        const shifted = self.count - index - 1;
        // Byte-wise copying avoids a multi-KiB Record temporary on the stack.
        if (shifted != 0) std.mem.copyForwards(u8, std.mem.sliceAsBytes(self.records[index .. index + shifted]), std.mem.sliceAsBytes(self.records[index + 1 .. self.count]));
        self.count -= 1;
        if (closing_active) {
            self.active = @min(index, self.count - 1);
            try self.restore(model);
        } else {
            if (index < self.active) self.active -= 1;
            cancelInteraction(model);
        }
        return .changed;
    }

    fn check(self: *const TabStore, model: *const Model) !void {
        try ready(model);
        if (self.count == 0 or self.count > capacity or self.active >= self.count) return error.NotInitialized;
    }

    fn find(self: *const TabStore, wanted: u32) ?usize {
        for (self.records[0..self.count], 0..) |*record, index| if (record.id == wanted) return index;
        return null;
    }

    fn capture(self: *TabStore, index: usize, model: *const Model) void {
        const record = &self.records[index];
        record.focus = model.focus;
        record.split = model.split;
        for (&record.panes, &model.panes, &model.histories) |*saved, *pane, *history| {
            @memcpy(saved.path[0..pane.path_len], pane.directory());
            saved.path_len = pane.path_len;
            saved.scroll = pane.scroll;
            saved.selected_len = 0;
            if (pane.selected) |selected| if (selected < pane.count) {
                const entry = &pane.entries[selected];
                @memcpy(saved.selected_name[0..entry.name_len], entry.bytes());
                saved.selected_len = entry.name_len;
                saved.selected_kind = entry.kind;
            };
            @memcpy(std.mem.asBytes(&saved.history), std.mem.asBytes(history));
        }
    }

    fn prepareRestore(self: *const TabStore, model: *Model) bool {
        cancelInteraction(model);
        const record = &self.records[self.active];
        model.split = record.split and model.split_allowed;
        const reversed = !model.split and record.focus == 1;
        model.focus = if (model.split) record.focus else 0;
        // Both paths and empty listings commit before callbacks. A failed
        // transaction can never expose another tab's entries under this path.
        for (&model.panes, &model.histories, 0..) |*pane, *history, index| {
            const saved = &record.panes[if (reversed) 1 - index else index];
            @memcpy(pane.path[0..saved.path_len], saved.path[0..saved.path_len]);
            pane.path_len = saved.path_len;
            pane.display_path_len = path_edit.display(pane.directory(), &pane.display_path).len;
            pane.count = 0;
            pane.selected = null;
            pane.scroll = 0;
            pane.truncated = false;
            @memcpy(std.mem.asBytes(history), std.mem.asBytes(&saved.history));
        }
        return reversed;
    }

    fn restore(self: *TabStore, model: *Model) !void {
        const reversed = self.prepareRestore(model);
        const record = &self.records[self.active];
        var first_error: ?anyerror = null;
        for (&model.panes, 0..) |*pane, index| {
            model.reload(index) catch |err| {
                if (first_error == null) first_error = err;
                continue;
            };
            const saved = &record.panes[if (reversed) 1 - index else index];
            restoreSelection(saved, pane);
        }
        if (first_error) |err| {
            model.reportError(err);
            return err;
        }
    }
};

fn restoreSelection(saved: *const Navigation, pane: *controller.Pane) void {
    for (pane.entries[0..pane.count], 0..) |*entry, row| {
        if (saved.selected_len != 0 and entry.kind == saved.selected_kind and
            std.mem.eql(u8, saved.selected_name[0..saved.selected_len], entry.bytes()))
        {
            pane.selected = row;
            break;
        }
    }
    pane.scroll = @min(saved.scroll, pane.count -| 1);
}

fn readListing(provider: api.Provider, path: []const u8, output: *[api.max_entries]api.Entry, count: *usize, truncated: *bool) !void {
    try api.validatePath(path);
    var cursor: usize = 0;
    count.* = 0;
    truncated.* = false;
    while (true) {
        const before = cursor;
        const entry = try provider.list(provider.context, path, &cursor) orelse return;
        if (cursor <= before or entry.name_len > api.max_name_bytes) return error.InvalidListing;
        try api.validateName(entry.bytes());
        for (output[0..count.*]) |*previous| if (std.mem.eql(u8, previous.bytes(), entry.bytes())) return error.InvalidListing;
        if (count.* == api.max_entries) {
            truncated.* = true;
            return;
        }
        output[count.*] = entry;
        count.* += 1;
    }
}

fn sameNavigation(a: *const Record, b: *const Record) bool {
    if (a.focus != b.focus or a.split != b.split) return false;
    for (&a.panes, &b.panes) |*left, *right| {
        if (left.path_len != right.path_len or !std.mem.eql(u8, left.path[0..left.path_len], right.path[0..right.path_len]) or
            left.scroll != right.scroll or left.selected_len != right.selected_len or
            (left.selected_len != 0 and (left.selected_kind != right.selected_kind or !std.mem.eql(u8, left.selected_name[0..left.selected_len], right.selected_name[0..right.selected_len]))) or
            left.history.count != right.history.count or left.history.position != right.history.position) return false;
        for (left.history.locations[0..left.history.count], right.history.locations[0..right.history.count]) |*one, *two| {
            if (one.len != two.len or !std.mem.eql(u8, one.bytes[0..one.len], two.bytes[0..two.len])) return false;
        }
    }
    return true;
}

fn ready(model: *const Model) !void {
    if (!model.initialized or model.provider == null or model.focus >= 2) return error.NotInitialized;
}

fn wipe(bytes: []u8) void {
    const target: [*]volatile u8 = @ptrCast(bytes.ptr);
    for (0..bytes.len) |index| target[index] = 0;
}
fn cancelInteraction(model: *Model) void {
    model.dismissMenu();
    model.drag = null;
    model.pressed_action = null;
    model.pressed_shortcut = null;
    model.hovered_action = null;
    model.pressed_edit = null;
    model.edit = .none;
    model.edit_len = 0;
    model.edit_cursor = 0;
    wipe(&model.edit_text);
    model.path_editing = false;
    wipe(&model.path_editor.bytes);
    model.path_editor.len = 0;
    model.path_editor.cursor = 0;
    model.path_editor.anchor = 0;
    model.preview_open = false;
    model.preview_len = 0;
    model.preview_name_len = 0;
    model.preview_path_len = 0;
    wipe(&model.preview);
    wipe(&model.preview_name);
    wipe(&model.preview_path);
    model.status_len = 0;
    model.status_error = false;
    model.status_notice = false;
    model.revision +|= 1;
}
