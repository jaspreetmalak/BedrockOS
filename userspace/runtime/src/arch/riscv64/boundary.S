.section .bedrock.boundary,"ax",@progbits
.balign 4
.global bedrock_user_boundary
.type bedrock_user_boundary,@function
bedrock_user_boundary:
    .4byte 0x00000073
.size bedrock_user_boundary, .-bedrock_user_boundary
.section .note.GNU-stack,"",@progbits
