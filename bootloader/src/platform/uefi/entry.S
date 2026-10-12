/* PE/COFF helpers use the x86-64 UEFI/Win64 ABI. The copied transition
   switches to Bedrock's SysV kernel ABI only after ExitBootServices. */
.text
.code64
.global bedrock_pc_in8
bedrock_pc_in8:
    movl %ecx, %edx
    xorl %eax, %eax
    inb %dx, %al
    ret
.global bedrock_pc_out8
bedrock_pc_out8:
    movl %edx, %eax
    movl %ecx, %edx
    outb %al, %dx
    ret
.global bedrock_uefi_cr4
bedrock_uefi_cr4:
    movq %cr4, %rax
    ret
.global bedrock_uefi_physical_bits
bedrock_uefi_physical_bits:
    pushq %rbx
    movl $1, %eax
    cpuid
    testl $(1<<16), %edx /* Explicit PAT policy requires CPU PAT support. */
    jz 3f
    movl $0x80000000, %eax
    cpuid
    cmpl $0x80000008, %eax
    jb 4f
    movl $0x80000008, %eax
    cpuid
    andl $0xff, %eax
    popq %rbx
    ret
3:
    xorl %eax, %eax
    popq %rbx
    ret
4:
    movl $36, %eax
    popq %rbx
    ret
.global bedrock_uefi_halt
bedrock_uefi_halt:
    cli
1:
    hlt
    jmp 1b
.global bedrock_uefi_exit
bedrock_uefi_exit:
    movl $0x11, %eax
    testq %rcx, %rcx
    jnz 2f
    movl $0x10, %eax
2:
    movw $0xf4, %dx
    outl %eax, %dx
    jmp bedrock_uefi_halt

/* Position-independent block copied into dynamically allocated loader RAM.
   RCX points to {entry, info, bytes, cr3, stack_top}, five u64 fields.
   Neither the EFI image nor its old stack needs to remain mapped. */
.p2align 4
.global bedrock_uefi_transition_start
bedrock_uefi_transition_start:
    cli
    cld
    movq 0(%rcx), %r11 /* kernel entry */
    movq 8(%rcx), %rdi /* checked handoff */
    movq 16(%rcx), %rsi /* available bytes */
    movq 24(%rcx), %r10 /* own page table root */
    movq 32(%rcx), %rsp /* own stack */
    xorl %ebp, %ebp
    movb $0xff, %al
    outb %al, $0x21
    outb %al, $0xa1
    movb $0x80, %al
    outb %al, $0x70

    /* Reset PCID before disabling PCIDE, and flush old global translations.
       LA57 is rejected by the loader before boot services are terminated. */
    movq %cr3, %rax
    andq $-4096, %rax
    movq %rax, %cr3
    movq %cr4, %rax
    andq $~((1<<7)|(1<<17)|(1<<18)|(1<<23)), %rax
    orq $0x620, %rax /* PAE, OSFXSR, OSXMMEXCPT */
    movq %rax, %cr4
    movq %cr0, %r9
    andq $~((1<<30)|(1<<29)|12), %r9 /* CD/NW/EM/TS clear. */
    orq $0x22, %r9 /* MP and NE. */
    movq %r9, %rax
    orq $(1<<30), %rax /* Disable caching during PAT replacement. */
    movq %rax, %cr0
    wbinvd
    movl $0x277, %ecx /* IA32_PAT: WB WT UC- UC WB WT WC UC. */
    movl $0x00070406, %eax
    movl $0x00010406, %edx
    wrmsr
    wbinvd
    movq %r10, %cr3
    movq %r9, %cr0
    fninit
    ldmxcsr bedrock_uefi_default_mxcsr(%rip)

    leaq bedrock_uefi_gdt(%rip), %rax
    subq $16, %rsp
    movw $31, (%rsp)
    movq %rax, 2(%rsp)
    lgdt (%rsp)
    addq $16, %rsp
    pushq $0x18
    leaq bedrock_uefi_long_mode(%rip), %rax
    pushq %rax
    lretq
bedrock_uefi_long_mode:
    movw $0x10, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss
    xorw %ax, %ax
    movw %ax, %fs
    movw %ax, %gs
    xorl %eax, %eax
    xorl %edx, %edx
    movl $0xc0000100, %ecx
    wrmsr /* FS_BASE */
    incl %ecx
    wrmsr /* GS_BASE */
    incl %ecx
    wrmsr /* KERNEL_GS_BASE */
    mfence
    xorl %eax, %eax
    cpuid
    jmp *%r11
.p2align 3
bedrock_uefi_gdt:
    .quad 0
    .quad 0x00cf9b000000ffff
    .quad 0x00cf93000000ffff
    .quad 0x00af9b000000ffff
bedrock_uefi_default_mxcsr:
    .long 0x1f80
.global bedrock_uefi_transition_end
bedrock_uefi_transition_end:
