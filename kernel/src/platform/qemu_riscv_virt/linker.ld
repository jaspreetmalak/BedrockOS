/* Integer-only M-mode kernel at its final physical RAM address. */
OUTPUT_ARCH(riscv)
ENTRY(_start)

PHDRS
{
    text PT_LOAD FLAGS(5);
    rodata PT_LOAD FLAGS(4);
    data PT_LOAD FLAGS(6);
}

SECTIONS
{
    . = 0x80200000;
    __kernel_image_start = .;
    .text : ALIGN(16)
    {
        KEEP(*(.text.entry))
        *(.text .text.*)
    } :text
    .rodata : ALIGN(16)
    {
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
        *(.data.rel.ro .data.rel.ro.*)
    } :rodata
    .data : ALIGN(16)
    {
        *(.data .data.*)
        __global_pointer$ = . + 0x800;
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
    __stack_bottom = 0x803f0000;
    __stack_top = 0x80400000;

    /DISCARD/ :
    {
        *(.comment)
        *(.note .note.*)
        *(.eh_frame .eh_frame.*)
    }
}

ASSERT(_start == 0x80200000, "RV64 kernel entry must be its first initialized byte")
ASSERT(__kernel_allocated_end <= __stack_bottom, "RV64 kernel sections overlap its stack")
ASSERT((__bss_start & 7) == 0 && (__bss_end & 7) == 0, "RV64 kernel BSS must permit 64-bit clearing")
ASSERT((__stack_top & 15) == 0, "RV64 kernel stack must be 16-byte aligned")
ASSERT((bedrock_riscv_trap_vector & 3) == 0, "RV64 direct mtvec must be four-byte aligned")
