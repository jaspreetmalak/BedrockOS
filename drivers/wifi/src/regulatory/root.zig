//! Country/device policy intersection only. No application country authority,
//! radio activation, geolocation, DFS/AFC implementation or certification claim.
pub const types = @import("types.zig");
pub const database = @import("database.zig");
pub const DfsRegion = types.DfsRegion;
pub const Wmm = types.Wmm;
pub const Band = types.Band;
pub const Environment = types.Environment;
pub const Flags = types.Flags;
pub const Reasons = types.Reasons;
pub const Rule = types.Rule;
pub const Country = types.Country;
pub const ChannelCap = types.ChannelCap;
pub const Request = types.Request;
pub const Decision = types.Decision;
pub const Policy = @import("policy.zig");
pub const Error = Policy.Error;
pub const evaluate = Policy.evaluate;
pub const validateCountry = Policy.validateCountry;
pub const validateCaps = Policy.validateCaps;
pub const centerKhz = Policy.centerKhz;
pub const approvedScanList = Policy.approvedScanList;
pub const max_channel_caps = Policy.max_channel_caps;
pub const lookup = database.lookup;

test {
    _ = @import("tests.zig");
}
