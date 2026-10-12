.section .text.entry,"ax",@progbits
.code64
.global _start
.type _start,@function
_start:
    /* Kernel entry supplies a page-aligned top, without a CALL return address.
     * Align before CALL so the C callee sees RSP%16==8 as SysV requires. */
    andq $-16, %rsp
    xorq %rbp, %rbp
    cld
    call bedrock_user_main
    ud2
.size _start, . - _start
.section .note.GNU-stack,"",@progbits
