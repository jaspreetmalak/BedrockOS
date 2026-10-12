# Timer preemption and saved user contexts

The three primary UEFI kernels extend their protected user-mode bring-up with
a single-CPU round-robin scheduler. A hardware timer interrupts a user task
that never yields. The kernel saves its native context, returns to the shared
scheduling policy, and enters the next task's private address space. A later
dispatch resumes the interrupted task's saved instruction and stack pointers.

## Code boundaries

`kernel/src/core/scheduler.zig` owns bounded task states, selection, quantum
accounting and terminal reasons. It contains no CPU register, interrupt or
firmware operations. `core/isolation.zig` supplies the boot-time workloads and
selects the current task's trusted mapping and handle records.

Architecture adapters retain native register state in bounded kernel-only
registries. An opaque context handle is never exposed as an application syscall
argument. The adapter verifies hardware interrupt provenance, saves the user
context before leaving its protected trap stack, and restores the trusted
kernel continuation. Existing protected paging and syscall/fault checks remain
in place. The bootloader, filesystem and boot protocol stay separate packages.

Context slots are reusable. Each kernel-only handle includes a slot and
generation; destroying a context invalidates the old handle before the slot can
serve another task. Generation exhaustion retires a slot instead of wrapping.
Context creation and resume also validate the referenced address space's root
and generation. Active contexts cannot be destroyed.

The kernel runs with interrupts masked while it changes scheduler, allocator,
handle and mapping state. User entry restores an unfinished hardware quantum,
or starts a new one after an acknowledged expiry, and enables only its timer
interrupt path. Cooperative returns mask delivery while retaining that quantum.
A verified timer interrupt consumes it before returning to the kernel. This is user-mode preemption, not kernel preemption
or an SMP scheduler.

x86 contexts preserve x87/SSE state through FXSAVE; AVX/XSAVE is not enabled.
ARM frames include SIMD/FP state, but EL0 FP/SIMD access remains trapped for
these integer fixtures. RV contexts are integer-only with FP/vector state
disabled. Enabling those application features requires extending the entry
and isolation contracts.

## Timer and platform contracts

| UEFI reference | Timer path | Scope |
| --- | --- | --- |
| x86-64 QEMU Q35, one CPU | PIT channel 0, legacy PIC IRQ0, IDT vector 32 | Explicit PC platform backend; x2APIC rejected, inherited xAPIC disabled; firmware legacy routing required |
| ARM64 QEMU virt, Cortex-A57 | Architectural non-secure physical timer and GICv2 PPI | Controller registers and interrupt binding come from the copied DTB; Security Extensions, GICv3 and unsupported bindings fail |
| RV64 QEMU virt, one hart, OpenSBI | SBI TIME and supervisor timer interrupts | DTB timebase and SBI extension availability are checked; machine firmware retains control of M mode |

The target quantum is approximately 10 ms. A timer tick is a scheduling event,
not a wall-clock API or a claim of precise application CPU accounting. No
unrelated device interrupts are enabled. ARM EL0 cannot change interrupt masks
or the kernel timer's control; x86 user IOPL stays zero; RISC-V timer control
remains privileged. Controller discovery does not imply support for every
physical computer, GIC revision or timer implementation.

Repeated cooperative yields retain the unfinished timer quantum, so they cannot
continually postpone a sleeping process's deadline. With no runnable process,
the kernel polls that hardware timer with interrupts masked and advances one
scheduler tick only after observing and acknowledging its real expiry. Each
observed expiry counts once; long kernel work and missed intervals do not
produce catch-up ticks. Sleep is measured in these scheduler ticks rather than
elapsed wall-clock time.

## Acceptance workload

The earlier five protection-fault probes and checked syscalls run first. Two
new saved contexts then use the existing private code/data/stack mappings.
Each initial context is destroyed and replaced before execution, so hardware
entry and resume also exercise a reused slot with a different generation.
Both workloads loop without making syscalls. They directly check their distinct
private sentinels, exercise stack/register state, and advance separate counters.

The core dispatches A, B, A, B, A, B. After each hardware timer return it requires:

- Exactly one new timer event and no syscall, exit or fault from that task.
- Its private progress counter has increased.
- Its sentinel is intact and the one-time entry counter is still exactly one.

The entry counter catches a false resume that restarts the program instead of
restoring the interrupted PC. After three quanta per task, the trusted core
marks both ready tasks stopped at the workload budget. All six timer returns,
context-resume verification and scheduling-completion markers are required by
both boot-test runners. Normal images perform the same workload before idling.

The core then destroys both saved contexts before releasing their private
address spaces. Architecture-owned table frames are reclaimed separately from
the core-owned code/data/stack frames. A space with any live context reference
rejects teardown, and translation invalidation precedes table-frame reuse.
The fixture's three payload-frame, one-handle and one-process charges are
released; permanent kernel mappings and trap stacks remain owned. Full app
accounting of page-table and kernel overhead is still outside this milestone.

Lifecycle checks also exercise partial table-build rollback at allocation caps
zero through three, reject stale handles and address-space references, and
repeat creation/cleanup for more than eight cycles. Allocator and fixture
accounting must return to their baseline after each completed cycle. This
verifies reusable ownership without adding an app loader or an exit/wait API.

Native policy tests cover fairness, sparse/empty queues, terminal tasks,
invalid transitions and atomic counter-overflow rejection. Timer-discovery tests
cover bounded FDT parsing, controller/parent selection, clock widths and rejected
bindings. The kernel interface
probe compiles actual scheduler transitions for all three required ISAs.

The preceding preemption milestone was verified on 2026-10-11 with Zig 0.17.0
and the documented QEMU profiles:
119 workspace native tests, 57 independent kernel tests and twelve cross-ISA
component probes passed in Debug and ReleaseSafe. Both 18-configuration boot
matrices passed, including all reset regressions and all six timer returns per
UEFI boot. ReleaseSafe x86 also passed with its kernel placed at `0x100000000`
and 4096 MiB RAM. Normal ReleaseSafe graphical images completed the same checks
on all three ISAs at 256 MiB and stayed alive until controlled QMP shutdown;
their framebuffers were captured and inspected. Physical hardware remains
unqualified.

## Remaining process work

These are fixed boot tasks, with one active CPU or hart and explicit ownership
cleanup. A zeroed page-backed kernel heap supplies kernel allocation.
The [native process milestone](native-processes.md) now builds on these adapters
with a static ELF catalog, user init, spawn/wait/exit, sleep/wakeup and blocking
capability IPC. Unfinished timer quanta survive cooperative returns, so frequent
yields cannot continually reset a sleeper's clock. Saved user register validation
contains invalid return state before it can reach a privileged return path.
General VFS descriptors, exec replacement, CPU affinity, interrupt-driven
device I/O and trusted resource brokers remain later work.
The complete [mandatory app sandbox](application-model.md), source compatibility
and desktop still depend on those mechanisms.

Direct-reset profiles retain their allocator/breakpoint regression scope. This
scheduler milestone applies to the three primary UEFI paths.

Primary implementation references: [Intel APIC system programming](https://cdrdv2-public.intel.com/812386/253668-sdm-vol-3a.pdf),
[QEMU Q35 interrupt-controller setup](https://github.com/qemu/qemu/blob/v10.1.0/hw/i386/pc_q35.c),
[Arm GICv2 architecture](https://documentation-service.arm.com/static/5f8ff196f86e16515cdbf969),
[Arm generic timer guide](https://documentation-service.arm.com/static/66c4754f32f35b31ceb317ff),
[SBI TIME](https://docs.riscv.org/reference/sbi/v3.0/ext-time.html) and
[RISC-V supervisor interrupt state](https://docs.riscv.org/reference/isa/v20260120/priv/supervisor.html).
