# Native Notes app

Notes is a protected native Zig app with a private `/container/notes.txt`
document, a bounded 4096-byte ASCII editor and native AxisUI glass surfaces.
Its app-owned File/Edit/View menus are separate from the desktop system bar.

File exposes Save, Reload from disk and Close window. Reload is disabled while
unsaved changes exist; load/save use the same checked private file path as the
editor. Edit exposes deleting the previous/next character and inserting a new
line. View moves to the beginning or end through the existing editor navigation.
Alt+F/E/V opens a menu; arrows, Home/End, Enter and Escape operate it. Disabled
items cannot dispatch, and a pointer command needs a matched press/release.
Outside clicks dismiss without clicking through to the note or Save button.

Menus occupy the original toolbar's left region at local x12,y8,height30,
width `client_width-112`. The right Save button, fixed editor geometry, original
Axis Sans metrics and footer remain in place. Popups are bounded to the client
viewport, and configure/status/redraw cancellation clears menu captures.
Closing requests the existing window service to release the app cleanly.
The menus add no cross-app filesystem, framebuffer or device authority.
