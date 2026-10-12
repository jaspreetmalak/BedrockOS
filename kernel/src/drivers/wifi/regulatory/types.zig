//! Original private policy types. Frequencies/bandwidths are exact kHz;
//! EIRP/conducted power are mBm and antenna gain is mBi (100 units per dB).
pub const DfsRegion = enum(u8) { unset, fcc, etsi, jp };
pub const Wmm = enum(u8) { none, etsi };
pub const Band = enum(u8) { ghz2 = 1, ghz5 = 2, ghz6 = 3 };
pub const Environment = enum(u8) { unknown, indoor, outdoor };
pub const Flags = struct {
    pub const no_ir: u32 = 1 << 0;
    pub const dfs: u32 = 1 << 1;
    pub const no_outdoor: u32 = 1 << 2;
    pub const no_indoor: u32 = 1 << 3;
    pub const no_ofdm: u32 = 1 << 4;
    pub const no_cck: u32 = 1 << 5;
    pub const no_ht40minus: u32 = 1 << 6;
    pub const no_ht40plus: u32 = 1 << 7;
    pub const no_80mhz: u32 = 1 << 8;
    pub const no_160mhz: u32 = 1 << 9;
    pub const auto_bw: u32 = 1 << 10;
    pub const ir_concurrent: u32 = 1 << 11;
    pub const no_320mhz: u32 = 1 << 12;
    pub const afc: u32 = 1 << 13;
    pub const all: u32 = (1 << 14) - 1;
};
pub const Rule = struct {
    start_khz: u32,
    end_khz: u32,
    max_bandwidth_khz: u32,
    max_eirp_mbm: i32,
    max_antenna_gain_mbi: ?i32 = null,
    psd_mbm_mhz: ?i32 = null,
    flags: u32 = 0,
    wmm: Wmm = .none,
};
/// The rule slice is borrowed immutable storage. Generated data has static
/// lifetime; a caller-supplied policy snapshot must own its copied rule storage.
pub const Country = struct { alpha2: [2]u8, dfs_region: DfsRegion = .unset, rules: []const Rule };
pub const Request = struct { band: Band, channel: u16, bandwidth_khz: u32 = 20_000 };
/// All proof fields are supplied by a trusted board/firmware adapter. Presence
/// in a country database never invents calibrated RX, antenna gain or TX power.
pub const ChannelCap = struct {
    band: Band,
    channel: u16,
    center_khz: u32,
    available_rx: bool = false,
    calibrated: bool = false,
    max_bandwidth_khz: u32 = 20_000,
    max_conducted_power_mbm: ?i32 = null,
    antenna_gain_mbi: ?i32 = null,
    flags: u32 = 0,
    wmm_etsi_configured: bool = false,
};
pub const Reasons = struct {
    pub const no_matching_rule: u32 = 1 << 0;
    pub const uncalibrated: u32 = 1 << 1;
    pub const receive_unavailable: u32 = 1 << 2;
    pub const no_ir: u32 = 1 << 3;
    pub const dfs: u32 = 1 << 4;
    pub const environment: u32 = 1 << 5;
    pub const unsupported_band: u32 = 1 << 6;
    pub const unsupported_bandwidth: u32 = 1 << 7;
    pub const power_unproven: u32 = 1 << 8;
    pub const antenna_gain: u32 = 1 << 9;
    pub const world: u32 = 1 << 10;
    pub const afc: u32 = 1 << 11;
    pub const wmm: u32 = 1 << 12;
    pub const no_ofdm: u32 = 1 << 13;
    pub const psd: u32 = 1 << 14;
    pub const no_cck: u32 = 1 << 15;
};
pub const Decision = struct {
    allow_passive_scan: bool = false,
    allow_initiate_tx: bool = false,
    center_khz: u32,
    bandwidth_khz: u32,
    max_eirp_mbm: ?i32 = null,
    max_conducted_power_mbm: ?i32 = null,
    flags: u32 = 0,
    reasons: u32 = 0,
};
