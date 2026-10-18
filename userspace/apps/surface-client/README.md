# Native surface client

One `bedrock-surface-client` binary runs under separate installed identities
105 and 106. Each process owns a 320×240 logical RGB surface and renders its
native AxisUI view into a capability-controlled mapping. Submitting a frame
revokes its writable mapping. An authenticated display-service ACK confirms
the server has presented and released the read snapshot; the client then maps
its next frame explicitly.
Only one frame is in flight. The client retains its owner handle across frames,
uses mapping slot zero, and increments submission sequence numbers. Client B
waits twelve scheduler ticks between redraws; A waits two. Pixels are logical
`0x00RRGGBB`; the privileged broker converts them into the firmware's scanout
masks during presentation.

The native Toggle accent control changes the view after focused pointer input.
Events arrive from trusted service identity 104 with a checked sender PID.
Client B remains alive while init replaces A. After three acknowledged frames,
A argument 1 reads its revoked mapping and must fault with status 139 while
its surface and endpoint are still live. Argument 2 presents three frames,
closes its surface/connection and exits 23. Argument 0 remains persistent.

The same sources also check denied service publication, framebuffer metadata
and presentation, read-only owner mapping, invalid slots/handles and forged
service peers/surface grants. These are application surfaces, not framebuffer
access or arbitrary shared-memory authority.
This bounded demonstration has fixed windows and client-side title decoration.
It does not provide close/minimize/fullscreen controls or migrate Files to the
new service. App termination and restart are exercised by the installed init
workload, rather than window controls.
