/* Shared bounded ELF64 PIE layout for trusted Bedrock driver modules. */
ENTRY(bedrock_driver_entry)
PHDRS
{
    ro PT_LOAD FILEHDR PHDRS FLAGS(4);
    text PT_LOAD FLAGS(5);
    data PT_LOAD FLAGS(6);
    dynamic PT_DYNAMIC FLAGS(6);
    note PT_NOTE FLAGS(4);
}
SECTIONS
{
    . = SIZEOF_HEADERS;
    .driver_note : ALIGN(4) { KEEP(*(.note.bedrock)) KEEP(*(.driver_note)) } :ro :note
    .rodata : ALIGN(8) { *(.rodata .rodata.*) } :ro
    .dynsym : ALIGN(8) { *(.dynsym) } :ro
    .dynstr : ALIGN(8) { *(.dynstr) } :ro
    .hash : ALIGN(8) { *(.hash) } :ro
    .gnu.hash : ALIGN(8) { *(.gnu.hash) } :ro
    .rela.dyn : ALIGN(8) { *(.rela.dyn) } :ro

    . = ALIGN(4096);
    .text : ALIGN(16) { *(.text .text.*) } :text

    . = ALIGN(4096);
    .data : ALIGN(8) { *(.data .data.*) *(.sdata .sdata.*) *(.got .got.*) } :data
    .dynamic : ALIGN(8) { *(.dynamic) } :data :dynamic
    .bss (NOLOAD) : ALIGN(16) { *(.bss .bss.*) *(.sbss .sbss.*) *(COMMON) } :data
    /DISCARD/ : { *(.eh_frame .eh_frame.*) *(.comment) *(.note.GNU-stack) }
}
