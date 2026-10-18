/* Zero-based ELF64 PIE, loaded and relocated to a firmware-allocated arena. */
ENTRY(_start)
PHDRS
{
    text PT_LOAD FLAGS(5);
    rodata PT_LOAD FLAGS(4);
    data PT_LOAD FLAGS(6);
    dynamic PT_DYNAMIC FLAGS(6);
}
SECTIONS
{
    . = 0;
    __kernel_image_start = .;
    __text_start = .;
    .text : ALIGN(16) { KEEP(*(.text.entry)) KEEP(*(.text.vectors)) *(.text .text.*) } :text
    . = ALIGN(4096);
    __text_end = .;
    __rodata_start = .;
    .rodata : { *(.rodata .rodata.*) *(.srodata .srodata.*) } :rodata
    .dynsym : { *(.dynsym) } :rodata
    .dynstr : { *(.dynstr) } :rodata
    .hash : { *(.hash) } :rodata
    .gnu.hash : { *(.gnu.hash) } :rodata
    .rela.dyn : { *(.rela.dyn) *(.rela.*) } :rodata
    . = ALIGN(4096);
    __rodata_end = .;
    __data_start = .;
    .data : { *(.data .data.*) *(.data.rel.ro .data.rel.ro.*) __global_pointer$ = . + 0x800; *(.sdata .sdata.*) *(.got .got.*) } :data
    .dynamic : { *(.dynamic) } :data :dynamic
    __kernel_image_end = .;
    .bss (NOLOAD) : ALIGN(16) { __bss_start = .; *(.bss .bss.*) *(.sbss .sbss.*) *(COMMON) . = ALIGN(16); __bss_end = .; } :data
    . = ALIGN(4096);
    __data_end = .;
    .stack 0x3e0000 (NOLOAD) : {
        __stack_bottom = .;
        __stack_guard = . - 0x1000;
        . += 0x20000;
    } :data
    __stack_top = .;
    __kernel_allocated_end = .;
    /DISCARD/ : { *(.comment) *(.note .note.*) *(.eh_frame .eh_frame.*) }
}
ASSERT(_start == 0, "PIE kernel entry must be first")
ASSERT(__data_end <= __stack_guard, "PIE kernel overlaps its stack guard")
ASSERT(__stack_top == 0x400000, "PIE kernel allocation must be 4 MiB")
