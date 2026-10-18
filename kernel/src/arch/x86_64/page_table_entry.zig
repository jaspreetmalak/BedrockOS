//! Exact shared-table pointer checks account for hardware's Accessed update.
const address_mask: u64 = 0x000f_ffff_ffff_f000;
const present: u64 = 1;
const writable: u64 = 1 << 1;
const user: u64 = 1 << 2;
const accessed: u64 = 1 << 5;

pub fn matchesSharedTable(entry: u64, physical: u64) bool {
    if (physical == 0 or physical & address_mask != physical) return false;
    // Dirty belongs to leaf entries; only Accessed may change this pointer.
    return entry & ~accessed == physical | present | writable | user;
}

test "shared nonleaf table identity survives hardware Accessed updates only" {
    const t = @import("std").testing;
    const physical: u64 = 0x12345000;
    const pointer = physical | present | writable | user;
    try t.expect(matchesSharedTable(pointer, physical));
    try t.expect(matchesSharedTable(pointer | accessed, physical));
    try t.expect(!matchesSharedTable(pointer | accessed, physical + 4096));
    for ([_]u64{ present, writable, user }) |required|
        try t.expect(!matchesSharedTable((pointer | accessed) & ~required, physical));
    for ([_]u64{ 1 << 6, 1 << 7, 1 << 63 }) |unexpected|
        try t.expect(!matchesSharedTable(pointer | accessed | unexpected, physical));
    try t.expect(!matchesSharedTable(7, 0));
    try t.expect(!matchesSharedTable(pointer, physical + 1));
}
