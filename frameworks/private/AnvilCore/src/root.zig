//! Trusted Anvil providers. This framework owns no discovery or app grants.
pub const anvil = @import("anvil");
pub const software = @import("software.zig");
pub const Image = software.Image;
pub const Access = software.Access;
pub const Software = software.Software;

test {
    _ = @import("tests.zig");
}
