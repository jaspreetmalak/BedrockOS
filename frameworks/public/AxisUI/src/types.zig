//! Borrowed declarative view values. Child/text slices must live through render.
pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return .{ .r = r, .g = g, .b = b };
    }
};

pub const PixelMasks = struct {
    red: u32,
    green: u32,
    blue: u32,
    reserved: u32 = 0,
};

pub const Align = enum { start, center, end, stretch };
pub const Material = struct { tint: Color, opacity: u8 = 192 };

pub const Style = struct {
    inset: u16 = 0,
    spacing: u16 = 0,
    width: ?u16 = null,
    height: ?u16 = null,
    foreground_color: ?Color = null,
    background_color: ?Color = null,
    background_material: ?Material = null,
    border_color: ?Color = null,
    border_width: u8 = 0,
    radius: u16 = 0,
    font_scale: ?u8 = null,
    flex_weight: u16 = 0,
    alignment: Align = .stretch,
};

pub const View = struct {
    kind: union(enum) {
        text: []const u8,
        hstack: []const View,
        vstack: []const View,
        zstack: []const View,
        spacer: void,
    },
    style: Style = .{},

    pub fn padding(self: View, value: u16) View {
        var result = self;
        result.style.inset = value;
        return result;
    }
    pub fn gap(self: View, value: u16) View {
        var result = self;
        result.style.spacing = value;
        return result;
    }
    pub fn frame(self: View, width: ?u16, height: ?u16) View {
        var result = self;
        result.style.width = width;
        result.style.height = height;
        return result;
    }
    pub fn foreground(self: View, color: Color) View {
        var result = self;
        result.style.foreground_color = color;
        return result;
    }
    pub fn background(self: View, color: Color) View {
        var result = self;
        result.style.background_color = color;
        result.style.background_material = null;
        return result;
    }
    pub fn material(self: View, value: Material) View {
        var result = self;
        result.style.background_color = null;
        result.style.background_material = value;
        return result;
    }
    pub fn border(self: View, color: Color, width: u8) View {
        var result = self;
        result.style.border_color = color;
        result.style.border_width = width;
        return result;
    }
    pub fn cornerRadius(self: View, radius: u16) View {
        var result = self;
        result.style.radius = radius;
        return result;
    }
    pub fn scale(self: View, value: u8) View {
        var result = self;
        result.style.font_scale = value;
        return result;
    }
    pub fn flex(self: View, weight: u16) View {
        var result = self;
        result.style.flex_weight = weight;
        return result;
    }
    pub fn @"align"(self: View, alignment: Align) View {
        var result = self;
        result.style.alignment = alignment;
        return result;
    }
};

pub fn Text(bytes: []const u8) View {
    return .{ .kind = .{ .text = bytes } };
}
pub fn HStack(children: []const View) View {
    return .{ .kind = .{ .hstack = children } };
}
pub fn VStack(children: []const View) View {
    return .{ .kind = .{ .vstack = children } };
}
pub fn ZStack(children: []const View) View {
    return .{ .kind = .{ .zstack = children } };
}
pub fn Spacer() View {
    return (View{ .kind = .spacer }).flex(1);
}
