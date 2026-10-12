# Native lifecycle acceptance applications

The package builds this source twice: `bedrock-user-service` receives six messages
through an inherited receive-only endpoint, validates the kernel-issued sender
header and payload, checks that sending is denied, sleeps and exits with status
42. `bedrock-user-fault` uses three launch modes: an actual architectural null
read, a yield after setting the user stack pointer to zero, and getpid at the
code page's final instruction with its return on the NX data page. The latter
two are catalog IDs for the same ELF artifact. Each expects exit status 139.

Both are separately linked ELF64 executables using the shared
[Bedrock64 runtime](../../runtime/README.md). They are bounded acceptance roles;
the service role does not implement a system-service process, VFS or display API.
