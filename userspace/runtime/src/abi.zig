//! Bedrock64 v0: native, 64-bit, little-endian syscall and launch contract.
//! An experimental source ABI shared by the kernel and standalone user images.
pub const version: u64 = 0;
pub const page_size: u64 = 4096;
pub const code: u64 = 0x20_0000_0000;
pub const data: u64 = code + page_size;
pub const guard: u64 = code + 2 * page_size;
pub const stack: u64 = code + 3 * page_size;
pub const stack_top: u64 = code + 4 * page_size;
pub const max_payload: usize = 64;
pub const send_right: u64 = 1 << 8;
pub const receive_right: u64 = 1 << 9;
pub const max_path: usize = 128;
pub const max_io: usize = 256;
pub const fd_tag_file: u64 = @as(u64, 1) << 63;
pub const fd_tag_pipe: u64 = @as(u64, 1) << 62;
pub const open_flags = struct {
    pub const read: u64 = 1;
    pub const write: u64 = 2;
    pub const create: u64 = 4;
    pub const truncate: u64 = 8;
};
pub const descriptor_rights = struct {
    pub const read: u64 = 1;
    pub const write: u64 = 2;
};
pub const seek_whence = struct {
    pub const set: u64 = 0;
    pub const current: u64 = 1;
    pub const end: u64 = 2;
};

pub const syscall = struct {
    pub const getpid: u64 = 0x100;
    pub const spawn: u64 = 0x101; // Catalog image ID, endpoint token (or zero), retained rights.
    pub const exit: u64 = 0x102; // Unsigned exit status, bounded to 0..255.
    pub const wait: u64 = 0x103; // Direct child PID, or zero for any child; returns exit status.
    pub const yield: u64 = 0x104;
    pub const clock_ticks: u64 = 0x106; // Observed hardware-quantum clock.
    pub const sleep: u64 = 0x105; // Scheduler ticks; zero behaves as yield.
    pub const ipc_create: u64 = 0x110;
    pub const ipc_send: u64 = 0x111; // Endpoint token, input address, payload length.
    pub const ipc_receive: u64 = 0x112; // Endpoint token, output address, total buffer capacity.
    pub const close: u64 = 0x113;
    pub const write: u64 = 0x114; // Stdout1 or authorized file/pipe, input address, length <=256.
    pub const open: u64 = 0x120; // Path address, byte length <=128, open_flags.
    pub const read: u64 = 0x121; // File/pipe descriptor, output address, length <=256.
    pub const seek: u64 = 0x122; // File descriptor, bitcast i64 offset, seek_whence.
    pub const spawn_path: u64 = 0x123; // Executable path address/length, launch argument.
    pub const exec: u64 = 0x124; // Executable path address/length, launch argument; success never returns.
    pub const pipe: u64 = 0x125; // Writable PipePair address, reserved0, reserved0.
    pub const dup: u64 = 0x126; // Pipe descriptor, attenuated descriptor_rights, reserved0.
    pub const spawn_pipe: u64 = 0x127; // Executable path address/length, authorized pipe writer.
    pub const list: u64 = 0x130; // Directory path/length and writable DirectoryRecord.
    pub const mkdir: u64 = 0x131;
    pub const copy: u64 = 0x132; // Readable PathPair, reserved0, reserved0.
    pub const rename: u64 = 0x133;
    pub const unlink: u64 = 0x134;
    pub const nullify: u64 = 0x135; // Mutable private file path/length, reserved0; overwrite/delete both Bedrock banks.
    pub const udp_open: u64 = 0x140; // Readable UdpConnect, reserved0, reserved0.
    pub const udp_send: u64 = 0x141; // Socket token, readable whole datagram, length <=256.
    pub const udp_receive: u64 = 0x142; // Socket token, writable buffer, capacity <=256; nonblocking.
    pub const ui_geometry: u64 = 0x150; // Window-local width high32, height low32.
    pub const ui_event: u64 = 0x151; // Blocking eight-byte AxisUI event.
    pub const ui_rect: u64 = 0x152; // Readable DrawRect, reserved0, reserved0.
    pub const ui_present: u64 = 0x153;
    pub const ui_material: u64 = 0x154; // Readable DrawMaterial, reserved0, reserved0; clipped to this client.
    pub const ui_pending: u64 = 0x155; // Nonblocking host-routed event or zero; all arguments reserved0.
    pub const wifi_status: u64 = 0x160; // Writable WifiStatus, reserved0, reserved0; requires observation.
    pub const wifi_scan_start: u64 = 0x161; // All arguments zero; requires Wi-Fi control.
    pub const wifi_scan_read: u64 = 0x162; // Writable WifiScan, reserved0, reserved0; non-consuming snapshot.
    pub const wifi_join: u64 = 0x163; // Readable WifiJoin, reserved0, reserved0; transient credentials.
    pub const wifi_disconnect: u64 = 0x164; // All arguments zero; requires Wi-Fi control.
    pub const wifi_enable: u64 = 0x165; // Boolean 0/1, reserved0, reserved0; requires Wi-Fi control.
};
pub const image = struct {
    pub const init: u64 = 1;
    pub const service: u64 = 2;
    pub const fault: u64 = 3;
    pub const fault_stack: u64 = 4;
    pub const fault_boundary: u64 = 5;
    pub const io: u64 = 6;
    pub const exec: u64 = 7;
    pub const network: u64 = 8;
    pub const wifi: u64 = 9;
};
pub const errno = struct {
    pub const permission: u64 = fromSigned(-13);
    pub const no_entry: u64 = fromSigned(-2);
    pub const again: u64 = fromSigned(-11);
    pub const bad_descriptor: u64 = fromSigned(-9);
    pub const fault: u64 = fromSigned(-14);
    pub const invalid: u64 = fromSigned(-22);
    pub const no_memory: u64 = fromSigned(-12);
    pub const no_child: u64 = fromSigned(-10);
    pub const no_process: u64 = fromSigned(-3);
    pub const busy: u64 = fromSigned(-16);
    pub const broken_pipe: u64 = fromSigned(-32);
    pub const unknown: u64 = fromSigned(-38);
    pub const message_size: u64 = fromSigned(-90);
    pub const not_directory: u64 = fromSigned(-20);
    pub const not_seekable: u64 = fromSigned(-29);
    pub const io: u64 = fromSigned(-5);
    pub const exists: u64 = fromSigned(-17);
    pub const not_empty: u64 = fromSigned(-39);
    pub const read_only: u64 = fromSigned(-30);
    pub const file_too_large: u64 = fromSigned(-27);
    pub const network_unavailable: u64 = fromSigned(-100);
    pub const not_supported: u64 = fromSigned(-95);
    pub const stale: u64 = fromSigned(-116);
};
pub fn fromSigned(value: i64) u64 {
    return @bitCast(value);
}
/// Opaque tokens can use either sign bit; only the final 4095 values are errno.
pub fn isError(value: u64) bool {
    return value >= fromSigned(-4095);
}

/// receive writes this trusted header followed by length payload bytes and
/// returns their combined byte count. Sender identity is supplied by the kernel.
pub const MessageHeader = extern struct { sender: u64, length: u64 };
/// Nonblocking bounded pipes use tagged per-process descriptors, not global
/// object identities. Both endpoints are copied out atomically on success.
pub const PipePair = extern struct { reader: u64, writer: u64 };
pub const PathPair = extern struct { source: u64, source_length: u64, destination: u64, destination_length: u64 };
/// Address octets retain network order; the port follows the native LE ABI.
pub const UdpConnect = extern struct { address: [4]u8, port: u16, reserved: u16 = 0 };
/// All unused bytes must be zero. SSIDs are length-delimited binary bytes.
pub const WifiBss = extern struct {
    ssid: [32]u8 = @splat(0),
    bssid: [6]u8 = @splat(0),
    channel: u16 = 0,
    signal_dbm: i16 = 0,
    ssid_len: u8 = 0,
    security: u8 = 0,
};
pub const WifiScan = extern struct {
    generation: u64 = 0,
    count: u32 = 0,
    reserved: u32 = 0,
    entries: [16]WifiBss = @splat(.{}),
};
pub const WifiStatus = extern struct {
    revision: u64 = 0,
    current: WifiBss = .{},
    state: u8 = 0,
    failure: u8 = 0,
    simulated: u8 = 0,
    has_current: u8 = 0,
    reserved: [8]u8 = @splat(0),
};
pub const WifiJoin = extern struct {
    generation: u64,
    index: u32,
    credential_len: u8 = 0,
    reserved: [3]u8 = @splat(0),
    credential: [63]u8 = @splat(0),
    padding: u8 = 0,
};
pub const DirectoryRecord = extern struct {
    cursor: u64,
    name: [96]u8,
    size: u64,
    kind: u8,
    name_len: u8,
    read_only: u8,
    reserved: [5]u8,
};
pub const DrawRect = extern struct { x: u32, y: u32, width: u32, height: u32, color: u32, reserved: u32 = 0 };
/// Tint is standard 0x00RRGGBB and opacity is 0..255. The host supplies the
/// immutable blurred backdrop; requests never identify or read scanout memory.
pub const DrawMaterial = extern struct { x: u32, y: u32, width: u32, height: u32, tint: u32, opacity: u32, reserved: u64 = 0 };
pub const test_payload: u64 = 0xbedd_0064_1122_3344;
pub const fault_exit_status: u64 = 139;

// Launch arguments: parent PID (zero for init), one explicitly inherited IPC
// handle or pipe writer (zero if absent), then the caller's launch argument.
// Successful exec preserves PID/parent/profile, closes file/IPC/pipe descriptors
// and reissues stdout1; its inherited argument is zero. getpid is
// authoritative. x86: int 0x80, rax number/result, rdi/rsi/rdx arguments;
// ARM64: svc #0, x8 number, x0 result, x0/x1/x2 arguments;
// RV64: ecall, a7 number, a0 result, a0/a1/a2 arguments. Preserved registers and
// post-syscall PC survive blocking. No POSIX or foreign binary ABI is implied.
comptime {
    if (@sizeOf(WifiBss) != 44 or @offsetOf(WifiBss, "channel") != 38 or
        @sizeOf(WifiScan) != 720 or @offsetOf(WifiScan, "entries") != 16 or
        @sizeOf(WifiStatus) != 64 or @offsetOf(WifiStatus, "state") != 52 or
        @sizeOf(WifiJoin) != 80 or @offsetOf(WifiJoin, "credential") != 16)
        @compileError("Bedrock64 Wi-Fi layout changed");
    if (@sizeOf(UdpConnect) != 8 or @offsetOf(UdpConnect, "port") != 4 or @offsetOf(UdpConnect, "reserved") != 6)
        @compileError("Bedrock64 UDP request layout changed");
    if (@sizeOf(MessageHeader) != 16) @compileError("Bedrock64 message layout changed");
    if (@sizeOf(PipePair) != 16 or @offsetOf(PipePair, "writer") != 8)
        @compileError("Bedrock64 pipe descriptor layout changed");
    if (@sizeOf(DrawMaterial) != 32 or @offsetOf(DrawMaterial, "reserved") != 24)
        @compileError("Bedrock64 frosted material layout changed");
}
