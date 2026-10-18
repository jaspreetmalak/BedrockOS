//! Loader-facing validation shares the kernel's original board format.
pub const validate = @import("mediatek/board.zig").validate;
