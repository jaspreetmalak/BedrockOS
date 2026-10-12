/* QEMU virt reset ROM enters this ELF in M-mode: a0=hart, a1=DTB. */
.option norvc
.option norelax
.section .text.boot, "ax", @progbits
.balign 16
.global _start
.type _start, @function
_start:
    csrci mstatus, 8
    csrw mie, zero
    csrw medeleg, zero
    csrw mideleg, zero
    /* Keep MPRV, FS and VS clear: every compiled module is integer-only. */
    li t0, ((1 << 17) | (3 << 13) | (3 << 9))
    csrc mstatus, t0
    csrw satp, zero
    sfence.vma
    bnez a0, bedrock_riscv_loader_halt
    mv s0, a0
    mv s1, a1
    la gp, __global_pointer$
    li tp, 0
    la sp, __loader_stack_top
    la t0, __loader_trap
    csrw mtvec, t0

    la t0, __bss_start
    la t1, __bss_end
.Lloader_bss:
    bgeu t0, t1, .Lloader_initialized
    sd zero, 0(t0)
    addi t0, t0, 8
    j .Lloader_bss
.Lloader_initialized:
    mv a0, s0
    mv a1, s1
    call bedrock_riscv_loader_main
    j bedrock_riscv_loader_halt
.size _start, . - _start

.section .text, "ax", @progbits
.balign 16
.global __loader_trap
.type __loader_trap, @function
__loader_trap:
    csrci mstatus, 8
    csrr a0, mcause
    csrr a1, mepc
    csrr a2, mtval
    call bedrock_riscv_loader_fault
    j bedrock_riscv_loader_halt
.size __loader_trap, . - __loader_trap

.global bedrock_riscv_loader_misa
.type bedrock_riscv_loader_misa, @function
bedrock_riscv_loader_misa:
    csrr a0, misa
    ret
.size bedrock_riscv_loader_misa, . - bedrock_riscv_loader_misa

.global bedrock_riscv_loader_jump
.type bedrock_riscv_loader_jump, @function
/* a0=entry, a1=BootInfo, a2=bytes. Kernel owns its stack and gp. */
bedrock_riscv_loader_jump:
    mv t0, a0
    mv a0, a1
    mv a1, a2
    fence iorw, iorw
    fence.i
    jr t0
.size bedrock_riscv_loader_jump, . - bedrock_riscv_loader_jump

.global bedrock_riscv_io_fence
.type bedrock_riscv_io_fence, @function
bedrock_riscv_io_fence:
    fence iorw, iorw
    ret
.size bedrock_riscv_io_fence, . - bedrock_riscv_io_fence

.global bedrock_riscv_loader_exit
.type bedrock_riscv_loader_exit, @function
bedrock_riscv_loader_exit:
    li t0, 0x100000
    beqz a0, .Lloader_exit_pass
    li t1, 0x13333
    j .Lloader_exit
.Lloader_exit_pass:
    li t1, 0x5555
.Lloader_exit:
    fence iorw, iorw
    sw t1, 0(t0)
    fence iorw, iorw
    j bedrock_riscv_loader_halt
.size bedrock_riscv_loader_exit, . - bedrock_riscv_loader_exit

.global bedrock_riscv_loader_halt
.type bedrock_riscv_loader_halt, @function
bedrock_riscv_loader_halt:
    csrci mstatus, 8
    csrw mie, zero
.Lloader_halt:
    wfi
    j .Lloader_halt
.size bedrock_riscv_loader_halt, . - bedrock_riscv_loader_halt

.section .note.GNU-stack, "", @progbits
