# Observer application

`bedrock-app-observer` is a native protected ELF using trusted app ID 102.
It validates startup identity/environment, checks that launch/system/network
requests and bundle writes are denied, and exercises an 8 KiB BSS object and
the process-owned heap allocator.

It writes `OBSERVER` to its private `/container/session.txt`, retains the file
and a heap allocation, and reads that file on every scheduler tick while worker
instances write the same virtual path in their own container. A 16-byte pipe
heartbeat contains its original PID and a sequence number. Backpressure keeps
it alive without losing the next sequence number. It continues until its owner
terminates the process; acceptance cleanup belongs to the kernel.
