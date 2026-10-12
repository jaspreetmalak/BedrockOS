/* QEMU virt firmware entry. The selected profile resets into EL1h at 0. */
.section .text.boot, "ax", %progbits
.balign 4
.global _start
.type _start, %function
_start:
    msr daifset, #0xf
    mrs x0, CurrentEL
    cmp x0, #4
    b.ne bedrock_bootloader_halt
    msr SPSel, #1

    /* Zig may emit FP/SIMD instructions even for ordinary memory copies. */
    mrs x0, CPACR_EL1
    orr x0, x0, #(3 << 20)
    msr CPACR_EL1, x0
    isb

    ldr x0, =__loader_stack_top
    mov sp, x0

    /* Initialized writable data has a flash LMA and a RAM VMA. */
    ldr x0, =__data_load_start
    ldr x1, =__data_start
    ldr x2, =__data_end
.Lcopy_data:
    cmp x1, x2
    b.hs .Lclear_bss_start
    ldrb w3, [x0], #1
    strb w3, [x1], #1
    b .Lcopy_data

.Lclear_bss_start:
    ldr x1, =__bss_start
    ldr x2, =__bss_end
.Lclear_bss:
    cmp x1, x2
    b.hs .Linitialized
    strb wzr, [x1], #1
    b .Lclear_bss

.Linitialized:
    ldr x0, =__loader_vectors
    msr VBAR_EL1, x0
    isb
    bl bedrock_bootloader_main
    b bedrock_bootloader_halt
.size _start, . - _start
.ltorg

.section .text, "ax", %progbits
.balign 4
.global bedrock_bootloader_current_el
.type bedrock_bootloader_current_el, %function
bedrock_bootloader_current_el:
    mrs x0, CurrentEL
    lsr x0, x0, #2
    ret
.size bedrock_bootloader_current_el, . - bedrock_bootloader_current_el

.global bedrock_bootloader_sctlr
.type bedrock_bootloader_sctlr, %function
bedrock_bootloader_sctlr:
    mrs x0, SCTLR_EL1
    ret
.size bedrock_bootloader_sctlr, . - bedrock_bootloader_sctlr

.global bedrock_bootloader_halt
.type bedrock_bootloader_halt, %function
bedrock_bootloader_halt:
    msr daifset, #0xf
.Lhalt:
    wfe
    b .Lhalt
.size bedrock_bootloader_halt, . - bedrock_bootloader_halt

/* C ABI input: x0 = entry, x1 = BootInfo pointer, x2 = accessible bytes. */
.global bedrock_bootloader_jump
.type bedrock_bootloader_jump, %function
bedrock_bootloader_jump:
    mov x16, x0
    mov x0, x1
    mov x1, x2
    /* This profile keeps the MMU and data cache disabled throughout loading. */
    dsb sy
    ic iallu
    dsb sy
    isb
    br x16
.size bedrock_bootloader_jump, . - bedrock_bootloader_jump

/* Test-only AArch64 semihosting exit: two native 64-bit argument words. */
.global bedrock_bootloader_exit
.type bedrock_bootloader_exit, %function
bedrock_bootloader_exit:
    sub sp, sp, #16
    mov x1, sp
    ldr x2, =0x20026
    str x2, [sp]
    str x0, [sp, #8]
    mov w0, #0x20
    hlt #0xf000
    b bedrock_bootloader_halt
.size bedrock_bootloader_exit, . - bedrock_bootloader_exit
.ltorg

/* All exception classes are fatal in the first loader implementation. */
.section .text.vectors, "ax", %progbits
.balign 2048
.global __loader_vectors
.type __loader_vectors, %object
__loader_vectors:
.rept 16
    b .Lloader_fault
    .space 124
.endr
.size __loader_vectors, . - __loader_vectors

.Lloader_fault:
    msr daifset, #0xf
    mrs x0, ESR_EL1
    mrs x1, ELR_EL1
    mrs x2, FAR_EL1
    bl bedrock_bootloader_fault
    b bedrock_bootloader_halt

.section .note.GNU-stack, "", %progbits
