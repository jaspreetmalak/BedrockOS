# Native Files client

This independent Zig package exports `files_app` and compile probe
`bedrock-files-app`. Its model/view imports public AxisUI, with no kernel,
filesystem or browser dependency. The protected entry adapter in `src/main.zig`
uses the host-supplied Bedrock64 runtime. The host supplies all authority through
[Provider callbacks](src/provider.zig); paths never select an app identity or
expose raw storage. Window ownership, title-bar controls and driver/service
integration belong to the host.

The default view is one file list with a Places sidebar, Back/Forward/Up controls,
a breadcrumb, Split/More controls and a small status row. There is no duplicate
heading beneath the host title bar. Split toggles a second folder list. Native
folder/document/home icons, preserved filename case and a size column use
AxisUI's shared font metrics and clipped icon renderer.

`Model.init(provider,left_directory,right_directory)!void` initializes caller
storage in place. `dispatch(event,width,height)!void` routes native events;
provider errors appear in the status row. `action(Action)` and `shortcut(Shortcut)`
expose controls to hosts. `renderWithWorkspace(surface,workspace,model)!void`
renders client bounds of at least 640×360. Retain `Model` and `Workspace` outside
small kernel stacks and serialize access. Views and callback data remain borrowed
only through synchronous calls. Command surfaces submit drawing without a
framebuffer pointer; the receiver rechecks client bounds and rights.

Frosted materials shade a frozen backdrop rather than accumulating alpha over
the previous frame. The charcoal/blue client tint uses opacity 170/255; the
sidebar, navigation, headers and status row use 195–215/255. Text, selected rows,
errors and pressed/hovered controls remain solid. Native callers attach their
immutable AxisUI `Backdrop` with `Surface.setBackdrop`; protected clients submit
material commands through the optional `CommandSink.materialRect` callback.
The receiver owns the wallpaper blur cache and clips requests to the window.
An absent backdrop/material callback uses a solid tint fallback. Files never
samples scanout or obtains another application's content.

Each folder view copies at most 32 entries, with 96-byte ASCII names and a
256-byte canonical absolute path. A larger listing shows “first 32 entries.”
Providers may impose tighter bounds. Duplicate/malformed names or nonprogressing
cursors fail before replacing the previous listing. Enumeration cursors are
valid for one listing; mutations refresh the views. Listing order is supplied
by the provider.

Select with the pointer or arrow keys. Enter, Open or a host-tagged unmoved
double-click opens a directory/file. A read callback provides a copied read-only
preview of the first 512 bytes; unsupported bytes become `?`. Escape or Up closes
it. A drag never opens an item. Home/Documents/Downloads are real sidebar
navigation controls and drop targets. Drag onto a sidebar folder, a directory
row or the other split view to move once on valid release. Ctrl held at drag
start or drop selects copy; releasing it early preserves that drag's copy intent.
Outside drops, same-folder empty-space drops and simple clicks do not mutate files.

Copy/Cut retain a copied source path; Paste uses the current active folder.
Ctrl+C/X/V are equivalent. Providers recheck authority at Paste. Failure keeps
the clipboard for explicit user action; successful Cut/Paste clears it.
File mutations live in a native right-click menu and the More menu, leaving one
compact navigation row. Right-click selects the targeted file/folder, or clears
selection on blank folder space. Open, Copy, Cut, Paste, Rename, Delete and Refresh
are contextual; blank-space menus offer New folder/New file. Missing callbacks,
read-only entries and inapplicable operations appear disabled. A matched left
press/release activates an enabled item once. Outside clicks and Escape dismiss;
keyboard navigation, refresh and geometry changes dismiss the old target too.
Tab switches folder focus in split view. Back/Forward
history retains eight copied locations per view; failed navigation leaves it
intact, and a successful new visit discards the forward branch. Alt+Left/Right/Up
navigate. F2 renames, F5 refreshes, and Delete performs ordinary removal.

The optional destructive **Nullify (overwrite + delete)** menu item is distinct
from Delete. It applies only to a writable file, requires a matched menu release,
and has no hotkey. The host supplies `Provider.nullify(context,path)!void` and
rechecks authority. The integrated Bedrock backend overwrites both logical
storage snapshots and deletes the file; this does not promise erasure of SSD
remapping, host backups or data another process already copied. Success visibly
reports “File nullified in Bedrock.” The model volatile-zeroes the full matching
preview/name/path buffers and matching clipboard storage; the renderer clears
its preview text scratch. Unrelated retained copies remain intact. A failure
reports “Nullify incomplete: storage may need recovery.” Deletion may have
committed before a later scrub/readback failure; Files never retries automatically.

Name editing supports insertion, cursor movement, Home/End, Backspace/Delete,
Enter and Escape. Captured mouse Create/Save and Cancel controls also work in
the breadcrumb row. Long names keep the text cursor visible. Unicode input is
explicitly unsupported in this first font/editor profile.

`Geometry.initMode(width,height,split)` shares draw/hit geometry; `init` selects
single view. The sole navigation row is 40 pixels, with 32-pixel
controls. The sidebar is 148 pixels wide, file rows 28 pixels, and status footer
24 pixels. `button(Action)`, `sidebar(Shortcut)`, `row`, `confirm` and `cancel`
expose rectangles to hosts/tests. Header `button` rectangles exist only for
Back/Forward/Up/Split/More; mutation actions have no hidden toolbar hit areas.
`MenuGeometry.init(width,height,kind,anchor)` clamps the 208-pixel popup to client
bounds. Its four-pixel padding surrounds 28-pixel rows; `item`, `itemAt` and
`actionIndex` share render/hit geometry. `MenuKind` and `menuActions(kind)` expose
file/directory/background/More choices. `Model.menu` records the anchor and
hover/press state, and `menuEnabled(Action)` exposes availability hints. Existing
actions 0–12 remain stable; Nullify is 13 and More is 14. `colors` and `materials`
export the palette. The frosted popup uses a translated clipped command surface
on both native pixel and protected command backends.

A host `redraw` event invalidates pixels while preserving history, selection,
scroll, clipboard, editing and preview. Code 1 cancels pointer gestures after
geometry/visibility changes and dismisses menus; code 0 preserves them for focus repaint. These
events and source directories grant no device or filesystem authority.

`Provider` contains opaque `context` and required `list(context,path,cursor)!?Entry`.
Entries copy name, kind, size and a read-only hint; every result must advance the
cursor, and null means EOF. Optional callbacks are open/read/write/create/mkdir/
copy/move/remove/nullify. Unavailable menu callbacks are disabled; unsupported
host/keyboard actions show a plain status message. Read/write take offsets
and slices; copy/move take complete source/destination paths. Validation failures
leave the namespace unchanged. An I/O failure may retain a complete old or new
committed snapshot; a poisoned provider requires fresh-mount recovery. The model
never retries a failed mutation automatically. Read-only hints do not replace
provider authorization, and collision policy belongs to the provider.

Run `zig build test check` with pinned Zig 0.17.0. Tests cover sidebar/split drag
behavior, clipboard/history, denied operations, keyboard/mouse editing,
double-click metadata, redraw preservation, path/enumeration bounds, previews
and pixel/command rendering at minimum/reference sizes. Menu tests cover all
viewport edges, contextual/read-only availability, outside/release cancellation,
stale-target dismissal, Nullify exact-once/error behavior, visible scoped results
and full matching-cache clearing. Material tests compare
both backends against an immutable blurred backdrop, verify unchanged output on
repaint, and check solid control/error ink and guarded stride. Standard target and
optimization options plus `-Drelocatable=true` apply. Host storage/authority and
workflow acceptance is recorded separately in the
[integrated verification](../../../docs/storage-and-files-verification.md).
The named emulator profile does not qualify physical hardware or a standalone
compositor.
