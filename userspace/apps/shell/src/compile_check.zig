const desktop_shell = @import("desktop_shell");

export fn bedrock_desktop_shell_compile_probe(pixels: [*]volatile u32, pixel_count: usize, width: u32, height: u32, stride: u32) callconv(.c) bool {
    var surface = desktop_shell.axisui.Surface.init(pixels[0..pixel_count], width, height, stride, .{
        .red = 0x00ff0000,
        .green = 0x0000ff00,
        .blue = 0x000000ff,
        .reserved = 0xff000000,
    }) catch return false;
    desktop_shell.render(&surface, "COMPILE PROBE") catch return false;
    return true;
}
