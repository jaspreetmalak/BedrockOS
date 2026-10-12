//! UEFI loader with firmware-allocated arenas and a relocated ELF64 kernel.
const std = @import("std");
const uefi = std.os.uefi;
const protocol = @import("boot_protocol");
const options = @import("boot_options");
const memory = @import("memory.zig");
const serial = @import("uart.zig");
const paging = @import("paging.zig");
const elf = @import("elf_loader");
const kernel_image = @embedFile("kernel_image");
const loader_capacity = 0x200000;
const kernel_capacity = 0x200000;
const raw_map_offset = 0x40000;
const raw_map_capacity = 0x40000;
const page_tables_offset = 0x80000;
const page_tables_capacity = 0x100000;
const transition_offset = 0x180000;
const context_offset = 0x181000;
const Transition = extern struct { entry: u64, info: u64, bytes: u64, cr3: u64, stack_top: u64 };
comptime {
    if (@sizeOf(Transition) != 40 or @offsetOf(Transition, "cr3") != 24)
        @compileError("transition context ABI changed");
}
extern var bedrock_uefi_transition_start: u8;
extern var bedrock_uefi_transition_end: u8;
extern fn bedrock_uefi_cr4() callconv(.c) u64;
extern fn bedrock_uefi_physical_bits() callconv(.c) u32;
extern fn bedrock_uefi_exit(status: u64) callconv(.c) noreturn;
extern fn bedrock_uefi_halt() callconv(.c) noreturn;
var exit_attempted = false;

pub const panic = std.debug.FullPanic(panicHandler);
fn halt(status: u64) noreturn {
    if (options.smoke_test) bedrock_uefi_exit(status);
    bedrock_uefi_halt();
}
fn panicHandler(message: []const u8, _: ?usize) noreturn {
    log("[panic] UEFI loader: ");
    log(message);
    log("\n");
    halt(1);
}
fn firmwareWrite(bytes: []const u8) void {
    const out = uefi.system_table.con_out orelse return;
    var buffer: [192:0]u16 = undefined;
    var position: usize = 0;
    for (bytes) |byte| {
        if (position + 2 >= buffer.len) {
            buffer[position] = 0;
            _ = out.outputString(&buffer) catch false;
            position = 0;
        }
        if (byte == '\n') {
            buffer[position] = '\r';
            position += 1;
        }
        buffer[position] = byte;
        position += 1;
    }
    buffer[position] = 0;
    _ = out.outputString(&buffer) catch false;
}
fn log(bytes: []const u8) void {
    if (options.smoke_test) serial.write(bytes) else if (!exit_attempted) firmwareWrite(bytes);
}
fn logHex(value: u64) void {
    const digits = "0123456789abcdef";
    var bytes: [18]u8 = undefined;
    bytes[0] = '0';
    bytes[1] = 'x';
    for (0..16) |index| bytes[index + 2] = digits[@intCast((value >> @as(u6, @intCast((15 - index) * 4))) & 15)];
    log(&bytes);
}
fn rsdpAddress() u64 {
    var legacy: u64 = 0;
    for (uefi.system_table.configuration_table[0..uefi.system_table.number_of_table_entries]) |entry| {
        if (entry.vendor_guid.eql(uefi.tables.ConfigurationTable.acpi_20_table_guid))
            return @intFromPtr(entry.vendor_table);
        if (entry.vendor_guid.eql(uefi.tables.ConfigurationTable.acpi_10_table_guid))
            legacy = @intFromPtr(entry.vendor_table);
    }
    return legacy;
}
fn framebuffer(bs: *uefi.tables.BootServices) !protocol.Framebuffer {
    const gop = (try bs.locateProtocol(uefi.protocol.GraphicsOutput, null)) orelse return error.NoGraphicsOutput;
    const mode = gop.mode;
    const info = mode.info;
    var result: protocol.Framebuffer = .{
        .base = mode.frame_buffer_base,
        .size = mode.frame_buffer_size,
        .width = info.horizontal_resolution,
        .height = info.vertical_resolution,
        .pixels_per_scanline = info.pixels_per_scan_line,
        .format = 1,
    };
    switch (info.pixel_format) {
        .red_green_blue_reserved_8_bit_per_color => {
            result.red_mask = 0xff;
            result.green_mask = 0xff00;
            result.blue_mask = 0xff0000;
        },
        .blue_green_red_reserved_8_bit_per_color => {
            result.red_mask = 0xff0000;
            result.green_mask = 0xff00;
            result.blue_mask = 0xff;
        },
        .bit_mask => {
            result.red_mask = info.pixel_information.red_mask;
            result.green_mask = info.pixel_information.green_mask;
            result.blue_mask = info.pixel_information.blue_mask;
        },
        .blt_only => return error.NoLinearFramebuffer,
    }
    try result.validate();
    return result;
}
fn descriptorCache(descriptor: *const uefi.tables.MemoryDescriptor) paging.Cache {
    const ram = switch (descriptor.type) {
        .loader_code, .loader_data, .boot_services_code, .boot_services_data, .runtime_services_code, .runtime_services_data, .conventional_memory, .acpi_reclaim_memory, .acpi_memory_nvs => true,
        else => false,
    };
    if (!ram) return .uncacheable;
    if (descriptor.attribute.wb) return .write_back;
    if (descriptor.attribute.wt) return .write_through;
    if (descriptor.attribute.wc) return .write_combining;
    if (descriptor.attribute.uc or descriptor.attribute.uce) return .uncacheable;
    return .write_back;
}
fn prepareMappings(map: uefi.tables.MemoryMapSlice, info: *protocol.BootInfo, physical_bits: u32) !u64 {
    const base = info.loader_reserved.base + page_tables_offset;
    const pool: [*]align(4096) u64 = @ptrFromInt(base);
    var builder = try paging.Builder.init(pool[0 .. page_tables_capacity / 8], base, physical_bits);
    const graphics_range: protocol.PhysicalRange = .{ .base = info.framebuffer.base, .length = info.framebuffer.size };
    const graphics_end = try graphics_range.endExclusive();
    var graphics_wc_bytes: u64 = 0;
    for (0..map.info.len) |index| {
        const descriptor = map.getUnchecked(index);
        const length = @mulWithOverflow(descriptor.number_of_pages, @as(u64, 4096));
        if (length[1] != 0) return error.PhysicalRangeOverflow;
        const range: protocol.PhysicalRange = .{ .base = descriptor.physical_start, .length = length[0] };
        const cache = descriptorCache(descriptor);
        const end = try range.endExclusive();
        const loader_end = try info.loader_reserved.endExclusive();
        // Page-table walks use WB for the pool itself. Reject firmware that
        // does not permit that policy rather than silently overriding it.
        if (range.base < loader_end and info.loader_reserved.base < end and cache != .write_back)
            return error.UnsupportedLoaderCachePolicy;
        try builder.map(range, cache);
        const overlap_base = @max(graphics_range.base, range.base);
        const overlap_end = @min(graphics_end, end);
        if (overlap_base < overlap_end and descriptor.attribute.wc)
            graphics_wc_bytes += overlap_end - overlap_base;
    }
    // Ownership validation already proves the arenas are described by EFI.
    // GOP uses WC only when every byte is covered by WC-capable descriptors.
    if (info.framebuffer.base != 0)
        try builder.map(graphics_range, if (graphics_wc_bytes == graphics_range.length) .write_combining else .uncacheable);
    // Q35 modern VirtIO devices have a 16KiB capability BAR. Retain only
    // assigned memory BARs of that vendor; PCI configuration uses port I/O.
    for (0..32) |slot| for (0..8) |function| {
        const identity = pciRead(@intCast(slot), @intCast(function), 0);
        if (identity & 0xffff != 0x1af4) continue;
        var bar: u8 = 0;
        while (bar < 6) : (bar += 1) {
            const low = pciRead(@intCast(slot), @intCast(function), 0x10 + bar * 4);
            if (low == 0 or low == 0xffffffff or low & 1 != 0) continue;
            var address: u64 = low & ~@as(u32, 15);
            if (low & 6 == 4) {
                if (bar == 5) return error.InvalidPciBar;
                address |= @as(u64, pciRead(@intCast(slot), @intCast(function), 0x14 + bar * 4)) << 32;
                bar += 1;
            }
            if (address == 0) continue;
            const registers: protocol.PhysicalRange = .{ .base = address, .length = 0x4000 };
            for (info.memory_regions[0..info.memory_region_count]) |region| {
                if (region.kind == @backingInt(protocol.MemoryKind.usable) and region.range.base < try registers.endExclusive() and address < try region.range.endExclusive())
                    return error.PciBarOverlapsRam;
            }
            try builder.map(registers, .uncacheable);
        }
    };
    builder.publish(info);
    return base;
}
fn pciRead(slot: u8, function: u8, offset: u8) u32 {
    const address: u32 = 0x80000000 | (@as(u32, slot) << 11) | (@as(u32, function) << 8) | offset;
    asm volatile ("outl %%eax, %%dx"
        :
        : [value] "{eax}" (address),
          [port] "{dx}" (@as(u16, 0xcf8)),
        : .{ .memory = true });
    return asm volatile ("inl %%dx, %%eax"
        : [value] "={eax}" (-> u32),
        : [port] "{dx}" (@as(u16, 0xcfc)),
        : .{ .memory = true });
}
fn copyTransition(base: u64) !void {
    const start = @intFromPtr(&bedrock_uefi_transition_start);
    const end = @intFromPtr(&bedrock_uefi_transition_end);
    if (end <= start or end - start > 4096) return error.InvalidTransitionBlock;
    const source: [*]const u8 = @ptrFromInt(start);
    const destination: [*]volatile u8 = @ptrFromInt(base + transition_offset);
    for (source[0 .. end - start], 0..) |byte, index| destination[index] = byte;
}
fn allocateKernel(bs: *uefi.tables.BootServices, buffer: []align(8) u8, alignment: u64) ![]align(4096) uefi.Page {
    if (options.kernel_min == 0) {
        // Retain alignment padding as owned kernel memory; no partially freed
        // allocation is exposed if firmware has an allocation/free failure.
        const capacity = kernel_capacity + alignment - 4096;
        return bs.allocatePages(.any, .loader_data, @intCast(capacity / 4096));
    }
    if (options.kernel_min % 4096 != 0) return error.UnalignedKernelMinimum;
    const map = try bs.getMemoryMap(buffer);
    for (0..map.info.len) |index| {
        const descriptor = map.getUnchecked(index);
        if (descriptor.type != .conventional_memory or descriptor.attribute.memory_runtime) continue;
        const length = @mulWithOverflow(descriptor.number_of_pages, @as(u64, 4096));
        if (length[1] != 0) return error.PhysicalRangeOverflow;
        const range: protocol.PhysicalRange = .{ .base = descriptor.physical_start, .length = length[0] };
        const minimum = @max(range.base, options.kernel_min);
        const rounded = @addWithOverflow(minimum, alignment - 1);
        if (rounded[1] != 0) continue;
        const candidate = rounded[0] & ~(alignment - 1);
        const end = @addWithOverflow(candidate, @as(u64, kernel_capacity));
        if (end[1] != 0 or end[0] > try range.endExclusive()) continue;
        return bs.allocatePages(.{ .address = @ptrFromInt(candidate) }, .loader_data, kernel_capacity / 4096) catch continue;
    }
    return error.NoKernelArenaAboveMinimum;
}
fn run(bs: *uefi.tables.BootServices) !noreturn {
    if (bedrock_uefi_cr4() & (1 << 12) != 0) return error.FiveLevelPagingUnsupported;
    const physical_bits = bedrock_uefi_physical_bits();
    if (physical_bits < 32 or physical_bits > 52) return error.PhysicalAddressingUnsupported;
    const address_limit = @min(paging.canonical_limit, @as(u64, 1) << @as(u6, @intCast(physical_bits)));
    const image = try elf.inspect(kernel_image, .x86_64);
    if (image.span > kernel_capacity) return error.KernelImageTooLarge;
    _ = bs.setWatchdogTimer(0, 0, null) catch {};
    const loader_pages = bs.allocatePages(.any, .loader_data, loader_capacity / 4096) catch
        return error.LoaderArenaUnavailable;
    defer if (!exit_attempted) bs.freePages(loader_pages) catch {};
    const loader_base = @intFromPtr(loader_pages.ptr);
    const loader_range: protocol.PhysicalRange = .{ .base = loader_base, .length = loader_capacity };
    if (loader_base == 0 or try loader_range.endExclusive() > address_limit)
        return error.LoaderArenaOutsideAddressableRange;
    const loader_bytes: [*]u8 = @ptrCast(loader_pages.ptr);
    @memset(loader_bytes[0..loader_capacity], 0);
    const map_buffer: [*]align(@alignOf(uefi.tables.MemoryDescriptor)) u8 = @ptrFromInt(loader_base + raw_map_offset);
    const buffer = map_buffer[0..raw_map_capacity];
    const kernel_pages = try allocateKernel(bs, buffer, image.alignment);
    defer if (!exit_attempted) bs.freePages(kernel_pages) catch {};
    const allocation_base = @intFromPtr(kernel_pages.ptr);
    const kernel_range: protocol.PhysicalRange = .{ .base = allocation_base, .length = kernel_pages.len * 4096 };
    if (allocation_base == 0 or try kernel_range.endExclusive() > address_limit)
        return error.KernelArenaOutsideAddressableRange;
    const kernel_base = (allocation_base + image.alignment - 1) & ~(image.alignment - 1);
    const kernel_bytes: [*]u8 = @ptrFromInt(kernel_base);
    const kernel_entry = try elf.load(kernel_image, .x86_64, kernel_bytes[0..kernel_capacity]);
    log("[bootloader] kernel physical base=");
    logHex(kernel_base);
    log(" loader physical base=");
    logHex(loader_base);
    log("\n");
    log("[bootloader] kernel image copied\n");
    const graphics = framebuffer(bs) catch |err| if (options.smoke_test) protocol.Framebuffer{} else return err;
    try copyTransition(loader_base);
    const info: *protocol.BootInfo = @ptrFromInt(loader_base);
    var header = protocol.Header.init(.x86_64);
    header.header_size = @sizeOf(protocol.BootInfo);
    info.* = .{
        .header = header,
        .uart_base = if (options.smoke_test) 0x3f8 else 0,
        .dtb = .{ .base = 0, .length = 0 },
        .kernel_image = .{ .base = kernel_base, .length = image.span },
        .ram = .{ .base = 0, .length = 0 }, // Populated from the final EFI map.
        .loader_reserved = .{ .base = loader_base, .length = loader_capacity },
        .kernel_reserved = .{ .base = allocation_base, .length = kernel_pages.len * 4096 },
        .flags = if (options.smoke_test) protocol.flag_smoke_exit else 0,
        .console = if (options.smoke_test) .{
            .kind = @backingInt(protocol.ConsoleKind.ns16550_io),
            .base = 0x3f8,
            .register_stride = 1,
            .clock_hz = 1843200,
            .baud_rate = 115200,
        } else .{ .kind = @backingInt(protocol.ConsoleKind.framebuffer), .base = graphics.base },
        .boot_environment = @backingInt(protocol.BootEnvironment.uefi),
        .entry_state = @backingInt(protocol.EntryState.x86_64_long_mode),
        .acpi_rsdp = rsdpAddress(),
        .framebuffer = graphics,
    };
    // Emit the last firmware diagnostic before the final map/key acquisition.
    const initial_map = try bs.getMemoryMap(buffer);
    try memory.populate(initial_map, info);
    _ = try prepareMappings(initial_map, info, physical_bits);
    try info.validate(@sizeOf(protocol.BootInfo), .x86_64);
    log("[bootloader] handoff ready\n");
    for (0..8) |_| {
        const map = try bs.getMemoryMap(buffer);
        try memory.populate(map, info);
        const cr3 = try prepareMappings(map, info, physical_bits);
        try info.validate(@sizeOf(protocol.BootInfo), .x86_64);
        // No boot-service or device-handle calls occur between this map/key
        // acquisition and ExitBootServices, or after the first exit attempt.
        exit_attempted = true;
        bs.exitBootServices(uefi.handle, map.info.key) catch |err| switch (err) {
            error.InvalidParameter => continue,
            else => return err,
        };
        if (options.smoke_test) serial.write("[bootloader] exit boot services\n");
        const context: *Transition = @ptrFromInt(loader_base + context_offset);
        context.* = .{ .entry = kernel_entry, .info = @intFromPtr(info), .bytes = @sizeOf(protocol.BootInfo), .cr3 = cr3, .stack_top = loader_base + loader_capacity };
        const jump: *const fn (*const Transition) callconv(.c) noreturn = @ptrFromInt(loader_base + transition_offset);
        jump(context);
    }
    return error.ExitBootServicesRetryLimit;
}
pub fn main() uefi.Status {
    if (options.smoke_test) serial.init();
    log("[bootloader] x86_64 firmware entry\n");
    log("[bootloader] UEFI application entry\n");
    const bs = uefi.system_table.boot_services orelse return .unsupported;
    run(bs) catch |err| {
        log("[fault] UEFI loader: ");
        log(@errorName(err));
        log("\n");
        if (exit_attempted or options.smoke_test) halt(1);
        return .load_error;
    };
}
