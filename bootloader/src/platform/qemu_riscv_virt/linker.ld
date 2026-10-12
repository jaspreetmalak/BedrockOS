/* M-mode RAM firmware ELF, loaded by QEMU's reset ROM without OpenSBI. */
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
    . = 0x80000000;
    .text : ALIGN(16)
    {
        KEEP(*(.text.boot))
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
        __data_start = .;
        *(.data .data.*)
        __global_pointer$ = . + 0x800;
        *(.sdata .sdata.*)
        *(.got .got.*)
        . = ALIGN(16);
        __data_end = .;
    } :data
    __loader_image_end = .;
    .bss (NOLOAD) : ALIGN(16)
    {
        __bss_start = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        . = ALIGN(16);
        __bss_end = .;
    } :data
    __loader_allocated_end = .;

    /* BootInfo can occupy loader data/BSS or the 128 KiB stack. */
    __loader_stack_bottom = 0x800e0000;
    __loader_stack_top = 0x80100000;
    __dtb_copy_start = 0x80100000;
    __dtb_copy_limit = 0x80180000;
    __loader_reserved_end = 0x80200000;

    /DISCARD/ :
    {
        *(.comment)
        *(.note .note.*)
        *(.eh_frame .eh_frame.*)
    }
}

ASSERT(_start == 0x80000000, "RV64 firmware entry must be at RAM base")
ASSERT(__loader_allocated_end <= __loader_stack_bottom, "RV64 loader sections overlap its stack")
ASSERT((__bss_start & 7) == 0 && (__bss_end & 7) == 0, "RV64 loader BSS must permit 64-bit clearing")
ASSERT((__loader_stack_top & 15) == 0, "RV64 loader stack must be 16-byte aligned")
ASSERT((__loader_trap & 3) == 0, "RV64 direct mtvec must be four-byte aligned")
