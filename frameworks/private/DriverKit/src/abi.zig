//! Private, versioned C ABI for separately packaged kernel driver modules.
//! No Zig error sets, slices, allocator tickets, or driver owners cross it.
const std = @import("std");
pub const major: u16 = 1;
pub const minor: u16 = 0;
pub const wifi_class: u32 = 1;
pub const note_type: u32 = 0x42524456;
pub const note_name: [8]u8 = "BEDROCK\x00".*;
pub const descriptor_magic: [8]u8 = "BDRVABI1".*;
pub const Capabilities = struct {
    pub const scan: u32 = 1;
    pub const wpa2_psk: u32 = 2;
};
pub const Status = enum(u32) { ok = 0, no_event = 1, invalid_abi = 2, unavailable = 3, failed = 4, retired = 5 };
pub const Allocation = extern struct { token: u64, base: u64, length: u64 };
pub const Host = extern struct {
    abi_major: u16 = major,
    abi_minor: u16 = minor,
    size: u32 = @sizeOf(Host),
    context: *anyopaque,
    /// Borrowed public boot-protocol POD, validated before module entry.
    /// The kernel retains its backing pages throughout the module lifetime.
    boot_info: *const anyopaque,
    boot_info_size: u32,
    reserved: u32 = 0,
    now_ms: u64,
    allocate: *const fn (*anyopaque, u64, u64, *Allocation) callconv(.c) u32,
    resolve: *const fn (*anyopaque, u64, *Allocation) callconv(.c) u32,
    release: *const fn (*anyopaque, u64) callconv(.c) u32,

    pub fn validate(self: *const Host) bool {
        return self.abi_major == major and self.abi_minor <= minor and self.size == @sizeOf(Host) and
            self.reserved == 0 and self.boot_info_size != 0;
    }
};
pub const Bss = extern struct {
    ssid: [32]u8 = @splat(0),
    bssid: [6]u8 = @splat(0),
    channel: u16 = 0,
    signal_dbm: i16 = 0,
    ssid_len: u8 = 0,
    security: u8 = 0,
    reserved: [4]u8 = @splat(0),
};
pub const EventKind = enum(u32) { none = 0, scan_result = 1, scan_complete = 2, joined = 3, failed = 4, link_lost = 5, ethernet = 6 };
/// A complete caller-owned copy; no receive-buffer pointer escapes the module.
pub const Event = extern struct {
    kind: u32 = @backingInt(EventKind.none),
    length: u32 = 0,
    operation: u64 = 0,
    bss: Bss = .{},
    bssid: [6]u8 = @splat(0),
    security: u8 = 0,
    authenticated: u8 = 0,
    failure: u8 = 0,
    reserved: [7]u8 = @splat(0),
    ethernet: [1280]u8 = @splat(0),
};
pub const ReportFlags = struct {
    pub const attempted: u32 = 1;
    pub const factory_power_intersected: u32 = 2;
    pub const dma_retained: u32 = 4;
};
pub const Report = extern struct {
    stage: u32 = 0,
    status: u32 = @backingInt(Status.unavailable),
    flags: u32 = 0,
    error_length: u32 = 0,
    error_text: [96]u8 = @splat(0),
};
/// The entry publishes this table before hardware initialization, allowing
/// failure reporting and quiescence without exporting private module state.
pub const Radio = extern struct {
    abi_major: u16 = major,
    abi_minor: u16 = minor,
    size: u32 = @sizeOf(Radio),
    context: ?*anyopaque = null,
    capabilities: u32 = 0,
    reserved: u32 = 0,
    enable: ?*const fn (*anyopaque, u8) callconv(.c) u32 = null,
    scan: ?*const fn (*anyopaque, u64) callconv(.c) u32 = null,
    join: ?*const fn (*anyopaque, u64, *const Bss, [*]const u8, u32, u64) callconv(.c) u32 = null,
    cancel: ?*const fn (*anyopaque, u64) callconv(.c) u32 = null,
    disconnect: ?*const fn (*anyopaque) callconv(.c) u32 = null,
    poll: ?*const fn (*anyopaque, u64, *Event) callconv(.c) u32 = null,
    send: ?*const fn (*anyopaque, [*]const u8, u32) callconv(.c) u32 = null,
    connected: ?*const fn (*anyopaque) callconv(.c) u8 = null,
    mac: ?*const fn (*anyopaque, *[6]u8) callconv(.c) u32 = null,
    stop: ?*const fn (*anyopaque) callconv(.c) u32 = null,
    report: ?*const fn (*anyopaque, *Report) callconv(.c) u32 = null,

    pub fn validate(self: *const Radio) bool {
        return self.abi_major == major and self.abi_minor <= minor and self.size == @sizeOf(Radio) and
            self.reserved == 0 and self.context != null and self.capabilities & ~@as(u32, 3) == 0 and
            self.enable != null and self.scan != null and self.join != null and self.cancel != null and
            self.disconnect != null and self.poll != null and self.send != null and self.connected != null and
            self.mac != null and self.stop != null and self.report != null;
    }
};
pub const Entry = *const fn (*const Host, *Radio) callconv(.c) u32;
/// The descriptor is file metadata, not a relocated pointer-bearing structure.
/// It lives in a readable nonwritable, nonexecutable PT_LOAD and PT_NOTE.
pub const Descriptor = extern struct {
    magic: [8]u8 = descriptor_magic,
    size: u32 = @sizeOf(Descriptor),
    abi_major: u16 = major,
    abi_minor: u16 = minor,
    class: u32 = wifi_class,
    module_version: u32 = 1,
    vendor: u16,
    product: u16,
    subsystem_vendor: u16 = 0xffff,
    subsystem_product: u16 = 0xffff,
    architecture: u16,
    reserved: u16 = 0,
    capabilities: u32,
    id: [24]u8,

    pub fn validate(self: *const Descriptor) bool {
        if (!std.mem.eql(u8, &self.magic, &descriptor_magic) or self.size != @sizeOf(Descriptor) or
            self.abi_major != major or self.abi_minor > minor or self.class != wifi_class or self.module_version == 0 or
            self.vendor == 0 or self.vendor == 0xffff or self.product == 0 or self.product == 0xffff or
            self.reserved != 0 or self.capabilities & ~@as(u32, 3) != 0) return false;
        var terminated = false;
        var length: usize = 0;
        for (self.id) |byte| {
            if (byte == 0) {
                terminated = true;
            } else {
                if (terminated or !(std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '-' or byte == '_')) return false;
                length += 1;
            }
        }
        return terminated and length != 0;
    }
    pub fn matches(self: *const Descriptor, vendor: u16, product: u16, subvendor: u16, subproduct: u16) bool {
        return self.validate() and self.vendor == vendor and self.product == product and
            (self.subsystem_vendor == 0xffff or self.subsystem_vendor == subvendor) and
            (self.subsystem_product == 0xffff or self.subsystem_product == subproduct);
    }
};
pub const Note = extern struct {
    name_size: u32 = note_name.len,
    descriptor_size: u32 = @sizeOf(Descriptor),
    kind: u32 = note_type,
    name: [8]u8 = note_name,
    descriptor: Descriptor,
};
comptime {
    if (@sizeOf(Allocation) != 24 or @sizeOf(Host) != 64 or @sizeOf(Bss) != 48 or
        @sizeOf(Event) != 1360 or @sizeOf(Report) != 112 or @sizeOf(Radio) != 112 or
        @sizeOf(Descriptor) != 64 or @sizeOf(Note) != 84 or @offsetOf(Note, "descriptor") != 20)
        @compileError("driver ABI layout changed; increment its major version");
}
test "descriptor version, bounded id, and subsystem matching are explicit" {
    var value: Descriptor = .{ .vendor = 0x14c3, .product = 0x0616, .architecture = 62, .capabilities = 3, .id = @splat(0) };
    @memcpy(value.id[0..18], "org.bedrock.mt7922");
    try std.testing.expect(value.matches(0x14c3, 0x0616, 1, 2));
    try std.testing.expect(!value.matches(0x14c3, 0x7921, 1, 2));
    value.subsystem_product = 2;
    try std.testing.expect(!value.matches(0x14c3, 0x0616, 1, 3));
    value.abi_major = 2;
    try std.testing.expect(!value.validate());
    value.abi_major = 1;
    value.id[23] = 'x';
    try std.testing.expect(!value.validate());
}
