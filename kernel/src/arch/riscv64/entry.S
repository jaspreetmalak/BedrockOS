/* Integer-only kernel: reset M-mode or UEFI S-mode, selected at build time. */
#ifdef BEDROCK_UEFI
#define STATUS sstatus
#define CAUSE scause
#define EPC sepc
#define TVAL stval
#define TVEC stvec
#define IE sie
#define INTERRUPT_ENABLE 2
#define TRAP_RETURN sret
#else
#define STATUS mstatus
#define CAUSE mcause
#define EPC mepc
#define TVAL mtval
#define TVEC mtvec
#define IE mie
#define INTERRUPT_ENABLE 8
#define TRAP_RETURN mret
#endif
.option norvc
.option norelax
.section .text.entry, "ax", @progbits
.balign 16
.global _start
.type _start, @function
_start:
    csrci STATUS, INTERRUPT_ENABLE
    csrw IE, zero
#ifndef BEDROCK_UEFI
    csrw medeleg, zero
    csrw mideleg, zero
    li t0, ((1 << 17) | (3 << 13) | (3 << 9))
#else
    /* Clear SUM/MXR and optional FP/vector state before integer-only code. */
    li t0, ((1 << 18) | (1 << 19) | (3 << 13) | (3 << 9))
#endif
    csrc STATUS, t0
    csrw satp, zero
    sfence.vma
#ifdef BEDROCK_UEFI
    csrw sscratch, zero
#endif
    mv s0, a0
    mv s1, a1
#ifdef BEDROCK_UEFI
    mv s2, a2
    mv s3, a3
#else
    li s2, 0x80000000
    li s3, 0x100000
#endif
    lla gp, __global_pointer$
    li tp, 0
    lla sp, __stack_top
    lla t0, bedrock_riscv_trap_vector
    csrw TVEC, t0
    lla t0, __bss_start
    lla t1, __bss_end
.Lkernel_bss:
    bgeu t0, t1, .Lkernel_initialized
    sd zero, 0(t0)
    addi t0, t0, 8
    j .Lkernel_bss
.Lkernel_initialized:
    mv a0, s0
    mv a1, s1
    mv a2, s2
    mv a3, s3
    call bedrock_riscv_kernel_main
    j bedrock_riscv_kernel_halt
.size _start, . - _start

.section .text.traps, "ax", @progbits
.balign 16
.global bedrock_riscv_trap_vector
.type bedrock_riscv_trap_vector, @function
bedrock_riscv_trap_vector:
    /* x0..x31 occupy slots0..248; mstatus at256, alignment padding at264. */
    addi sp, sp, -272
    sd zero, 0(sp)
    sd ra, 8(sp)
    sd t0, 40(sp)
    addi t0, sp, 272
    sd t0, 16(sp)
    sd gp, 24(sp)
    sd tp, 32(sp)
    sd t1, 48(sp)
    sd t2, 56(sp)
    sd s0, 64(sp)
    sd s1, 72(sp)
    sd a0, 80(sp)
    sd a1, 88(sp)
    sd a2, 96(sp)
    sd a3, 104(sp)
    sd a4, 112(sp)
    sd a5, 120(sp)
    sd a6, 128(sp)
    sd a7, 136(sp)
    sd s2, 144(sp)
    sd s3, 152(sp)
    sd s4, 160(sp)
    sd s5, 168(sp)
    sd s6, 176(sp)
    sd s7, 184(sp)
    sd s8, 192(sp)
    sd s9, 200(sp)
    sd s10, 208(sp)
    sd s11, 216(sp)
    sd t3, 224(sp)
    sd t4, 232(sp)
    sd t5, 240(sp)
    sd t6, 248(sp)
    csrr a3, STATUS
    sd a3, 256(sp)
    csrr a0, CAUSE
    csrr a1, EPC
    csrr a2, TVAL
    call bedrock_riscv_kernel_trap
    csrw EPC, a0
    ld t0, 256(sp)
    csrw STATUS, t0
    ld ra, 8(sp)
    ld gp, 24(sp)
    ld tp, 32(sp)
    ld t0, 40(sp)
    ld t1, 48(sp)
    ld t2, 56(sp)
    ld s0, 64(sp)
    ld s1, 72(sp)
    ld a0, 80(sp)
    ld a1, 88(sp)
    ld a2, 96(sp)
    ld a3, 104(sp)
    ld a4, 112(sp)
    ld a5, 120(sp)
    ld a6, 128(sp)
    ld a7, 136(sp)
    ld s2, 144(sp)
    ld s3, 152(sp)
    ld s4, 160(sp)
    ld s5, 168(sp)
    ld s6, 176(sp)
    ld s7, 184(sp)
    ld s8, 192(sp)
    ld s9, 200(sp)
    ld s10, 208(sp)
    ld s11, 216(sp)
    ld t3, 224(sp)
    ld t4, 232(sp)
    ld t5, 240(sp)
    ld t6, 248(sp)
    ld sp, 16(sp)
    TRAP_RETURN
.size bedrock_riscv_trap_vector, . - bedrock_riscv_trap_vector

.section .text, "ax", @progbits
.balign 16
.global bedrock_riscv_kernel_break
.global bedrock_riscv_break_instruction
.type bedrock_riscv_kernel_break, @function
bedrock_riscv_kernel_break:
bedrock_riscv_break_instruction:
    /* norvc guarantees this probe is the four-byte EBREAK, not C.EBREAK. */
    ebreak
    ret
.size bedrock_riscv_kernel_break, . - bedrock_riscv_kernel_break

.global bedrock_riscv_kernel_misa
.type bedrock_riscv_kernel_misa, @function
bedrock_riscv_kernel_misa:
#ifdef BEDROCK_UEFI
    li a0, 0
#else
    csrr a0, misa
#endif
    ret
.size bedrock_riscv_kernel_misa, . - bedrock_riscv_kernel_misa

.global bedrock_riscv_kernel_status
.type bedrock_riscv_kernel_status, @function
bedrock_riscv_kernel_status:
    csrr a0, STATUS
    ret
.size bedrock_riscv_kernel_status, . - bedrock_riscv_kernel_status

.global bedrock_riscv_kernel_translation
.type bedrock_riscv_kernel_translation, @function
bedrock_riscv_kernel_translation:
    csrr a0, satp
    ret
.size bedrock_riscv_kernel_translation, . - bedrock_riscv_kernel_translation

.global bedrock_riscv_io_fence
.type bedrock_riscv_io_fence, @function
bedrock_riscv_io_fence:
    fence iorw, iorw
    ret
.size bedrock_riscv_io_fence, . - bedrock_riscv_io_fence

.global bedrock_riscv_kernel_exit
.type bedrock_riscv_kernel_exit, @function
bedrock_riscv_kernel_exit:
    li t0, 0x100000
    beqz a0, .Lkernel_exit_pass
    li t1, 0x13333
    j .Lkernel_exit
.Lkernel_exit_pass:
    li t1, 0x5555
.Lkernel_exit:
    fence iorw, iorw
    sw t1, 0(t0)
    fence iorw, iorw
    j bedrock_riscv_kernel_halt
.size bedrock_riscv_kernel_exit, . - bedrock_riscv_kernel_exit

.global bedrock_riscv_kernel_halt
.type bedrock_riscv_kernel_halt, @function
bedrock_riscv_kernel_halt:
    csrci STATUS, INTERRUPT_ENABLE
    csrw IE, zero
.Lkernel_halt:
    wfi
    j .Lkernel_halt
.size bedrock_riscv_kernel_halt, . - bedrock_riscv_kernel_halt

.section .note.GNU-stack, "", @progbits
