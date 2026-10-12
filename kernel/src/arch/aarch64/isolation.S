/* Owned EL1 translation and protected cooperative/preemptive continuations. */
.section .text.isolation, "ax"
.balign 16
.global bedrock_arm_current_ttbr
.type bedrock_arm_current_ttbr, %function
bedrock_arm_current_ttbr:
    mrs x0, ttbr0_el1
    ret
.size bedrock_arm_current_ttbr, . - bedrock_arm_current_ttbr
.global bedrock_arm_current_cpacr
.type bedrock_arm_current_cpacr, %function
bedrock_arm_current_cpacr:
    mrs x0, cpacr_el1
    ret
.size bedrock_arm_current_cpacr, . - bedrock_arm_current_cpacr
.global bedrock_arm_current_sp
.type bedrock_arm_current_sp, %function
bedrock_arm_current_sp:
    mov x0, sp
    ret
.size bedrock_arm_current_sp, . - bedrock_arm_current_sp
.global bedrock_arm_current_user_sp
.type bedrock_arm_current_user_sp, %function
bedrock_arm_current_user_sp:
    mrs x0, sp_el0
    ret
.size bedrock_arm_current_user_sp, . - bedrock_arm_current_user_sp
.global bedrock_arm_current_daif
.type bedrock_arm_current_daif, %function
bedrock_arm_current_daif:
    mrs x0, daif
    ret
.size bedrock_arm_current_daif, . - bedrock_arm_current_daif
.global bedrock_arm_current_cntkctl
.type bedrock_arm_current_cntkctl, %function
bedrock_arm_current_cntkctl:
    mrs x0, cntkctl_el1
    ret
.size bedrock_arm_current_cntkctl, . - bedrock_arm_current_cntkctl
.global bedrock_arm_refresh_tables
.type bedrock_arm_refresh_tables, %function
bedrock_arm_refresh_tables:
    dsb ishst
    tlbi vmalle1
    dsb ish
    isb
    ret
.size bedrock_arm_refresh_tables, . - bedrock_arm_refresh_tables
.global bedrock_arm_retire_tables
.type bedrock_arm_retire_tables, %function
bedrock_arm_retire_tables:
    /* Only the permanent kernel root is active. Publish the invalid private
     * descriptors, retire all ASID0/global walk and translation cache state,
     * and invalidate old user instruction aliases before frames are reused. */
    dsb ishst
    tlbi vmalle1
    dsb ish
    ic iallu
    dsb ish
    isb
    ret
.size bedrock_arm_retire_tables, . - bedrock_arm_retire_tables
.global bedrock_arm_device_barrier
.type bedrock_arm_device_barrier, %function
bedrock_arm_device_barrier:
    dsb sy
    ret
.size bedrock_arm_device_barrier, . - bedrock_arm_device_barrier
.global bedrock_arm_timer_initialize
.type bedrock_arm_timer_initialize, %function
bedrock_arm_timer_initialize:
    msr daifset, #0xf
    msr cntkctl_el1, xzr /* No EL0 timer programming or counter access. */
    mrs x0, sctlr_el1
    bic x0, x0, #(1 << 9) /* UMA must not let EL0 mask timer IRQs. */
    msr sctlr_el1, x0
    mov x0, #2
    msr cntp_ctl_el0, x0
    msr cntv_ctl_el0, x0
    isb
    mrs x0, cntfrq_el0
    ret
.size bedrock_arm_timer_initialize, . - bedrock_arm_timer_initialize
.global bedrock_arm_timer_stop
.type bedrock_arm_timer_stop, %function
bedrock_arm_timer_stop:
    mov x0, #2
    msr cntp_ctl_el0, x0
    isb
    dsb sy
    ret
.size bedrock_arm_timer_stop, . - bedrock_arm_timer_stop
.global bedrock_arm_timer_status
.type bedrock_arm_timer_status, %function
bedrock_arm_timer_status:
    mrs x0, cntp_ctl_el0
    ret
.size bedrock_arm_timer_status, . - bedrock_arm_timer_status
.global bedrock_arm_timer_now
.type bedrock_arm_timer_now, %function
bedrock_arm_timer_now:
    isb
    mrs x0, cntpct_el0
    ret
.size bedrock_arm_timer_now, . - bedrock_arm_timer_now
.global bedrock_arm_timer_arm
.type bedrock_arm_timer_arm, %function
/* Kernel-root polling path: DAIF stays masked throughout this call. */
bedrock_arm_timer_arm:
    msr cntp_cval_el0, x0
    mov x1, #1
    msr cntp_ctl_el0, x1
    isb
    dsb sy
    ret
.size bedrock_arm_timer_arm, . - bedrock_arm_timer_arm

.global bedrock_arm_enable_mmu
.type bedrock_arm_enable_mmu, %function
bedrock_arm_enable_mmu:
    /* MAIR: Device-nGnRnE, normal WB, normal NC, normal WT. */
    movz x2, #0xff00
    movk x2, #0xbb44, lsl #16
    msr mair_el1, x2
    msr tcr_el1, x1
    msr ttbr0_el1, x0
    msr ttbr1_el1, xzr
    dsb sy
    isb
    tlbi vmalle1
    ic iallu
    dsb sy
    isb
    mrs x2, sctlr_el1
    bic x2, x2, #(1 << 24) /* E0E */
    bic x2, x2, #(1 << 25) /* EE */
    bic x2, x2, #(1 << 9)  /* UMA: EL0 cannot change interrupt masks. */
    bic x2, x2, #(1 << 14) /* DZE: trap EL0 DC ZVA. */
    bic x2, x2, #(1 << 26) /* UCI: trap EL0 cache maintenance. */
    orr x2, x2, #1
    orr x2, x2, #(1 << 2)
    orr x2, x2, #(1 << 3) /* SA */
    orr x2, x2, #(1 << 4) /* SA0 */
    orr x2, x2, #(1 << 12)
    orr x2, x2, #(1 << 19) /* WXN */
    msr sctlr_el1, x2
    isb
    ret
.size bedrock_arm_enable_mmu, . - bedrock_arm_enable_mmu

.global bedrock_arm_publish_code
.type bedrock_arm_publish_code, %function
bedrock_arm_publish_code:
    add x1, x0, x1
    mrs x2, ctr_el0
    ubfx x2, x2, #16, #4
    mov x3, #4
    lsl x2, x3, x2
    sub x3, x2, #1
    bic x0, x0, x3
.Lpublish_lines:
    dc cvau, x0
    add x0, x0, x2
    cmp x0, x1
    b.lo .Lpublish_lines
    dsb ish
    /* Whole-I-cache invalidation also covers the new user virtual alias. */
    ic iallu
    dsb ish
    isb
    ret
.size bedrock_arm_publish_code, . - bedrock_arm_publish_code

/* 816 bytes: GPR/DAIF256, SIMD512, FPCR/FPSR16, TTBR/SP_EL0/CPACR24,
 * final8 padding. Keeping all registers avoids leaking a kernel continuation. */
.macro SAVE_KERNEL_CONTINUATION
    sub sp, sp, #816
    stp x0, x1, [sp, #0]
    stp x2, x3, [sp, #16]
    stp x4, x5, [sp, #32]
    stp x6, x7, [sp, #48]
    stp x8, x9, [sp, #64]
    stp x10, x11, [sp, #80]
    stp x12, x13, [sp, #96]
    stp x14, x15, [sp, #112]
    stp x16, x17, [sp, #128]
    stp x18, x19, [sp, #144]
    stp x20, x21, [sp, #160]
    stp x22, x23, [sp, #176]
    stp x24, x25, [sp, #192]
    stp x26, x27, [sp, #208]
    stp x28, x29, [sp, #224]
    str x30, [sp, #240]
    mrs x9, daif
    str x9, [sp, #248]
    msr daifset, #0xf
    stp q0, q1, [sp, #256]
    stp q2, q3, [sp, #288]
    stp q4, q5, [sp, #320]
    stp q6, q7, [sp, #352]
    stp q8, q9, [sp, #384]
    stp q10, q11, [sp, #416]
    stp q12, q13, [sp, #448]
    stp q14, q15, [sp, #480]
    stp q16, q17, [sp, #512]
    stp q18, q19, [sp, #544]
    stp q20, q21, [sp, #576]
    stp q22, q23, [sp, #608]
    stp q24, q25, [sp, #640]
    stp q26, q27, [sp, #672]
    stp q28, q29, [sp, #704]
    stp q30, q31, [sp, #736]
    mrs x9, fpcr
    str x9, [sp, #768]
    mrs x9, fpsr
    str x9, [sp, #776]
    mrs x9, ttbr0_el1
    str x9, [sp, #784]
    mrs x9, sp_el0
    str x9, [sp, #792]
    mrs x9, cpacr_el1
    str x9, [sp, #800]
    /* FPEN=01 permits the kernel's SIMD but traps all EL0 FP/SIMD. */
    bic x9, x9, #(3 << 20)
    orr x9, x9, #(1 << 20)
    msr cpacr_el1, x9
    adrp x9, bedrock_arm_saved_kernel_sp
    add x9, x9, :lo12:bedrock_arm_saved_kernel_sp
    mov x10, sp
    str x10, [x9]
    dsb ish
    msr ttbr0_el1, x0
    isb
    tlbi vmalle1
    dsb ish
    isb
.endm

.global bedrock_arm_run_user
.type bedrock_arm_run_user, %function
bedrock_arm_run_user:
    SAVE_KERNEL_CONTINUATION
    mov x16, x1
    ldr x9, [x16, #0]
    msr elr_el1, x9
    ldr x9, [x16, #8]
    msr sp_el0, x9
    mov x9, #0x3c0 /* EL0t, clear NZCV, keep interrupts masked. */
    msr spsr_el1, x9
    ldp x0, x1, [x16, #16]
    ldr x2, [x16, #32]
    mov x3, xzr
    mov x4, xzr
    mov x5, xzr
    mov x6, xzr
    mov x7, xzr
    mov x8, xzr
    mov x9, xzr
    mov x10, xzr
    mov x11, xzr
    mov x12, xzr
    mov x13, xzr
    mov x14, xzr
    mov x15, xzr
    mov x16, xzr
    mov x17, xzr
    mov x18, xzr
    mov x19, xzr
    mov x20, xzr
    mov x21, xzr
    mov x22, xzr
    mov x23, xzr
    mov x24, xzr
    mov x25, xzr
    mov x26, xzr
    mov x27, xzr
    mov x28, xzr
    mov x29, xzr
    mov x30, xzr
    eret
.size bedrock_arm_run_user, . - bedrock_arm_run_user

.global bedrock_arm_resume_user
.type bedrock_arm_resume_user, %function
/* x0=root,x1=saved full frame,x2=PC,x3=user SP,x4=absolute deadline. */
bedrock_arm_resume_user:
    SAVE_KERNEL_CONTINUATION
    msr sp_el0, x3
    /* Use the same complete exception restoration path as resumed SVCs.
     * The temporary784-byte frame is below the protected continuation. */
    sub sp, sp, #784
    mov x9, x1
    mov x10, sp
    mov x11, #49
.Lcopy_saved_user_frame:
    ldp x12, x13, [x9], #16
    stp x12, x13, [x10], #16
    subs x11, x11, #1
    b.ne .Lcopy_saved_user_frame
    msr cntp_cval_el0, x4
    mov x9, #1
    msr cntp_ctl_el0, x9
    isb
    mov x0, x2
    b bedrock_arm_restore_exception
.size bedrock_arm_resume_user, . - bedrock_arm_resume_user

.global bedrock_arm_finish_user
.type bedrock_arm_finish_user, %function
bedrock_arm_finish_user:
    /* Already at EL1h. Abandon the failed task's exception/Zig call frames,
     * restore the kernel root, then return to run_user's trusted caller. */
    msr daifset, #0xf
    adrp x9, bedrock_arm_saved_kernel_sp
    add x9, x9, :lo12:bedrock_arm_saved_kernel_sp
    ldr x10, [x9]
    cbz x10, .Linvalid_continuation
    str xzr, [x9]
    mov sp, x10
    ldr x9, [sp, #784]
    dsb ish
    msr ttbr0_el1, x9
    isb
    tlbi vmalle1
    dsb ish
    isb
    ldr x9, [sp, #792]
    msr sp_el0, x9
    ldr x9, [sp, #800]
    msr cpacr_el1, x9
    isb
    ldp q0, q1, [sp, #256]
    ldp q2, q3, [sp, #288]
    ldp q4, q5, [sp, #320]
    ldp q6, q7, [sp, #352]
    ldp q8, q9, [sp, #384]
    ldp q10, q11, [sp, #416]
    ldp q12, q13, [sp, #448]
    ldp q14, q15, [sp, #480]
    ldp q16, q17, [sp, #512]
    ldp q18, q19, [sp, #544]
    ldp q20, q21, [sp, #576]
    ldp q22, q23, [sp, #608]
    ldp q24, q25, [sp, #640]
    ldp q26, q27, [sp, #672]
    ldp q28, q29, [sp, #704]
    ldp q30, q31, [sp, #736]
    ldr x9, [sp, #768]
    msr fpcr, x9
    ldr x9, [sp, #776]
    msr fpsr, x9
    ldr x9, [sp, #248]
    msr daif, x9
    ldp x0, x1, [sp, #0]
    ldp x2, x3, [sp, #16]
    ldp x4, x5, [sp, #32]
    ldp x6, x7, [sp, #48]
    ldp x8, x9, [sp, #64]
    ldp x10, x11, [sp, #80]
    ldp x12, x13, [sp, #96]
    ldp x14, x15, [sp, #112]
    ldp x16, x17, [sp, #128]
    ldp x18, x19, [sp, #144]
    ldp x20, x21, [sp, #160]
    ldp x22, x23, [sp, #176]
    ldp x24, x25, [sp, #192]
    ldp x26, x27, [sp, #208]
    ldp x28, x29, [sp, #224]
    ldr x30, [sp, #240]
    add sp, sp, #816
    ret
.Linvalid_continuation:
    b bedrock_arch_halt
.size bedrock_arm_finish_user, . - bedrock_arm_finish_user

.section .bss.isolation, "aw", %nobits
.balign 8
bedrock_arm_saved_kernel_sp:
    .zero 8

/* Copied as bytes into an RX user page. No absolute code relocations. */
.section .rodata.user_probe, "a"
.balign 16
.global bedrock_arm_user_program_start
.global bedrock_arm_user_program_end
bedrock_arm_user_program_start:
    mov x20, x0
    mov x21, x1
    mov x22, x2
    /* Exercise the private RW stack before any syscall or forbidden access. */
    stp x20, x21, [sp, #-16]!
    ldp x20, x21, [sp], #16
    cmp x20, #6
    b.eq .Lprobe_spin
    cbz x20, .Lprobe_normal
    cmp x20, #3
    b.eq .Lprobe_write_code
    cmp x20, #4
    b.eq .Lprobe_execute_stack
    ldr x0, [x21] /* kernel, peer or guard read must fault */
    b .Lprobe_failed
.Lprobe_write_code:
    str xzr, [x21]
    b .Lprobe_failed
.Lprobe_execute_stack:
    br x21
.Lprobe_normal:
    movz x0, #0x1000
    movk x0, #0x20, lsl #32
    ldr x2, [x0] /* Hardware-selected private data, checked by the dispatcher. */
    mov x1, #8
    mov x8, #0
    svc #0
    cmp x0, #8
    b.ne .Lprobe_failed
    mov x0, x21
    mov x1, #8
    mov x8, #0
    svc #0
    mov x9, #-14
    cmp x0, x9
    b.ne .Lprobe_failed
    mov x8, #0xffff
    svc #0
    mov x9, #-38
    cmp x0, x9
    b.ne .Lprobe_failed
    mov x0, x22
    movz x1, #0x1000
    movk x1, #0x20, lsl #32
    mov x2, #8
    mov x8, #2
    svc #0
    mov x9, #-13
    cmp x0, x9
    b.ne .Lprobe_failed
    mov x0, #0
    b .Lprobe_exit
.Lprobe_failed:
    mov x0, #99
.Lprobe_exit:
    mov x8, #1
    svc #0
    b .Lprobe_exit

/* Non-yielding fixture. Its entry count proves that subsequent quanta resume
 * the interrupted PC rather than restarting even while the counter progresses. */
.Lprobe_spin:
    mov x19, x21 /* expected per-task sentinel from Invocation.arg1 */
    movz x21, #0x1000
    movk x21, #0x20, lsl #32
    ldr x0, [x21, #16]
    add x0, x0, #1
    str x0, [x21, #16]
    mov x20, #0x20ab
    stp x19, x20, [sp, #-16]!
    mov x3, #0x3311
    mov x4, #0x4422
    mov x5, #0x5533
    mov x6, #0x6644
    mov x7, #0x7755
    mov x8, #0x8866
    mov x9, #0x9977
    mov x10, #0xaa88
    mov x11, #0xbb99
    mov x12, #0xccaa
    mov x13, #0xddbb
    mov x14, #0xeecc
    mov x15, #0xffdd
    mov x16, #0x16ab
    mov x17, #0x17bc
    mov x18, #0x18cd
    mov x22, #0x22de
    mov x23, #0x23ef
    mov x24, #0x24fa
    mov x25, #0x25ab
    mov x26, #0x26bc
    mov x27, #0x27cd
    mov x28, #0x28de
    mov x29, #0x29ef
    mov x30, #0x30fa
.Lspin_loop:
    ldr x0, [x21]
    cmp x0, x19
    b.ne .Lprobe_failed
    ldp x0, x1, [sp]
    cmp x0, x19
    b.ne .Lprobe_failed
    cmp x1, x20
    b.ne .Lprobe_failed
.macro CHECK_USER_PATTERN register, value
    mov x1, #\value
    cmp \register, x1
    b.ne .Lprobe_failed
.endm
    CHECK_USER_PATTERN x3, 0x3311
    CHECK_USER_PATTERN x4, 0x4422
    CHECK_USER_PATTERN x5, 0x5533
    CHECK_USER_PATTERN x6, 0x6644
    CHECK_USER_PATTERN x7, 0x7755
    CHECK_USER_PATTERN x8, 0x8866
    CHECK_USER_PATTERN x9, 0x9977
    CHECK_USER_PATTERN x10, 0xaa88
    CHECK_USER_PATTERN x11, 0xbb99
    CHECK_USER_PATTERN x12, 0xccaa
    CHECK_USER_PATTERN x13, 0xddbb
    CHECK_USER_PATTERN x14, 0xeecc
    CHECK_USER_PATTERN x15, 0xffdd
    CHECK_USER_PATTERN x16, 0x16ab
    CHECK_USER_PATTERN x17, 0x17bc
    CHECK_USER_PATTERN x18, 0x18cd
    CHECK_USER_PATTERN x20, 0x20ab
    CHECK_USER_PATTERN x22, 0x22de
    CHECK_USER_PATTERN x23, 0x23ef
    CHECK_USER_PATTERN x24, 0x24fa
    CHECK_USER_PATTERN x25, 0x25ab
    CHECK_USER_PATTERN x26, 0x26bc
    CHECK_USER_PATTERN x27, 0x27cd
    CHECK_USER_PATTERN x28, 0x28de
    CHECK_USER_PATTERN x29, 0x29ef
    CHECK_USER_PATTERN x30, 0x30fa
    ldr x2, [x21, #8]
    add x2, x2, #1
    str x2, [x21, #8]
    b .Lspin_loop
bedrock_arm_user_program_end:

.section .note.GNU-stack, "", %progbits
