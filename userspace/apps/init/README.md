# First native init application

This separate Zig ELF executable uses the experimental Bedrock64 ABI. It creates
an IPC channel, launches a receive-only child, yields so its receive blocks, sends
six messages so the four-message mailbox blocks a sender, waits for status 42
and verifies null-read, zero-stack and code-boundary children exit with status
139. It then exercises timer sleep, yield, endpoint close/stale rejection and
bounded console output before exiting successfully.

It also checks unknown calls, invalid pointers, an oversized message and an
invalid image ID. `userspace/build.zig` builds the `bedrock-user-init` artifact
using the shared [runtime](../../runtime/README.md). This is a bounded acceptance
application, not yet a configurable service manager or general program launcher.
