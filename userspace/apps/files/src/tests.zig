const std = @import("std");
const files = @import("root.zig");
const ui = files.axisui;
const Mock = struct {
    moves: usize = 0,
    copies: usize = 0,
    creates: usize = 0,
    folders: usize = 0,
    removes: usize = 0,
    opens: usize = 0,
    nullifies: usize = 0,
    source_present: bool = true,
    read_only: bool = false,
    deny: bool = false,
    last_source: [256]u8 = undefined,
    source_len: usize = 0,
    last_destination: [256]u8 = undefined,
    destination_len: usize = 0,
    fn from(context: *anyopaque) *Mock {
        return @ptrCast(@alignCast(context));
    }
    fn listing(context: *anyopaque, path: []const u8, cursor: *usize) anyerror!?files.Entry {
        const self = from(context);
        if (std.mem.eql(u8, path, "/container")) {
            const names = [_][]const u8{ "Documents", "Downloads", "Desktop" };
            if (cursor.* >= names.len) return null;
            const name = names[cursor.*];
            cursor.* += 1;
            return try files.Entry.init(name, .directory, 0, false);
        }
        if (std.mem.eql(u8, path, "/container/Left") or std.mem.eql(u8, path, "/container/Documents")) {
            if (cursor.* == 0 and self.source_present) {
                cursor.* += 1;
                return try files.Entry.init("note.txt", .file, 12, self.read_only);
            }
            if (cursor.* <= 1) {
                cursor.* = 2;
                return try files.Entry.init("Folder", .directory, 0, false);
            }
            return null;
        }
        if (std.mem.eql(u8, path, "/container/Right") or std.mem.eql(u8, path, "/container/Downloads")) {
            if (cursor.* == 0) {
                cursor.* += 1;
                return try files.Entry.init("Dest", .directory, 0, false);
            }
            return null;
        }
        if (std.mem.eql(u8, path, "/container/Right/Dest") or std.mem.eql(u8, path, "/container/Left/Folder") or std.mem.eql(u8, path, "/container/Documents/Folder") or std.mem.eql(u8, path, "/container/Downloads/Dest")) return null;
        if (std.mem.eql(u8, path, "/container/Desktop")) return null;
        return error.PermissionDenied;
    }
    fn record(self: *Mock, source: []const u8, destination: []const u8) void {
        @memcpy(self.last_source[0..source.len], source);
        self.source_len = source.len;
        @memcpy(self.last_destination[0..destination.len], destination);
        self.destination_len = destination.len;
    }
    fn move(context: *anyopaque, source: []const u8, destination: []const u8) anyerror!void {
        const self = from(context);
        self.moves += 1;
        if (self.deny) return error.PermissionDenied;
        self.record(source, destination);
        self.source_present = false;
    }
    fn copy(context: *anyopaque, source: []const u8, destination: []const u8) anyerror!void {
        const self = from(context);
        self.copies += 1;
        if (self.deny) return error.PermissionDenied;
        self.record(source, destination);
    }
    fn create(context: *anyopaque, path: []const u8) anyerror!void {
        const self = from(context);
        self.creates += 1;
        if (self.deny) return error.ReadOnly;
        self.record("", path);
    }
    fn mkdir(context: *anyopaque, path: []const u8) anyerror!void {
        const self = from(context);
        self.folders += 1;
        if (self.deny) return error.ReadOnly;
        self.record("", path);
    }
    fn remove(context: *anyopaque, path: []const u8) anyerror!void {
        const self = from(context);
        self.removes += 1;
        if (self.deny) return error.PermissionDenied;
        self.record(path, "");
        self.source_present = false;
    }
    fn open(context: *anyopaque, path: []const u8) anyerror!void {
        const self = from(context);
        self.opens += 1;
        if (self.deny) return error.PermissionDenied;
        self.record(path, "");
    }
    fn nullify(context: *anyopaque, path: []const u8) anyerror!void {
        const self = from(context);
        self.nullifies += 1;
        self.record(path, "");
        // A storage failure can occur after namespace deletion committed.
        self.source_present = false;
        if (self.deny) return error.IoError;
    }
    fn provider(self: *Mock) files.Provider {
        return .{ .context = self, .list = listing, .move = move, .copy = copy, .create = create, .mkdir = mkdir, .remove = remove, .open = open, .nullify = nullify };
    }
};
fn send(model: *files.Model, kind: ui.input.Kind, code: u16, x: i16, y: i16, mods: u8) !void {
    try model.dispatch(.{ .kind = kind, .code = code, .x = x, .y = y, .modifiers = mods }, 800, 600);
}
fn drag(model: *files.Model, destination_x: i16, destination_y: i16, mods: u8) !void {
    model.split = true;
    const geometry = try files.Geometry.initMode(800, 600, true);
    const source = geometry.list(0);
    try send(model, .pointer_down, 1, @intCast(source.x + 12), @intCast(source.y + 10), 0);
    try send(model, .pointer_move, 0, destination_x, destination_y, mods);
    try send(model, .pointer_up, 1, destination_x, destination_y, mods);
}
test "cross-pane folder drag moves once only on release and duplicate release is inert" {
    var mock: Mock = .{};
    var model: files.Model = .{};
    try model.init(mock.provider(), "/container/Left", "/container/Right");
    model.split = true;
    const geometry = try files.Geometry.initMode(800, 600, true);
    const left = geometry.list(0);
    const right = geometry.list(1);
    try send(&model, .pointer_down, 1, @intCast(left.x + 12), @intCast(left.y + 10), 0);
    try send(&model, .pointer_move, 0, @intCast(right.x + 12), @intCast(right.y + 10), 0);
    try std.testing.expectEqual(@as(usize, 0), mock.moves);
    try send(&model, .pointer_up, 1, @intCast(right.x + 12), @intCast(right.y + 10), 0);
    try std.testing.expectEqual(@as(usize, 1), mock.moves);
    try std.testing.expectEqualStrings("/container/Left/note.txt", mock.last_source[0..mock.source_len]);
    try std.testing.expectEqualStrings("/container/Right/Dest/note.txt", mock.last_destination[0..mock.destination_len]);
    try send(&model, .pointer_up, 1, @intCast(right.x + 12), @intCast(right.y + 10), 0);
    try std.testing.expectEqual(@as(usize, 1), mock.moves);
}
test "invalid outside/same-pane drops and clicks never call mutation providers" {
    var mock: Mock = .{};
    var model: files.Model = .{};
    try model.init(mock.provider(), "/container/Left", "/container/Right");
    try drag(&model, -10, -10, 0);
    try drag(&model, 180, 250, 0);
    const row = (try files.Geometry.initMode(800, 600, true)).row(0, 0);
    try send(&model, .pointer_down, 1, @intCast(row.x + 30), @intCast(row.y + 10), 0);
    try send(&model, .pointer_up, 1, @intCast(row.x + 30), @intCast(row.y + 10), 0);
    try std.testing.expectEqual(@as(usize, 0), mock.moves);
    try std.testing.expectEqual(@as(usize, 0), mock.copies);
}
test "Ctrl drag copies and read-only source prevents moves without overriding provider authority" {
    var mock: Mock = .{ .read_only = true };
    var model: files.Model = .{};
    try model.init(mock.provider(), "/container/Left", "/container/Right");
    try drag(&model, 490, 220, 0);
    try std.testing.expectEqual(@as(usize, 0), mock.moves);
    try std.testing.expectEqualStrings("This item is read-only.", model.statusText());
    try drag(&model, 490, 220, ui.input.modifiers.control);
    try std.testing.expectEqual(@as(usize, 1), mock.copies);
    try std.testing.expect(mock.source_present);
}
test "Ctrl held at drag start stays copy intent after key release and never repeats" {
    var mock: Mock = .{};
    var model: files.Model = .{};
    try model.init(mock.provider(), "/container/Left", "/container/Right");
    model.split = true;
    const geometry = try files.Geometry.initMode(800, 600, true);
    const source = geometry.list(0);
    const destination = geometry.list(1);
    const x: i16 = @intCast(destination.x + 12);
    const y: i16 = @intCast(destination.y + 10);
    try send(&model, .pointer_down, 1, @intCast(source.x + 12), @intCast(source.y + 10), ui.input.modifiers.control);
    try send(&model, .key_up, 0, 0, 0, 0);
    try send(&model, .pointer_move, 0, x, y, 0);
    try std.testing.expectEqual(@as(usize, 0), mock.copies);
    try send(&model, .pointer_up, 1, x, y, 0);
    try std.testing.expectEqual(@as(usize, 1), mock.copies);
    try std.testing.expectEqual(@as(usize, 0), mock.moves);
    try std.testing.expect(mock.source_present);
    try std.testing.expectEqualStrings("/container/Right/Dest/note.txt", mock.last_destination[0..mock.destination_len]);
    try send(&model, .pointer_up, 1, x, y, 0);
    try std.testing.expectEqual(@as(usize, 1), mock.copies);
    // Copy intent belongs to this drag, not later unmodified gestures.
    try drag(&model, 490, 220, 0);
    try std.testing.expectEqual(@as(usize, 1), mock.moves);
    try std.testing.expectEqual(@as(usize, 1), mock.copies);
}
test "provider failures are visible and preserve file and listing state" {
    var mock: Mock = .{ .deny = true };
    var model: files.Model = .{};
    try model.init(mock.provider(), "/container/Left", "/container/Right");
    try drag(&model, 490, 220, 0);
    try std.testing.expectEqual(@as(usize, 1), mock.moves);
    try std.testing.expect(model.status_error and mock.source_present);
    try std.testing.expectEqualStrings("You don't have permission for this action.", model.statusText());
    try std.testing.expectEqual(@as(usize, 2), model.panes[0].count);
}
test "rename editing inserts deletes navigates and commits canonical names" {
    var mock: Mock = .{};
    var model: files.Model = .{};
    try model.init(mock.provider(), "/container/Left", "/container/Right");
    model.panes[0].selected = 0;
    try send(&model, .key_down, @backingInt(ui.input.Key.f2), 0, 0, 0);
    try send(&model, .key_down, @backingInt(ui.input.Key.home), 0, 0, 0);
    try send(&model, .text, 'X', 0, 0, 0);
    try send(&model, .key_down, @backingInt(ui.input.Key.backspace), 0, 0, 0);
    try send(&model, .text, 'N', 0, 0, 0);
    try send(&model, .key_down, @backingInt(ui.input.Key.delete), 0, 0, 0);
    try std.testing.expectEqualStrings("Note.txt", model.editText());
    try send(&model, .key_down, @backingInt(ui.input.Key.enter), 0, 0, 0);
    try std.testing.expectEqual(@as(usize, 1), mock.moves);
    try std.testing.expectEqualStrings("/container/Left/Note.txt", mock.last_destination[0..mock.destination_len]);
    try std.testing.expectEqual(files.Edit.none, model.edit);
}
test "creation keyboard bounds and unsupported Unicode are explicit" {
    var mock: Mock = .{};
    var model: files.Model = .{};
    try model.init(mock.provider(), "/container/Left", "/container/Right");
    model.action(.new_file);
    try send(&model, .text, 0xe9, 0, 0, 0);
    try std.testing.expectEqualStrings("Only ASCII characters are supported for now.", model.statusText());
    try std.testing.expectEqual(@as(usize, 0), model.edit_len);
    for ("new.txt") |byte| try send(&model, .text, byte, 0, 0, 0);
    const editing_revision = model.revision;
    try send(&model, .key_down, @backingInt(ui.input.Key.f5), 0, 0, 0);
    try std.testing.expect(model.revision > editing_revision);
    try std.testing.expectEqualStrings("new.txt", model.editText());
    try send(&model, .key_down, @backingInt(ui.input.Key.enter), 0, 0, 0);
    try std.testing.expectEqual(@as(usize, 1), mock.creates);
    try std.testing.expectEqualStrings("/container/Left/new.txt", mock.last_destination[0..mock.destination_len]);
    model.action(.new_folder);
    for (0..files.max_name_bytes) |_| try send(&model, .text, 'a', 0, 0, 0);
    try send(&model, .text, 'b', 0, 0, 0);
    try std.testing.expectEqualStrings("Names can have at most 96 characters.", model.statusText());
    try std.testing.expectEqual(@as(usize, files.max_name_bytes), model.edit_len);
    try send(&model, .key_down, @backingInt(ui.input.Key.escape), 0, 0, 0);
    try std.testing.expectEqual(@as(usize, 0), mock.folders);
    try std.testing.expectError(error.InvalidPath, files.provider.validatePath("/container/../bundle"));
}
test "navigation focus and failed listing retain the previous directory" {
    var mock: Mock = .{};
    var model: files.Model = .{};
    try model.init(mock.provider(), "/container/Left", "/container/Right");
    try send(&model, .key_down, @backingInt(ui.input.Key.tab), 0, 0, 0);
    try std.testing.expectEqual(@as(usize, 0), model.focus);
    model.action(.split);
    try send(&model, .key_down, @backingInt(ui.input.Key.tab), 0, 0, 0);
    try std.testing.expectEqual(@as(usize, 1), model.focus);
    try send(&model, .key_down, @backingInt(ui.input.Key.down), 0, 0, 0);
    try send(&model, .key_down, @backingInt(ui.input.Key.enter), 0, 0, 0);
    try std.testing.expectEqualStrings("/container/Right/Dest", model.panes[1].directory());
    try std.testing.expectError(error.PermissionDenied, model.navigate(1, "/ungranted"));
    try std.testing.expectEqualStrings("/container/Right/Dest", model.panes[1].directory());
    model.action(.up);
    try std.testing.expectEqualStrings("/container/Right", model.panes[1].directory());
}
const Flood = struct {
    malformed: bool = false,
    fn list(context: *anyopaque, _: []const u8, cursor: *usize) anyerror!?files.Entry {
        const self: *Flood = @ptrCast(@alignCast(context));
        if (cursor.* == 40) return null;
        var buffer: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&buffer, "file{d}", .{cursor.*});
        if (!self.malformed) cursor.* += 1;
        return try files.Entry.init(name, .file, 0, false);
    }
};
test "listing is bounded and failed nonprogressing provider preserves committed entries" {
    var context: Flood = .{};
    var model: files.Model = .{};
    try model.init(.{ .context = &context, .list = Flood.list }, "/left", "/right");
    try std.testing.expectEqual(@as(usize, files.max_entries), model.panes[0].count);
    try std.testing.expect(model.panes[0].truncated);
    context.malformed = true;
    try std.testing.expectError(error.InvalidListing, model.reload(0));
    try std.testing.expectEqual(@as(usize, files.max_entries), model.panes[0].count);
    try std.testing.expectEqualStrings("file0", model.panes[0].entries[0].bytes());
}
test "compact native Files at minimum and reference sizes preserves guards and stride" {
    var mock: Mock = .{};
    var model: files.Model = .{};
    try model.init(mock.provider(), "/container/Left", "/container/Right");
    model.panes[0].selected = 0;
    var workspace: files.Workspace = undefined;
    for ([_]struct { width: u32, height: u32 }{ .{ .width = 640, .height = 360 }, .{ .width = 800, .height = 600 }, .{ .width = 1280, .height = 800 } }) |size| {
        const stride = size.width + 5;
        const count = @as(usize, stride) * size.height;
        const pixels = try std.testing.allocator.alloc(u32, count + 2);
        defer std.testing.allocator.free(pixels);
        @memset(pixels, 0x12345678);
        var surface = try ui.Surface.init(pixels[1 .. count + 1], size.width, size.height, stride, .{ .red = 0xff0000, .green = 0xff00, .blue = 0xff });
        try files.renderWithWorkspace(&surface, &workspace, &model);
        try std.testing.expectEqual(@as(u32, 0x12345678), pixels[0]);
        try std.testing.expectEqual(@as(u32, 0x12345678), pixels[count + 1]);
        for (0..size.height) |row| for (size.width..stride) |column| try std.testing.expectEqual(@as(u32, 0x12345678), pixels[1 + row * stride + column]);
        const geometry = try files.Geometry.init(size.width, size.height);
        const rect = geometry.list(0);
        try std.testing.expectEqual(surface.encode(files.colors.selected), pixels[1 + @as(usize, @intCast(rect.y + 1)) * stride + @as(usize, @intCast(rect.x + 24))]);
        try std.testing.expect(pixels[1 + @as(usize, @intCast(rect.y + 1)) * stride + @as(usize, @intCast(rect.x + 1))] != surface.encode(files.colors.selected));
        try std.testing.expect(pixels[1 + (@as(usize, size.height) - 20) * stride + 20] != 0x12345678);
    }
}

test "file opening displays bounded copied ASCII preview and closes on Escape" {
    const Reader = struct {
        fn read(_: *anyopaque, _: []const u8, offset: u64, output: []u8) anyerror!usize {
            if (offset != 0) return error.OutOfBounds;
            const text = "Visible contents\n\xff\x00tail";
            @memcpy(output[0..text.len], text);
            return text.len;
        }
    };
    var mock: Mock = .{};
    var model: files.Model = .{};
    var provider = mock.provider();
    provider.read = Reader.read;
    try model.init(provider, "/container/Left", "/container/Right");
    model.panes[0].selected = 0;
    try send(&model, .key_down, @backingInt(ui.input.Key.enter), 0, 0, 0);
    try std.testing.expect(model.preview_open);
    try std.testing.expectEqualStrings("Visible contents\n??tail", model.previewText());
    try std.testing.expectEqualStrings("note.txt", model.preview_name[0..model.preview_name_len]);
    const preview_revision = model.revision;
    try send(&model, .key_down, @backingInt(ui.input.Key.f5), 0, 0, 0);
    try std.testing.expect(model.revision > preview_revision and model.preview_open);
    try std.testing.expectEqualStrings("Visible contents\n??tail", model.previewText());
    try send(&model, .key_down, @backingInt(ui.input.Key.escape), 0, 0, 0);
    try std.testing.expect(!model.preview_open);
    try contextRow(&model, 0);
    try clickMenu(&model, .open);
    try std.testing.expect(model.preview_open);
}

test "keyboard refresh cancels captured drag before listing identities can change" {
    var mock: Mock = .{};
    var model: files.Model = .{};
    try model.init(mock.provider(), "/container/Left", "/container/Right");
    model.split = true;
    const geometry = try files.Geometry.initMode(800, 600, true);
    const row = geometry.row(0, 0);
    try send(&model, .pointer_down, 1, @intCast(row.x + 30), @intCast(row.y + 10), 0);
    try std.testing.expect(model.drag != null);
    try send(&model, .pointer_move, 0, 490, 220, 0);
    try send(&model, .key_down, @backingInt(ui.input.Key.f5), 0, 0, 0);
    try send(&model, .pointer_up, 1, 490, 220, 0);
    try std.testing.expectEqual(@as(usize, 0), mock.moves);
    try std.testing.expect(model.drag == null);
}

test "Files caller storage stays bounded for a protected desktop profile" {
    try std.testing.expect(@sizeOf(files.Model) < 64 * 1024);
    try std.testing.expect(@sizeOf(files.Workspace) < 128 * 1024);
}

const FrostFixture = struct {
    source: []u32,
    colors: []u32,
    scratch: []u32,
    backdrop: ui.Backdrop,
    fn init() !FrostFixture {
        const allocator = std.testing.allocator;
        const source = try allocator.alloc(u32, 832 * 632);
        errdefer allocator.free(source);
        for (0..632) |y| for (0..832) |x| {
            source[y * 832 + x] = @as(u32, @intCast(35 + x * 180 / 832)) << 16 |
                @as(u32, @intCast(55 + y * 120 / 632)) << 8 |
                @as(u32, @intCast(140 + (x + y) % 80));
        };
        const required = try ui.Backdrop.requiredLen(832, 632);
        const colors = try allocator.alloc(u32, required);
        errdefer allocator.free(colors);
        const scratch = try allocator.alloc(u32, required);
        errdefer allocator.free(scratch);
        const wallpaper = try ui.Surface.init(source, 832, 632, 832, .{ .red = 0xff0000, .green = 0xff00, .blue = 0xff });
        return .{ .source = source, .colors = colors, .scratch = scratch, .backdrop = try ui.Backdrop.build(&wallpaper, colors, scratch) };
    }
    fn deinit(self: *FrostFixture) void {
        std.testing.allocator.free(self.scratch);
        std.testing.allocator.free(self.colors);
        std.testing.allocator.free(self.source);
    }
};
fn expectedMaterial(sample: ui.Color, material: ui.Material) u32 {
    const alpha: u32 = material.opacity;
    const inverse = 255 - alpha;
    const r = (@as(u32, sample.r) * inverse + @as(u32, material.tint.r) * alpha + 127) / 255;
    const g = (@as(u32, sample.g) * inverse + @as(u32, material.tint.g) * alpha + 127) / 255;
    const b = (@as(u32, sample.b) * inverse + @as(u32, material.tint.b) * alpha + 127) / 255;
    return r << 16 | g << 8 | b;
}
test "Files material commands match frozen-backdrop pixels and repeated rendering is stable" {
    const Sink = struct {
        pixels: []u32,
        backdrop: *const ui.Backdrop,
        material_calls: usize = 0,
        material_edge_calls: usize = 0,
        calls: usize = 0,
        invalid: bool = false,
        fn fill(context: *anyopaque, x: u32, y: u32, width: u32, height: u32, value: u32) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            if (x >= 800 or y >= 600 or width > 800 - x or height > 600 - y or width == 0 or height == 0) {
                self.invalid = true;
                return;
            }
            for (y..y + height) |row| for (x..x + width) |column| {
                self.pixels[row * 800 + column] = value;
            };
        }
        fn material(context: *anyopaque, x: u32, y: u32, width: u32, height: u32, value: ui.Material) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.material_calls += 1;
            if (x >= 800 or y >= 600 or width > 800 - x or height > 600 - y or width == 0 or height == 0) {
                self.invalid = true;
                return;
            }
            for (y..y + height) |row| for (x..x + width) |column| {
                self.pixels[row * 800 + column] = expectedMaterial(self.backdrop.sample(@as(i64, @intCast(column)) + 16, @as(i64, @intCast(row)) + 16), value);
            };
        }
        fn blend(context: *anyopaque, x: u32, y: u32, pixel: u32, coverage: u8) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (x >= 800 or y >= 600) {
                self.invalid = true;
                return;
            }
            var target = ui.Surface.init(self.pixels, 800, 600, 800, .{ .red = 0xff0000, .green = 0xff00, .blue = 0xff }) catch unreachable;
            target.blendPixel(x, y, ui.Color.rgb(@intCast(pixel >> 16 & 255), @intCast(pixel >> 8 & 255), @intCast(pixel & 255)), coverage);
        }
        fn materialPixel(context: *anyopaque, x: u32, y: u32, value: ui.Material, coverage: u8) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (x >= 800 or y >= 600 or coverage == 0 or coverage == 255) {
                self.invalid = true;
                return;
            }
            self.material_edge_calls += 1;
            var target = ui.Surface.init(self.pixels, 800, 600, 800, .{ .red = 0xff0000, .green = 0xff00, .blue = 0xff }) catch unreachable;
            target.setBackdrop(self.backdrop, .{ .x = 16, .y = 16 }) catch unreachable;
            target.materialPixel(x, y, value, coverage);
        }
    };
    var frost = try FrostFixture.init();
    defer frost.deinit();
    const direct = try std.testing.allocator.alloc(u32, 800 * 600);
    defer std.testing.allocator.free(direct);
    const submitted = try std.testing.allocator.alloc(u32, 800 * 600);
    defer std.testing.allocator.free(submitted);
    @memset(direct, 0x333333);
    @memset(submitted, 0x333333);
    var receiver: Sink = .{ .pixels = submitted, .backdrop = &frost.backdrop };
    var mock: Mock = .{};
    var model: files.Model = .{};
    var workspace: files.Workspace = undefined;
    try model.init(mock.provider(), "/container/Left", "/container/Right");
    model.panes[0].selected = 0;
    var native = try ui.Surface.init(direct, 800, 600, 800, .{ .red = 0xff0000, .green = 0xff00, .blue = 0xff });
    try native.setBackdrop(&frost.backdrop, .{ .x = 16, .y = 16 });
    var commands = try ui.Surface.initCommands(800, 600, .{ .context = &receiver, .fillRect = Sink.fill, .materialRect = Sink.material, .materialPixel = Sink.materialPixel, .blendPixel = Sink.blend });
    try files.renderWithWorkspace(&native, &workspace, &model);
    try files.renderWithWorkspace(&commands, &workspace, &model);
    try std.testing.expectEqualSlices(u32, direct, submitted);
    try std.testing.expect(!receiver.invalid and receiver.calls != 0 and receiver.material_calls != 0);
    try std.testing.expect(receiver.calls < 10000);
    const initial = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(direct));
    @memset(direct, 0xff0000);
    @memset(submitted, 0x00ff00);
    try files.renderWithWorkspace(&native, &workspace, &model);
    try files.renderWithWorkspace(&commands, &workspace, &model);
    try std.testing.expectEqualSlices(u32, direct, submitted);
    try std.testing.expectEqual(initial, std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(direct)));
    // Navigation/sidebar overlap must sample wallpaper rather than blending the
    // root tint a second time. Plain list background retains wallpaper variation.
    try std.testing.expectEqual(expectedMaterial(frost.backdrop.sample(716, 556), files.materials.client), direct[540 * 800 + 700]);
    try std.testing.expectEqual(expectedMaterial(frost.backdrop.sample(36, 316), files.materials.sidebar), direct[300 * 800 + 20]);
    try std.testing.expectEqual(expectedMaterial(frost.backdrop.sample(36, 17), files.materials.navigation), direct[1 * 800 + 20]);
    try std.testing.expect(direct[540 * 800 + 700] != direct[250 * 800 + 700]);
    // A popup uses a translated clipped command surface in both paths. Test
    // both a row context menu and a bottom-right More popup with disabled rows.
    inline for (.{ files.MenuKind.file, files.MenuKind.more }) |kind| {
        model.menu = .{ .kind = kind, .anchor = .{ .x = 799, .y = 599 }, .hovered = 1 };
        try files.renderWithWorkspace(&native, &workspace, &model);
        try files.renderWithWorkspace(&commands, &workspace, &model);
        try std.testing.expectEqualSlices(u32, direct, submitted);
        try std.testing.expect(!receiver.invalid and receiver.material_edge_calls != 0);
        const menu_hash = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(direct));
        @memset(direct, 0);
        try files.renderWithWorkspace(&native, &workspace, &model);
        try std.testing.expectEqual(menu_hash, std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(direct)));
    }
    model.menu = null;
    model.path_editing = true;
    model.path_editor.set("~/Documents", true);
    const path = windowPath(800);
    try files.renderWindowWithWorkspace(&native, &workspace, &model, path);
    try files.renderWindowWithWorkspace(&commands, &workspace, &model, path);
    try std.testing.expectEqualSlices(u32, direct, submitted);
    const window_hash = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(direct));
    native.fillRect(@intCast(path.x), @intCast(path.y), path.width, path.height, 0xff0000);
    commands.fillRect(@intCast(path.x), @intCast(path.y), path.width, path.height, 0x00ff00);
    try files.renderWindowWithWorkspace(&native, &workspace, &model, path);
    try files.renderWindowWithWorkspace(&commands, &workspace, &model, path);
    try std.testing.expectEqualSlices(u32, direct, submitted);
    try std.testing.expectEqual(window_hash, std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(direct)));
    try std.testing.expect(!receiver.invalid and receiver.material_edge_calls != 0);
}
test "frosted Files keeps solid selection text and errors readable with guarded pixel storage" {
    var frost = try FrostFixture.init();
    defer frost.deinit();
    const stride: usize = 645;
    const height: usize = 360;
    const pixels = try std.testing.allocator.alloc(u32, stride * height + 2);
    defer std.testing.allocator.free(pixels);
    @memset(pixels, 0x12345678);
    var surface = try ui.Surface.init(pixels[1 .. pixels.len - 1], 640, 360, stride, .{ .red = 0xff0000, .green = 0xff00, .blue = 0xff });
    try surface.setBackdrop(&frost.backdrop, .{ .x = 16, .y = 16 });
    var mock: Mock = .{};
    var model: files.Model = .{};
    var workspace: files.Workspace = undefined;
    try model.init(mock.provider(), "/container/Documents", "/container/Downloads");
    model.panes[0].selected = 0;
    try files.renderWithWorkspace(&surface, &workspace, &model);
    const rect = (try files.Geometry.init(640, 360)).row(0, 0);
    try std.testing.expectEqual(surface.encode(files.colors.selected), pixels[1 + @as(usize, @intCast(rect.y + 1)) * stride + @as(usize, @intCast(rect.x + 24))]);
    try std.testing.expect(pixels[1 + @as(usize, @intCast(rect.y + 1)) * stride + @as(usize, @intCast(rect.x + 1))] != surface.encode(files.colors.selected));
    var ink: usize = 0;
    for (@as(usize, @intCast(rect.y))..@as(usize, @intCast(rect.y + 28))) |y| for (@as(usize, @intCast(rect.x + 24))..@as(usize, @intCast(rect.x + 160))) |x| {
        const color = surface.decode(pixels[1 + y * stride + x]);
        if (color.r >= 170 and color.g >= 170 and color.b >= 180) ink += 1;
    };
    try std.testing.expect(ink > 30);
    model.action(.paste); // An actual failed control action shows a solid error.
    try files.renderWithWorkspace(&surface, &workspace, &model);
    var error_ink: usize = 0;
    for (height - 24..height) |y| for (0..640) |x| {
        const color = surface.decode(pixels[1 + y * stride + x]);
        if (color.r >= 170 and color.g >= 90 and color.b >= 80 and color.r > @as(u16, color.g) + 50) error_ink += 1;
    };
    try std.testing.expect(error_ink > 30);
    try std.testing.expectEqual(@as(u32, 0x12345678), pixels[0]);
    try std.testing.expectEqual(@as(u32, 0x12345678), pixels[pixels.len - 1]);
    for (0..height) |y| for (640..stride) |x| try std.testing.expectEqual(@as(u32, 0x12345678), pixels[1 + y * stride + x]);
}

fn click(model: *files.Model, rect: ui.Rect) !void {
    const x: i16 = @intCast(rect.x + @as(i32, @intCast(rect.width / 2)));
    const y: i16 = @intCast(rect.y + @as(i32, @intCast(rect.height / 2)));
    try send(model, .pointer_down, 1, x, y, 0);
    try send(model, .pointer_up, 1, x, y, 0);
}

test "Desktop shortcut stays visible at the minimum viewport and preserves existing shortcut values" {
    try std.testing.expectEqual(@as(u8, 0), @backingInt(files.Shortcut.home));
    try std.testing.expectEqual(@as(u8, 1), @backingInt(files.Shortcut.documents));
    try std.testing.expectEqual(@as(u8, 2), @backingInt(files.Shortcut.downloads));
    try std.testing.expectEqualStrings("/container/Desktop", files.layout.shortcutPath(.desktop));
    for ([_][2]u32{ .{ 316, 204 }, .{ 320, 208 }, .{ 800, 600 } }) |size| {
        const geometry = try files.Geometry.init(size[0], size[1]);
        var previous_bottom: i32 = 0;
        for ([_]files.Shortcut{ .home, .documents, .downloads, .desktop }) |shortcut| {
            const rect = geometry.sidebar(shortcut);
            try std.testing.expect(rect.height >= 22);
            try std.testing.expect(rect.y >= previous_bottom);
            previous_bottom = rect.y + @as(i32, @intCast(rect.height));
            try std.testing.expect(previous_bottom <= size[1] - files.layout.footer_height - 8);
            try std.testing.expectEqual(shortcut, geometry.shortcutAt(.{ .x = rect.x + 4, .y = rect.y + 4 }).?);
        }
    }
    try std.testing.expectEqual(@as(u32, 32), (try files.Geometry.init(800, 600)).sidebar(.desktop).height);
}

test "minimum Files window paints the complete Desktop label including its descender" {
    const Ink = struct {
        fn bounds(pixels: []const u32, stride: usize, region: ui.Rect, background: u32) !ui.Rect {
            var left = region.x + @as(i32, @intCast(region.width));
            var top = region.y + @as(i32, @intCast(region.height));
            var right = region.x;
            var bottom = region.y;
            for (@as(usize, @intCast(region.y))..@as(usize, @intCast(region.y)) + region.height) |y| {
                for (@as(usize, @intCast(region.x))..@as(usize, @intCast(region.x)) + region.width) |x| {
                    if (pixels[y * stride + x] == background) continue;
                    left = @min(left, @as(i32, @intCast(x)));
                    top = @min(top, @as(i32, @intCast(y)));
                    right = @max(right, @as(i32, @intCast(x + 1)));
                    bottom = @max(bottom, @as(i32, @intCast(y + 1)));
                }
            }
            try std.testing.expect(right > left and bottom > top);
            return .{ .x = left, .y = top, .width = @intCast(right - left), .height = @intCast(bottom - top) };
        }
    };
    const width = files.layout.minimum_width;
    inline for ([_]u32{ files.layout.minimum_height, 360 }) |body_height| {
        const height = body_height + files.layout.window_header_height;
        var mock: Mock = .{};
        var model: files.Model = .{};
        var workspace: files.Workspace = undefined;
        try model.init(mock.provider(), "/container/Documents", "/container/Downloads");
        var pixels: [width * height]u32 = @splat(0);
        var surface = try ui.Surface.init(&pixels, width, height, width, .{ .red = 0xff0000, .green = 0xff00, .blue = 0xff });
        try files.renderWindowWithWorkspace(&surface, &workspace, &model, windowPath(width));
        var row = (try files.Geometry.init(width, body_height)).sidebar(.desktop);
        try std.testing.expectEqual(@as(u32, if (body_height == files.layout.minimum_height) 22 else 32), row.height);
        row.y += files.layout.window_header_height;
        // Exclude the folder icon; the remaining row contains only Desktop's ink.
        row.x += 24;
        row.width -= 24;
        const background = surface.encode(files.colors.sidebar);
        const actual = try Ink.bounds(&pixels, width, row, background);

        // Use the font painter as an unclipped reference, independent of the app's
        // declarative tree, row padding and ancestor clips. Compare every gray edge,
        // so a missing bottom row of the final 'p' cannot pass an ink-count check.
        var reference_pixels: [132 * ui.font.line_height]u32 = @splat(background);
        var reference = try ui.Surface.init(&reference_pixels, 132, ui.font.line_height, 132, surface.masks);
        try ui.font.paint(&reference, "Desktop", 0, 0, files.colors.text, 1);
        const expected = try Ink.bounds(&reference_pixels, 132, .{ .x = 0, .y = 0, .width = 132, .height = ui.font.line_height }, background);
        try std.testing.expectEqual(expected.width, actual.width);
        try std.testing.expectEqual(expected.height, actual.height);
        try std.testing.expectEqual((try ui.font.controlOriginY(row.y, row.height, 1)) + expected.y, actual.y);
        for (0..expected.height) |y| for (0..expected.width) |x| {
            const reference_at = (@as(usize, @intCast(expected.y)) + y) * 132 + @as(usize, @intCast(expected.x)) + x;
            const actual_at = (@as(usize, @intCast(actual.y)) + y) * width + @as(usize, @intCast(actual.x)) + x;
            try std.testing.expectEqual(reference_pixels[reference_at], pixels[actual_at]);
        };
    }
}

test "Desktop navigation and drag drop use the checked private container path" {
    var mock: Mock = .{};
    var model: files.Model = .{};
    try model.init(mock.provider(), "/container/Documents", "/container/Downloads");
    const geometry = try files.Geometry.init(800, 600);
    try click(&model, geometry.sidebar(.desktop));
    try std.testing.expectEqualStrings("/container/Desktop", model.panes[0].directory());
    try std.testing.expectEqualStrings("~/Desktop", model.headerPath());
    try std.testing.expectEqual(@as(usize, 0), model.panes[0].count);
    try click(&model, geometry.button(.back));
    try std.testing.expectEqualStrings("/container/Documents", model.panes[0].directory());
    const source = geometry.row(0, 0);
    const target = geometry.sidebar(.desktop);
    try send(&model, .pointer_down, 1, @intCast(source.x + 12), @intCast(source.y + 10), 0);
    try send(&model, .pointer_move, 0, @intCast(target.x + 12), @intCast(target.y + 10), 0);
    try std.testing.expectEqual(@as(usize, 0), mock.moves);
    try send(&model, .pointer_up, 1, @intCast(target.x + 12), @intCast(target.y + 10), 0);
    try std.testing.expectEqualStrings("/container/Documents/note.txt", mock.last_source[0..mock.source_len]);
    try std.testing.expectEqualStrings("/container/Desktop/note.txt", mock.last_destination[0..mock.destination_len]);
    try std.testing.expectEqual(@as(usize, 1), mock.moves);
    try send(&model, .pointer_up, 1, @intCast(target.x + 12), @intCast(target.y + 10), 0);
    try std.testing.expectEqual(@as(usize, 1), mock.moves);
}

test "Desktop upgrade adds only its private folder and tolerates existing or unavailable storage" {
    const Storage = struct {
        attempts: usize = 0,
        created: bool = false,
        failure: ?anyerror = null,
        fn list(_: *anyopaque, _: []const u8, _: *usize) anyerror!?files.Entry {
            return null;
        }
        fn mkdir(context: *anyopaque, path: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            try std.testing.expectEqualStrings("/container/Desktop", path);
            self.attempts += 1;
            if (self.failure) |err| return err;
            if (self.created) return error.AlreadyExists;
            self.created = true;
        }
    };
    var storage: Storage = .{};
    const provider: files.Provider = .{ .context = &storage, .list = Storage.list, .mkdir = Storage.mkdir };
    files.Model.ensureDesktop(provider);
    try std.testing.expect(storage.created);
    files.Model.ensureDesktop(provider);
    try std.testing.expectEqual(@as(usize, 2), storage.attempts);
    for ([_]anyerror{ error.AlreadyExists, error.ReadOnly, error.Capacity, error.PermissionDenied }) |failure| {
        storage.failure = failure;
        files.Model.ensureDesktop(provider);
    }
    try std.testing.expectEqual(@as(usize, 6), storage.attempts);
    files.Model.ensureDesktop(.{ .context = &storage, .list = Storage.list });
    try std.testing.expectEqual(@as(usize, 6), storage.attempts);
}

fn contextRow(model: *files.Model, visible_row: usize) !void {
    const row = (try files.Geometry.initMode(800, 600, model.split)).row(model.focus, visible_row);
    try send(model, .pointer_down, @backingInt(ui.input.Button.right), @intCast(row.x + 32), @intCast(row.y + 10), 0);
    try send(model, .pointer_up, @backingInt(ui.input.Button.right), @intCast(row.x + 32), @intCast(row.y + 10), 0);
}
fn menuRect(model: *const files.Model, action: files.Action) !ui.Rect {
    const menu = model.menu orelse return error.NoMenu;
    const bounds = try files.MenuGeometry.init(800, 600, menu.kind, menu.anchor);
    return bounds.item(bounds.actionIndex(action) orelse return error.NoAction);
}
fn clickMenu(model: *files.Model, action: files.Action) !void {
    try click(model, try menuRect(model, action));
}
fn moreAction(model: *files.Model, action: files.Action) !void {
    try click(model, (try files.Geometry.initMode(800, 600, model.split)).button(.more));
    try clickMenu(model, action);
}
test "single browser sidebar drop moves once and release outside does nothing" {
    var mock: Mock = .{};
    var model: files.Model = .{};
    try model.init(mock.provider(), "/container/Documents", "/container/Downloads");
    const geometry = try files.Geometry.init(800, 600);
    try std.testing.expect(!model.split and geometry.pane(1).width == 0);
    const row = geometry.row(0, 0);
    const target = geometry.sidebar(.downloads);
    try send(&model, .pointer_down, 1, @intCast(row.x + 32), @intCast(row.y + 10), 0);
    try send(&model, .pointer_move, 0, @intCast(target.x + 30), @intCast(target.y + 12), 0);
    try std.testing.expectEqual(@as(usize, 0), mock.moves);
    try send(&model, .pointer_up, 1, @intCast(target.x + 30), @intCast(target.y + 12), 0);
    try std.testing.expectEqualStrings("/container/Downloads/note.txt", mock.last_destination[0..mock.destination_len]);
    try std.testing.expectEqual(@as(usize, 1), mock.moves);
    try send(&model, .pointer_up, 1, @intCast(target.x + 30), @intCast(target.y + 12), 0);
    try std.testing.expectEqual(@as(usize, 1), mock.moves);
    mock.source_present = true;
    try model.reload(0);
    try send(&model, .pointer_down, 1, @intCast(row.x + 32), @intCast(row.y + 10), ui.input.modifiers.control);
    try send(&model, .pointer_move, 0, -8, -8, 0);
    try send(&model, .pointer_up, 1, -8, -8, 0);
    try std.testing.expectEqual(@as(usize, 1), mock.moves);
    try std.testing.expectEqual(@as(usize, 0), mock.copies);
}
test "single sidebar Ctrl copy keeps initial intent after modifier release" {
    var mock: Mock = .{ .read_only = true };
    var model: files.Model = .{};
    try model.init(mock.provider(), "/container/Documents", "/container/Downloads");
    const geometry = try files.Geometry.init(800, 600);
    const row = geometry.row(0, 0);
    const target = geometry.sidebar(.downloads);
    try send(&model, .pointer_down, 1, @intCast(row.x + 32), @intCast(row.y + 10), ui.input.modifiers.control);
    try send(&model, .pointer_move, 0, @intCast(target.x + 30), @intCast(target.y + 12), 0);
    try send(&model, .pointer_up, 1, @intCast(target.x + 30), @intCast(target.y + 12), 0);
    try std.testing.expectEqual(@as(usize, 1), mock.copies);
    try std.testing.expectEqual(@as(usize, 0), mock.moves);
    try std.testing.expect(mock.source_present);
}
test "copy and cut use copied clipboard paths and paste current directory with checked provider errors" {
    var mock: Mock = .{};
    var model: files.Model = .{};
    try model.init(mock.provider(), "/container/Documents", "/container/Downloads");
    model.panes[0].selected = 0;
    try send(&model, .key_down, 'c', 0, 0, ui.input.modifiers.control);
    try std.testing.expectEqual(@as(usize, 0), mock.copies);
    try std.testing.expect(model.clipboard != null);
    const geometry = try files.Geometry.init(800, 600);
    try click(&model, geometry.sidebar(.downloads));
    try std.testing.expectEqualStrings("/container/Downloads", model.panes[0].directory());
    mock.deny = true;
    try moreAction(&model, .paste);
    try std.testing.expect(model.status_error and model.clipboard != null);
    try std.testing.expectEqualStrings("You don't have permission for this action.", model.statusText());
    mock.deny = false;
    try send(&model, .key_down, 'v', 0, 0, ui.input.modifiers.control);
    try std.testing.expectEqualStrings("/container/Documents/note.txt", mock.last_source[0..mock.source_len]);
    try std.testing.expectEqualStrings("/container/Downloads/note.txt", mock.last_destination[0..mock.destination_len]);
    try std.testing.expect(model.clipboard != null); // Copy may be pasted again.
    try click(&model, geometry.sidebar(.documents));
    model.panes[0].selected = 0;
    try send(&model, .key_down, 'x', 0, 0, ui.input.modifiers.control);
    try std.testing.expectEqual(@as(usize, 0), mock.moves);
    try click(&model, geometry.sidebar(.downloads));
    model.action(.paste);
    try std.testing.expectEqual(@as(usize, 1), mock.moves);
    try std.testing.expect(model.clipboard == null);
}
test "navigation buttons and shortcuts preserve bounded history and truncate forward branch only on success" {
    var mock: Mock = .{};
    var model: files.Model = .{};
    try model.init(mock.provider(), "/container/Documents", "/container/Downloads");
    const geometry = try files.Geometry.init(800, 600);
    try click(&model, geometry.sidebar(.home));
    try std.testing.expectEqualStrings("/container", model.panes[0].directory());
    try click(&model, geometry.sidebar(.downloads));
    try click(&model, geometry.button(.back));
    try std.testing.expectEqualStrings("/container", model.panes[0].directory());
    try std.testing.expect(model.canForward());
    const position = model.histories[0].position;
    try std.testing.expectError(error.PermissionDenied, model.navigate(0, "/ungranted"));
    try std.testing.expectEqual(position, model.histories[0].position);
    try std.testing.expect(model.canForward());
    try send(&model, .key_down, @backingInt(ui.input.Key.right), 0, 0, ui.input.modifiers.alt);
    try std.testing.expectEqualStrings("/container/Downloads", model.panes[0].directory());
    for (0..20) |i| model.shortcut(if (i % 2 == 0) .documents else .downloads);
    try std.testing.expectEqual(@as(usize, 8), model.histories[0].count);
    model.action(.back);
    model.shortcut(.home);
    try std.testing.expect(!model.canForward());
    try click(&model, geometry.button(.split));
    try std.testing.expect(model.split);
    try send(&model, .key_down, @backingInt(ui.input.Key.tab), 0, 0, 0);
    try std.testing.expectEqual(@as(usize, 1), model.focus);
    try click(&model, geometry.button(.split));
    try std.testing.expect(!model.split and model.focus == 0);
}
test "redraw preserves editing preview selection scroll clipboard and history but cancels obsolete geometry gestures" {
    var mock: Mock = .{};
    var model: files.Model = .{};
    try model.init(mock.provider(), "/container/Documents", "/container/Downloads");
    model.panes[0].selected = 0;
    model.action(.copy);
    model.action(.rename);
    model.panes[0].scroll = 1;
    const position = model.histories[0].position;
    const revision = model.revision;
    try model.dispatch(.{ .kind = .redraw, .code = 1 }, 1280, 800);
    try std.testing.expect(model.revision > revision and model.edit == .rename and model.clipboard != null);
    try std.testing.expectEqualStrings("note.txt", model.editText());
    try std.testing.expectEqual(@as(?usize, 0), model.panes[0].selected);
    try std.testing.expectEqual(@as(usize, 1), model.panes[0].scroll);
    try std.testing.expectEqual(position, model.histories[0].position);
    model.edit = .none;
    model.preview_open = true;
    model.preview_len = 4;
    @memcpy(model.preview[0..4], "text");
    try model.dispatch(.{ .kind = .redraw }, 640, 360);
    try std.testing.expect(model.preview_open and model.clipboard != null);
    try std.testing.expectEqualStrings("text", model.previewText());
    model.preview_open = false;
    model.panes[0].scroll = 0;
    const row = (try files.Geometry.init(800, 600)).row(0, 0);
    try send(&model, .pointer_down, 1, @intCast(row.x + 30), @intCast(row.y + 10), 0);
    try model.dispatch(.{ .kind = .redraw }, 800, 600);
    try std.testing.expect(model.drag != null);
    try model.dispatch(.{ .kind = .redraw, .code = 1 }, 1280, 800);
    try std.testing.expect(model.drag == null);
    const target = (try files.Geometry.init(1280, 800)).sidebar(.downloads);
    try model.dispatch(.{ .kind = .pointer_up, .code = 1, .x = @intCast(target.x + 20), .y = @intCast(target.y + 10) }, 1280, 800);
    try std.testing.expectEqual(@as(usize, 0), mock.moves);
}
test "compact control rectangles have nonoverlapping usable hit areas and consistent row bounds" {
    inline for (.{ false, true }) |split| {
        const geometry = try files.Geometry.initMode(640, 360, split);
        inline for (.{ files.Action.back, files.Action.forward, files.Action.up, files.Action.split, files.Action.more }) |action| {
            const rect = geometry.button(action);
            try std.testing.expect(rect.width >= 32 and rect.height == 32);
            try std.testing.expect(rect.x >= 0 and rect.x + @as(i32, @intCast(rect.width)) <= 640);
            try std.testing.expectEqual(action, geometry.actionAt(.{ .x = rect.x + 2, .y = rect.y + 2 }).?);
        }
        const row = geometry.row(0, 0);
        try std.testing.expectEqual(@as(i32, 68), row.y);
        try std.testing.expectEqual(@as(u32, 28), row.height);
        try std.testing.expectEqual(@as(usize, 0), geometry.paneAt(.{ .x = row.x + 2, .y = row.y + 2 }).?);
    }
}
test "mouse Create Save and Cancel are captured controls with visible validation failures" {
    var mock: Mock = .{};
    var model: files.Model = .{};
    try model.init(mock.provider(), "/container/Documents", "/container/Downloads");
    const geometry = try files.Geometry.init(800, 600);
    try moreAction(&model, .new_folder);
    try click(&model, geometry.confirm());
    try std.testing.expect(model.edit == .new_folder and model.status_error);
    try std.testing.expectEqual(@as(usize, 0), mock.folders);
    for ("New Folder") |byte| try send(&model, .text, byte, 0, 0, 0);
    try click(&model, geometry.confirm());
    try std.testing.expectEqual(@as(usize, 1), mock.folders);
    try std.testing.expectEqualStrings("/container/Documents/New Folder", mock.last_destination[0..mock.destination_len]);
    model.panes[0].selected = 0;
    model.action(.rename);
    try send(&model, .key_down, @backingInt(ui.input.Key.home), 0, 0, 0);
    try send(&model, .text, 'X', 0, 0, 0);
    try click(&model, geometry.confirm());
    try std.testing.expectEqualStrings("/container/Documents/Xnote.txt", mock.last_destination[0..mock.destination_len]);
    model.action(.new_file);
    for ("cancel.txt") |byte| try send(&model, .text, byte, 0, 0, 0);
    try click(&model, geometry.cancel());
    try std.testing.expect(model.edit == .none and mock.creates == 0);
    model.action(.new_file);
    for ("not-created.txt") |byte| try send(&model, .text, byte, 0, 0, 0);
    const confirm = geometry.confirm();
    try send(&model, .pointer_down, 1, @intCast(confirm.x + 4), @intCast(confirm.y + 4), 0);
    try send(&model, .pointer_up, 1, -8, -8, 0);
    try std.testing.expect(model.edit == .new_file and mock.creates == 0);
}
test "only an unmoved host double click opens a same-row file or directory" {
    var mock: Mock = .{};
    var model: files.Model = .{};
    try model.init(mock.provider(), "/container/Documents", "/container/Downloads");
    const geometry = try files.Geometry.init(800, 600);
    const file_row = geometry.row(0, 0);
    try click(&model, file_row);
    try std.testing.expectEqual(@as(usize, 0), mock.opens);
    const x: i16 = @intCast(file_row.x + 32);
    const y: i16 = @intCast(file_row.y + 10);
    try send(&model, .pointer_down, 1, x, y, 0);
    try send(&model, .pointer_up, 1, x, y, ui.input.modifiers.double_click);
    try std.testing.expectEqual(@as(usize, 1), mock.opens);
    try send(&model, .pointer_down, 1, x, y, 0);
    try send(&model, .pointer_move, 0, x + 8, y, 0);
    try send(&model, .pointer_up, 1, x + 8, y, ui.input.modifiers.double_click);
    try std.testing.expectEqual(@as(usize, 1), mock.opens);
    const directory = geometry.row(0, 1);
    try send(&model, .pointer_down, 1, @intCast(directory.x + 32), @intCast(directory.y + 10), 0);
    try send(&model, .pointer_up, 1, @intCast(directory.x + 32), @intCast(directory.y + 10), ui.input.modifiers.double_click);
    try std.testing.expectEqualStrings("/container/Documents/Folder", model.panes[0].directory());
}
test "Up stops at granted roots without asking the provider for an outside location" {
    const Scoped = struct {
        calls: usize = 0,
        outside: usize = 0,
        fn list(context: *anyopaque, path: []const u8, _: *usize) anyerror!?files.Entry {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            if (std.mem.eql(u8, path, "/container") or std.mem.eql(u8, path, "/bundle") or std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/container/Documents")) return null;
            self.outside += 1;
            return error.PermissionDenied;
        }
    };
    var scoped: Scoped = .{};
    var model: files.Model = .{};
    const provider: files.Provider = .{ .context = &scoped, .list = Scoped.list };
    for ([_][]const u8{ "/container", "/bundle", "/" }) |root| {
        try model.init(provider, root, root);
        try std.testing.expect(!model.canUp());
        const calls = scoped.calls;
        model.action(.up);
        try std.testing.expectEqual(calls, scoped.calls);
        try std.testing.expectEqualStrings(root, model.panes[0].directory());
        try std.testing.expect(!model.status_error);
    }
    try model.init(provider, "/container/Documents", "/bundle");
    try std.testing.expect(model.canUp());
    model.action(.up);
    try std.testing.expectEqualStrings("/container", model.panes[0].directory());
    try std.testing.expect(!model.canUp());
    const calls = scoped.calls;
    try click(&model, (try files.Geometry.init(800, 600)).button(.up));
    try std.testing.expectEqual(calls, scoped.calls);
    model.preview_open = true;
    model.action(.up);
    try std.testing.expect(!model.preview_open);
    try std.testing.expectEqual(calls, scoped.calls);
    try std.testing.expectEqual(@as(usize, 0), scoped.outside);
}

test "menus clamp at every viewport edge and retain stable action IDs and hit rows" {
    try std.testing.expectEqual(@as(u8, 13), @backingInt(files.Action.nullify));
    try std.testing.expectEqual(@as(u8, 14), @backingInt(files.Action.more));
    const Size = struct { width: u32, height: u32 };
    for ([_]Size{ .{ .width = 640, .height = 360 }, .{ .width = 800, .height = 600 }, .{ .width = 1280, .height = 800 } }) |size| {
        for ([_]ui.Point{ .{ .x = -30, .y = -30 }, .{ .x = 0, .y = @intCast(size.height) }, .{ .x = @intCast(size.width), .y = 0 }, .{ .x = @intCast(size.width + 30), .y = @intCast(size.height + 30) } }) |anchor| {
            inline for (.{ files.MenuKind.file, files.MenuKind.directory, files.MenuKind.background, files.MenuKind.more }) |kind| {
                const bounds = try files.MenuGeometry.init(size.width, size.height, kind, anchor);
                try std.testing.expect(bounds.rect.x >= 0 and bounds.rect.y >= 0);
                try std.testing.expect(bounds.rect.x + @as(i32, @intCast(bounds.rect.width)) <= size.width);
                try std.testing.expect(bounds.rect.y + @as(i32, @intCast(bounds.rect.height)) <= size.height);
                for (files.menuActions(kind), 0..) |action, i| {
                    const rect = bounds.item(i);
                    try std.testing.expect(rect.width >= 32 and rect.height == 28);
                    try std.testing.expectEqual(i, bounds.itemAt(.{ .x = rect.x + 8, .y = rect.y + 8 }).?);
                    try std.testing.expectEqual(i, bounds.actionIndex(action).?);
                }
                try std.testing.expect(bounds.itemAt(.{ .x = bounds.rect.x + 1, .y = bounds.rect.y + 1 }) == null);
            }
        }
    }
    const file = try files.MenuGeometry.init(800, 600, .file, .{ .x = 0, .y = 0 });
    try std.testing.expectEqual(@as(usize, 6), file.actionIndex(.nullify).?);
    const directory = try files.MenuGeometry.init(800, 600, .directory, .{ .x = 0, .y = 0 });
    try std.testing.expect(directory.actionIndex(.nullify) == null);
    const more = try files.MenuGeometry.init(800, 600, .more, .{ .x = 0, .y = 0 });
    try std.testing.expectEqual(@as(usize, 7), more.actionIndex(.nullify).?);
}

test "right click targets a row or blank folder and disabled actions remain inert" {
    var mock: Mock = .{ .read_only = true };
    var model: files.Model = .{};
    try model.init(mock.provider(), "/container/Documents", "/container/Downloads");
    try contextRow(&model, 0);
    try std.testing.expect(model.menu.?.kind == .file and model.panes[0].selected == 0 and model.drag == null);
    try std.testing.expect(model.menuEnabled(.open) and model.menuEnabled(.copy));
    try std.testing.expect(!model.menuEnabled(.remove) and !model.menuEnabled(.rename) and !model.menuEnabled(.nullify));
    try clickMenu(&model, .nullify);
    try std.testing.expectEqual(@as(usize, 0), mock.nullifies);
    try std.testing.expect(model.menu != null);
    try send(&model, .key_down, @backingInt(ui.input.Key.escape), 0, 0, 0);
    try contextRow(&model, 1);
    try std.testing.expect(model.menu.?.kind == .directory and model.panes[0].selected == 1);
    try std.testing.expect(!model.menuEnabled(.nullify));
    try send(&model, .pointer_down, 3, 300, 260, 0);
    try std.testing.expect(model.menu.?.kind == .background and model.panes[0].selected == null);
    try std.testing.expect(model.menuEnabled(.new_file) and model.menuEnabled(.new_folder));
    try std.testing.expect(!model.menuEnabled(.paste));
    try clickMenu(&model, .new_file);
    try std.testing.expect(model.edit == .new_file and model.menu == null);
    try send(&model, .key_down, @backingInt(ui.input.Key.escape), 0, 0, 0);
    var provider = mock.provider();
    provider.nullify = null;
    mock.read_only = false;
    try model.init(provider, "/container/Documents", "/container/Downloads");
    try contextRow(&model, 0);
    try std.testing.expect(!model.menuEnabled(.nullify));
    try clickMenu(&model, .nullify);
    try std.testing.expectEqual(@as(usize, 0), mock.nullifies);
}

test "menu mutations require a matching release and dismiss on outside keyboard refresh or geometry change" {
    var mock: Mock = .{};
    var model: files.Model = .{};
    try model.init(mock.provider(), "/container/Documents", "/container/Downloads");
    try contextRow(&model, 0);
    const nullify = try menuRect(&model, .nullify);
    const remove = try menuRect(&model, .remove);
    try send(&model, .pointer_down, 1, @intCast(nullify.x + 8), @intCast(nullify.y + 8), 0);
    try send(&model, .pointer_up, 1, @intCast(remove.x + 8), @intCast(remove.y + 8), 0);
    try std.testing.expect(mock.nullifies == 0 and mock.removes == 0);
    try send(&model, .pointer_down, 1, -8, -8, 0);
    try std.testing.expect(model.menu == null);
    try send(&model, .pointer_up, 1, @intCast(nullify.x + 8), @intCast(nullify.y + 8), 0);
    try std.testing.expect(mock.nullifies == 0 and mock.removes == 0);
    try contextRow(&model, 0);
    try send(&model, .pointer_move, 0, @intCast(nullify.x + 8), @intCast(nullify.y + 8), 0);
    try std.testing.expectEqual(@as(?usize, 6), model.menu.?.hovered);
    try send(&model, .pointer_down, 1, @intCast(nullify.x + 8), @intCast(nullify.y + 8), 0);
    try send(&model, .key_down, @backingInt(ui.input.Key.f5), 0, 0, 0);
    try std.testing.expect(model.menu == null and model.panes[0].selected == null);
    try send(&model, .pointer_up, 1, @intCast(nullify.x + 8), @intCast(nullify.y + 8), 0);
    try contextRow(&model, 0);
    try send(&model, .pointer_down, 1, @intCast(nullify.x + 8), @intCast(nullify.y + 8), 0);
    try model.dispatch(.{ .kind = .redraw }, 800, 600);
    try std.testing.expect(model.menu.?.pressed == 6);
    try model.dispatch(.{ .kind = .redraw, .code = 1 }, 1280, 800);
    try std.testing.expect(model.menu == null);
    try send(&model, .pointer_up, 1, @intCast(nullify.x + 8), @intCast(nullify.y + 8), 0);
    model.action(.nullify);
    try std.testing.expectEqual(@as(usize, 0), mock.nullifies);
    try contextRow(&model, 0);
    try send(&model, .key_down, @backingInt(ui.input.Key.enter), 0, 0, 0);
    try std.testing.expectEqual(@as(usize, 0), mock.nullifies);
    // Delete keeps its ordinary semantics and does not scrub through Nullify.
    try contextRow(&model, 0);
    try clickMenu(&model, .remove);
    try std.testing.expectEqual(@as(usize, 1), mock.removes);
    try std.testing.expectEqual(@as(usize, 0), mock.nullifies);
}

test "Nullify executes once clears matching retained copies and keeps a visible scoped result" {
    const Reader = struct {
        fn read(_: *anyopaque, _: []const u8, _: u64, output: []u8) anyerror!usize {
            @memcpy(output[0..13], "Private bytes");
            return 13;
        }
    };
    var mock: Mock = .{};
    var provider = mock.provider();
    provider.read = Reader.read;
    var model: files.Model = .{};
    try model.init(provider, "/container/Documents", "/container/Downloads");
    model.panes[0].selected = 0;
    model.action(.copy);
    model.action(.open);
    try std.testing.expect(model.preview_open and model.clipboard != null);
    @memset(model.preview[model.preview_len..], 0xa5);
    @memset(model.preview_name[model.preview_name_len..], 0xa5);
    @memset(model.preview_path[model.preview_path_len..], 0xa5);
    model.closePreview();
    try contextRow(&model, 0);
    const rect = try menuRect(&model, .nullify);
    try clickMenu(&model, .nullify);
    try std.testing.expectEqual(@as(usize, 1), mock.nullifies);
    try std.testing.expectEqualStrings("/container/Documents/note.txt", mock.last_source[0..mock.source_len]);
    try std.testing.expect(model.menu == null and model.clipboard == null and !model.preview_open);
    try std.testing.expectEqual(@as(usize, 0), model.preview_len);
    for (model.preview) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    for (model.preview_name) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    for (model.preview_path) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    try std.testing.expectEqualStrings("File nullified in Bedrock", model.statusText());
    try std.testing.expect(model.status_notice and !model.status_error);
    try send(&model, .pointer_up, 1, @intCast(rect.x + 8), @intCast(rect.y + 8), 0);
    try std.testing.expectEqual(@as(usize, 1), mock.nullifies);
    const pixels = try std.testing.allocator.alloc(u32, 800 * 600);
    defer std.testing.allocator.free(pixels);
    var surface = try ui.Surface.init(pixels, 800, 600, 800, .{ .red = 0xff0000, .green = 0xff00, .blue = 0xff });
    var workspace: files.Workspace = undefined;
    @memset(&workspace.preview_text, 0xa5);
    try files.renderWithWorkspace(&surface, &workspace, &model);
    for (workspace.preview_text) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    const visible_hash = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(pixels[576 * 800 ..]));
    model.status_notice = false;
    try files.renderWithWorkspace(&surface, &workspace, &model);
    try std.testing.expect(visible_hash != std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(pixels[576 * 800 ..])));
}

test "Nullify failure is incomplete without automatic retry and unrelated retained file copies survive" {
    var mock: Mock = .{ .deny = true };
    var model: files.Model = .{};
    try model.init(mock.provider(), "/container/Documents", "/container/Downloads");
    const other_path = "/container/Downloads/note.txt";
    @memcpy(model.preview_path[0..other_path.len], other_path);
    model.preview_path_len = other_path.len;
    @memcpy(model.preview[0..5], "Other");
    model.preview_len = 5;
    model.clipboard = .{ .source_len = other_path.len, .name_len = 8 };
    @memcpy(model.clipboard.?.source[0..other_path.len], other_path);
    @memcpy(model.clipboard.?.name[0..8], "note.txt");
    try contextRow(&model, 0);
    const rect = try menuRect(&model, .nullify);
    try clickMenu(&model, .nullify);
    try std.testing.expect(model.status_error and !model.status_notice);
    try std.testing.expectEqualStrings("Nullify incomplete: storage may need recovery.", model.statusText());
    try std.testing.expectEqualStrings("Other", model.previewText());
    try std.testing.expect(model.clipboard != null);
    try std.testing.expectEqualStrings(other_path, model.clipboard.?.source[0..model.clipboard.?.source_len]);
    try send(&model, .pointer_up, 1, @intCast(rect.x + 8), @intCast(rect.y + 8), 0);
    try std.testing.expectEqual(@as(usize, 1), mock.nullifies);
    try std.testing.expect(!mock.source_present);
    // Failure also wipes a matching preview/clipboard even if deletion already
    // committed, while preserving the scoped incomplete result after refresh.
    mock.source_present = true;
    try model.init(mock.provider(), "/container/Documents", "/container/Downloads");
    const matching = "/container/Documents/note.txt";
    @memcpy(model.preview_path[0..matching.len], matching);
    model.preview_path_len = matching.len;
    @memset(&model.preview, 0xa5);
    @memset(&model.preview_name, 0xa5);
    model.preview_len = 5;
    model.panes[0].selected = 0;
    model.action(.copy);
    try contextRow(&model, 0);
    try clickMenu(&model, .nullify);
    try std.testing.expectEqual(@as(usize, 2), mock.nullifies);
    try std.testing.expect(model.clipboard == null and model.preview_len == 0);
    for (model.preview) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    for (model.preview_name) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    try std.testing.expectEqualStrings("Nullify incomplete: storage may need recovery.", model.statusText());
}

test "minimum viewport popup material and sharp destructive label stay inside guarded stride" {
    var frost = try FrostFixture.init();
    defer frost.deinit();
    const stride = 645;
    const pixels = try std.testing.allocator.alloc(u32, stride * 360 + 2);
    defer std.testing.allocator.free(pixels);
    @memset(pixels, 0x12345678);
    var surface = try ui.Surface.init(pixels[1 .. pixels.len - 1], 640, 360, stride, .{ .red = 0xff0000, .green = 0xff00, .blue = 0xff });
    try surface.setBackdrop(&frost.backdrop, .{ .x = 16, .y = 16 });
    var mock: Mock = .{};
    var model: files.Model = .{};
    try model.init(mock.provider(), "/container/Documents", "/container/Downloads");
    model.panes[0].selected = 0;
    model.menu = .{ .kind = .more, .anchor = .{ .x = 639, .y = 359 }, .hovered = 7 };
    var workspace: files.Workspace = undefined;
    try files.renderWithWorkspace(&surface, &workspace, &model);
    const bounds = try files.MenuGeometry.init(640, 360, .more, model.menu.?.anchor);
    const nullify = bounds.item(7);
    var ink: usize = 0;
    for (@as(usize, @intCast(nullify.y))..@as(usize, @intCast(nullify.y + 28))) |y| for (@as(usize, @intCast(nullify.x))..@as(usize, @intCast(nullify.x + 200))) |x| {
        if (pixels[1 + y * stride + x] == surface.encode(files.colors.error_color)) ink += 1;
    };
    try std.testing.expect(ink > 30);
    const plain = bounds.item(8);
    const x: usize = @intCast(plain.x + 180);
    const y: usize = @intCast(plain.y + 2);
    try std.testing.expectEqual(expectedMaterial(frost.backdrop.sample(@intCast(x + 16), @intCast(y + 16)), files.materials.menu), pixels[1 + y * stride + x]);
    try std.testing.expectEqual(@as(u32, 0x12345678), pixels[0]);
    try std.testing.expectEqual(@as(u32, 0x12345678), pixels[pixels.len - 1]);
    for (0..360) |row| for (640..stride) |column| try std.testing.expectEqual(@as(u32, 0x12345678), pixels[1 + row * stride + column]);
}

test "responsive Files paints minimum and tiled clients with aligned toolbar hits" {
    const sentinel: u32 = 0x12345678;
    const Size = struct { width: u32, height: u32 };
    for ([_]Size{ .{ .width = 316, .height = 204 }, .{ .width = 396, .height = 510 }, .{ .width = 636, .height = 710 } }) |size| {
        var mock: Mock = .{};
        var model: files.Model = .{};
        var workspace: files.Workspace = undefined;
        try model.init(mock.provider(), "/container/Documents", "/container/Downloads");
        try model.dispatch(.{ .kind = .redraw, .code = 1 }, size.width, size.height);
        model.panes[0].selected = 0;
        const geometry = try files.Geometry.init(size.width, size.height);
        try std.testing.expect(!geometry.canSplit() and geometry.visible_rows >= 4);
        const stride = size.width + 5;
        const count = @as(usize, stride) * size.height;
        const pixels = try std.testing.allocator.alloc(u32, count + 2);
        defer std.testing.allocator.free(pixels);
        @memset(pixels, sentinel);
        var surface = try ui.Surface.init(pixels[1 .. count + 1], size.width, size.height, stride, .{ .red = 0xff0000, .green = 0xff00, .blue = 0xff });
        model.hovered_action = .more;
        try files.renderWithWorkspace(&surface, &workspace, &model);
        const more = geometry.button(.more);
        try std.testing.expectEqual(files.Action.more, geometry.actionAt(.{ .x = more.x + 2, .y = more.y + 16 }).?);
        try std.testing.expectEqual(surface.encode(files.colors.hover), pixels[1 + @as(usize, @intCast(more.y + 16)) * stride + @as(usize, @intCast(more.x + 2))]);
        const row = geometry.row(0, 0);
        try std.testing.expectEqual(surface.encode(files.colors.selected), pixels[1 + @as(usize, @intCast(row.y + 1)) * stride + @as(usize, @intCast(row.x + 24))]);
        try std.testing.expect(pixels[1 + @as(usize, @intCast(row.y + 1)) * stride + @as(usize, @intCast(row.x + 1))] != surface.encode(files.colors.selected));
        model.action(.rename);
        model.pressed_edit = .confirm;
        try files.renderWithWorkspace(&surface, &workspace, &model);
        const confirm = geometry.confirm();
        try std.testing.expectEqual(surface.encode(files.colors.selected), pixels[1 + @as(usize, @intCast(confirm.y + 16)) * stride + @as(usize, @intCast(confirm.x + 2))]);
        model.edit = .none;
        model.preview_open = true;
        model.preview_name_len = 8;
        @memcpy(model.preview_name[0..8], "note.txt");
        model.preview_len = 48;
        @memset(model.preview[0..48], 'A');
        try files.renderWithWorkspace(&surface, &workspace, &model);
        model.preview_open = false;
        inline for (.{ files.MenuKind.file, files.MenuKind.directory, files.MenuKind.background, files.MenuKind.more }) |kind| {
            model.menu = .{ .kind = kind, .anchor = .{ .x = @intCast(size.width), .y = @intCast(size.height) } };
            try files.renderWithWorkspace(&surface, &workspace, &model);
            const bounds = try files.MenuGeometry.init(size.width, size.height, kind, model.menu.?.anchor);
            try std.testing.expect(bounds.rect.y >= 0 and bounds.rect.y + @as(i32, @intCast(bounds.rect.height)) <= size.height);
            for (files.menuActions(kind), 0..) |_, i| {
                const item = bounds.item(i);
                try std.testing.expect(item.height >= 18);
                try std.testing.expectEqual(i, bounds.itemAt(.{ .x = item.x + 8, .y = item.y + @as(i32, @intCast(item.height / 2)) }).?);
                var ink: usize = 0;
                for (@as(usize, @intCast(item.y))..@as(usize, @intCast(item.y + @as(i32, @intCast(item.height))))) |y| {
                    for (@as(usize, @intCast(item.x))..@as(usize, @intCast(item.x + @as(i32, @intCast(item.width))))) |x| {
                        const pixel = pixels[1 + y * stride + x];
                        if (pixel == surface.encode(files.colors.text) or pixel == surface.encode(files.colors.muted) or pixel == surface.encode(files.colors.error_color)) ink += 1;
                    }
                }
                try std.testing.expect(ink > 8);
            }
        }
        try std.testing.expectEqual(sentinel, pixels[0]);
        try std.testing.expectEqual(sentinel, pixels[count + 1]);
        for (0..size.height) |y| for (size.width..stride) |x| try std.testing.expectEqual(sentinel, pixels[1 + y * stride + x]);
    }
    try std.testing.expectError(error.InvalidViewport, files.Geometry.init(315, 204));
    try std.testing.expectError(error.InvalidViewport, files.Geometry.init(316, 203));
}

test "shrinking split Files preserves its focused location and editing target" {
    var mock: Mock = .{};
    var model: files.Model = .{};
    try model.init(mock.provider(), "/container/Documents", "/container/Downloads");
    model.action(.split);
    model.focus = 1;
    model.panes[1].selected = 0;
    model.action(.rename);
    try model.dispatch(.{ .kind = .redraw, .code = 1 }, 316, 204);
    try std.testing.expect(!model.split and !model.split_allowed and model.focus == 0);
    try std.testing.expectEqualStrings("/container/Downloads", model.panes[0].directory());
    try std.testing.expectEqualStrings("/container/Documents", model.panes[1].directory());
    try std.testing.expectEqualStrings("/container/Downloads", model.histories[0].locations[model.histories[0].position].bytes[0..model.histories[0].locations[model.histories[0].position].len]);
    try std.testing.expect(model.edit == .rename and std.mem.eql(u8, model.editText(), "Dest"));
    try std.testing.expect(!model.menuEnabled(.split));
    const geometry = try files.Geometry.initMode(316, 204, true);
    try std.testing.expect(!geometry.split and geometry.pane(1).width == 0 and geometry.button(.split).width == 0);
    model.edit = .none;
    model.action(.split);
    try std.testing.expect(!model.split);
    try model.dispatch(.{ .kind = .redraw, .code = 1 }, 640, 360);
    try std.testing.expect(model.menuEnabled(.split));
    model.action(.split);
    try std.testing.expect(model.split);
}

test "minimum Files redraw reveals selection and compressed More actions dispatch safely" {
    var context: Flood = .{};
    var model: files.Model = .{};
    try model.init(.{ .context = &context, .list = Flood.list }, "/left", "/right");
    model.panes[0].selected = 8;
    try model.dispatch(.{ .kind = .redraw, .code = 1 }, 316, 204);
    try std.testing.expectEqual(@as(usize, 5), model.panes[0].scroll);
    const geometry = try files.Geometry.init(316, 204);
    const more = geometry.button(.more);
    const point: ui.Point = .{ .x = more.x + 10, .y = more.y + 10 };
    try model.dispatch(.{ .kind = .pointer_down, .code = 1, .x = @intCast(point.x), .y = @intCast(point.y) }, 316, 204);
    try model.dispatch(.{ .kind = .pointer_up, .code = 1, .x = @intCast(point.x), .y = @intCast(point.y) }, 316, 204);
    try std.testing.expect(model.menu != null and model.menu.?.kind == .more);
    const bounds = try files.MenuGeometry.init(316, 204, .more, model.menu.?.anchor);
    try std.testing.expectEqual(@as(u32, 19), bounds.row_height);
    const rect = bounds.item(bounds.actionIndex(.refresh).?);
    const revision = model.revision;
    try model.dispatch(.{ .kind = .pointer_down, .code = 1, .x = @intCast(rect.x + 10), .y = @intCast(rect.y + 9) }, 316, 204);
    try model.dispatch(.{ .kind = .pointer_up, .code = 1, .x = @intCast(rect.x + 10), .y = @intCast(rect.y + 9) }, 316, 204);
    try std.testing.expect(model.menu == null and model.revision > revision and model.initialized);
}

fn windowPath(width: u32) ui.Rect {
    return .{ .x = 104, .y = 4, .width = width - 204, .height = 24 };
}
fn windowSend(model: *files.Model, event: ui.Event, width: u32, height: u32) !void {
    try model.dispatchWindow(event, width, height, windowPath(width));
}
fn enterLocation(model: *files.Model, path: []const u8) !void {
    try windowSend(model, .{ .kind = .key_down, .code = 'l', .modifiers = ui.input.modifiers.control }, 800, 632);
    for (path) |byte| try windowSend(model, .{ .kind = .text, .code = byte }, 800, 632);
    try windowSend(model, .{ .kind = .key_down, .code = @backingInt(ui.input.Key.enter) }, 800, 632);
}

test "location editor selections delete replace and preserve bounds at capacity" {
    const Editor = @import("path_editor.zig").Editor;
    var editor: Editor = .{};
    editor.set("/container/Documents", true);
    try editor.insert('/');
    try std.testing.expectEqualStrings("/", editor.text());
    editor.set("/container/Documents", false);
    editor.move(0, false);
    editor.right(true);
    try std.testing.expectEqual(@as(usize, 1), editor.selection().end);
    editor.delete();
    try std.testing.expectEqualStrings("container/Documents", editor.text());
    try editor.insert('/');
    editor.move(editor.len, false);
    editor.left(true);
    editor.backspace();
    try std.testing.expectEqualStrings("/container/Document", editor.text());
    editor.selectAll();
    editor.left(false);
    try std.testing.expectEqual(@as(usize, 0), editor.cursor);
    editor.selectAll();
    editor.right(false);
    try std.testing.expectEqual(editor.len, editor.cursor);
    const full: [files.max_path_bytes]u8 = @splat('x');
    editor.set(&full, false);
    try std.testing.expectError(error.PathTooLong, editor.insert('y'));
    try std.testing.expectEqualSlices(u8, &full, editor.text());
    try std.testing.expectError(error.UnsupportedCharacter, editor.insert(0x80));
    editor.selectAll();
    try editor.insert('z');
    try std.testing.expectEqualStrings("z", editor.text());
}

test "window path keyboard opens canonical private folders and records actual history" {
    var mock: Mock = .{};
    var model: files.Model = .{};
    try model.init(mock.provider(), "/container/Documents", "/container/Downloads");
    try windowSend(&model, .{ .kind = .key_down, .code = 'l', .modifiers = ui.input.modifiers.control }, 800, 632);
    try std.testing.expect(model.path_editing);
    try std.testing.expectEqualStrings("~/Documents", model.headerPath());
    try std.testing.expectEqual(@as(usize, 0), model.path_editor.selection().start);
    try std.testing.expectEqual(model.path_editor.len, model.path_editor.selection().end);
    try enterLocation(&model, "~//Downloads/");
    try std.testing.expect(!model.path_editing and !model.status_error);
    try std.testing.expectEqualStrings("~/Downloads", model.headerPath());
    try std.testing.expectEqual(@as(u64, 1), model.path_commits);
    try std.testing.expectEqual(@as(usize, 2), model.histories[0].count);
    try windowSend(&model, .{ .kind = .key_down, .code = @backingInt(ui.input.Key.left), .modifiers = ui.input.modifiers.alt }, 800, 632);
    try std.testing.expectEqualStrings("~/Documents", model.headerPath());
    try windowSend(&model, .{ .kind = .key_down, .code = 'l', .modifiers = ui.input.modifiers.control }, 800, 632);
    try windowSend(&model, .{ .kind = .key_down, .code = 'a', .modifiers = ui.input.modifiers.control }, 800, 632);
    try windowSend(&model, .{ .kind = .text, .code = '/' }, 800, 632);
    try windowSend(&model, .{ .kind = .key_down, .code = @backingInt(ui.input.Key.escape) }, 800, 632);
    try std.testing.expect(!model.path_editing);
    try std.testing.expectEqualStrings("~/Documents", model.headerPath());
    try std.testing.expectEqual(@as(u64, 1), model.path_commits);
    try std.testing.expectEqual(@as(usize, 2), model.histories[0].count);
}

test "failed typed locations retain directory listing selection history and sandbox boundary" {
    const Provider = struct {
        mock: Mock = .{},
        calls: usize = 0,
        fn list(context: *anyopaque, path: []const u8, cursor: *usize) anyerror!?files.Entry {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            if (std.mem.eql(u8, path, "/container/Documents/note.txt")) return error.NotDirectory;
            if (std.mem.eql(u8, path, "/container/Missing")) return error.NotFound;
            if (std.mem.eql(u8, path, "/container/Partial")) {
                if (cursor.* != 0) return error.PermissionDenied;
                cursor.* = 1;
                return try files.Entry.init("temporary", .file, 1, false);
            }
            return Mock.listing(&self.mock, path, cursor);
        }
    };
    var provider: Provider = .{};
    var model: files.Model = .{};
    try model.init(.{ .context = &provider, .list = Provider.list }, "/container/Documents", "/container/Downloads");
    model.panes[0].selected = 0;
    const initial = model.panes[0];
    for ([_][]const u8{ "~/Documents/note.txt", "~/Missing", "~/Partial", "/private/108/container/notes.txt", "/container/../Downloads", "/container2" }, 0..) |path, index| {
        const calls = provider.calls;
        try enterLocation(&model, path);
        try std.testing.expect(model.path_editing and model.status_error);
        try std.testing.expectEqualStrings(path, model.headerPath());
        try std.testing.expectEqualStrings("/container/Documents", model.panes[0].directory());
        try std.testing.expectEqual(initial.count, model.panes[0].count);
        try std.testing.expectEqual(initial.selected, model.panes[0].selected);
        try std.testing.expectEqualSlices(u8, initial.entries[0].bytes(), model.panes[0].entries[0].bytes());
        try std.testing.expectEqual(@as(usize, 1), model.histories[0].count);
        try std.testing.expectEqual(@as(u64, 0), model.path_commits);
        try std.testing.expectEqual(@as(u64, @intCast(index + 1)), model.path_rejections);
        if (index >= 3) try std.testing.expectEqual(calls, provider.calls);
    }
}

test "center path input stays separate from server chrome and tracks focused split pane" {
    var mock: Mock = .{};
    var model: files.Model = .{};
    try model.init(mock.provider(), "/container/Documents", "/container/Downloads");
    for ([_]i16{ 20, 103, 700, 780 }) |x| try windowSend(&model, .{ .kind = .pointer_down, .code = 1, .x = x, .y = 12 }, 800, 632);
    try std.testing.expect(!model.path_editing);
    try windowSend(&model, .{ .kind = .pointer_down, .code = 1, .x = 120, .y = 12 }, 800, 632);
    try windowSend(&model, .{ .kind = .pointer_up, .code = 1, .x = 120, .y = 12 }, 800, 632);
    try std.testing.expect(model.path_editing);
    try std.testing.expectEqual(@as(usize, 0), model.path_editor.selection().start);
    try std.testing.expectEqual(model.path_editor.len, model.path_editor.selection().end);
    try windowSend(&model, .{ .kind = .key_down, .code = @backingInt(ui.input.Key.home) }, 800, 632);
    try windowSend(&model, .{ .kind = .key_down, .code = @backingInt(ui.input.Key.right), .modifiers = ui.input.modifiers.shift }, 800, 632);
    try std.testing.expectEqual(@as(usize, 1), model.path_editor.selection().end);
    try windowSend(&model, .{ .kind = .key_down, .code = @backingInt(ui.input.Key.end) }, 800, 632);
    try std.testing.expectEqual(model.path_editor.len, model.path_editor.cursor);
    model.split = true;
    try windowSend(&model, .{ .kind = .key_down, .code = @backingInt(ui.input.Key.tab) }, 800, 632);
    try std.testing.expect(!model.path_editing and model.focus == 1);
    try std.testing.expectEqualStrings("~/Downloads", model.headerPath());
    try windowSend(&model, .{ .kind = .redraw, .code = 1 }, 316, 236);
    try std.testing.expect(!model.split and model.focus == 0);
    try std.testing.expectEqualStrings("~/Downloads", model.headerPath());
    const more = (try files.Geometry.init(316, 204)).button(.more);
    try windowSend(&model, .{ .kind = .pointer_down, .code = 1, .x = @intCast(more.x + 12), .y = @intCast(more.y + 32 + 12) }, 316, 236);
    try windowSend(&model, .{ .kind = .pointer_up, .code = 1, .x = @intCast(more.x + 12), .y = @intCast(more.y + 32 + 12) }, 316, 236);
    try std.testing.expect(model.menu != null and model.menu.?.kind == .more);
}

test "window path paints clipped proportional caret without touching chrome or stride padding" {
    for ([_]struct { width: u32, height: u32 }{ .{ .width = 316, .height = 236 }, .{ .width = 396, .height = 542 }, .{ .width = 800, .height = 632 } }) |size| {
        var mock: Mock = .{};
        var model: files.Model = .{};
        var workspace: files.Workspace = undefined;
        try model.init(mock.provider(), "/container/Documents", "/container/Downloads");
        const stride = size.width + 5;
        const pixels = try std.testing.allocator.alloc(u32, @as(usize, stride) * size.height + 2);
        defer std.testing.allocator.free(pixels);
        @memset(pixels, 0x12345678);
        var surface = try ui.Surface.init(pixels[1 .. pixels.len - 1], size.width, size.height, stride, .{ .red = 0xff0000, .green = 0xff00, .blue = 0xff });
        const path = windowPath(size.width);
        try windowSend(&model, .{ .kind = .key_down, .code = 'l', .modifiers = ui.input.modifiers.control }, size.width, size.height);
        try windowSend(&model, .{ .kind = .key_down, .code = @backingInt(ui.input.Key.end) }, size.width, size.height);
        model.path_editor.set("~/Documents/VeryLongFolderWWWWiiiWWWW/AnotherFolder", false);
        try files.renderWindowWithWorkspace(&surface, &workspace, &model, path);
        const visible = model.path_editor.visibleStart(path.width - 12);
        if (size.width == 316) try std.testing.expect(visible != 0);
        try std.testing.expect(@import("path_editor.zig").measured(model.path_editor.text()[visible..model.path_editor.cursor]) < path.width - 12);
        var text_ink: usize = 0;
        var caret_ink: usize = 0;
        for (0..32) |y| for (0..size.width) |x| {
            const pixel = pixels[1 + y * stride + x];
            if (!path.contains(.{ .x = @intCast(x), .y = @intCast(y) })) try std.testing.expectEqual(@as(u32, 0x12345678), pixel);
            if (pixel == surface.encode(files.colors.text)) text_ink += 1;
            if (pixel == surface.encode(files.colors.accent)) caret_ink += 1;
        };
        try std.testing.expect(text_ink > 10 and caret_ink >= 14);
        if (size.width == 800) for (40..64) |y| for (140..680) |x| try std.testing.expectEqual(surface.encode(files.colors.toolbar), pixels[1 + y * stride + x]);
        const rendered = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(pixels));
        // Partial glass coverage must depend on this frame's caption base,
        // never the preceding submitted field pixels or an old file listing.
        surface.fillRect(@intCast(path.x), @intCast(path.y), path.width, path.height, 0xff0000);
        surface.fillRect(0, 32, size.width, size.height - 32, 0x00ff00);
        try files.renderWindowWithWorkspace(&surface, &workspace, &model, path);
        try std.testing.expectEqual(rendered, std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(pixels)));
        try std.testing.expectEqual(@as(u32, 0x12345678), pixels[0]);
        try std.testing.expectEqual(@as(u32, 0x12345678), pixels[pixels.len - 1]);
        for (0..size.height) |y| for (size.width..stride) |x| try std.testing.expectEqual(@as(u32, 0x12345678), pixels[1 + y * stride + x]);
        try windowSend(&model, .{ .kind = .pointer_down, .code = 1, .x = @intCast(path.x + 6), .y = 12 }, size.width, size.height);
        try std.testing.expectEqual(visible, model.path_editor.cursor);
    }
    try std.testing.expectError(error.InvalidViewport, files.layout.WindowGeometry.init(316, 235, false, windowPath(316)));
    try std.testing.expectError(error.InvalidViewport, files.layout.WindowGeometry.init(316, 236, false, .{ .x = 104, .y = 20, .width = 112, .height = 24 }));
}

test "location editing below tabs preserves trusted caption and working navigation" {
    const width = 316;
    const height = 236;
    const path = try files.layout.WindowGeometry.navigationPath(width);
    try std.testing.expectEqual(@as(i32, 128), path.x);
    try std.testing.expectEqual(@as(i32, 36), path.y);
    var mock: Mock = .{};
    var model: files.Model = .{};
    try model.init(mock.provider(), "/container/Documents", "/container/Downloads");
    try model.dispatchWindow(.{ .kind = .pointer_down, .code = 1, .x = @intCast(path.x + 8), .y = @intCast(path.y + 12) }, width, height, path);
    try model.dispatchWindow(.{ .kind = .pointer_up, .code = 1, .x = @intCast(path.x + 8), .y = @intCast(path.y + 12) }, width, height, path);
    try std.testing.expect(model.path_editing and model.path_activations == 1);

    const untouched: u32 = 0x12345678;
    const memory = try std.testing.allocator.alloc(u32, width * height);
    defer std.testing.allocator.free(memory);
    @memset(memory, untouched);
    var surface = try ui.Surface.init(memory, width, height, width, .{ .red = 0xff0000, .green = 0xff00, .blue = 0xff });
    var workspace: files.Workspace = undefined;
    try files.renderWindowWithWorkspace(&surface, &workspace, &model, path);
    for (memory[0 .. width * files.layout.window_header_height]) |pixel| try std.testing.expectEqual(untouched, pixel);
    var location_ink: usize = 0;
    for (36..68) |y| for (128..252) |x| {
        if (memory[y * width + x] == surface.encode(files.colors.text)) location_ink += 1;
    };
    try std.testing.expect(location_ink > 20);

    try model.dispatchWindow(.{ .kind = .key_down, .code = 'a', .modifiers = ui.input.modifiers.control }, width, height, path);
    for ("~/Desktop") |byte| try model.dispatchWindow(.{ .kind = .text, .code = byte }, width, height, path);
    try model.dispatchWindow(.{ .kind = .key_down, .code = @backingInt(ui.input.Key.enter) }, width, height, path);
    try std.testing.expect(!model.path_editing and model.path_commits == 1);
    try std.testing.expectEqualStrings("/container/Desktop", model.panes[0].directory());
    try model.dispatchWindow(.{ .kind = .pointer_down, .code = 1, .x = 100, .y = 50 }, width, height, path);
    try model.dispatchWindow(.{ .kind = .pointer_up, .code = 1, .x = 100, .y = 50 }, width, height, path);
    try std.testing.expectEqualStrings("/container", model.panes[0].directory());
    try std.testing.expectError(error.InvalidViewport, files.layout.WindowGeometry.init(width, height, false, .{ .x = 128, .y = 60, .width = 124, .height = 32 }));
}

test "captured body releases over every header region clear gestures without actions" {
    const geometry = try files.Geometry.init(800, 600);
    for ([_]i16{ 20, 120, 780 }) |header_x| {
        var mock: Mock = .{};
        var model: files.Model = .{};
        try model.init(mock.provider(), "/container/Documents", "/container/Downloads");
        const row = geometry.row(0, 0);
        try windowSend(&model, .{ .kind = .pointer_down, .code = 1, .x = @intCast(row.x + 12), .y = @intCast(row.y + 32 + 10) }, 800, 632);
        try windowSend(&model, .{ .kind = .pointer_move, .x = @intCast(row.x + 30), .y = @intCast(row.y + 32 + 10) }, 800, 632);
        try std.testing.expect(model.drag != null and model.drag.?.moving);
        try windowSend(&model, .{ .kind = .pointer_up, .code = 1, .x = header_x, .y = 12 }, 800, 632);
        try std.testing.expect(model.drag == null and !model.path_editing);
        const downloads = geometry.sidebar(.downloads);
        try windowSend(&model, .{ .kind = .pointer_move, .x = @intCast(downloads.x + 20), .y = @intCast(downloads.y + 32 + 10) }, 800, 632);
        try windowSend(&model, .{ .kind = .pointer_up, .code = 1, .x = @intCast(downloads.x + 20), .y = @intCast(downloads.y + 32 + 10) }, 800, 632);
        try std.testing.expectEqual(@as(usize, 0), mock.moves + mock.copies);

        const up = geometry.button(.up);
        try windowSend(&model, .{ .kind = .pointer_down, .code = 1, .x = @intCast(up.x + 12), .y = @intCast(up.y + 32 + 12) }, 800, 632);
        try std.testing.expect(model.pressed_action == .up);
        try windowSend(&model, .{ .kind = .pointer_up, .code = 1, .x = header_x, .y = 12 }, 800, 632);
        try std.testing.expect(model.pressed_action == null and !model.path_editing);
        try windowSend(&model, .{ .kind = .pointer_up, .code = 1, .x = @intCast(up.x + 12), .y = @intCast(up.y + 32 + 12) }, 800, 632);
        try std.testing.expectEqualStrings("/container/Documents", model.panes[0].directory());

        try windowSend(&model, .{ .kind = .pointer_down, .code = 1, .x = @intCast(downloads.x + 20), .y = @intCast(downloads.y + 32 + 10) }, 800, 632);
        try std.testing.expect(model.pressed_shortcut == .downloads);
        try windowSend(&model, .{ .kind = .pointer_up, .code = 1, .x = header_x, .y = 12 }, 800, 632);
        try std.testing.expect(model.pressed_shortcut == null and !model.path_editing);

        model.panes[0].selected = 0;
        const more = geometry.button(.more);
        try windowSend(&model, .{ .kind = .pointer_down, .code = 1, .x = @intCast(more.x + 12), .y = @intCast(more.y + 32 + 12) }, 800, 632);
        try windowSend(&model, .{ .kind = .pointer_up, .code = 1, .x = @intCast(more.x + 12), .y = @intCast(more.y + 32 + 12) }, 800, 632);
        const menu = model.menu.?;
        const bounds = try files.MenuGeometry.init(800, 600, menu.kind, menu.anchor);
        const item = bounds.item(bounds.actionIndex(.nullify).?);
        try windowSend(&model, .{ .kind = .pointer_down, .code = 1, .x = @intCast(item.x + 12), .y = @intCast(item.y + 32 + 12) }, 800, 632);
        try std.testing.expect(model.menu.?.pressed != null);
        try windowSend(&model, .{ .kind = .pointer_up, .code = 1, .x = header_x, .y = 12 }, 800, 632);
        try std.testing.expect(model.menu == null and !model.path_editing);
        try windowSend(&model, .{ .kind = .pointer_up, .code = 1, .x = @intCast(item.x + 12), .y = @intCast(item.y + 32 + 12) }, 800, 632);
        try std.testing.expectEqual(@as(usize, 0), mock.nullifies);

        try windowSend(&model, .{ .kind = .key_down, .code = @backingInt(ui.input.Key.f2) }, 800, 632);
        const confirm = geometry.confirm();
        try windowSend(&model, .{ .kind = .pointer_down, .code = 1, .x = @intCast(confirm.x + 12), .y = @intCast(confirm.y + 32 + 12) }, 800, 632);
        try std.testing.expect(model.pressed_edit == .confirm);
        try windowSend(&model, .{ .kind = .pointer_up, .code = 1, .x = header_x, .y = 12 }, 800, 632);
        try std.testing.expect(model.pressed_edit == null and model.edit == .rename and !model.path_editing);
        try std.testing.expectEqual(@as(usize, 0), mock.moves);
    }
}
