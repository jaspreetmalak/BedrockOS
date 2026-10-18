# Window server policy

This native Zig package supplies reusable window geometry, focus and input
routing. The primary protected display service uses it through
`display-server/src/window_main.zig` and `window_policy.zig`; retained desktop
hosts also call the same policy. The package itself owns no framebuffer,
device, file or process authority. The primary catalogue remains bounded to
two GUI clients and one window per client PID; see the
[native window guide](../../../docs/window-desktop.md).

`Window.init(width, height)` accepts screens from 800×600 through 16384×16384.
Floating frames are 704×460 at (48,72) on an 800×600 screen, and 960×620 at
(160,72) on a 1280×800 screen. Normal frames have a two-pixel border and a
32-pixel title strip. Maximized windows use the work area below the 42-pixel
desktop bar and above a 12-pixel bottom margin. Fullscreen uses the entire
screen and retains a 32-pixel title strip. These are `Window.init` defaults;
the primary compositor applies requested frame sizes and its own minimum of
320×240 outer pixels.

`frame()` and `surface()` describe the outer window. `client()` describes the
authorized application rectangle; `title()`, `borderWidth()`, `controlRect()`
and `controls()` supply chrome geometry. `hovered` and `pressed_control` are
presentation state. Primary windows set `modern_header = true`: the app name
is on the left, with rectangular Minimize, Maximize/Restore and Close controls
on the right. The protected compositor fills the modern caption with opaque
RGB `(20,21,26)`; wallpaper frosting applies to client panes. Shared
[header.zig](src/header.zig) places their 46×32 hitboxes at
`inner_width-138`, `inner_width-92` and `inner_width-46`, all at row zero with
no right-edge gap. Each 16-pixel icon is centered at local `(15,8)`. Minimize
and Maximize/Restore use transparent resting backgrounds and neutral hover/press
fills. Close uses a red hover fill, deeper red pressed fill and white X. The
modern fullscreen control has an empty rectangle; F11 and Escape handle fullscreen.

The compositor gives floating windows an 8-pixel outer radius and soft shadow.
Maximized, fullscreen and tiled frames have square corners and no floating
shadow. It applies the silhouette after permitted client pixels.

`modern_header` defaults to `false` so retained service-desktop and
kernel-hosted layouts stay consistent. Their `controls()` values retain close,
minimize and maximize on the left, and fullscreen on the right, each with a
24×24 hitbox for the original traffic dots or fullscreen icon.

The native SDK's `WindowOptions.header_content = true` opts into a client-owned
center accessory. The service sets `Window.header_content` and echoes the
validated flag in configure messages. `client()` then includes the full inner
frame, including the first 32 caption rows; `accessory()` supplies its global
center rectangle and `clientAt()` excludes all protected caption regions.
Without this option, `client()` starts below the 32-pixel caption.
`Session.headerLayout()` exposes the same layout in client-local coordinates
only while an opted-in viewport is visible. The title occupies `(12,0,84,32)`;
the accessory is `(104,4,inner_width-250,24)`, leaving an eight-pixel gap before
Minimize. At inner width 316 its accessory is `(104,4,66,24)`. The compositor
clips caption copies to this rectangle, so the app cannot paint the title or
controls. The accessory accepts generic native widgets; it is not a path-field
API. Files uses `AxisUI.tabs` there, with up to eight independent navigation
tabs. Its + button follows the last visible tab, or anchors at the right when
overflow arrows are present. Tab state and provider calls belong to Files;
this policy receives no filesystem authority.

Files' editable path lives below the title at client-local
`(128,36,inner_width-128-trailing,32)`, where `trailing` is 116 at widths of at
least 640 and 64 otherwise. The body still starts at row 32. These client widget
choices do not change the app-name region, service-owned colors, control
rectangles or input authority.
The kernel permits the header flag only on primary GUI create/configure messages,
rejects unknown bits, and stamps the sender's identity. The SDK validates service
provenance and shared layout bounds before exposing the accessory. Shell and
retained profiles keep zero flags.

Apps may also configure their own menu strips below the caption through AxisUI,
including a separate background and spacing. These strips are ordinary client
content; their customization does not delegate the title or caption controls.
The geometry changes do not alter the wire protocol, snapshot leases or
authority boundaries.

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
