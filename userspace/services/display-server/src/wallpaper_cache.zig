//! Lossless bounded cache of the procedural wallpaper's flat horizontal spans.
//! Store this in persistent compositor memory, never on a userspace stack.
const ui = @import("axisui");
pub const max_width = 1280;
pub const max_height = 800;
pub const max_columns = 128;
pub const palette_capacity = 4096;
pub const hash_capacity = 8192;
pub const Error = ui.Error || error{ InvalidWallpaperDimensions, NonuniformSpan, PaletteCapacity, CacheUnavailable, CacheMismatch };

pub const Cache = struct {
    indices: [max_columns * max_height]u16 = undefined,
    palette: [palette_capacity]u32 = undefined,
    edges: [max_columns + 1]u16 = undefined,
    masks: ui.PixelMasks = undefined,
    width: u16 = 0,
    height: u16 = 0,
    columns: u16 = 0,
    palette_count: u16 = 0,
    valid: bool = false,

    /// The source must be the clean, already rendered wallpaper. Capture reads
    /// every pixel and rejects nonflat spans or an exhausted palette instead
    /// of approximating the image. Source, cache and hash storage are disjoint;
    /// the caller allocates the 16KiB hash outside the small userspace stack.
    pub fn build(self: *Cache, source: *const ui.Surface, hash: *[hash_capacity]u16) Error!void {
        self.valid = false;
        try source.validate();
        if (source.commands != null) return error.BackdropUnavailable;
        if (source.width > max_width or source.height > max_height) return error.InvalidWallpaperDimensions;
        self.width = @intCast(source.width);
        self.height = @intCast(source.height);
        self.columns = @intCast(@min(source.width, max_columns));
        self.palette_count = 0;
        self.masks = source.masks;
        @memset(hash, 0);
        for (0..@as(usize, self.columns) + 1) |column| self.edges[column] = @intCast(column * source.width / self.columns);
        for (0..source.height) |row| {
            const source_row = row * source.stride;
            for (0..self.columns) |column| {
                const left = self.edges[column];
                const right = self.edges[column + 1];
                const color = source.pixels[source_row + left];
                for (left + 1..right) |x| if (source.pixels[source_row + x] != color) return error.NonuniformSpan;
                const id = try self.intern(color, hash);
                self.indices[row * self.columns + column] = id;
            }
        }
        self.valid = true;
    }

    /// Paint exact encoded pixels into a matching format and geometry. Stride
    /// may differ: each target row's padding remains untouched. Validation is
    /// complete before the first write, and all surface metadata is preserved.
    pub fn paint(self: *const Cache, target: *ui.Surface) Error!void {
        if (!self.valid) return error.CacheUnavailable;
        try target.validate();
        if (target.commands != null) return error.BackdropUnavailable;
        if (target.width != self.width or target.height != self.height or
            target.masks.red != self.masks.red or target.masks.green != self.masks.green or
            target.masks.blue != self.masks.blue or target.masks.reserved != self.masks.reserved) return error.CacheMismatch;
        for (0..self.height) |row| {
            const target_row = row * target.stride;
            const cached_row = row * self.columns;
            for (0..self.columns) |column| {
                const color = self.palette[self.indices[cached_row + column]];
                for (self.edges[column]..self.edges[column + 1]) |x| target.pixels[target_row + x] = color;
            }
        }
    }

    fn intern(self: *Cache, color: u32, hash: *[hash_capacity]u16) Error!u16 {
        var mixed = (color ^ (color >> 16)) *% 0x7feb352d;
        mixed = (mixed ^ (mixed >> 15)) *% 0x846ca68b;
        var slot: usize = (mixed ^ (mixed >> 16)) & (hash_capacity - 1);
        while (hash[slot] != 0) {
            const id = hash[slot] - 1;
            if (self.palette[id] == color) return id;
            slot = (slot + 1) & (hash_capacity - 1);
        }
        if (self.palette_count == palette_capacity) return error.PaletteCapacity;
        const id = self.palette_count;
        self.palette[id] = color;
        self.palette_count += 1;
        hash[slot] = id + 1;
        return id;
    }
};

comptime {
    if (@sizeOf(Cache) > 225000) @compileError("Wallpaper cache exceeds the compositor's bounded writable-memory plan");
}
