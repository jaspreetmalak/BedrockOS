/* UEFI uses AAPCS64. Transition is copied to a page-aligned owned arena. */
.text
.balign 16
.global bedrock_uefi_run_on_stack
bedrock_uefi_run_on_stack:
    mov x8, x0
    mov x9, sp
    mov x10, x30
    mov sp, x2
    sub sp, sp, #16
    stp x9, x10, [sp]
    mov x0, x1
    blr x8
    ldp x9, x30, [sp]
    mov sp, x9
    ret
.global bedrock_uefi_current_el
bedrock_uefi_current_el:
    mrs x0, CurrentEL
    lsr x0, x0, #2
    ret
.global bedrock_uefi_physical_bits
bedrock_uefi_physical_bits:
    mrs x1, id_aa64mmfr0_el1
    and x1, x1, #15
    mov w0, #32
    cbz x1, 1f
    mov w0, #36
    cmp x1, #1
    b.eq 1f
    mov w0, #40
    cmp x1, #2
    b.eq 1f
    mov w0, #42
    cmp x1, #3
    b.eq 1f
    mov w0, #44
    cmp x1, #4
    b.eq 1f
    mov w0, #48
    cmp x1, #5
    b.eq 1f
    mov w0, #52
    cmp x1, #6
    b.eq 1f
    mov w0, #0
1:  ret

/* Publish newly written instructions before executing the copied transition.
   CTR_EL0 supplies the separate instruction/data line sizes. */
.global bedrock_uefi_publish_code
bedrock_uefi_publish_code:
    add x2, x0, x1
    mrs x3, ctr_el0
    ubfx x4, x3, #16, #4
    mov x5, #4
    lsl x4, x5, x4
    sub x6, x4, #1
    bic x6, x0, x6
.Lpublish_data:
    cmp x6, x2
    b.hs .Lpublish_data_done
    dc cvau, x6
    add x6, x6, x4
    b .Lpublish_data
.Lpublish_data_done:
    dsb ish
    and x3, x3, #15
    lsl x4, x5, x3
    sub x6, x4, #1
    bic x6, x0, x6
.Lpublish_instructions:
    cmp x6, x2
    b.hs .Lpublish_done
    ic ivau, x6
    add x6, x6, x4
    b .Lpublish_instructions
.Lpublish_done:
    dsb ish
    isb
    ret

.global bedrock_uefi_halt
bedrock_uefi_halt:
    msr daifset, #15
2:  wfi
    b 2b
.global bedrock_uefi_smoke_exit
bedrock_uefi_smoke_exit:
    sub sp, sp, #16
    mov x2, #0x26
    movk x2, #2, lsl #16
    stp x2, x0, [sp]
    mov x0, #0x20
    mov x1, sp
    hlt #0xf000
    b bedrock_uefi_halt

/* entry, info, bytes, arena-base, arena-bytes, transition-stack-top. */
.balign 4096
.global bedrock_uefi_transition_start
bedrock_uefi_transition_start:
    msr daifset, #15
    mov x19, x0
    mov x20, x1
    mov x21, x2
    mov x22, x3
    mov x23, x4
    mov x24, x5
    mrs x25, CurrentEL
    adr x0, .Ltransition_vectors
    cmp x25, #8
    b.eq .Lvbar_el2
    msr vbar_el1, x0
    b .Lvbar_ready
.Lvbar_el2:
    msr vbar_el2, x0
.Lvbar_ready:
    isb
    /* UEFI guarantees identity RAM and architecturally manageable caches.
       Clean every data/unified cache by set/way before disabling caching;
       this preserves dirty firmware runtime tables as well as our copies.
       Both legacy and FEAT_CCIDX CCSIDR layouts are decoded. */
    dsb sy
    mrs x0, clidr_el1
    mrs x1, id_aa64mmfr2_el1
    ubfx x1, x1, #20, #4
    mov x2, #0
.Lcache_level:
    cmp x2, #7
    b.hs .Lcache_done
    add x3, x2, x2, lsl #1
    lsr x4, x0, x3
    and x4, x4, #7
    cmp x4, #2
    b.lo .Lcache_next
    cmp x4, #4
    b.hi .Lcache_next
    lsl x3, x2, #1
    msr csselr_el1, x3
    isb
    mrs x4, ccsidr_el1
    and x5, x4, #7
    add x5, x5, #4
    cbnz x1, .Lccidx
    ubfx x6, x4, #3, #10
    ubfx x7, x4, #13, #15
    b .Lcache_geometry
.Lccidx:
    ubfx x6, x4, #3, #21
    ubfx x7, x4, #32, #24
.Lcache_geometry:
    clz w8, w6
.Lcache_set:
    mov x9, x6
.Lcache_way:
    lsl w10, w9, w8
    lsl x11, x7, x5
    orr x10, x10, x11
    orr x10, x10, x3
    dc cisw, x10
    subs x9, x9, #1
    b.ge .Lcache_way
    subs x7, x7, #1
    b.ge .Lcache_set
.Lcache_next:
    add x2, x2, #1
    b .Lcache_level
.Lcache_done:
    msr csselr_el1, xzr
    dsb sy
    isb
    mov x12, #0x1005
    cmp x25, #8
    b.eq .Ldisable_el2
    mrs x0, sctlr_el1
    bic x0, x0, x12
    msr sctlr_el1, x0
    isb
    tlbi vmalle1
    dsb sy
    ic iallu
    dsb sy
    isb
    mov sp, x24
    b .Lenter_el1
.Ldisable_el2:
    mrs x0, sctlr_el2
    bic x0, x0, x12
    msr sctlr_el2, x0
    isb
    tlbi alle2
    dsb sy
    ic iallu
    dsb sy
    isb
    mov sp, x24
    /* Own EL1 execution and translation state; do not inherit unknown EL1
       stage-1 settings from firmware running at EL2. */
    mov x0, #0x80000000
    msr hcr_el2, x0
    /* Baseline non-VHE CPTR_EL2 RES1 bits [13:12], [9:0]. */
    mov x0, #0x33ff
    msr cptr_el2, x0
    msr vttbr_el2, xzr
    mov x0, #0x0800
    movk x0, #0x30d0, lsl #16
    msr sctlr_el1, x0
    msr ttbr0_el1, xzr
    msr ttbr1_el1, xzr
    msr tcr_el1, xzr
    msr cntvoff_el2, xzr
    mrs x0, cnthctl_el2
    orr x0, x0, #3
    msr cnthctl_el2, x0
    adr x0, .Ltransition_vectors
    msr vbar_el1, x0
    msr sp_el1, x24
    adr x0, .Lenter_el1
    msr elr_el2, x0
    mov x0, #0x3c5
    msr spsr_el2, x0
    isb
    eret
.Lenter_el1:
    msr spsel, #1
    mrs x0, cpacr_el1
    orr x0, x0, #(3 << 20)
    msr cpacr_el1, x0
    isb
    mov x0, x20
    mov x1, x21
    mov x2, x22
    mov x3, x23
    br x19
.Ltransition_fault:
    msr daifset, #15
3:  wfi
    b 3b
.balign 2048
.Ltransition_vectors:
.rept 16
    b .Ltransition_fault
    .space 124
.endr
.global bedrock_uefi_transition_end
bedrock_uefi_transition_end:
