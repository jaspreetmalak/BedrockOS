ENTRY(_start)
PHDRS
{
    code PT_LOAD FLAGS(5);
    data PT_LOAD FLAGS(6);
}
SECTIONS
{
    . = 0x2000000000;
    .text : ALIGN(16)
    {
        KEEP(*(.text.entry))
        *(.text .text.*)
        *(.rodata .rodata.* .srodata .srodata.*)
    } :code
    __user_body_end = .;
    ASSERT(__user_body_end <= 0x2000000ffc, "user code/rodata exceeds first-profile body")
    .text.boundary 0x2000000ffc :
    {
        KEEP(*(.bedrock.boundary))
    } :code
    ASSERT(SIZEOF(.text.boundary) == 0 || SIZEOF(.text.boundary) == 4, "boundary probe must occupy final four code bytes")
    __user_code_end = .;
    . = 0x2000001000;
    .data : ALIGN(16)
    {
        *(.data .data.* .sdata .sdata.*)
        *(.got .got.*)
    } :data
    .bss (NOLOAD) : ALIGN(16)
    {
        *(.bss .bss.* .sbss .sbss.*)
        *(COMMON)
    } :data
    __user_data_end = .;
    PROVIDE(__global_pointer$ = 0x2000001800);
    ASSERT(__user_data_end > 0x2000001000, "user data page must contain the entry counter")
    ASSERT(__user_data_end <= 0x2000002000, "user data/BSS exceeds first-profile page")
    /DISCARD/ :
    {
        *(.eh_frame .eh_frame.* .eh_frame_hdr)
        *(.note .note.* .comment .riscv.attributes)
    }
}
