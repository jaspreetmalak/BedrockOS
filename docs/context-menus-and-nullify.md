# Native context menus and scoped Nullify

Files now has one compact 40-pixel header: Back/Forward/Up, breadcrumb and
Split/More. The old mutation command strip is removed. A native item right-click
menu selects the targeted file or folder; a background right-click clears the
selection and offers folder actions. More exposes named mutations without
crowding the header. All drawing remains Zig/AxisUI inside the protected Files
ELF, through clipped command surfaces and an immutable wallpaper material cache.

## Menu behavior

File menus offer Open, Copy, Cut, Paste, Rename, Delete, Nullify and Refresh.
Folder menus omit Nullify. Background menus offer New folder, New file, Paste,
Refresh and Split. Missing callbacks and inapplicable/read-only actions are
disabled. Copy/Cut/Paste and existing keyboard shortcuts retain their behavior.

Popups are 208 pixels wide, with four-pixel padding and 28-pixel rows. Placement
clamps to every client edge. Hover and pressed ink remain sharp over the native
frosted background. An enabled item activates once after a left press and release
inside the same row. Outside clicks and Escape dismiss; keyboard navigation,
refresh, scrolling and geometry changes discard stale targeted menus.

## Nullify authority and storage

The red **Nullify (overwrite + delete)** item is separate from ordinary Delete.
It applies only to a writable file and acts immediately on its matched menu
release, with no extra confirmation and no hotkey. A provider is an authority
boundary, so disabled UI is a convenience rather than the security check.

Protected Bedrock64 `nullify` (`0x135`) takes a readable canonical path pointer,
path byte length and zero reserved third argument. The kernel copies/checks the
path and rechecks trusted app identity, private-container write authority,
metadata ownership and mutable file kind. It denies bundles and directories;
the client receives no raw block device or whole-device sanitization grant.

The bounded durable backend builds a clean current tree without the selected
file, preserving other current files. It volatile-clears retained RAM snapshots
and normalizes unused record/path/data bytes. It then replaces both complete
logical disk banks, including unused payload padding and bank tails. For each
bank, payload/tail writes are flushed before its generation/CRC header is written
and flushed. Exact readback checks the expected header and serialized payload,
plus zero padding/tails. Only after both banks pass does the call return success.
The first clean bank is committed and verified before overwriting the former
active bank.

Files visibly reports **“File nullified in Bedrock”** on success. It volatile-zeroes
the complete matching preview, name and path buffers and matching clipboard
storage; the renderer clears preview text scratch. Another file's cached copy
is preserved. Copies already held by other processes are not revoked.

An I/O, flush or readback failure makes the live backend unusable until a fresh
mount. Old target data may remain, or deletion may have committed before a later
historical-bank scrub fails. Files clears its matching caches, reports
**“Nullify incomplete: storage may need recovery.”**, and never retries
automatically. Failed Nullify does not establish erasure or rollback.

## Scope of the guarantee

Success verifies the logical bytes managed by this dedicated Bedrock image.
It does not erase SSD-remapped NAND, host snapshots/backups, storage-controller
copies or data independently copied elsewhere. No physical storage hardware has
been qualified. This is not a claim of NIST certification, media purge or a
complete device-sanitization program.

[NIST SP 800-88 Revision 2](https://nvlpubs.nist.gov/nistpubs/SpecialPublications/NIST.SP.800-88r2.pdf),
section 3.1.1, explains that ordinary read/write interfaces cannot address all
past flash data when spare cells and wear leveling are involved. Bedrock's
logical-bank verification is bounded by that distinction; successful readback
does not prove inaccessible physical copies were sanitized.

## Verification

Acceptance passed on 2026-10-11. Independent package results pass in both Debug
and ReleaseSafe:

- Files: **31/31** native tests plus native compile checks; all six PIC checks
  cover x86-64, ARM64 with strict alignment and integer-only RV64.
- Filesystem: **35/35** native tests, including Nullify preflight, complete-bank
  overwrite/readback and injected failure handling.

Files tests cover contextual/disabled rows, every popup edge, canceled and stale
gestures, exact-once Nullify, unchanged ordinary Delete, visible scoped results,
full matching-cache clearing and preserved unrelated caches. Material tests
compare native and protected command pixels and unchanged output on repeated
render, with guarded stride and sharp destructive text.

The root `test check test-uefi test-desktop -j2` run passed **172/172 build steps**
in each optimization mode. This covers workspace native suites, all three
freestanding compile targets, the three UEFI smoke paths and actual desktop
workflows. Unchanged cached checks are included; build-step counts are not a
fresh native-test inventory. The default Debug build/install passed **106/106**
steps.

All **six workflows** passed across x86-64, ARM64 and RV64 in both modes:
**twelve normal boots, twenty-four protected client starts and twelve checked
close/resource-reclamation operations**. They retain file, clipboard, drag/drop,
editing, preview, navigation, window controls and abrupt-reboot acceptance,
and add actual background/item context menus and checked Nullify authority.

The six real Nullify actions were independently checked against **twelve
complete logical banks**. Inspection validates exact format, header/payload CRCs,
identical surviving payloads and zero free-record bytes, padding and tails.
The uniquely seeded old secret and nullified pathname are absent from the raw
image and after a fresh boot. Namespace-denial startup markers and the later
Nullify result-frame marker are required. Final capture waits for that result
frame's `ui_present`, rather than assuming partial drawing is complete.

The aggregate receipt `.zig-cache/context-nullify-verification.json` records
passed builds/workflows, log hashes, source hashes and installed artifact hashes.
Actual PNGs are under `zig-out/desktop-tests/{debug,safe}/`, named
`files-{arch}-first-{initial,background-context-menu,nullify-context-menu,nullified}.png`.
These local generated artifacts are ignored and later runs may replace captures.

Prior [Files UI](files-ui-verification.md),
[frosted materials](frosted-materials.md) and
[persistent storage](storage-and-files-verification.md) receipts remain historical
evidence for their respective milestones; this revision has its own completed
integrated acceptance.

Reproduce package checks with the pinned Zig compiler:

```text
cd userspace/apps/files
zig build test check
zig build test check -Doptimize=ReleaseSafe
cd ../../../filesystem
zig build test
zig build test -Doptimize=ReleaseSafe
```

Reproduce integrated acceptance from the workspace root:

```text
zig build test check test-uefi test-desktop -j2 --summary all
zig build test check test-uefi test-desktop -Doptimize=ReleaseSafe -j2 --summary all
zig build -j2 --summary all
```

These workflows qualify only
the named single-CPU QEMU UEFI references, not physical computers or a standalone
user-space compositor.
