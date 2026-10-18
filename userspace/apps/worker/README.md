# Worker application

`bedrock-app-worker` is a native protected ELF using trusted app ID 103.
Every start validates its startup identity/environment, denied launcher/system
calls and bundle writes, an initially zero 8 KiB BSS object, a fresh zeroed heap
allocation and transactional allocator exhaustion.

Launch argument 1 writes `FAULTED` into its private `/container/session.txt`,
leaves a file descriptor and allocation live, and executes an architectural
store into the RO/NX startup page. The resulting protection fault must retire
the process with status 139 and reclaim those resources. Argument 2 reads that
persistent file using a new process and heap, writes `RUNNING`, frees its
allocation, closes the file and exits with status 23. Argument 0 verifies the
retained file and remains alive as the normal persistent worker.

The supervisor repeats the fault/restart cycle while Observer remains alive
under a separate identity. These sources demonstrate lifecycle and sandbox
contracts; the workload is not a general desktop application.
