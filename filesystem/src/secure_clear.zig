//! Explicit volatile stores for filesystem-owned sensitive RAM. Caller-held
//! copies, registers, device caches and physical media are outside this helper.
pub fn bytes(storage: []u8) void {
    const destination: [*]volatile u8 = @ptrCast(storage.ptr);
    for (0..storage.len) |index| destination[index] = 0;
}
