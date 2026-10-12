/* Selected ARM64 QEMU virt firmware profile; all addresses are physical. */
OUTPUT_ARCH(aarch64)
ENTRY(_start)

MEMORY
{
    FLASH (rx) : ORIGIN = 0x00000000, LENGTH = 0x04000000
    LOADER_RAM (rw) : ORIGIN = 0x40100000, LENGTH = 0x00080000
    LOADER_STACK (rw) : ORIGIN = 0x40180000, LENGTH = 0x00080000
}

SECTIONS
{
    .text ORIGIN(FLASH) :
    {
        __flash_start = .;
        KEEP(*(.text.boot))
        *(.text .text.*)
    } > FLASH

    .rodata :
    {
        . = ALIGN(16);
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
        . = ALIGN(16);
        __flash_payload_end = .;
    } > FLASH

    .data ORIGIN(LOADER_RAM) :
    {
        __data_start = .;
        *(.data .data.*)
        *(.sdata .sdata.*)
        *(.got .got.*)
        . = ALIGN(16);
        __data_end = .;
    } > LOADER_RAM AT> FLASH
    __data_load_start = LOADADDR(.data);
    __data_load_end = LOADADDR(.data) + SIZEOF(.data);
    __flash_image_end = __data_load_end;

    .bss (NOLOAD) :
    {
        . = ALIGN(16);
        __bss_start = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        . = ALIGN(16);
        __bss_end = .;
    } > LOADER_RAM

    .stack ORIGIN(LOADER_STACK) (NOLOAD) :
    {
        __loader_stack_bottom = .;
        . += LENGTH(LOADER_STACK);
        __loader_stack_top = .;
    } > LOADER_STACK

    /DISCARD/ :
    {
        *(.comment)
        *(.note .note.*)
        *(.eh_frame .eh_frame.*)
        *(.ARM.exidx .ARM.exidx.*)
        *(.ARM.extab .ARM.extab.*)
    }
}

ASSERT(_start == 0x00000000, "Firmware reset entry must be at flash address zero")
ASSERT(__data_start == 0x40100000, "Loader data VMA must match the startup contract")
ASSERT(__data_load_start >= __flash_payload_end, "Loader data LMA overlaps flash payload")
ASSERT(__bss_end <= 0x40180000, "Loader writable memory overlaps its stack")
ASSERT(__loader_stack_bottom == 0x40180000, "Loader stack bottom moved")
ASSERT(__loader_stack_top == 0x40200000, "Loader stack top moved")
ASSERT((__loader_stack_top & 15) == 0, "Loader stack must be 16-byte aligned")
ASSERT((__loader_vectors & 2047) == 0, "Loader vectors must be 2048-byte aligned")
ASSERT(__flash_image_end <= 0x04000000, "Firmware exceeds the first flash bank")
