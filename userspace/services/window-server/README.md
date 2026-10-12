# Window server policy

This native Zig package owns window geometry, focus and input routing. The
current kernel desktop host calls it and supplies protected clients, scanout
and input. It is not yet a separately executing service process. The package
owns no framebuffer, device, file or process authority.

`Window.init(width, height)` accepts screens from 800×600 through 16384×16384.
Floating frames are 704×460 at (48,72) on an 800×600 screen, and 960×620 at
(160,72) on a 1280×800 screen. Normal frames have a two-pixel border and a
32-pixel title strip. Maximized windows use the work area below the 42-pixel
desktop bar and above a 12-pixel bottom margin. Fullscreen uses the entire
screen and retains a 32-pixel title strip so its exit control stays available.
Every mode supplies at least a 640×360 client.

`frame()` and `surface()` describe the outer window. `client()` describes the
authorized application rectangle; `title()`, `borderWidth()`, `controlRect()`
and `controls()` supply chrome geometry. `controls()` returns four
`ControlRect { control, rect }` values: close, minimize and maximize on the
left, and fullscreen on the right. Each hitbox is 24×24; the host draws the
smaller traffic dots and fullscreen icon inside those hitboxes. `hovered` and
`pressed_control` are presentation state.

`route(event)` returns client-local events. Title drags and controls stay in
the service. A control executes only when the left button is released inside
the originally pressed hitbox. Client capture retains a release outside the
client so the application can cancel a drag. Geometry changes cancel pointer
capture. Wheel input requires both focus and a pointer inside the client.

`mode` is floating, maximized or fullscreen. `saved_geometry` retains the
floating frame; fullscreen remembers the preceding mode. `minimize()` hides
the window without closing it. `open()` restores visibility and clears the
distinct `closed` state. `toggleMaximize()`, `toggleFullscreen()` and
`restore()` preserve the prior geometry. `close()` marks the window closed;
the host must tear down its protected client and launch a fresh client on
reopen. The host also clears queued events and refreshes client geometry
after a mode change.

Focused visible windows reserve F11 for fullscreen, Escape only while
fullscreen, and Alt+F4 for close. Held F11 and Escape keys do not repeat mode
changes. Ordinary Escape remains available to application previews. Wire key
codes match AxisUI: F4 is 0x10a and F11 is 0x10b.

Run package checks with `zig build test` and `zig build test -Doptimize=ReleaseSafe`.
