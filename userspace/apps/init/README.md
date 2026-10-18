# Native init programs

`src/window_supervisor.zig` builds as `bedrock-window-init`, the primary
[native window desktop](../../../docs/window-desktop.md) supervisor. The trusted
catalogue contains init 101, compositor 104, shell 107, Files 2 and Notes 108.
Its companion artifacts are `bedrock-window-server`, `bedrock-window-shell`,
`bedrock-window-files` and `bedrock-window-notes`. Init creates a pipe and passes
only its writer into the compositor, then launches shell and both GUI children
through the authorized `spawn_app` interface.

The compositor's 136-byte `WindowHeartbeat` contains 17 `u64` fields: server,
shell, Files and Notes PIDs; three client frame counters; independent Files/Notes
close and launch-request counters; configure sequence; presents; workspace;
tiled state; focused PID; and a zero reserved field. Init checks server identity,
monotonic counters and frame progress within each PID generation. After three
initial frames from each client it calls `window_ready` (`0x10d`, all arguments
zero). The kernel independently verifies five live processes, six surfaces and
actual frame publication/presentation. Readiness leaves the supervisor running.

Files and Notes are polled and reaped independently with `waitPoll(pid)`.
Starting a replacement requires the compositor to retire the old PID's last
snapshot and advance that application's closure generation. Normal status 0
close waits for a new shell launch request; a nonzero status restarts that
child. Startup frame progress is checked for each new generation. A Notes
protection fault reports 139 and leaves Files, shell and compositor running.
The deliberately requested Startup write fault is enabled only by acceptance
launch flags. App identity and authority always come from the kernel catalogue.

GUI clients use `window_client.Session.openWindow` with create kind 9, followed
by own-window resize/focus/close requests 10–12. Shell receives authenticated
workspace/tile/focus status 13 and requests launch of Files 2 or Notes 108.
Configure epochs and exact frame ACKs retain immutable snapshots across resize,
tiling and workspace changes; only the service can call `window_state`
(`0x624`) for trusted lifecycle observations. See the
[runtime contract](../../runtime/README.md#primary-native-window-profile).

Current pointer/keyboard input is polled from separate bounded device queues.
Per-device event order is retained, while cross-device chronology can vary
between polls; dependent automation waits for selection/caret/paint evidence.
An IRQ/event-driven input broker remains future work. The tested references
are QEMU/UEFI; these checks do not claim physical-hardware validation.

The older four-app desktop remains a separate regression profile:

`src/desktop_supervisor.zig` builds as `bedrock-desktop-init`. It launches the
installed compositor104, shell107 and Files2, inheriting a pipe writer only into
the compositor. Its authenticated 80-byte heartbeat reports peer PIDs, per-peer
frame progress, closure retirement and monotonic launch requests. Init waits for
three initial frames from each client before reporting `desktop_ready`.
It polls Files with `waitPoll`, reaps completed children, and waits for the
compositor to retire Files' reader leases before launching a requested new
generation. Nonzero Files exits are restarted automatically; normal close waits
for the shell's next launch request. Closing/minimizing never restarts shell or
compositor. PID markers come from actual process and heartbeat identities.

`src/display_supervisor.zig` retains the earlier bounded surface demonstration
with independent client105/client106 identities and repeated A fault/restart
cycles. It remains separate from the Files desktop and headless app workloads.

`src/supervisor.zig` builds as `bedrock-app-init`, the persistent installed-app
supervisor. It decodes the immutable startup record, creates a pipe, launches
observer and worker packages through the trusted `spawn_app` interface, and
passes only a pipe writer to the observer. It waits for a worker protection
fault, starts a fresh worker that verifies its persistent file and clean heap,
then keeps a persistent worker alongside the original observer. Heartbeats carry
the observer PID and a monotonically increasing sequence number.

The same supervisor performs three crash/restart cycles in the dedicated
acceptance profile and one in the production demonstration profile. Its
`application_ready` call reports the milestone to the kernel; it continues
waiting and restarting a failed worker after backoff. It keeps its pipe reader
and never exits merely because the initial workload is complete. Package IDs
and launch approval come from the kernel catalogue, not the app's arguments.

`src/main.zig` remains the historical bounded lifecycle acceptance program:

This separate Zig ELF executable uses the experimental Bedrock64 ABI. It creates
an IPC channel, launches a receive-only child, yields so its receive blocks, sends
six messages so the four-message mailbox blocks a sender, waits for status 42
and verifies null-read, zero-stack and code-boundary children exit with status
139. It then exercises timer sleep, yield, endpoint close/stale rejection and
bounded console output before exiting successfully.

It also checks unknown calls, invalid pointers, an oversized message and an
invalid image ID. `userspace/build.zig` builds the `bedrock-user-init` artifact
using the shared [runtime](../../runtime/README.md). This is a bounded acceptance
application. It is kept separate from the persistent supervisor so existing
lifecycle, IPC, file and network regressions retain their original workloads.
