.section .text.entry,"ax",@progbits
.balign 16
.global _start
.type _start,@function
_start:
    /* A0/A1/A2 retain trusted launch arguments. Disable relaxation while
     * computing GP, since the incoming user GP has not been established. */
    .option push
    .option norelax
    lla gp, __global_pointer$
    .option pop
    li tp, 0
    li s0, 0
    call bedrock_user_main
    ebreak
.size _start, . - _start
.section .note.GNU-stack,"",@progbits
