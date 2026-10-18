/* The reset ROM copies initialized bytes to [2 MiB, 4 MiB). */
OUTPUT_ARCH(i386:x86-64)
ENTRY(_start)
PHDRS
{
    text PT_LOAD FLAGS(5);
    rodata PT_LOAD FLAGS(4);
    data PT_LOAD FLAGS(6);
}
SECTIONS
{
    . = 0x200000;
    __kernel_image_start = .;
    .text : ALIGN(16)
    {
        KEEP(*(.text.entry))
        *(.text .text.*)
    } :text
    .rodata : ALIGN(16)
    {
        *(.rodata .rodata.*)
        *(.data.rel.ro .data.rel.ro.*)
    } :rodata
    .data : ALIGN(16)
    {
        *(.data .data.*)
        *(.got .got.*)
    } :data
    __kernel_image_end = .;
    .bss (NOLOAD) : ALIGN(16)
    {
        __bss_start = .;
        *(.bss .bss.*)
        *(COMMON)
        . = ALIGN(16);
        __bss_end = .;
    } :data
    __stack_bottom = 0x3e0000;
    __stack_top = 0x400000;
    /DISCARD/ : { *(.comment) *(.note .note.*) *(.eh_frame .eh_frame.*) }
}
ASSERT(_start == 0x200000, "kernel entry must be the first copied byte")
ASSERT(__bss_end <= __stack_bottom, "kernel sections overlap its 128 KiB stack")
ASSERT((__stack_top & 15) == 0, "kernel stack must be 16-byte aligned")
