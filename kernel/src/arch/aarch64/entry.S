/* EL1h entry. x0/x1=handoff pointer/bytes, x2/x3=trusted loader arena. */
.section .text.entry, "ax"
.balign 16
.global _start
.type _start, %function
_start:
    msr daifset, #0xf
    mov x19, x0
    mov x20, x1
#ifdef BEDROCK_UEFI
    mov x21, x2
    mov x22, x3
#else
    mov x21, #0x40100000
    mov x22, #0x100000
#endif
    msr spsel, #1
    adrp x2, __stack_top
    add x2, x2, :lo12:__stack_top
    mov sp, x2

    adrp x2, __bss_start
    add x2, x2, :lo12:__bss_start
    adrp x3, __bss_end
    add x3, x3, :lo12:__bss_end
.Lclear_bss:
    cmp x2, x3
    b.hs .Lbss_done
    str xzr, [x2], #8
    b .Lclear_bss
.Lbss_done:
    mrs x2, cpacr_el1
    orr x2, x2, #(3 << 20)
    msr cpacr_el1, x2
    isb

    adrp x2, bedrock_exception_vectors
    add x2, x2, :lo12:bedrock_exception_vectors
    msr vbar_el1, x2
    isb
    mov x0, x19
    mov x1, x20
    mov x2, x21
    mov x3, x22
    bl bedrock_kernel_main
    b bedrock_arch_halt
.size _start, . - _start
.ltorg

/* The four groups are current EL/SP0, current EL/SPx, lower EL/A64, A32. */
.section .text.vectors, "ax"
.balign 2048
.global bedrock_exception_vectors
.type bedrock_exception_vectors, %object
bedrock_exception_vectors:
    b .Lvector_0
    .space 124
    b .Lvector_1
    .space 124
    b .Lvector_2
    .space 124
    b .Lvector_3
    .space 124
    b .Lvector_4
    .space 124
    b .Lvector_5
    .space 124
    b .Lvector_6
    .space 124
    b .Lvector_7
    .space 124
    b .Lvector_8
    .space 124
    b .Lvector_9
    .space 124
    b .Lvector_10
    .space 124
    b .Lvector_11
    .space 124
    b .Lvector_12
    .space 124
    b .Lvector_13
    .space 124
    b .Lvector_14
    .space 124
    b .Lvector_15
    .space 124
.size bedrock_exception_vectors, . - bedrock_exception_vectors

.section .text.exceptions, "ax"
.balign 16
/* 784-byte frame: GPRs/SPSR 256, SIMD 512, FPCR/FPSR 16. */
.macro VECTOR_HANDLER number
.Lvector_\number:
    sub sp, sp, #784
    stp x0, x1, [sp, #0]
    stp x2, x3, [sp, #16]
    mov x3, #\number
    b .Lsave_exception_context
.endm
VECTOR_HANDLER 0
VECTOR_HANDLER 1
VECTOR_HANDLER 2
VECTOR_HANDLER 3
VECTOR_HANDLER 4
VECTOR_HANDLER 5
VECTOR_HANDLER 6
VECTOR_HANDLER 7
VECTOR_HANDLER 8
VECTOR_HANDLER 9
VECTOR_HANDLER 10
VECTOR_HANDLER 11
VECTOR_HANDLER 12
VECTOR_HANDLER 13
VECTOR_HANDLER 14
VECTOR_HANDLER 15

.Lsave_exception_context:
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
    mrs x0, spsr_el1
    str x0, [sp, #248]
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
    mrs x0, fpcr
    mrs x1, fpsr
    str x0, [sp, #768]
    str x1, [sp, #776]

#ifdef BEDROCK_UEFI
    cmp x3, #8
    b.eq .Luser_exception
    cmp x3, #9
    b.ne .Lkernel_exception
.Luser_exception:
    mov x4, x3
    mov x0, sp
    mrs x1, esr_el1
    mrs x2, elr_el1
    mrs x3, far_el1
    bl bedrock_arm_user_exception
    b .Lrestore_exception
.Lkernel_exception:
#endif
    mrs x0, esr_el1
    mrs x1, elr_el1
    mrs x2, far_el1
    bl bedrock_exception_handler
    /* A resumed SVC returns its already advanced PC; BRK returns PC+4. */
.Lrestore_exception:
.global bedrock_arm_restore_exception
.hidden bedrock_arm_restore_exception
bedrock_arm_restore_exception:
    msr elr_el1, x0

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
    ldr x0, [sp, #768]
    ldr x1, [sp, #776]
    msr fpcr, x0
    msr fpsr, x1
    ldr x0, [sp, #248]
    msr spsr_el1, x0
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
    add sp, sp, #784
    eret

.section .text.helpers, "ax"
.balign 16
.global bedrock_arch_current_el
.type bedrock_arch_current_el, %function
bedrock_arch_current_el:
    mrs x0, CurrentEL
    lsr x0, x0, #2
    ret
.size bedrock_arch_current_el, . - bedrock_arch_current_el

.global bedrock_arch_translation_state
.type bedrock_arch_translation_state, %function
bedrock_arch_translation_state:
    mrs x0, sctlr_el1
    ret
.size bedrock_arch_translation_state, . - bedrock_arch_translation_state

.global bedrock_arch_memory_features
.type bedrock_arch_memory_features, %function
bedrock_arch_memory_features:
    mrs x0, id_aa64mmfr0_el1
    ret
.size bedrock_arch_memory_features, . - bedrock_arch_memory_features

.global bedrock_arch_deliberate_brk
.global bedrock_arch_brk_instruction
.type bedrock_arch_deliberate_brk, %function
bedrock_arch_deliberate_brk:
bedrock_arch_brk_instruction:
    brk #0xbed
    ret
.size bedrock_arch_deliberate_brk, . - bedrock_arch_deliberate_brk

.global bedrock_arch_semihost_exit
.type bedrock_arch_semihost_exit, %function
bedrock_arch_semihost_exit:
    sub sp, sp, #16
    mov x2, #0x26
    movk x2, #2, lsl #16
    stp x2, xzr, [sp]
    mov x0, #0x20
    mov x1, sp
    hlt #0xf000
    b bedrock_arch_halt
.size bedrock_arch_semihost_exit, . - bedrock_arch_semihost_exit

.global bedrock_arch_halt
.type bedrock_arch_halt, %function
bedrock_arch_halt:
    msr daifset, #0xf
.Lhalt:
    wfi
    b .Lhalt
.size bedrock_arch_halt, . - bedrock_arch_halt

.section .note.GNU-stack, "", %progbits
