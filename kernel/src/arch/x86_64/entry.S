.section .text.entry,"ax",@progbits
.code64
.global _start
.type _start,@function
_start:
    cli
    cld
    movq %rdi, %r12
    movq %rsi, %r13
    leaq __stack_top(%rip), %rsp
    xorq %rbp, %rbp
    leaq __bss_start(%rip), %rdi
    leaq __bss_end(%rip), %rcx
    subq %rdi, %rcx
    xorl %eax, %eax
    rep stosb
    movq %r12, %rdi
    movq %r13, %rsi
    call bedrock_kernel_main
    jmp bedrock_arch_halt

.section .text,"ax",@progbits
.global bedrock_arch_halt
.type bedrock_arch_halt,@function
bedrock_arch_halt:
    cli
1:
    hlt
    jmp 1b
.global bedrock_arch_exit
.type bedrock_arch_exit,@function
bedrock_arch_exit:
    movl $0x11, %eax
    testq %rdi, %rdi
    jnz 2f
    movl $0x10, %eax
2:
    movw $0xf4, %dx
    outl %eax, %dx
    jmp bedrock_arch_halt
.global bedrock_pc_in8
.type bedrock_pc_in8,@function
bedrock_pc_in8:
    movl %edi, %edx
    xorl %eax, %eax
    inb %dx, %al
    ret
.global bedrock_pc_out8
.type bedrock_pc_out8,@function
bedrock_pc_out8:
    movl %edi, %edx
    movl %esi, %eax
    outb %al, %dx
    ret
.global bedrock_arch_install_idt
.type bedrock_arch_install_idt,@function
bedrock_arch_install_idt:
    subq $16, %rsp
    movw %si, (%rsp)
    movq %rdi, 2(%rsp)
    lidt (%rsp)
    addq $16, %rsp
    ret
.global bedrock_arch_cr3
.type bedrock_arch_cr3,@function
bedrock_arch_cr3:
    movq %cr3, %rax
    ret
.global bedrock_arch_physical_bits
.type bedrock_arch_physical_bits,@function
bedrock_arch_physical_bits:
    pushq %rbx
    movl $0x80000000, %eax
    cpuid
    cmpl $0x80000008, %eax
    jb 3f
    movl $0x80000008, %eax
    cpuid
    andl $0xff, %eax
    popq %rbx
    ret
3:
    movl $36, %eax
    popq %rbx
    ret

/* CPU error-code and no-error-code exceptions become the same two-word
   prefix. The hardware frame stays intact until IRETQ. */
.macro ISR number, has_error=0
.global bedrock_isr_\number
.hidden bedrock_isr_\number
bedrock_isr_\number:
.if \has_error == 0
    pushq $0
.endif
    pushq $\number
    jmp bedrock_isr_common
.endm
ISR 0
ISR 1
ISR 2
ISR 3
ISR 4
ISR 5
ISR 6
ISR 7
ISR 8, 1
ISR 9
ISR 10, 1
ISR 11, 1
ISR 12, 1
ISR 13, 1
ISR 14, 1
ISR 15
ISR 16
ISR 17, 1
ISR 18
ISR 19
ISR 20
ISR 21, 1
ISR 22
ISR 23
ISR 24
ISR 25
ISR 26
ISR 27
ISR 28
ISR 29, 1
ISR 30, 1
ISR 31
.global bedrock_arch_default_isr
bedrock_arch_default_isr:
    pushq $0
    pushq $255
#ifdef BEDROCK_UEFI
    jmp bedrock_isr_common
.global bedrock_x86_syscall_isr
bedrock_x86_syscall_isr:
    pushq $0
    pushq $128
    jmp bedrock_isr_common
.global bedrock_x86_timer_isr
bedrock_x86_timer_isr:
    pushq $0
    pushq $32
#endif
bedrock_isr_common:
    pushq %rax
    pushq %rbx
    pushq %rcx
    pushq %rdx
    pushq %rsi
    pushq %rdi
    pushq %rbp
    pushq %r8
    pushq %r9
    pushq %r10
    pushq %r11
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    movq %rsp, %r12
    subq $528, %rsp
    andq $-16, %rsp
    /* Baseline x86-64 permits x87 and SSE/SSE2, not AVX/XSAVE state. */
    fxsave64 (%rsp)
    cld
#ifdef BEDROCK_UEFI
    testq $3, 144(%r12) /* Saved CS: user FP controls must not reach C. */
    jz bedrock_isr_kernel_fp
    fxrstor64 bedrock_x86_clean_fx(%rip)
bedrock_isr_kernel_fp:
    movq %r12, %rdi
    movq %rsp, %rsi /* Exact user FXSAVE image, before C uses clean FP state. */
    call bedrock_x86_isolation_trap
    testb %al, %al
    jnz bedrock_isr_restore
#endif
    movq 120(%r12), %rdi /* vector */
    movq 128(%r12), %rsi /* error code */
    movq 136(%r12), %rdx /* saved RIP */
    movq %cr2, %rcx
    call bedrock_exception_handler
#ifdef BEDROCK_UEFI
bedrock_isr_restore:
#endif
    fxrstor64 (%rsp)
    movq %r12, %rsp
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %r11
    popq %r10
    popq %r9
    popq %r8
    popq %rbp
    popq %rdi
    popq %rsi
    popq %rdx
    popq %rcx
    popq %rbx
    popq %rax
    addq $16, %rsp
    iretq

/* This probe checks GPRs, low/high XMM registers, x87 and restored DF after
   the Zig handler has printed through COM1. Preserve the caller's ABI state. */
.global bedrock_arch_deliberate_int3
.type bedrock_arch_deliberate_int3,@function
bedrock_arch_deliberate_int3:
    pushq %rbx
    pushq %rbp
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    subq $32, %rsp
    movdqa bedrock_probe_xmm(%rip), %xmm0
    movdqa bedrock_probe_xmm(%rip), %xmm15
    fld1
    movl $0x11, %eax
    movl $0x22, %ebx
    movl $0x33, %ecx
    movl $0x44, %edx
    movl $0x55, %esi
    movl $0x66, %edi
    movl $0x77, %ebp
    movl $0x88, %r8d
    movl $0x99, %r9d
    movl $0xaa, %r10d
    movl $0xbb, %r11d
    movl $0xcc, %r12d
    movl $0xdd, %r13d
    movl $0xee, %r14d
    movl $0xff, %r15d
    std
    int3
.global bedrock_arch_int3_resume
bedrock_arch_int3_resume:
    cmpq $0x11, %rax
    jne bedrock_probe_failed
    cmpq $0x22, %rbx
    jne bedrock_probe_failed
    cmpq $0x33, %rcx
    jne bedrock_probe_failed
    cmpq $0x44, %rdx
    jne bedrock_probe_failed
    cmpq $0x55, %rsi
    jne bedrock_probe_failed
    cmpq $0x66, %rdi
    jne bedrock_probe_failed
    cmpq $0x77, %rbp
    jne bedrock_probe_failed
    cmpq $0x88, %r8
    jne bedrock_probe_failed
    cmpq $0x99, %r9
    jne bedrock_probe_failed
    cmpq $0xaa, %r10
    jne bedrock_probe_failed
    cmpq $0xbb, %r11
    jne bedrock_probe_failed
    cmpq $0xcc, %r12
    jne bedrock_probe_failed
    cmpq $0xdd, %r13
    jne bedrock_probe_failed
    cmpq $0xee, %r14
    jne bedrock_probe_failed
    cmpq $0xff, %r15
    jne bedrock_probe_failed
    pushfq
    popq %rax
    testq $0x400, %rax
    jz bedrock_probe_failed
    cld
    movdqu %xmm0, (%rsp)
    movdqu %xmm15, 16(%rsp)
    movabsq $0x0123456789abcdef, %rax
    cmpq %rax, (%rsp)
    jne bedrock_probe_failed
    cmpq %rax, 16(%rsp)
    jne bedrock_probe_failed
    movabsq $0xfedcba9876543210, %rax
    cmpq %rax, 8(%rsp)
    jne bedrock_probe_failed
    cmpq %rax, 24(%rsp)
    jne bedrock_probe_failed
    fstpt (%rsp)
    movabsq $0x8000000000000000, %rax
    cmpq %rax, (%rsp)
    jne bedrock_probe_failed_after_x87
    cmpw $0x3fff, 8(%rsp)
    jne bedrock_probe_failed_after_x87
    movl $1, %eax
    jmp bedrock_probe_done
bedrock_probe_failed:
    cld
    fstp %st(0)
bedrock_probe_failed_after_x87:
    xorl %eax, %eax
bedrock_probe_done:
    addq $32, %rsp
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rbp
    popq %rbx
    ret

.section .rodata,"a",@progbits
.balign 16
bedrock_probe_xmm:
    .quad 0x0123456789abcdef, 0xfedcba9876543210
.global bedrock_arch_isr_table
.hidden bedrock_arch_isr_table
.balign 8
.section .data.rel.ro,"aw",@progbits
.balign 8
bedrock_arch_isr_table:
    .quad bedrock_isr_0, bedrock_isr_1, bedrock_isr_2, bedrock_isr_3
    .quad bedrock_isr_4, bedrock_isr_5, bedrock_isr_6, bedrock_isr_7
    .quad bedrock_isr_8, bedrock_isr_9, bedrock_isr_10, bedrock_isr_11
    .quad bedrock_isr_12, bedrock_isr_13, bedrock_isr_14, bedrock_isr_15
    .quad bedrock_isr_16, bedrock_isr_17, bedrock_isr_18, bedrock_isr_19
    .quad bedrock_isr_20, bedrock_isr_21, bedrock_isr_22, bedrock_isr_23
    .quad bedrock_isr_24, bedrock_isr_25, bedrock_isr_26, bedrock_isr_27
    .quad bedrock_isr_28, bedrock_isr_29, bedrock_isr_30, bedrock_isr_31
.section .note.GNU-stack,"",@progbits
