.text
.code64
.global bedrock_x86_nx_supported
.type bedrock_x86_nx_supported,@function
bedrock_x86_nx_supported:
    pushq %rbx
    movl $0x80000000, %eax
    cpuid
    cmpl $0x80000001, %eax
    jb 1f
    movl $0x80000001, %eax
    cpuid
    shrl $20, %edx
    movl %edx, %eax
    andl $1, %eax
    popq %rbx
    ret
1:
    xorl %eax, %eax
    popq %rbx
    ret

/* Named single-CPU Q35 profile: remove inherited local-APIC routing/timers
   and receive the legacy PIC's INTR directly. x2APIC is not this profile. */
.global bedrock_x86_legacy_interrupts
.type bedrock_x86_legacy_interrupts,@function
bedrock_x86_legacy_interrupts:
    cli
    pushq %rbx
    movl $1, %eax
    cpuid
    testl $(1<<9), %edx
    jz 4f
    movl $0x1b, %ecx
    rdmsr
    testl $(1<<10), %eax
    jnz 5f
    andl $~(1<<11), %eax
    wrmsr
    rdmsr
    testl $(1<<11), %eax
    jnz 5f
4:
    movl $1, %eax
    popq %rbx
    ret
5:
    xorl %eax, %eax
    popq %rbx
    ret
.global bedrock_x86_protect
.type bedrock_x86_protect,@function
bedrock_x86_protect:
    cli
    movl $0xc0000080, %ecx
    rdmsr
    andl $~1, %eax /* No inherited SYSCALL target may bypass our int80 gate. */
    orl $(1<<11), %eax
    wrmsr
    pushq %rbx
    movl $1, %eax
    cpuid
    testl $(1<<11), %edx
    jz 3f
    movl $0x174, %ecx /* SYSENTER_CS=0 makes user SYSENTER fault. */
    xorl %eax, %eax
    xorl %edx, %edx
    wrmsr
3:
    popq %rbx
    movl $0xc0000100, %ecx
    xorl %eax, %eax
    xorl %edx, %edx
    wrmsr /* FS base */
    incl %ecx
    wrmsr /* GS base */
    incl %ecx
    wrmsr /* kernel GS base */
    movq %cr0, %rax
    orq $(1<<16), %rax
    movq %rax, %cr0
    movq %rdi, %cr3
    ret

/* The supported profile has CR4.PCIDE/PGE clear and creates no global leaves.
   Flush current translations and paging-structure caches before recycling an
   inactive space's recorded page-table frames. */
.global bedrock_x86_flush_tlb
.type bedrock_x86_flush_tlb,@function
bedrock_x86_flush_tlb:
    movq %cr3, %rax
    movq %rax, %cr3
    ret

.global bedrock_x86_install_gdt
.type bedrock_x86_install_gdt,@function
bedrock_x86_install_gdt:
    subq $16, %rsp
    movw %si, (%rsp)
    movq %rdi, 2(%rsp)
    lgdt (%rsp)
    addq $16, %rsp
    pushq $0x18
    leaq 2f(%rip), %rax
    pushq %rax
    lretq
2:
    movw $0x10, %ax
    movw %ax, %ss
    movw %ax, %ds
    movw %ax, %es
    xorw %ax, %ax
    movw %ax, %fs
    movw %ax, %gs
    movw $0x30, %ax
    ltr %ax
    ret

/* Save the cooperative kernel continuation on its current owned stack. The
   user can neither select it nor write its supervisor-only mappings. */
.global bedrock_x86_enter
.type bedrock_x86_enter,@function
bedrock_x86_enter:
    pushq %rbx
    pushq %rbp
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    subq $520, %rsp
    fxsave64 (%rsp)
    movq %rsp, bedrock_x86_saved_rsp(%rip)
    movq %cr3, %rax
    movq %rax, bedrock_x86_saved_cr3(%rip)
    movq %rsi, %r11
    movq %rdi, %cr3
    fxrstor64 bedrock_x86_clean_fx(%rip)
    movq 0(%r11), %rax
    movq 8(%r11), %rbx
    movq 16(%r11), %rdi
    movq 24(%r11), %rsi
    movq 32(%r11), %rdx
    pushq $0x2b
    pushq %rbx
    pushq $2 /* IF, IOPL, DF, TF, AC and NT clear. */
    pushq $0x23
    pushq %rax
    movw $0x2b, %ax
    movw %ax, %ds
    movw %ax, %es
    xorl %eax, %eax
    xorl %ebx, %ebx
    xorl %ecx, %ecx
    xorl %ebp, %ebp
    xorl %r8d, %r8d
    xorl %r9d, %r9d
    xorl %r10d, %r10d
    xorl %r11d, %r11d
    xorl %r12d, %r12d
    xorl %r13d, %r13d
    xorl %r14d, %r14d
    xorl %r15d, %r15d
    iretq

/* Same trusted kernel continuation as cooperative entry, but restore the
   saved full user frame/FX image rather than constructing a fresh launch. */
.global bedrock_x86_resume
.type bedrock_x86_resume,@function
bedrock_x86_resume:
    cli
    pushq %rbx
    pushq %rbp
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    subq $520, %rsp
    fxsave64 (%rsp)
    movq %rsp, bedrock_x86_saved_rsp(%rip)
    movq %cr3, %rax
    movq %rax, bedrock_x86_saved_cr3(%rip)
    movq %rdi, %cr3
    fxrstor64 (%rdx)
    movw $0x2b, %ax
    movw %ax, %ds
    movw %ax, %es
    movq %rsi, %rsp
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

.global bedrock_x86_leave
.type bedrock_x86_leave,@function
bedrock_x86_leave:
    cli
    cld
    movq bedrock_x86_saved_cr3(%rip), %rax
    movq %rax, %cr3
    movw $0x10, %ax
    movw %ax, %ss
    movw %ax, %ds
    movw %ax, %es
    movq bedrock_x86_saved_rsp(%rip), %rsp
    fxrstor64 (%rsp)
    addq $520, %rsp
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rbp
    popq %rbx
    ret

.section .bss,"aw",@nobits
.balign 8
bedrock_x86_saved_rsp: .quad 0
bedrock_x86_saved_cr3: .quad 0

.section .rodata,"a",@progbits
.balign 16
.global bedrock_x86_clean_fx
.hidden bedrock_x86_clean_fx
bedrock_x86_clean_fx:
    .word 0x037f
    .zero 22
    .long 0x1f80
    .zero 484

/* Standalone PIC fixture copied to a private RX page; every target and token
   arrives through checked launch arguments, never through kernel blob refs. */
.balign 16
.global bedrock_x86_program_start
.hidden bedrock_x86_program_start
bedrock_x86_program_start:
    movq %rsi, %r12
    movq %rdx, %r13
    testq %rdi, %rdi
    jz user_normal
    cmpq $6, %rdi
    je user_spin
    cmpq $3, %rdi
    je user_write
    cmpq $4, %rdi
    je user_execute
    movq (%r12), %rax
    jmp user_failed
user_write:
    movb $0xcc, (%r12)
    jmp user_failed
user_execute:
    jmp *%r12
user_normal:
    xorq %rax, %rax
    movabsq $0x2000001000, %rdi
    movq (%rdi), %rdx /* Read the active task's real user mapping. */
    pushq %rdx
    popq %rbx /* Exercise the private RW+NX user stack. */
    cmpq %rdx, %rbx
    jne user_failed
    movq $8, %rsi
    int $0x80
    cmpq $8, %rax
    jne user_failed
    xorq %rax, %rax
    movq %r12, %rdi
    movq $8, %rsi
    int $0x80
    cmpq $-14, %rax
    jne user_failed
    movq $0xffff, %rax
    int $0x80
    cmpq $-38, %rax
    jne user_failed
    movq $2, %rax
    movq %r13, %rdi
    int $0x80
    cmpq $-13, %rax
    jne user_failed
    movq $1, %rax
    xorq %rdi, %rdi
    int $0x80
user_spin:
    movabsq $0x2000001000, %rdi
    cmpq %r12, (%rdi)
    jne user_failed
    incq 16(%rdi) /* Launch occurs once; resumption must not repeat entry. */
    movq %r12, %rbx
    movq %r12, %xmm0
    punpcklqdq %xmm0, %xmm0
    movdqa %xmm0, %xmm15
    fld1
    pushq %r12
    movl $0x22, %esi
    movl $0x33, %edx
    movl $0x44, %ecx
    movl $0x55, %ebp
    movl $0x88, %r8d
    movl $0x99, %r9d
    movl $0xaa, %r10d
    movl $0xbb, %r11d
    movl $0xcc, %r13d
    movl $0xdd, %r14d
    movl $0xee, %r15d
    std
user_spin_loop:
    cmpq %r12, (%rdi)
    jne user_failed
    cmpq %r12, %rbx
    jne user_failed
    cmpq %r12, (%rsp)
    jne user_failed
    cmpq $0x22, %rsi
    jne user_failed
    cmpq $0x33, %rdx
    jne user_failed
    cmpq $0x44, %rcx
    jne user_failed
    cmpq $0x55, %rbp
    jne user_failed
    cmpq $0x88, %r8
    jne user_failed
    cmpq $0x99, %r9
    jne user_failed
    cmpq $0xaa, %r10
    jne user_failed
    cmpq $0xbb, %r11
    jne user_failed
    cmpq $0xcc, %r13
    jne user_failed
    cmpq $0xdd, %r14
    jne user_failed
    cmpq $0xee, %r15
    jne user_failed
    pushfq
    popq %rax
    andq $0x600, %rax
    cmpq $0x600, %rax /* Both user IF and DF survive each timer frame. */
    jne user_failed
    movq %xmm0, %rax
    cmpq %r12, %rax
    jne user_failed
    movdqa %xmm0, %xmm1
    psrldq $8, %xmm1
    movq %xmm1, %rax
    cmpq %r12, %rax
    jne user_failed
    movq %xmm15, %rax
    cmpq %r12, %rax
    jne user_failed
    movdqa %xmm15, %xmm1
    psrldq $8, %xmm1
    movq %xmm1, %rax
    cmpq %r12, %rax
    jne user_failed
    subq $16, %rsp
    fld %st(0)
    fstpt (%rsp)
    movabsq $0x8000000000000000, %rax
    cmpq %rax, (%rsp)
    jne user_failed
    cmpw $0x3fff, 8(%rsp)
    jne user_failed
    fnstcw 10(%rsp)
    cmpw $0x037f, 10(%rsp)
    jne user_failed
    stmxcsr 12(%rsp)
    cmpl $0x1f80, 12(%rsp)
    jne user_failed
    addq $16, %rsp
    incq 8(%rdi)
    jmp user_spin_loop
user_failed:
    movq $1, %rax
    movq $99, %rdi
    int $0x80
    ud2
.global bedrock_x86_program_end
.hidden bedrock_x86_program_end
bedrock_x86_program_end:
.section .note.GNU-stack,"",@progbits
