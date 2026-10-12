//! Build probe only. This is not a boot entry point or a bootable image.
const bootloader = @import("bootloader");

export fn bedrock_bootloader_probe() callconv(.c) u32 {
    const header = bootloader.prepareHeader();
    header.validate(@sizeOf(@TypeOf(header)), bootloader.arch.kind) catch return 0;
    return @backingInt(bootloader.arch.kind);
}
