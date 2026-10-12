/* QEMU PC reset ROM. No firmware services are used. */
.section .boot16,"ax",@progbits
.code16
.global bedrock_reset16
bedrock_reset16:
    cli
    cld
    /* Preserve the reset CS hidden base until the protected-mode far jump. */
    inb $0x92, %al
    andb $0xfe, %al
    orb $0x02, %al
    outb %al, $0x92
    movb $0x80, %al
    outb %al, $0x70
    lgdtl %cs:(bedrock_gdt_pointer - 0xffff0000)
    movl %cr0, %eax
    orl $1, %eax
    movl %eax, %cr0
    ljmpl $0x08, $bedrock_protected32

.balign 8
bedrock_gdt:
    .quad 0x0000000000000000
    /* Set the accessed bits up front: the GDT itself lives in read-only ROM. */
    .quad 0x00cf9b000000ffff /* 0x08: flat 32-bit code */
    .quad 0x00cf93000000ffff /* 0x10: flat data */
    .quad 0x00af9b000000ffff /* 0x18: 64-bit code */
bedrock_gdt_end:
bedrock_gdt_pointer:
    .word bedrock_gdt_end - bedrock_gdt - 1
    .long bedrock_gdt

.code32
bedrock_protected32:
    movw $0x10, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss
    movw %ax, %fs
    movw %ax, %gs
    movl $__loader_stack_top, %esp
    xorl %ebp, %ebp
    movb $0xff, %al
    outb %al, $0x21
    outb %al, $0xa1

    movl $__data_load_start, %esi
    movl $__data_start, %edi
    movl $__data_end, %ecx
    subl %edi, %ecx
    rep movsb
    movl $__bss_start, %edi
    movl $__bss_end, %ecx
    subl %edi, %ecx
    xorl %eax, %eax
    rep stosb

    /* This profile requires PAE, FXSR, SSE, SSE2 and long mode. */
    movl $1, %eax
    cpuid
    andl $0x07000040, %edx
    cmpl $0x07000040, %edx
    jne bedrock_early_halt
    movl $0x80000000, %eax
    cpuid
    cmpl $0x80000001, %eax
    jb bedrock_early_halt
    movl $0x80000001, %eax
    cpuid
    testl $0x20000000, %edx
    jz bedrock_early_halt

    /* Six zeroed pages: PML4, PDPT and four directories. Identity-map 4 GiB
       with 2 MiB leaves so both low RAM and the reset ROM remain reachable. */
    movl $__page_tables_start, %edi
    movl $6144, %ecx
    xorl %eax, %eax
    rep stosl
    movl $__pdpt, %eax
    orl $3, %eax
    movl %eax, __pml4
    movl $__pd0, %eax
    orl $3, %eax
    movl $__pdpt, %edi
    movl $4, %ecx
1:
    movl %eax, (%edi)
    addl $0x1000, %eax
    addl $8, %edi
    loop 1b
    movl $__pd0, %edi
    movl $0x83, %eax
    movl $2048, %ecx
2:
    movl %eax, (%edi)
    addl $0x200000, %eax
    addl $8, %edi
    loop 2b

    movl %cr4, %eax
    orl $0x620, %eax /* PAE, OSFXSR, OSXMMEXCPT; AVX remains disabled. */
    movl %eax, %cr4
    movl %cr0, %eax
    andl $0x9ffffff3, %eax /* Clear CD, NW, EM and TS. */
    orl $0x22, %eax /* MP and NE. */
    movl %eax, %cr0
    fninit
    movl $__pml4, %eax
    movl %eax, %cr3
    movl $0xc0000080, %ecx
    rdmsr
    orl $0x100, %eax /* EFER.LME */
    wrmsr
    movl %cr0, %eax
    orl $0x80000000, %eax
    movl %eax, %cr0
    ljmpl $0x18, $bedrock_long64
bedrock_early_halt:
    cli
3:
    hlt
    jmp 3b

.code64
bedrock_long64:
    movabsq $__loader_stack_top, %rsp
    xorq %rbp, %rbp
    ldmxcsr bedrock_default_mxcsr(%rip)
    /* Every loader exception is fatal. The kernel installs detailed gates. */
    movabsq $bedrock_loader_idt, %rdi
    movabsq $bedrock_loader_exception, %rax
    movl $256, %ecx
4:
    movw %ax, 0(%rdi)
    movw $0x18, 2(%rdi)
    movb $0, 4(%rdi)
    movb $0x8e, 5(%rdi)
    movq %rax, %rdx
    shrq $16, %rdx
    movw %dx, 6(%rdi)
    shrq $16, %rdx
    movl %edx, 8(%rdi)
    movl $0, 12(%rdi)
    addq $16, %rdi
    loop 4b
    subq $16, %rsp
    movw $4095, (%rsp)
    movabsq $bedrock_loader_idt, %rax
    movq %rax, 2(%rsp)
    lidt (%rsp)
    addq $16, %rsp
    call bedrock_bootloader_main
    jmp bedrock_bootloader_halt
bedrock_loader_exception:
    cli
    cld
    andq $-16, %rsp
    call bedrock_bootloader_fault
    jmp bedrock_bootloader_halt

.section .text,"ax",@progbits
.code64
.global bedrock_bootloader_halt
.type bedrock_bootloader_halt,@function
bedrock_bootloader_halt:
    cli
5:
    hlt
    jmp 5b

.global bedrock_bootloader_exit
.type bedrock_bootloader_exit,@function
bedrock_bootloader_exit:
    movl $0x11, %eax
    testq %rdi, %rdi
    jnz 6f
    movl $0x10, %eax
6:
    movw $0xf4, %dx
    outl %eax, %dx
    jmp bedrock_bootloader_halt

.global bedrock_bootloader_jump
.type bedrock_bootloader_jump,@function
bedrock_bootloader_jump:
    movq %rdi, %r11
    movq %rsi, %rdi
    movq %rdx, %rsi
    /* x86 instruction/data caches are coherent. CPUID serializes the copy. */
    mfence
    xorl %eax, %eax
    cpuid
    jmp *%r11

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
.global bedrock_pc_out16
.type bedrock_pc_out16,@function
bedrock_pc_out16:
    movl %edi, %edx
    movl %esi, %eax
    outw %ax, %dx
    ret

.section .rodata,"a",@progbits
.balign 4
bedrock_default_mxcsr:
    .long 0x1f80
.section .bss,"aw",@nobits
.balign 16
bedrock_loader_idt:
    .skip 4096

.section .reset,"ax",@progbits
.code16
.global _start
_start:
    jmp bedrock_reset16
    .fill 16 - (. - _start), 1, 0x90
.section .note.GNU-stack,"",@progbits
