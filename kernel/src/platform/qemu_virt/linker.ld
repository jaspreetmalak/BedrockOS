/* Physical layout for the named QEMU virt-10.1 ARM64 platform. */
ENTRY(_start)

PHDRS
{
    text PT_LOAD FLAGS(5);
    rodata PT_LOAD FLAGS(4);
    data PT_LOAD FLAGS(6);
}

SECTIONS
{
    . = 0x40200000;
    __kernel_image_start = .;

    .text : ALIGN(16)
    {
        KEEP(*(.text.entry))
        KEEP(*(.text.vectors))
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
        *(.sdata .sdata.*)
        *(.got .got.*)
    } :data
    __kernel_image_end = .;

    .bss (NOLOAD) : ALIGN(16)
    {
        __bss_start = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        . = ALIGN(16);
        __bss_end = .;
    } :data
    __kernel_allocated_end = .;

    /* The handoff reserves the whole [0x40200000, 0x40400000) range. */
    __stack_bottom = 0x403e0000;
    __stack_top = 0x40400000;

    ASSERT(__kernel_image_start == 0x40200000, "kernel load address changed")
    ASSERT(_start == __kernel_image_start, "kernel entry must be the first initialized byte")
    ASSERT(__kernel_allocated_end <= __stack_bottom, "kernel sections overlap the 128 KiB stack")
    ASSERT((__bss_start & 7) == 0 && (__bss_end & 7) == 0, "BSS must permit 64-bit clearing")
    ASSERT((bedrock_exception_vectors & 0x7ff) == 0, "VBAR_EL1 table must be 2 KiB aligned")

    /DISCARD/ :
    {
        *(.comment)
        *(.note .note.*)
        *(.eh_frame .eh_frame.*)
    }
}
