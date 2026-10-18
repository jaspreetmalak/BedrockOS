//! Shared bounded AArch64/RV64 UEFI loader. Firmware owns pointer accessibility
//! while boot services are live; all retained data is copied into owned pages.
const std = @import("std");
const uefi = std.os.uefi;
const protocol = @import("boot_protocol");
const options = @import("boot_options");
const memory = @import("uefi_memory");
const elf = @import("elf_loader");
const fdt = @import("device_tree");
const wifi_assets = @import("wifi_assets.zig");
const driver_assets = @import("driver_assets.zig");
const app_assets = @import("app_assets.zig");
const kernel_image = @embedFile("kernel_image");
const arena_size = 0x200000;
const kernel_size = 0x400000;
const map_offset = 0x40000;
const map_capacity = 0x40000;
const dtb_offset = 0x80000;
const dtb_capacity = 0x80000;
const transition_offset = 0x180000;
const transition_capacity = 0x10000;
var exit_attempted = false;
var serial_ready = false;

const fdt_guid: uefi.Guid = .{
    .time_low = 0xb1b621d5,
    .time_mid = 0xf19c,
    .time_high_and_version = 0x41a5,
    .clock_seq_high_and_reserved = 0x83,
    .clock_seq_low = 0x0b,
    .node = .{ 0xd9, 0x15, 0x2c, 0x69, 0xaa, 0xe0 },
};

pub fn Panic(comptime Arch: type) type {
    return std.debug.FullPanic(struct {
        fn panic(message: []const u8, address: ?usize) noreturn {
            _ = address;
            log(Arch, "[panic] UEFI loader: ");
            log(Arch, message);
            log(Arch, "\n");
            Arch.stop(1);
        }
    }.panic);
}

fn firmwareWrite(bytes: []const u8) void {
    if (exit_attempted) return;
    const output = uefi.system_table.con_out orelse return;
    var buffer: [192:0]u16 = @splat(0);
    var count: usize = 0;
    for (bytes) |byte| {
        if (count >= buffer.len - 2) break;
        if (byte == '\n') {
            buffer[count] = '\r';
            count += 1;
        }
        buffer[count] = byte;
        count += 1;
    }
    buffer[count] = 0;
    _ = output.outputString(&buffer) catch false;
}

fn log(comptime Arch: type, bytes: []const u8) void {
    if (serial_ready and (options.smoke_test or exit_attempted)) Arch.write(bytes) else firmwareWrite(bytes);
}

fn logHex(comptime Arch: type, value: u64) void {
    var text: [18]u8 = undefined;
    text[0..2].* = "0x".*;
    for (0..16) |i| text[i + 2] = "0123456789abcdef"[@intCast((value >> @as(u6, @intCast((15 - i) * 4))) & 15)];
    log(Arch, &text);
}

fn logPlacement(comptime Arch: type, loader_base: u64, kernel_base: u64, span: u64) void {
    log(Arch, "\n[bootloader] loader arena=");
    logHex(Arch, loader_base);
    log(Arch, "\n[bootloader] kernel base=");
    logHex(Arch, kernel_base);
    log(Arch, " bytes=");
    logHex(Arch, span);
    log(Arch, "\n");
}

fn checkedEnd(base: u64, length: u64) !u64 {
    const sum = @addWithOverflow(base, length);
    if (sum[1] != 0) return error.AddressOverflow;
    return sum[0];
}
fn alignUp(value: u64, alignment: u64) !u64 {
    if (alignment == 0 or alignment & (alignment - 1) != 0) return error.InvalidAlignment;
    return (try checkedEnd(value, alignment - 1)) & ~(alignment - 1);
}
fn be32(address: usize) u32 {
    const p: [*]const volatile u8 = @ptrFromInt(address);
    return (@as(u32, p[0]) << 24) | (@as(u32, p[1]) << 16) | (@as(u32, p[2]) << 8) | p[3];
}

/// Trim only unused trailing FDT capacity, after the complete original blob
/// has passed the parser. EDK2 expands totalsize for later edits by over 1MiB.
/// Block offsets/content remain unchanged; the copied header names its new size.
fn compactDtbSize(address: usize, source_size: usize) !usize {
    var used: usize = 40;
    const structure_end = try checkedEnd(be32(address + 8), be32(address + 36));
    const strings_end = try checkedEnd(be32(address + 12), be32(address + 32));
    used = @intCast(@max(structure_end, strings_end));
    var reservation: usize = be32(address + 16);
    for (0..fdt.max_ranges + 1) |_| {
        if (reservation > source_size or source_size - reservation < 16) return error.InvalidDeviceTree;
        const empty = be32(address + reservation) == 0 and be32(address + reservation + 4) == 0 and
            be32(address + reservation + 8) == 0 and be32(address + reservation + 12) == 0;
        reservation += 16;
        if (empty) {
            used = @max(used, reservation);
            if (used > source_size or used > dtb_capacity) return error.DeviceTreeTooLarge;
            return used;
        }
    }
    return error.InvalidDeviceTree;
}

const Tables = struct { dtb: usize = 0, rsdp: u64 = 0 };
fn configurationTables() !Tables {
    if (uefi.system_table.number_of_table_entries > 1024) return error.TooManyConfigurationTables;
    var result: Tables = .{};
    var old_rsdp: u64 = 0;
    for (uefi.system_table.configuration_table[0..uefi.system_table.number_of_table_entries]) |table| {
        if (table.vendor_guid.eql(fdt_guid)) {
            if (result.dtb != 0) return error.DuplicateDeviceTree;
            result.dtb = @intFromPtr(table.vendor_table);
        } else if (table.vendor_guid.eql(uefi.tables.ConfigurationTable.acpi_20_table_guid)) {
            result.rsdp = @intFromPtr(table.vendor_table);
        } else if (table.vendor_guid.eql(uefi.tables.ConfigurationTable.acpi_10_table_guid)) {
            old_rsdp = @intFromPtr(table.vendor_table);
        }
    }
    if (result.rsdp == 0) result.rsdp = old_rsdp;
    return result;
}

fn graphics(bs: *uefi.tables.BootServices) !protocol.Framebuffer {
    const gop = (try bs.locateProtocol(uefi.protocol.GraphicsOutput, null)) orelse return error.MissingFramebuffer;
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
        else => return error.UnsupportedFramebuffer,
    }
    try result.validate();
    return result;
}

fn ramBacked(kind: uefi.tables.MemoryType) bool {
    return switch (kind) {
        .loader_code, .loader_data, .boot_services_code, .boot_services_data, .runtime_services_code, .runtime_services_data, .conventional_memory, .acpi_reclaim_memory, .acpi_memory_nvs => true,
        else => false,
    };
}

fn containsFirmwareRam(map: uefi.tables.MemoryMapSlice, range: protocol.PhysicalRange) !bool {
    const end = try range.endExclusive();
    var cursor = range.base;
    // Firmware need not return sorted descriptors. Advance only through a
    // descriptor that covers the current cursor, with a bounded number of hops.
    for (0..map.info.len) |_| {
        var next = cursor;
        for (0..map.info.len) |index| {
            const descriptor = map.getUnchecked(index);
            if (!ramBacked(descriptor.type)) continue;
            const bytes = @mulWithOverflow(descriptor.number_of_pages, @as(u64, 4096));
            if (bytes[1] != 0) return error.AddressOverflow;
            const limit = try checkedEnd(descriptor.physical_start, bytes[0]);
            if (descriptor.physical_start <= cursor and cursor < limit) next = @max(next, limit);
        }
        if (next >= end) return true;
        if (next == cursor) return false;
        cursor = next;
    }
    return false;
}

fn allocateKernel(bs: *uefi.tables.BootServices, raw_map: []align(@alignOf(uefi.tables.MemoryDescriptor)) u8, image: elf.Image) ![]align(4096) uefi.Page {
    const minimum: u64 = if (@hasDecl(options, "kernel_min")) options.kernel_min else 0;
    if (minimum == 0) {
        const size = try alignUp(try checkedEnd(image.span, image.alignment - 1), 4096);
        return bs.allocatePages(.any, .loader_data, @intCast(size / 4096));
    }
    const map = try bs.getMemoryMap(raw_map);
    if (map.info.len > 1024) return error.TooManyFirmwareDescriptors;
    for (0..map.info.len) |index| {
        const descriptor = map.getUnchecked(index);
        if (descriptor.type != .conventional_memory or descriptor.attribute.memory_runtime) continue;
        const bytes = @mulWithOverflow(descriptor.number_of_pages, @as(u64, 4096));
        if (bytes[1] != 0) return error.AddressOverflow;
        const end = try checkedEnd(descriptor.physical_start, bytes[0]);
        const start = try alignUp(@max(descriptor.physical_start, minimum), @max(image.alignment, 4096));
        if (try checkedEnd(start, image.span) > end) continue;
        return bs.allocatePages(.{ .address = @ptrFromInt(start) }, .loader_data, @intCast((try alignUp(image.span, 4096)) / 4096));
    }
    return error.NoKernelPlacement;
}

fn describeCoverage(map: uefi.tables.MemoryMapSlice, info: *protocol.BootInfo, bits: u32) !void {
    var coverage = try protocol.MappedRanges.init(bits);
    for (0..map.info.len) |index| {
        const descriptor = map.getUnchecked(index);
        if (!ramBacked(descriptor.type) or descriptor.number_of_pages == 0) continue;
        const bytes = @mulWithOverflow(descriptor.number_of_pages, @as(u64, 4096));
        if (bytes[1] != 0) return error.AddressOverflow;
        try coverage.add(.{ .base = descriptor.physical_start, .length = bytes[0] });
    }
    if (info.framebuffer.base != 0) try coverage.add(.{ .base = info.framebuffer.base, .length = info.framebuffer.size });
    if (info.console.kind == @backingInt(protocol.ConsoleKind.pl011))
        try coverage.add(.{ .base = info.console.base, .length = 0x48 })
    else if (info.console.kind == @backingInt(protocol.ConsoleKind.ns16550_mmio))
        try coverage.add(.{ .base = info.console.base, .length = @as(u64, info.console.register_stride) * 8 });
    // Named QEMU virt profiles: the copied DTB is required by these loaders.
    // These registers are never allocation candidates or user mappings.
    if (@import("builtin").cpu.arch == .aarch64) {
        try coverage.add(.{ .base = 0x0a000000, .length = 0x4000 });
        try coverage.add(.{ .base = 0x09000000, .length = 0x1000 });
    } else if (@import("builtin").cpu.arch == .riscv64) {
        try coverage.add(.{ .base = 0x10000000, .length = 0x9000 });
    }
    coverage.finalize(info);
}

fn preserveDtbReservations(info: *protocol.BootInfo, discovery: ?*const fdt.Discovery) !void {
    const parsed = discovery orelse return;
    if (parsed.reserved_count == 0) return;
    var builder: protocol.MemoryMap = .{};
    for (info.memory_regions[0..info.memory_region_count]) |region| {
        const kind: protocol.MemoryKind = @fromBackingInt(@intCast(region.kind));
        if (kind == .usable) try builder.addRam(region.range) else try builder.addReservation(region.range, kind);
    }
    for (parsed.reservations()) |range| try builder.addReservation(.{ .base = range.base, .length = range.length }, .reserved);
    try builder.finalize(info);
}

fn run(comptime Arch: type, bs: *uefi.tables.BootServices, loader: []align(4096) uefi.Page) !noreturn {
    const bits = try Arch.physicalBits();
    const layout = try elf.inspect(kernel_image, Arch.cpu_arch);
    if (layout.span != kernel_size or layout.alignment > kernel_size) return error.UnexpectedKernelLayout;
    try bs.setWatchdogTimer(0, 0, null);
    const loader_base = @intFromPtr(loader.ptr);
    const loader_bytes: [*]u8 = @ptrCast(loader.ptr);
    const raw_map: []align(@alignOf(uefi.tables.MemoryDescriptor)) u8 = @alignCast(loader_bytes[map_offset .. map_offset + map_capacity]);
    const kernel = try allocateKernel(bs, raw_map, layout);
    defer if (!exit_attempted) bs.freePages(kernel) catch {};
    const kernel_base = try alignUp(@intFromPtr(kernel.ptr), layout.alignment);
    const kernel_end = try checkedEnd(kernel_base, layout.span);
    const allocated_end = try checkedEnd(@intFromPtr(kernel.ptr), kernel.len * 4096);
    if (kernel_end > allocated_end) return error.UnexpectedKernelLayout;
    if (!options.smoke_test) logPlacement(Arch, loader_base, kernel_base, layout.span);

    const tables = try configurationTables();
    const fb = graphics(bs) catch protocol.Framebuffer{};
    var discovery: ?fdt.Discovery = null;
    var dtb_size: usize = 0;
    var selected_console: protocol.Console = .{};
    if (tables.dtb != 0) {
        // The config-table pointer itself is trusted firmware ABI input. A
        // descriptor-backed bound is established before reading even its header.
        const map = try bs.getMemoryMap(raw_map);
        if (map.info.len > 1024 or !(try containsFirmwareRam(map, .{ .base = tables.dtb, .length = 40 })))
            return error.UnbackedDeviceTree;
        if (be32(tables.dtb) != 0xd00dfeed) return error.InvalidDeviceTreeMagic;
        dtb_size = be32(tables.dtb + 4);
        log(Arch, "[bootloader] UEFI DTB base=");
        logHex(Arch, tables.dtb);
        log(Arch, " bytes=");
        logHex(Arch, dtb_size);
        log(Arch, "\n");
        if (dtb_size < 40) return error.TruncatedDeviceTree;
        // A bounded original capacity may exceed the copied arena when firmware
        // reserves trailing editing space; only validated live tables are kept.
        if (dtb_size > 0x1000000) return error.DeviceTreeTooLarge;
        if (!(try containsFirmwareRam(map, .{ .base = tables.dtb, .length = dtb_size }))) return error.UnbackedFullDeviceTree;
        const source_blob = @as([*]const u8, @ptrFromInt(tables.dtb))[0..dtb_size];
        discovery = if (!options.smoke_test and fb.base != 0) try fdt.parseHardware(source_blob) else try fdt.parse(source_blob);
        dtb_size = try compactDtbSize(tables.dtb, dtb_size);
        const parsed = &discovery.?;
        if (parsed.conflicts(.{ .base = loader_base, .length = arena_size }) or
            parsed.conflicts(.{ .base = @intFromPtr(kernel.ptr), .length = kernel.len * 4096 }))
            return error.DeviceTreeReservationConflict;
        if (parsed.console_available) {
            selected_console = .{
                .kind = switch (parsed.console.kind) {
                    .pl011 => @backingInt(protocol.ConsoleKind.pl011),
                    .ns16550_mmio => @backingInt(protocol.ConsoleKind.ns16550_mmio),
                },
                .base = parsed.console.range.base,
                .register_stride = parsed.console.register_stride,
                .clock_hz = parsed.console.clock_hz,
                .baud_rate = parsed.console.baud_rate,
            };
            try Arch.configure(selected_console);
            serial_ready = true;
            if (options.smoke_test) {
                Arch.write("[bootloader] " ++ Arch.name ++ " firmware entry\n");
                Arch.write("[bootloader] UEFI application entry\n");
                logPlacement(Arch, loader_base, kernel_base, layout.span);
            }
        }
        @memcpy(loader_bytes[dtb_offset .. dtb_offset + dtb_size], @as([*]const u8, @ptrFromInt(tables.dtb))[0..dtb_size]);
        std.mem.writeInt(u32, loader_bytes[dtb_offset + 4 ..][0..4], @intCast(dtb_size), .big);
    }
    if (options.smoke_test and !serial_ready) return error.MissingSerialConsole;
    if (!options.smoke_test and fb.base != 0) selected_console = .{
        .kind = @backingInt(protocol.ConsoleKind.framebuffer),
        .base = fb.base,
    } else if (!serial_ready) return error.MissingConsole;
    if (dtb_size == 0 and tables.rsdp == 0) return error.MissingHardwareDescription;

    const entry = try elf.load(kernel_image, Arch.cpu_arch, @as([*]u8, @ptrFromInt(kernel_base))[0..@intCast(layout.span)]);
    log(Arch, "[bootloader] kernel image copied\n");
    const transition = Arch.transitionBytes();
    if (transition.len == 0 or transition.len > transition_capacity) return error.TransitionTooLarge;
    @memcpy(loader_bytes[transition_offset .. transition_offset + transition.len], transition);
    Arch.publishCode(loader_base + transition_offset, transition.len);

    const info: *protocol.BootInfo = @ptrFromInt(loader_base);
    info.* = .{
        .header = protocol.Header.init(Arch.architecture),
        .uart_base = if (serial_ready) discovery.?.console.range.base else 0,
        .dtb = .{ .base = if (dtb_size == 0) 0 else loader_base + dtb_offset, .length = dtb_size },
        .kernel_image = .{ .base = kernel_base, .length = layout.span },
        .ram = .{ .base = 0, .length = 0 },
        .loader_reserved = .{ .base = loader_base, .length = arena_size },
        .kernel_reserved = .{ .base = @intFromPtr(kernel.ptr), .length = kernel.len * 4096 },
        .flags = if (options.smoke_test) protocol.flag_smoke_exit else 0,
        .console = selected_console,
        .boot_environment = @backingInt(protocol.BootEnvironment.uefi),
        .entry_state = @backingInt(Arch.entry_state),
        .acpi_rsdp = tables.rsdp,
        .framebuffer = fb,
    };
    info.header.header_size = @sizeOf(protocol.BootInfo);
    const address_limit = if (bits >= 64) std.math.maxInt(u64) else @as(u64, 1) << @as(u6, @intCast(bits));
    var wifi = wifi_assets.stage(bs, uefi.handle, address_limit) catch |err| failed: {
        log(Arch, "[bootloader] Wi-Fi assets unavailable: ");
        log(Arch, @errorName(err));
        log(Arch, "\n");
        break :failed wifi_assets.Outcome{};
    };
    defer if (!exit_attempted) {
        if (wifi.assets) |*assets| assets.release(bs) catch {};
    };
    if (wifi.assets) |*assets| {
        const reservation: protocol.PhysicalRange = .{ .base = @intFromPtr(assets.allocation.ptr), .length = assets.allocation.len };
        if (discovery) |*parsed| {
            if (parsed.conflicts(.{ .base = reservation.base, .length = reservation.length }))
                return error.DeviceTreeReservationConflict;
        }
        assets.publish(&info.wifi);
    }
    logWifiAssets(Arch, wifi);
    var driver = driver_assets.stage(bs, uefi.handle, switch (Arch.architecture) {
        .x86_64 => .x86_64,
        .aarch64 => .aarch64,
        .riscv64 => .riscv64,
    }, address_limit, options.driver_acceptance) catch |err| failed: {
        log(Arch, "[bootloader] driver module rejected: ");
        log(Arch, @errorName(err));
        log(Arch, "\n");
        break :failed null;
    };
    defer if (!exit_attempted) {
        if (driver) |*value| value.release(bs) catch {};
    };
    if (driver) |value| {
        if (discovery) |*parsed| if (parsed.conflicts(.{ .base = value.record.reservation.base, .length = value.record.reservation.length })) return error.DeviceTreeReservationConflict;
        info.drivers.count = 1;
        info.drivers.records[0] = value.record;
        log(Arch, "[bootloader] matching driver module staged\n");
    }
    var apps = app_assets.stage(bs, uefi.handle, switch (Arch.architecture) {
        .x86_64 => .x86_64,
        .aarch64 => .aarch64,
        .riscv64 => .riscv64,
    }, address_limit) catch |err| failed: {
        log(Arch, "[bootloader] application archive rejected: ");
        log(Arch, @errorName(err));
        log(Arch, "\n");
        break :failed null;
    };
    defer if (!exit_attempted) {
        if (apps) |*value| value.release(bs) catch {};
    };
    if (apps) |value| {
        if (discovery) |*parsed| if (parsed.conflicts(.{ .base = value.record.reservation.base, .length = value.record.reservation.length })) return error.DeviceTreeReservationConflict;
        info.apps = value.record;
        log(Arch, "[bootloader] application archive staged\n");
    }
    info.wall_clock = @import("wall_clock.zig").capture(uefi.system_table);
    var map = try bs.getMemoryMap(raw_map);
    try memory.populate(map, info);
    try preserveDtbReservations(info, if (discovery) |*parsed| parsed else null);
    try describeCoverage(map, info, bits);
    try info.validate(@sizeOf(protocol.BootInfo), Arch.architecture);
    log(Arch, "[bootloader] handoff ready\n");
    for (0..8) |_| {
        map = try bs.getMemoryMap(raw_map);
        try memory.populate(map, info);
        try preserveDtbReservations(info, if (discovery) |*parsed| parsed else null);
        try describeCoverage(map, info, bits);
        try info.validate(@sizeOf(protocol.BootInfo), Arch.architecture);
        exit_attempted = true;
        bs.exitBootServices(uefi.handle, map.info.key) catch |err| switch (err) {
            error.InvalidParameter => continue,
            else => return err,
        };
        // This is direct descriptor-selected MMIO, with no firmware call.
        if (options.smoke_test) Arch.write("[bootloader] exit boot services\n");
        // After ExitBootServices: no firmware protocols or allocator.
        const jump: *const fn (usize, usize, usize, usize, usize, usize) callconv(.c) noreturn = @ptrFromInt(loader_base + transition_offset);
        jump(@intCast(entry), loader_base, @sizeOf(protocol.BootInfo), loader_base, arena_size, loader_base + arena_size);
    }
    return error.ExitBootServicesRetriesExhausted;
}

fn logWifiAssets(comptime Arch: type, outcome: wifi_assets.Outcome) void {
    log(Arch, if (outcome.firmware == .ready) "[bootloader] Wi-Fi firmware assets verified\n" else "[bootloader] Wi-Fi firmware assets absent\n");
    if (outcome.firmware != .ready) return;
    log(Arch, switch (outcome.entropy) {
        .ready => "[bootloader] Wi-Fi EFI RNG seed acquired\n",
        .unavailable => "[bootloader] Wi-Fi EFI RNG unavailable\n",
        .failed => "[bootloader] Wi-Fi EFI RNG failed\n",
    });
    log(Arch, switch (outcome.profile) {
        .ready => "[bootloader] Wi-Fi board profile validated\n",
        .absent => "[bootloader] Wi-Fi board profile absent\n",
        .invalid => "[bootloader] Wi-Fi board profile rejected\n",
    });
}

pub fn main(comptime Arch: type) uefi.Status {
    if (!options.smoke_test) {
        log(Arch, "[bootloader] " ++ Arch.name ++ " firmware entry\n");
        log(Arch, "[bootloader] UEFI application entry\n");
    }
    const bs = uefi.system_table.boot_services orelse return .unsupported;
    // The bounded parser/map/ELF metadata needs more Debug stack than some
    // firmware provides. Allocate and zero our arena before entering that code;
    // the architecture thunk restores the original firmware SP on errors.
    const loader = bs.allocatePages(.any, .loader_code, arena_size / 4096) catch return .out_of_resources;
    const loader_bytes: [*]u8 = @ptrCast(loader.ptr);
    @memset(loader_bytes[0..arena_size], 0);
    const Context = struct { services: *uefi.tables.BootServices, pages: []align(4096) uefi.Page };
    var context: Context = .{ .services = bs, .pages = loader };
    const Call = struct {
        fn enter(raw: *anyopaque) callconv(.c) usize {
            const ctx: *Context = @ptrCast(@alignCast(raw));
            run(Arch, ctx.services, ctx.pages) catch |err| {
                log(Arch, "[fault] UEFI loader: ");
                log(Arch, @errorName(err));
                log(Arch, "\n");
                if (exit_attempted or options.smoke_test) Arch.stop(1);
                return @backingInt(uefi.Status.load_error);
            };
        }
    };
    const status = Arch.runOnStack(Call.enter, &context, @intFromPtr(loader.ptr) + arena_size);
    if (!exit_attempted) bs.freePages(loader) catch {};
    return @fromBackingInt(@intCast(status));
}
