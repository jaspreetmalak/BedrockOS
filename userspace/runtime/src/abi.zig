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
pub const wait_flags = struct {
    pub const nohang: u64 = 1;
};

pub const syscall = struct {
    pub const getpid: u64 = 0x100;
    pub const spawn: u64 = 0x101; // Catalog image ID, endpoint token (or zero), retained rights.
    pub const exit: u64 = 0x102; // Unsigned exit status, bounded to 0..255.
    pub const wait: u64 = 0x103; // Direct child PID, or zero for any child; returns exit status.
    pub const yield: u64 = 0x104;
    pub const clock_ticks: u64 = 0x106; // Observed hardware-quantum clock.
    pub const startup_info: u64 = 0x107; // All arguments zero; installed app's immutable Startup address.
    pub const clock_read: u64 = 0x108; // Writable ClockTime address, reserved0, reserved0; read-only snapshot.
    pub const application_ready: u64 = 0x10a; // Trusted init's supervision milestone; all arguments zero.
    pub const display_ready: u64 = 0x10b; // Trusted display init's milestone; all arguments zero.
    pub const desktop_ready: u64 = 0x10c; // Installed desktop init's milestone; all arguments zero.
    pub const window_ready: u64 = 0x10d; // Native window init supervision milestone; all arguments zero.
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
    pub const spawn_app: u64 = 0x128; // Trusted installed package ID, launch argument, authorized pipe writer or zero.
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
    pub const surface_create: u64 = 0x600;
    pub const surface_map: u64 = 0x601;
    pub const surface_unmap: u64 = 0x602;
    pub const surface_submit: u64 = 0x603;
    pub const surface_release: u64 = 0x604;
    pub const surface_close: u64 = 0x605;
    pub const service_open: u64 = 0x610;
    pub const service_connect: u64 = 0x611;
    pub const service_send: u64 = 0x612;
    pub const service_receive: u64 = 0x613;
    pub const service_close: u64 = 0x614;
    pub const display_present: u64 = 0x620;
    pub const display_info: u64 = 0x621;
    pub const display_input: u64 = 0x622;
    pub const desktop_state: u64 = 0x623; // Authenticated compositor lifecycle observation, state, reserved0, reserved0.
    pub const window_state: u64 = 0x624; // Window server diagnostic: state, authenticated app ID, auxiliary value.
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
pub const clock_flags = struct {
    pub const available: u32 = 1;
    pub const utc: u32 = 2;
    /// Progress is estimated from observed approximately 10 ms timer quanta.
    pub const observed_quanta: u32 = 4;
    pub const clamped: u32 = 8;
};
pub const ClockTime = extern struct {
    /// Unix epoch seconds if UTC is set; otherwise the firmware local calendar.
    seconds: i64 = 0,
    nanoseconds: u32 = 0,
    flags: u32 = 0,
    /// Minutes east of UTC, or 2047 when firmware did not supply a timezone.
    utc_offset_minutes: i32 = 0,
    reserved: u32 = 0,
    observed_ticks: u64 = 0,

    pub fn isAvailable(self: ClockTime) bool {
        return self.flags & clock_flags.available != 0;
    }
};
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

pub const display = struct {
    pub const server: u64 = 104;
    pub const client_a: u64 = 105;
    pub const client_b: u64 = 106;
    pub const shell: u64 = 107;
    pub const files: u64 = 2;
    pub const notes: u64 = 108;
    pub const service: u64 = 1;
    pub const format: u32 = 1; // Packed 0x00RRGGBB pixels, tightly packed rows.
    pub const map_base: u64 = code + 0x800000;
    pub const map_stride: u64 = 0x400000;
    pub const map_slots: u64 = 4;
    pub const frame: u32 = 1;
    pub const ack: u32 = 2;
    pub const peer_closed: u32 = 3;
    pub const heartbeat: u32 = 4;
    pub const input: u32 = 5;
    pub const configure: u32 = 6;
    pub const close: u32 = 7;
    pub const launch: u32 = 8;
    pub const create_window: u32 = 9;
    pub const resize_window: u32 = 10;
    pub const focus_window: u32 = 11;
    pub const close_window: u32 = 12;
    pub const window_status: u32 = 13;
    pub const move_window: u32 = 14;
    pub const window_rejected: u32 = 15;
    pub const retire_window: u32 = 16;
    // Create/configure only: the client viewport includes the inner caption.
    // Only the shared center accessory receives app pixels and pointer input.
    pub const header_content: u32 = 1;
    pub const header_tabs: u32 = 2;
    pub const window_id_shift: u5 = 16;
    pub const window_id_mask: u32 = 0xffff0000;
};
pub const DesktopHeartbeat = extern struct {
    server_pid: u64 = 0,
    launch_requests: u64 = 0,
    shell_pid: u64 = 0,
    files_pid: u64 = 0,
    shell_frames: u64 = 0,
    files_frames: u64 = 0,
    files_closed: u64 = 0,
    configure_sequence: u64 = 0,
    presents: u64 = 0,
    reserved: u64 = 0,
};
pub const WindowHeartbeat = extern struct {
    server_pid: u64 = 0,
    shell_pid: u64 = 0,
    files_pid: u64 = 0,
    notes_pid: u64 = 0,
    shell_frames: u64 = 0,
    files_frames: u64 = 0,
    notes_frames: u64 = 0,
    files_closed: u64 = 0,
    notes_closed: u64 = 0,
    files_launch_requests: u64 = 0,
    notes_launch_requests: u64 = 0,
    configure_sequence: u64 = 0,
    presents: u64 = 0,
    workspace: u64 = 0,
    tiled: u64 = 0,
    focused_pid: u64 = 0,
    reserved: u64 = 0,
};
pub const SurfaceCreate = extern struct { width: u32, height: u32, format: u32 = display.format, reserved: u32 = 0 };
/// A window compositor's owned full-display scene accepts a same-coordinate
/// source/destination damage rectangle. Other surfaces retain whole-source
/// placement at x/y. Display-service authority and mapping rights still apply.
pub const PresentRequest = extern struct { surface_token: u64, x: i32, y: i32, width: u32, height: u32, sequence: u64 };
pub const DisplayInfo = extern struct { width: u32 = 0, height: u32 = 0, format: u32 = 0, reserved: u32 = 0 };
pub const DisplayInput = extern struct { kind: u32 = 0, code: u32 = 0, x: i32 = 0, y: i32 = 0, modifiers: u32 = 0, reserved: u32 = 0, sequence: u64 = 0 };
/// Kernel-authenticated peers. Submit, rather than send, creates frame grants.
/// Server replies address a peer by PID/app; receive replaces these with the
/// service sender's authenticated identity. ACK has no surface grant.
pub const ServiceMessage = extern struct {
    kind: u32 = 0,
    flags: u32 = 0,
    peer_pid: u64 = 0,
    peer_app: u64 = 0,
    surface: u64 = 0,
    sequence: u64 = 0,
    width: u32 = 0,
    height: u32 = 0,
    payload: [16]u8 = @splat(0),
};

/// Installed programs use a separate kernel-selected address layout. Fixture
/// programs retain their original one-page layout and three launch registers.
pub const application = struct {
    pub const init: u64 = 101;
    pub const observer: u64 = 102;
    pub const worker: u64 = 103;
    pub const startup_address: u64 = code + 0x30000;
    pub const heap_address: u64 = code + 0x140000;
    pub const heap_limit: u64 = 0x80000;
    pub const test_mode: u32 = 1;
};

/// Length-delimited launch bytes, without pointers or an embedded NUL. Unused
/// bytes and reserved fields must be zero. Arguments need no libc convention.
pub const Text = extern struct {
    length: u16 = 0,
    reserved: [6]u8 = @splat(0),
    bytes: [56]u8 = @splat(0),

    pub fn init(bytes: []const u8) error{ TextTooLong, InvalidText }!Text {
        if (bytes.len > 56) return error.TextTooLong;
        var result: Text = .{ .length = @intCast(bytes.len) };
        for (bytes, 0..) |byte, i| {
            if (byte == 0) return error.InvalidText;
            result.bytes[i] = byte;
        }
        return result;
    }

    pub fn slice(self: *const Text) []const u8 {
        return self.bytes[0..self.length];
    }
};

/// Immutable startup information copied by the trusted launcher into its own
/// RO/NX page. Heap capacity is the actual fully mapped lease, not a promise
/// of demand paging. Exec receives a fresh record and fresh zeroed heap.
pub const Startup = extern struct {
    version: u32 = 1,
    size: u32 = @sizeOf(Startup),
    pid: u64 = 0,
    parent: u64 = 0,
    app_id: u64 = 0,
    inherited_token: u64 = 0,
    launch_arg: u64 = 0,
    heap_base: u64 = application.heap_address,
    heap_capacity: u64 = 0,
    heap_length: u64 = 0,
    flags: u32 = 0,
    argc: u16 = 0,
    envc: u16 = 0,
    args: [8]Text = @splat(.{}),
    environment: [8]Text = @splat(.{}),
    reserved: [8]u8 = @splat(0),
};

// Launch arguments: parent PID (zero for init), one explicitly inherited IPC
// handle or pipe writer (zero if absent), then the caller's launch argument.
// Successful exec preserves PID/parent/profile, closes file/IPC/pipe descriptors
// and reissues stdout1; its inherited argument is zero. getpid is
// authoritative. x86: int 0x80, rax number/result, rdi/rsi/rdx arguments;
// ARM64: svc #0, x8 number, x0 result, x0/x1/x2 arguments;
// RV64: ecall, a7 number, a0 result, a0/a1/a2 arguments. Preserved registers and
// post-syscall PC survive blocking. No POSIX or foreign binary ABI is implied.
comptime {
    if (@sizeOf(ClockTime) != 32 or @alignOf(ClockTime) != 8 or @offsetOf(ClockTime, "observed_ticks") != 24 or
        @offsetOf(ClockTime, "nanoseconds") != 8 or @offsetOf(ClockTime, "utc_offset_minutes") != 16)
        @compileError("Bedrock64 wall clock layout changed");
    if (@sizeOf(WindowHeartbeat) != 136) @compileError("Bedrock64 window heartbeat layout changed");
    if (@sizeOf(DesktopHeartbeat) != 80) @compileError("Bedrock64 desktop heartbeat layout changed");
    if (@sizeOf(SurfaceCreate) != 16 or @sizeOf(PresentRequest) != 32 or @offsetOf(PresentRequest, "sequence") != 24 or
        @sizeOf(DisplayInfo) != 16 or @sizeOf(DisplayInput) != 32 or @offsetOf(DisplayInput, "sequence") != 24 or
        @sizeOf(ServiceMessage) != 64 or @offsetOf(ServiceMessage, "payload") != 48)
        @compileError("Bedrock64 display service layout changed");
    if (@sizeOf(Text) != 64 or @offsetOf(Text, "bytes") != 8 or @sizeOf(Startup) != 1112 or
        @offsetOf(Startup, "args") != 80 or @offsetOf(Startup, "environment") != 592 or
        @offsetOf(Startup, "reserved") != 1104)
        @compileError("Bedrock64 installed application startup layout changed");
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
