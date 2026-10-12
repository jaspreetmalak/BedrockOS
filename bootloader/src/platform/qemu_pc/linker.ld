/* Fixed 2 MiB reset ROM and writable loader arena for pc-i440fx-10.1. */
OUTPUT_ARCH(i386:x86-64)
ENTRY(_start)
MEMORY
{
    ROM (rx) : ORIGIN = 0xffe00000, LENGTH = 0x200000
    LOADER_RAM (rw) : ORIGIN = 0x100000, LENGTH = 0x80000
    PAGE_TABLES (rw) : ORIGIN = 0x180000, LENGTH = 0x6000
    STACK (rw) : ORIGIN = 0x1f0000, LENGTH = 0x10000
}
SECTIONS
{
    .text ORIGIN(ROM) : { *(.text .text.*) *(.ltext .ltext.*) } > ROM
    .rodata : ALIGN(16)
    {
        *(.rodata .rodata.*)
        *(.lrodata .lrodata.*)
        *(.data.rel.ro .data.rel.ro.*)
        . = ALIGN(16);
        __rom_payload_end = .;
    } > ROM
    .data ORIGIN(LOADER_RAM) :
    {
        __data_start = .;
        *(.data .data.*)
        *(.ldata .ldata.*)
        *(.got .got.*)
        . = ALIGN(16);
        __data_end = .;
    } > LOADER_RAM AT> ROM
    __data_load_start = LOADADDR(.data);
    __data_load_end = LOADADDR(.data) + SIZEOF(.data);
    .bss (NOLOAD) : ALIGN(16)
    {
        __bss_start = .;
        *(.bss .bss.*)
        *(.lbss .lbss.*)
        *(COMMON)
        . = ALIGN(16);
        __bss_end = .;
    } > LOADER_RAM
    .page_tables ORIGIN(PAGE_TABLES) (NOLOAD) :
    {
        __page_tables_start = .;
        __pml4 = .; . += 0x1000;
        __pdpt = .; . += 0x1000;
        __pd0 = .; . += 0x4000;
        __page_tables_end = .;
    } > PAGE_TABLES
    .stack ORIGIN(STACK) (NOLOAD) :
    {
        __loader_stack_bottom = .;
        . += LENGTH(STACK);
        __loader_stack_top = .;
    } > STACK
    /* In the last 32 KiB: reset near jump retains the hidden CS base. */
    .boot16 0xffff8000 : { KEEP(*(.boot16)) } > ROM
    .reset 0xfffffff0 : { KEEP(*(.reset)) } > ROM
    /DISCARD/ : { *(.comment) *(.note .note.*) *(.eh_frame .eh_frame.*) *(.eh_frame_hdr) }
}
ASSERT(__data_load_start >= __rom_payload_end, "data load image overlaps ROM payload")
ASSERT(__data_load_end <= 0xffff8000, "firmware payload overlaps reset startup")
ASSERT(__bss_end <= 0x180000, "loader BSS overlaps page tables")
ASSERT(__page_tables_end == 0x186000, "page-table allocation changed")
ASSERT(__loader_stack_top == 0x200000, "loader stack top changed")
ASSERT(SIZEOF(.boot16) <= 0x7ff0, "reset startup overlaps reset vector")
ASSERT(_start == 0xfffffff0, "x86 reset vector moved")
ASSERT(SIZEOF(.reset) == 16, "ROM must end exactly at 4 GiB")
