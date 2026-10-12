// SPDX-License-Identifier: BSD-3-Clause
//! Intel protocol components. Identification and container inspection do not
//! initialize a device, authenticate firmware, or authorize radio operation.
pub const firmware = @import("firmware.zig");
pub const profiles = @import("profiles.zig");
pub const upstream_commit = "7d0a66e4bb9081d75c82ec4957c50034cb0ea449";

test {
    _ = @import("tests.zig");
}
