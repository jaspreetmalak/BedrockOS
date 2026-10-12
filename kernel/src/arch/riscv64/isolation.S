/* Cooperative and timer-preempted U-mode entry. Reset M-mode never uses it. */
.option norvc
.option norelax
.section .text, "ax", @progbits
.balign 16
.macro SAVE_KERNEL_CONTINUATION
    addi sp, sp, -176
    sd ra, 0(sp)
    sd s0, 8(sp)
    sd s1, 16(sp)
    sd s2, 24(sp)
    sd s3, 32(sp)
    sd s4, 40(sp)
    sd s5, 48(sp)
    sd s6, 56(sp)
    sd s7, 64(sp)
    sd s8, 72(sp)
    sd s9, 80(sp)
    sd s10, 88(sp)
    sd s11, 96(sp)
    sd gp, 104(sp)
    sd tp, 112(sp)
    csrr t0, sstatus
    sd t0, 120(sp)
    csrr t0, stvec
    sd t0, 128(sp)
    csrr t0, sscratch
    sd t0, 136(sp)
    csrr t0, satp
    sd t0, 144(sp)
    csrr t0, scounteren
    sd t0, 152(sp)
    csrr t0, sie
    sd t0, 160(sp)
    lla t0, .Lkernel_continuation
    sd sp, 0(t0)
    lla t0, bedrock_riscv_isolation_vector
    csrw stvec, t0
.endm

.global bedrock_riscv_isolation_enter
.type bedrock_riscv_isolation_enter, @function
/* a0=entry, a1=user SP, a2=trap-stack top, a3=satp, a4/a5/a6=user args.
 * Save the kernel's ABI state on its own stack before replacing every user GPR.
 * The caller serializes this one-hart continuation; no process may name it. */
bedrock_riscv_isolation_enter:
    SAVE_KERNEL_CONTINUATION
    csrw sie, zero
    csrw scounteren, zero
    li t0, ((1 << 1) | (1 << 5) | (1 << 8) | (1 << 18) | (1 << 19) | (3 << 13) | (3 << 9))
    csrc sstatus, t0
    csrw sepc, a0
    csrw sscratch, a2
    csrw satp, a3
    sfence.vma
    fence.i
    mv sp, a1
    mv a0, a4
    mv a1, a5
    mv a2, a6
    li ra, 0
    li gp, 0
    li tp, 0
    li t0, 0
    li t1, 0
    li t2, 0
    li t3, 0
    li t4, 0
    li t5, 0
    li t6, 0
    li s0, 0
    li s1, 0
    li s2, 0
    li s3, 0
    li s4, 0
    li s5, 0
    li s6, 0
    li s7, 0
    li s8, 0
    li s9, 0
    li s10, 0
    li s11, 0
    li a3, 0
    li a4, 0
    li a5, 0
    li a6, 0
    li a7, 0
    sret
.size bedrock_riscv_isolation_enter, . - bedrock_riscv_isolation_enter

.balign 16
.global bedrock_riscv_isolation_resume
.type bedrock_riscv_isolation_resume, @function
/* a0=saved integer frame, a1=trusted trap-stack top, a2=task satp.
 * Copy onto the supervisor trap stack, then use the exact trap-return path.
 * SIE stays clear in S mode. STIE can deliver only after entering U mode. */
bedrock_riscv_isolation_resume:
    SAVE_KERNEL_CONTINUATION
    csrw sie, zero
    csrw scounteren, zero
    csrw sscratch, zero
    li t0, ((1 << 1) | (1 << 18) | (1 << 19) | (3 << 13) | (3 << 9))
    csrc sstatus, t0
    csrw satp, a2
    sfence.vma
    fence.i
    addi sp, a1, -288
    mv t0, a0
    mv t1, sp
    li t2, 36
.Lcopy_saved_context:
    ld t3, 0(t0)
    sd t3, 0(t1)
    addi t0, t0, 8
    addi t1, t1, 8
    addi t2, t2, -1
    bnez t2, .Lcopy_saved_context
    li t0, (1 << 5)
    csrw sie, t0
    j .Lrestore_user_frame
.size bedrock_riscv_isolation_resume, . - bedrock_riscv_isolation_resume

/* SBI BASE probe_extension(TIME), returning 1 for any nonzero capability or
 * -1 on error. The SBI ABI preserves all registers other than a0/a1. */
.balign 16
.global bedrock_riscv_sbi_probe_time
.type bedrock_riscv_sbi_probe_time, @function
bedrock_riscv_sbi_probe_time:
    li a7, 0x10
    li a6, 3
    li a0, 0x54494d45
    ecall
    bnez a0, .Lsbi_probe_failed
    snez a0, a1
    ret
.Lsbi_probe_failed:
    li a0, -1
    ret
.size bedrock_riscv_sbi_probe_time, . - bedrock_riscv_sbi_probe_time

.global bedrock_riscv_sbi_set_timer
.type bedrock_riscv_sbi_set_timer, @function
bedrock_riscv_sbi_set_timer:
    li a7, 0x54494d45
    li a6, 0
    ecall
    ret
.size bedrock_riscv_sbi_set_timer, . - bedrock_riscv_sbi_set_timer

.global bedrock_riscv_read_time
.type bedrock_riscv_read_time, @function
bedrock_riscv_read_time:
    rdtime a0
    ret
.size bedrock_riscv_read_time, . - bedrock_riscv_read_time

.balign 16
.global bedrock_riscv_isolation_vector
.type bedrock_riscv_isolation_vector, @function
bedrock_riscv_isolation_vector:
    /* sscratch is a trusted supervisor stack while U mode runs, zero in the
     * handler. A nested S trap therefore never writes through a user SP. */
    csrrw sp, sscratch, sp
    bnez sp, .Luser_stack_switched
    csrrw sp, sscratch, sp
    addi sp, sp, -288
    sd t0, 40(sp)
    addi t0, sp, 288
    sd t0, 16(sp)
    j .Lsave_frame
.Luser_stack_switched:
    addi sp, sp, -288
    sd t0, 40(sp)
    csrr t0, sscratch
    sd t0, 16(sp)
    csrw sscratch, zero
.Lsave_frame:
    sd zero, 0(sp)
    sd ra, 8(sp)
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
    csrr t0, sepc
    sd t0, 256(sp)
    csrr t0, sstatus
    sd t0, 264(sp)
    csrr t0, scause
    sd t0, 272(sp)
    csrr t0, stval
    sd t0, 280(sp)
    lla gp, __global_pointer$
    li tp, 0
    mv a0, sp
    call bedrock_riscv_isolation_trap
    bnez a0, .Lreturn_kernel
.Lrestore_user_frame:
    ld t0, 256(sp)
    csrw sepc, t0
    ld t0, 264(sp)
    csrw sstatus, t0
    addi t0, sp, 288
    csrw sscratch, t0
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
    sret
.Lreturn_kernel:
    csrw sie, zero
    lla t0, .Lkernel_continuation
    ld sp, 0(t0)
    ld t0, 144(sp)
    csrw satp, t0
    sfence.vma
    ld t0, 128(sp)
    csrw stvec, t0
    ld t0, 136(sp)
    csrw sscratch, t0
    ld t0, 152(sp)
    csrw scounteren, t0
    ld t0, 160(sp)
    csrw sie, t0
    ld t0, 120(sp)
    csrw sstatus, t0
    ld ra, 0(sp)
    ld s0, 8(sp)
    ld s1, 16(sp)
    ld s2, 24(sp)
    ld s3, 32(sp)
    ld s4, 40(sp)
    ld s5, 48(sp)
    ld s6, 56(sp)
    ld s7, 64(sp)
    ld s8, 72(sp)
    ld s9, 80(sp)
    ld s10, 88(sp)
    ld s11, 96(sp)
    ld gp, 104(sp)
    ld tp, 112(sp)
    addi sp, sp, 176
    ret
.size bedrock_riscv_isolation_vector, . - bedrock_riscv_isolation_vector

/* This fixture contains no pointers into the kernel and no relocations. It is
 * copied to a private executable page; arguments identify only probe inputs. */
.section .rodata.user_probe, "a", @progbits
.balign 16
.global bedrock_riscv_user_program_start
.global bedrock_riscv_user_program_end
bedrock_riscv_user_program_start:
    mv s0, a0
    mv s1, a1
    mv s2, a2
    /* Prove the active root provides the private RW user stack. */
    addi sp, sp, -16
    sd s0, 0(sp)
    sd s1, 8(sp)
    ld s0, 0(sp)
    ld s1, 8(sp)
    addi sp, sp, 16
    beqz s0, .Luser_normal
    li t0, 1
    beq s0, t0, .Luser_read
    li t0, 2
    beq s0, t0, .Luser_read
    li t0, 3
    beq s0, t0, .Luser_write
    li t0, 4
    beq s0, t0, .Luser_execute
    li t0, 5
    beq s0, t0, .Luser_read
    li t0, 6
    beq s0, t0, .Luser_spin_start
    j .Luser_bad
.Luser_normal:
    li a7, 0
    li a0, 0x2000001000
    ld a2, 0(a0)
    li a1, 8
    ecall
    li t0, 8
    bne a0, t0, .Luser_bad
    li a7, 0
    mv a0, s1
    li a1, 8
    ecall
    li t0, -14
    bne a0, t0, .Luser_bad
    li a7, 0xffff
    ecall
    li t0, -38
    bne a0, t0, .Luser_bad
    li a7, 2
    mv a0, s2
    li a1, 0x2000001000
    li a2, 8
    ecall
    li t0, -13
    bne a0, t0, .Luser_bad
    li a7, 1
    li a0, 0
    ecall
    j .Luser_bad
.Luser_read:
    ld t0, 0(s1)
    j .Luser_bad
.Luser_write:
    sd zero, 0(s1)
    j .Luser_bad
.Luser_execute:
    jr s1
.Luser_spin_start:
    li s3, 0x2000001000
    /* A persistent entry count proves a resumed PC does not restart entry. */
    ld t0, 16(s3)
    addi t0, t0, 1
    sd t0, 16(s3)
    li s4, 0x1122334455667788
    li s5, 0x8877665544332211
    li s6, 0x123456789abcdef0
    li s7, 0xfedcba9876543210
    li s8, 0x18
    li s9, 0x19
    li s10, 0x1a
    li s11, 0x1b
    li ra, 0x21
    li gp, 0x23
    li tp, 0x24
    li a0, 0x2a
    li a1, 0x2b
    li a2, 0x2c
    li a3, 0x2d
    li a4, 0x2e
    li a5, 0x2f
    li a6, 0x30
    li a7, 0x31
    li t3, 0x3c
    li t4, 0x3d
    li t5, 0x3e
    li t6, 0x3f
    li t2, 0
    addi sp, sp, -16
    sd s1, 0(sp)
    sd s4, 8(sp)
.Luser_spin_loop:
    li t0, 6
    bne s0, t0, .Luser_bad
    bnez s2, .Luser_bad
    li t0, 0x2000001000
    bne s3, t0, .Luser_bad
    ld t1, 0(s3)
    bne t1, s1, .Luser_bad
    li t0, 0x1122334455667788
    bne s4, t0, .Luser_bad
    li t0, 0x8877665544332211
    bne s5, t0, .Luser_bad
    li t0, 0x123456789abcdef0
    bne s6, t0, .Luser_bad
    li t0, 0xfedcba9876543210
    bne s7, t0, .Luser_bad
    li t0, 0x18
    bne s8, t0, .Luser_bad
    li t0, 0x19
    bne s9, t0, .Luser_bad
    li t0, 0x1a
    bne s10, t0, .Luser_bad
    li t0, 0x1b
    bne s11, t0, .Luser_bad
    li t0, 0x21
    bne ra, t0, .Luser_bad
    li t0, 0x23
    bne gp, t0, .Luser_bad
    li t0, 0x24
    bne tp, t0, .Luser_bad
    li t0, 0x2a
    bne a0, t0, .Luser_bad
    li t0, 0x2b
    bne a1, t0, .Luser_bad
    li t0, 0x2c
    bne a2, t0, .Luser_bad
    li t0, 0x2d
    bne a3, t0, .Luser_bad
    li t0, 0x2e
    bne a4, t0, .Luser_bad
    li t0, 0x2f
    bne a5, t0, .Luser_bad
    li t0, 0x30
    bne a6, t0, .Luser_bad
    li t0, 0x31
    bne a7, t0, .Luser_bad
    li t0, 0x3c
    bne t3, t0, .Luser_bad
    li t0, 0x3d
    bne t4, t0, .Luser_bad
    li t0, 0x3e
    bne t5, t0, .Luser_bad
    li t0, 0x3f
    bne t6, t0, .Luser_bad
    li t0, 0x2000003ff0
    bne sp, t0, .Luser_bad
    ld t1, 0(sp)
    bne t1, s1, .Luser_bad
    ld t1, 8(sp)
    bne t1, s4, .Luser_bad
    ld t1, 8(s3)
    bne t1, t2, .Luser_bad
    addi t2, t2, 1
    sd t2, 8(s3)
    j .Luser_spin_loop
.Luser_bad:
    li a7, 1
    li a0, 99
    ecall
    j .Luser_bad
bedrock_riscv_user_program_end:

.section .bss, "aw", @nobits
.balign 8
.Lkernel_continuation:
    .zero 8
.section .note.GNU-stack, "", @progbits
