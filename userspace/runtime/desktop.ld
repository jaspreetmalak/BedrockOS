ENTRY(_start)
PHDRS { code PT_LOAD FLAGS(5); data PT_LOAD FLAGS(6); }
SECTIONS
{
    . = 0x2000010000;
    .text : ALIGN(16) {
        KEEP(*(.text.entry))
        *(.text .text.*) *(.rodata .rodata.* .srodata .srodata.*)
    } :code
    ASSERT(. <= 0x2000030000, "desktop RX exceeds 128KiB")
    . = 0x2000040000;
    .data : ALIGN(16) { *(.data .data.* .sdata .sdata.*) *(.got .got.*) } :data
    .bss (NOLOAD) : ALIGN(16) { *(.bss .bss.* .sbss .sbss.*) *(COMMON) } :data
    PROVIDE(__global_pointer$ = 0x2000040800);
    ASSERT(. <= 0x2000140000, "desktop RW exceeds 1MiB")
    /DISCARD/ : { *(.eh_frame .eh_frame.* .eh_frame_hdr) *(.note .note.* .comment .riscv.attributes) }
}
