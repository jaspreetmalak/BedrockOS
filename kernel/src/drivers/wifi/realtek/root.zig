// SPDX-License-Identifier: BSD-3-Clause
//! Native rtw89 protocol subset. No operational radio transport is provided.
pub const firmware = @import("firmware.zig");
pub const h2c = @import("h2c.zig");
pub const profiles = @import("profiles.zig");
pub const upstream_commit = "7d0a66e4bb9081d75c82ec4957c50034cb0ea449";
test {
    _ = @import("tests.zig");
}
