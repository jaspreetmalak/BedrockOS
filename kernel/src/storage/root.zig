//! Kernel storage adapters will connect hardware drivers to this portable API.
pub const filesystem = @import("filesystem");
pub const BlockDevice = filesystem.BlockDevice;
