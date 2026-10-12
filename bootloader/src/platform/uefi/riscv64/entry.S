/* Standard RV64 UEFI has LP64 ABI and executes in Supervisor mode. */
.option norvc
.option norelax
.text
.balign 16
.global bedrock_uefi_run_on_stack
bedrock_uefi_run_on_stack:
    mv t0, sp
    mv t1, ra
    mv t2, a0
    mv sp, a2
    addi sp, sp, -16
    sd t0, 0(sp)
    sd t1, 8(sp)
    mv a0, a1
    jalr t2
    ld t0, 0(sp)
    ld ra, 8(sp)
    mv sp, t0
    ret
.global bedrock_uefi_halt
.global bedrock_uefi_publish_code
bedrock_uefi_publish_code:
    fence rw, rw
    fence.i
    ret
bedrock_uefi_halt:
    csrci sstatus, 2
    csrw sie, zero
1:  wfi
    j 1b
.global bedrock_uefi_smoke_exit
bedrock_uefi_smoke_exit:
    /* Firmware may not map the test device; this emulator-only terminal path
       cannot return to firmware and takes ownership of translation first. */
    csrci sstatus, 2
    csrw sie, zero
    lla t0, .Lstop_fault
    csrw stvec, t0
    csrw satp, zero
    sfence.vma
    li t0, 0x100000
    li t1, 0x5555
    beqz a0, 2f
    li t1, 0x13333
2:  fence iorw, iorw
    sw t1, 0(t0)
    fence iorw, iorw
    j bedrock_uefi_halt
.Lstop_fault:
    wfi
    j .Lstop_fault
.global bedrock_uefi_io_fence
bedrock_uefi_io_fence:
    fence iorw, iorw
    ret

/* entry, info, bytes, arena-base, arena-bytes, transition-stack-top.
   No GP-relative accesses or absolute addresses occur in the copied block. */
.balign 4096
.global bedrock_uefi_transition_start
bedrock_uefi_transition_start:
    csrci sstatus, 2
    csrw sie, zero
    lla t0, .Ltransition_fault
    csrw stvec, t0
    li t0, ((1 << 18) | (1 << 19) | (3 << 13) | (3 << 9))
    csrc sstatus, t0
    csrw satp, zero
    sfence.vma
    fence iorw, iorw
    fence.i
    mv t0, a0
    mv a0, a1
    mv a1, a2
    mv a2, a3
    mv a3, a4
    mv sp, a5
    jr t0
.Ltransition_fault:
    csrci sstatus, 2
3:  wfi
    j 3b
.global bedrock_uefi_transition_end
bedrock_uefi_transition_end:
