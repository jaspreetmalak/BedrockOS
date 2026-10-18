const std = @import("std");
const files = @import("root.zig");
const tabs = @import("tabs.zig");

const Provider = struct {
    reordered: bool = false,
    removed: bool = false,
    missing: bool = false,
    partial: bool = false,
    changed_kind: bool = false,
    listings: usize = 0,
    writes: usize = 0,
    fn list(context: *anyopaque, path: []const u8, cursor: *usize) anyerror!?files.Entry {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.listings += 1;
        if (std.mem.eql(u8, path, "/container/Gone")) {
            if (self.missing) return error.NotFound;
            return null;
        }
        if (!std.mem.eql(u8, path, "/container/Documents") and !std.mem.eql(u8, path, "/container/Downloads") and
            !std.mem.eql(u8, path, "/container/Desktop") and !std.mem.eql(u8, path, "/container")) return error.PermissionDenied;
        if (self.partial and std.mem.eql(u8, path, "/container/Documents")) {
            if (cursor.* != 0) return error.PermissionDenied;
            cursor.* += 1;
            return try files.Entry.init("uncommitted.txt", .file, 1, false);
        }
        if (cursor.* >= (if (self.removed) @as(usize, 1) else 2)) return null;
        const index = cursor.*;
        cursor.* += 1;
        const note = !self.removed and (if (self.reordered) index == 1 else index == 0);
        return try files.Entry.init(if (note) "note.txt" else "other.txt", if (note and self.changed_kind) .directory else .file, 10, false);
    }
    fn write(context: *anyopaque, _: []const u8) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.writes += 1;
    }
    fn provider(self: *Provider) files.Provider {
        return .{ .context = self, .list = list, .create = write, .mkdir = write, .remove = write };
    }
};

test "Files tabs duplicate the focused folder with independent navigation histories and stable IDs" {
    var provider: Provider = .{};
    var model: files.Model = .{};
    var store: tabs.TabStore = .{};
    try model.init(provider.provider(), "/container/Documents", "/container/Downloads");
    model.split = true;
    model.focus = 1;
    try store.init(&model);
    try store.add(&model);
    try std.testing.expectEqual(@as(usize, 2), store.count);
    try std.testing.expectEqual(@as(usize, 1), store.active);
    try std.testing.expectEqualStrings("/container/Downloads", model.panes[0].directory());
    try std.testing.expect(!model.split and model.focus == 0 and !model.canBack());
    try std.testing.expectEqualStrings("Downloads", store.title(0, &model));
    try std.testing.expectEqualStrings("Downloads", store.title(1, &model));
    const first_id = store.id(0).?;
    const second_id = store.id(1).?;
    try std.testing.expect(first_id != second_id);
    try model.navigate(0, "/container/Desktop");
    try std.testing.expectEqualStrings("Desktop", store.title(1, &model));
    try std.testing.expectEqual(@as(usize, 2), model.histories[0].count);
    try store.select(0, &model);
    try std.testing.expect(model.split and model.focus == 1 and !model.canBack());
    try std.testing.expectEqualStrings("/container/Documents", model.panes[0].directory());
    try std.testing.expectEqualStrings("/container/Downloads", model.panes[1].directory());
    try store.select(1, &model);
    try std.testing.expect(!model.split and model.canBack());
    model.action(.back);
    try std.testing.expectEqualStrings("/container/Downloads", model.panes[0].directory());
    try std.testing.expectEqual(second_id, store.id(1).?);
    try std.testing.expectEqual(@as(usize, 0), provider.writes);
}

test "Files tab selection is rematched by name and kind after checked relisting" {
    var provider: Provider = .{};
    var model: files.Model = .{};
    var store: tabs.TabStore = .{};
    try model.init(provider.provider(), "/container/Documents", "/container/Downloads");
    model.panes[0].selected = 0;
    model.panes[0].scroll = 1;
    try store.init(&model);
    try store.add(&model);
    provider.reordered = true;
    try store.select(0, &model);
    try std.testing.expectEqual(@as(?usize, 1), model.panes[0].selected);
    try std.testing.expectEqual(@as(usize, 1), model.panes[0].scroll);
    try store.select(1, &model);
    provider.changed_kind = true;
    try store.select(0, &model);
    try std.testing.expect(model.panes[0].selected == null);
    model.panes[0].selected = 1;
    try store.select(1, &model);
    provider.removed = true;
    try store.select(0, &model);
    try std.testing.expect(model.panes[0].selected == null);
    try std.testing.expectEqual(@as(usize, 0), model.panes[0].scroll);
}

test "tab changes cancel captured actions editors and previews but share the clipboard" {
    var provider: Provider = .{};
    var model: files.Model = .{};
    var store: tabs.TabStore = .{};
    try model.init(provider.provider(), "/container/Documents", "/container/Downloads");
    model.panes[0].selected = 0;
    model.action(.copy);
    try store.init(&model);
    try store.add(&model);
    model.drag = .{ .pane = 0, .index = 0, .origin = .{ .x = 10, .y = 80 }, .moving = true };
    model.menu = .{ .kind = .file, .anchor = .{ .x = 10, .y = 80 }, .pressed = 0 };
    model.edit = .rename;
    model.edit_text[0] = 'X';
    model.edit_len = 1;
    model.pressed_edit = .confirm;
    model.pressed_action = .remove;
    model.pressed_shortcut = .desktop;
    model.path_editing = true;
    model.path_editor.set("~/Unsubmitted", true);
    model.preview_open = true;
    @memset(&model.preview, 'S');
    model.preview_len = model.preview.len;
    try store.select(0, &model);
    try std.testing.expect(model.drag == null and model.menu == null and model.edit == .none);
    try std.testing.expect(model.pressed_action == null and model.pressed_edit == null and model.pressed_shortcut == null);
    try std.testing.expect(!model.path_editing and model.path_editor.len == 0 and !model.preview_open and model.preview_len == 0);
    for (model.preview) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    try std.testing.expect(model.clipboard != null);
    try std.testing.expectEqualStrings("note.txt", model.clipboard.?.name[0..model.clipboard.?.name_len]);
    try std.testing.expectEqual(@as(usize, 0), provider.writes);
}

test "closing tabs picks neighbors preserves stable IDs and requests last-window closure" {
    var provider: Provider = .{};
    var model: files.Model = .{};
    var store: tabs.TabStore = .{};
    try model.init(provider.provider(), "/container/Documents", "/container/Downloads");
    try store.init(&model);
    try store.add(&model);
    try model.navigate(0, "/container/Downloads");
    try store.add(&model);
    try model.navigate(0, "/container/Desktop");
    const first_id = store.id(0).?;
    const last_id = store.id(2).?;
    try std.testing.expectEqual(tabs.CloseResult.changed, try store.close(1, &model));
    try std.testing.expectEqual(@as(usize, 1), store.active);
    try std.testing.expectEqual(last_id, store.id(1).?);
    try std.testing.expectEqualStrings("/container/Desktop", model.panes[0].directory());
    try std.testing.expectEqual(tabs.CloseResult.changed, try store.close(1, &model));
    try std.testing.expectEqual(first_id, store.id(0).?);
    try std.testing.expectEqualStrings("/container/Documents", model.panes[0].directory());
    try std.testing.expectEqual(tabs.CloseResult.close_window, try store.close(0, &model));
    try std.testing.expectEqual(@as(usize, 1), store.count);
    try std.testing.expectEqual(@as(usize, 0), provider.writes);
}

test "tab capacity ID exhaustion and invalid targets fail before mutating active interaction" {
    var provider: Provider = .{};
    var model: files.Model = .{};
    var store: tabs.TabStore = .{};
    try model.init(provider.provider(), "/container/Documents", "/container/Downloads");
    try store.init(&model);
    store.next_id = std.math.maxInt(u32);
    try store.add(&model);
    try std.testing.expectEqual(std.math.maxInt(u32), store.id(1).?);
    const calls = provider.listings;
    const revision = model.revision;
    model.edit = .rename;
    try std.testing.expectError(error.TabIdExhausted, store.add(&model));
    try std.testing.expectError(error.InvalidTab, store.select(2, &model));
    try std.testing.expectError(error.InvalidTab, store.close(2, &model));
    try std.testing.expectEqual(calls, provider.listings);
    try std.testing.expectEqual(revision, model.revision);
    try std.testing.expect(model.edit == .rename and store.count == 2 and store.active == 1);
    store.next_id = 3;
    model.edit = .none;
    while (store.count < tabs.capacity) try store.add(&model);
    const full_revision = model.revision;
    try std.testing.expectError(error.TabCapacity, store.add(&model));
    try std.testing.expectEqual(full_revision, model.revision);
    try std.testing.expectEqual(@as(usize, tabs.capacity), store.count);
    try std.testing.expect(@sizeOf(tabs.TabStore) < 48 * 1024);
}

test "failed partial or missing tab reloads expose no stale listing or selection and can recover" {
    var provider: Provider = .{};
    var model: files.Model = .{};
    var store: tabs.TabStore = .{};
    try model.init(provider.provider(), "/container/Documents", "/container/Downloads");
    model.panes[0].selected = 0;
    try store.init(&model);
    try store.add(&model);
    try model.navigate(0, "/container/Downloads");
    provider.partial = true;
    try std.testing.expectError(error.PermissionDenied, store.select(0, &model));
    try std.testing.expectEqualStrings("/container/Documents", model.panes[0].directory());
    try std.testing.expectEqual(@as(usize, 0), model.panes[0].count);
    try std.testing.expect(model.panes[0].selected == null and model.status_error);
    try std.testing.expect(std.mem.indexOf(u8, model.statusText(), "permission") != null);
    provider.partial = false;
    try store.select(1, &model);
    try model.navigate(0, "/container/Gone");
    try store.select(0, &model);
    provider.missing = true;
    try std.testing.expectError(error.NotFound, store.select(1, &model));
    try std.testing.expectEqualStrings("/container/Gone", model.panes[0].directory());
    try std.testing.expectEqual(@as(usize, 0), model.panes[0].count);
    try std.testing.expect(model.panes[0].selected == null);
    model.action(.back);
    try std.testing.expectEqualStrings("/container/Downloads", model.panes[0].directory());
    try std.testing.expectEqual(@as(usize, 2), model.panes[0].count);
    try std.testing.expectEqual(@as(usize, 0), provider.writes);
}

test "narrow tab restoration keeps its focused pane and history while collapsing split state" {
    var provider: Provider = .{};
    var model: files.Model = .{};
    var store: tabs.TabStore = .{};
    try model.init(provider.provider(), "/container/Documents", "/container/Downloads");
    model.split = true;
    model.focus = 1;
    try model.navigate(1, "/container/Desktop");
    try store.init(&model);
    try store.add(&model);
    model.split_allowed = false;
    try store.select(0, &model);
    try std.testing.expect(!model.split and model.focus == 0);
    try std.testing.expectEqualStrings("/container/Desktop", model.panes[0].directory());
    try std.testing.expectEqualStrings("/container/Documents", model.panes[1].directory());
    try std.testing.expect(model.canBack());
    model.action(.back);
    try std.testing.expectEqualStrings("/container/Downloads", model.panes[0].directory());
}

test "tab reorder preserves active identity and complete foreground and background navigation" {
    var provider: Provider = .{};
    var model: files.Model = .{};
    var store: tabs.TabStore = .{};
    try model.init(provider.provider(), "/container/Documents", "/container/Downloads");
    model.split = true;
    model.focus = 1;
    try model.navigate(1, "/container/Desktop");
    model.panes[1].selected = 1;
    model.panes[1].scroll = 1;
    try store.init(&model);
    const first = store.id(0).?;
    try store.add(&model);
    try model.navigate(0, "/container/Downloads");
    const second = store.id(1).?;
    try store.add(&model);
    const third = store.id(2).?;
    try store.select(0, &model);
    const reads = provider.listings;
    try store.reorder(2, 0, &model);
    try std.testing.expectEqual(@as(usize, 1), store.active);
    try std.testing.expectEqual(first, store.id(store.active).?);
    try std.testing.expectEqual(third, store.id(0).?);
    try std.testing.expectEqual(second, store.id(2).?);
    try std.testing.expect(model.split and model.focus == 1 and model.canBack());
    try std.testing.expectEqual(@as(?usize, 1), model.panes[1].selected);
    try std.testing.expectEqual(@as(usize, 1), model.panes[1].scroll);
    try std.testing.expectEqual(reads, provider.listings);
    try store.reorder(1, 2, &model);
    try std.testing.expectEqual(first, store.id(2).?);
    try std.testing.expectEqual(@as(usize, 2), store.active);
    try store.select(1, &model);
    try std.testing.expectEqual(second, store.id(store.active).?);
    try std.testing.expectEqualStrings("/container/Downloads", model.panes[0].directory());
    model.action(.back);
    try std.testing.expectEqualStrings("/container/Desktop", model.panes[0].directory());
    const revision = model.revision;
    try std.testing.expectError(error.InvalidTab, store.reorder(3, 0, &model));
    try std.testing.expectError(error.InvalidTab, store.reorder(0, 3, &model));
    try std.testing.expectEqual(revision, model.revision);
    try std.testing.expectEqual(@as(usize, 3), store.count);
    try std.testing.expectEqual(@as(usize, 0), provider.writes);
}

test "tab transfer imports fresh checked listings and complete navigation with a new local ID" {
    var provider: Provider = .{};
    var source_model: files.Model = .{};
    var source: tabs.TabStore = .{};
    var target_model: files.Model = .{};
    var target: tabs.TabStore = .{};
    var transfer: tabs.TabTransfer = .{};
    try source_model.init(provider.provider(), "/container/Documents", "/container/Downloads");
    try source.init(&source_model);
    try source.add(&source_model);
    source_model.split = true;
    source_model.focus = 1;
    try source_model.navigate(1, "/container/Desktop");
    source_model.panes[1].selected = 0;
    source_model.panes[1].scroll = 1;
    source_model.action(.copy);
    source_model.edit = .rename;
    source_model.preview_open = true;
    try target_model.init(provider.provider(), "/container/Downloads", "/container/Downloads");
    target_model.panes[0].selected = 1;
    target_model.action(.copy);
    try target.init(&target_model);
    const placeholder = target.id(0).?;
    try source.beginExport(1, &source_model, &transfer);
    try std.testing.expectError(error.TabTransferNotReady, source.commitExport(&source_model, &transfer));
    try std.testing.expectEqual(@as(usize, 2), source.count);
    try std.testing.expect(source_model.edit == .rename and source_model.preview_open);
    provider.reordered = true;
    try target.importTransfer(&target_model, &transfer);
    try std.testing.expect(target.id(0).? != placeholder and target.id(0).? != transfer.source_tab_id);
    try std.testing.expectEqual(@as(usize, 2), source.count);
    try std.testing.expect(target_model.split and target_model.focus == 1 and target_model.canBack());
    try std.testing.expectEqualStrings("/container/Desktop", target_model.panes[1].directory());
    try std.testing.expectEqual(@as(?usize, 1), target_model.panes[1].selected);
    try std.testing.expectEqual(@as(usize, 1), target_model.panes[1].scroll);
    try std.testing.expect(target_model.edit == .none and !target_model.preview_open and target_model.drag == null);
    try std.testing.expectEqualStrings("other.txt", target_model.clipboard.?.name[0..target_model.clipboard.?.name_len]);
    try std.testing.expectEqualStrings("note.txt", source_model.clipboard.?.name[0..source_model.clipboard.?.name_len]);
    try std.testing.expectEqual(tabs.CloseResult.changed, try source.commitExport(&source_model, &transfer));
    try std.testing.expect(transfer.committed and source.count == 1);
    target_model.action(.back);
    try std.testing.expectEqualStrings("/container/Documents", target_model.panes[1].directory());
    try std.testing.expectError(error.InvalidTabTransfer, source.commitExport(&source_model, &transfer));
    try std.testing.expectEqual(@as(usize, 0), provider.writes);
    try std.testing.expect(@sizeOf(tabs.TabTransfer) < 16 * 1024);
}

test "failed second-pane transfer validation preserves source and destination navigation atomically" {
    var provider: Provider = .{};
    var source_model: files.Model = .{};
    var source: tabs.TabStore = .{};
    var target_model: files.Model = .{};
    var target: tabs.TabStore = .{};
    var transfer: tabs.TabTransfer = .{};
    try source_model.init(provider.provider(), "/container/Documents", "/container/Gone");
    try source.init(&source_model);
    try target_model.init(provider.provider(), "/container/Downloads", "/container/Downloads");
    target_model.panes[0].selected = 1;
    target_model.panes[0].scroll = 1;
    try target.init(&target_model);
    const original_id = target.id(0).?;
    const next_id = target.next_id;
    try source.beginExport(0, &source_model, &transfer);
    provider.missing = true;
    try std.testing.expectError(error.NotFound, target.importTransfer(&target_model, &transfer));
    try std.testing.expectEqual(original_id, target.id(0).?);
    try std.testing.expectEqual(next_id, target.next_id);
    try std.testing.expectEqualStrings("/container/Downloads", target_model.panes[0].directory());
    try std.testing.expectEqualStrings("/container/Downloads", target_model.panes[1].directory());
    try std.testing.expectEqual(@as(usize, 2), target_model.panes[0].count);
    try std.testing.expectEqual(@as(?usize, 1), target_model.panes[0].selected);
    try std.testing.expectEqual(@as(usize, 1), target_model.panes[0].scroll);
    try std.testing.expect(target_model.status_error and transfer.destination == null and !transfer.committed);
    try std.testing.expectError(error.TabTransferNotReady, source.commitExport(&source_model, &transfer));
    try std.testing.expectEqual(@as(usize, 1), source.count);
    try std.testing.expectEqualStrings("/container/Documents", source_model.panes[0].directory());
    provider.missing = false;
    provider.partial = true;
    try std.testing.expectError(error.PermissionDenied, target.importTransfer(&target_model, &transfer));
    try std.testing.expectEqualStrings("/container/Downloads", target_model.panes[0].directory());
    try std.testing.expectEqual(@as(usize, 2), target_model.panes[0].count);
    transfer.cancel();
    try std.testing.expectError(error.InvalidTabTransfer, target.importTransfer(&target_model, &transfer));
    try std.testing.expectEqual(@as(usize, 0), provider.writes);
}

test "last-tab transfer closes its source only after import and validates context generations" {
    var provider: Provider = .{};
    var source_model: files.Model = .{};
    var source: tabs.TabStore = .{};
    var target_model: files.Model = .{};
    var target: tabs.TabStore = .{};
    var transfer: tabs.TabTransfer = .{};
    try source_model.init(provider.provider(), "/container/Documents", "/container/Downloads");
    try source.init(&source_model);
    try target_model.init(provider.provider(), "/container/Desktop", "/container/Desktop");
    try target.init(&target_model);
    try source.beginExport(0, &source_model, &transfer);
    try target.importTransfer(&target_model, &transfer);
    try target.init(&target_model); // Same address is now a new window generation.
    try std.testing.expectError(error.StaleTabTransfer, source.commitExport(&source_model, &transfer));
    try std.testing.expectEqual(@as(usize, 1), source.count);
    try source.beginExport(0, &source_model, &transfer);
    try target.importTransfer(&target_model, &transfer);
    try std.testing.expectEqual(tabs.CloseResult.close_window, try source.commitExport(&source_model, &transfer));
    try std.testing.expect(transfer.committed and source.count == 1);
    try source.beginExport(0, &source_model, &transfer);
    try source.init(&source_model);
    try std.testing.expectError(error.StaleTabTransfer, target.importTransfer(&target_model, &transfer));
}

test "tab transfer rejects changed source snapshots busy targets and exhausted IDs without tab loss" {
    var provider: Provider = .{};
    var source_model: files.Model = .{};
    var source: tabs.TabStore = .{};
    var target_model: files.Model = .{};
    var target: tabs.TabStore = .{};
    var transfer: tabs.TabTransfer = .{};
    try source_model.init(provider.provider(), "/container/Documents", "/container/Downloads");
    try source.init(&source_model);
    try target_model.init(provider.provider(), "/container/Desktop", "/container/Desktop");
    try target.init(&target_model);
    try source.beginExport(0, &source_model, &transfer);
    target.next_id = 0;
    const reads = provider.listings;
    try std.testing.expectError(error.TabIdExhausted, target.importTransfer(&target_model, &transfer));
    try std.testing.expectEqual(reads, provider.listings);
    target.next_id = 2;
    try target.add(&target_model);
    try std.testing.expectError(error.TabDestinationBusy, target.importTransfer(&target_model, &transfer));
    try std.testing.expectEqual(@as(usize, 2), target.count);
    _ = try target.close(1, &target_model);
    try target.importTransfer(&target_model, &transfer);
    try source_model.navigate(0, "/container/Downloads");
    try std.testing.expectError(error.TabTransferChanged, source.commitExport(&source_model, &transfer));
    try std.testing.expect(!transfer.committed and source.count == 1);
    try std.testing.expectEqualStrings("/container/Downloads", source_model.panes[0].directory());
}
