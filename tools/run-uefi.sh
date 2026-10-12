#!/bin/sh
set -eu
if [ "$#" -lt 4 ] || [ "$#" -gt 8 ]; then
    echo 'Usage: run-uefi.sh QEMU ESP_DIRECTORY UEFI_CODE UEFI_VARS [RAM_MIB] [x86_64|arm64|riscv64] [DATA_IMAGE] [network|offline]' >&2
    exit 2
fi
case "${6:-x86_64}" in
    x86_64) filename=BOOTX64.EFI; machine=pc-q35-10.1; cpu=qemu64 ;;
    arm64) filename=BOOTAA64.EFI; machine=virt-10.1,secure=off,virtualization=off,acpi=off; cpu=cortex-a57 ;;
    riscv64) filename=BOOTRISCV64.EFI; machine=virt,acpi=off; cpu=rv64 ;;
    *) echo 'Unsupported architecture' >&2; exit 2 ;;
esac
test -f "$2/EFI/BOOT/$filename"
test -f "$3"
test -f "$4"
qemu_executable=$1
esp_directory=$2
firmware_code=$3
firmware_vars=$4
ram_mib=${5:-128}
architecture=${6:-x86_64}
network_mode=${8:-offline}
case "$network_mode" in network|offline) ;; *) echo 'Unsupported network mode' >&2; exit 2 ;; esac
script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
data_image=${7:-"$script_directory/../zig-out/data/$architecture.img"}
if [ "$#" -lt 7 ] || [ -z "$7" ]; then mkdir -p "$script_directory/../zig-out/data"; fi
# Validate existing media without writes. Format only a missing ordinary file.
python3 -c 'import runpy,sys; from pathlib import Path; runpy.run_path(sys.argv[1])["validate_output"](Path(sys.argv[2]))' "$script_directory/make-data-image.py" "$data_image"
if [ ! -f "$data_image" ]; then python3 "$script_directory/make-data-image.py" "$data_image"; fi
data_option=$(printf '%s' "$data_image" | sed 's/,/,,/g')
set -- -machine "$machine" -cpu "$cpu" -accel tcg \
    -smp 1 -m "${ram_mib}M" -serial stdio -monitor none -no-reboot -nic none \
    -drive "if=pflash,format=raw,readonly=on,file=$firmware_code" \
    -drive "if=pflash,format=raw,snapshot=on,file=$firmware_vars"
if [ "$architecture" = x86_64 ]; then
    set -- "$@" -drive "format=raw,snapshot=on,file=fat:$esp_directory" \
        -drive "if=none,id=bedrock-data,format=raw,file=$data_option" \
        -device virtio-blk-pci,drive=bedrock-data,disable-legacy=on,serial=bedrock-data \
        -device virtio-keyboard-pci,disable-legacy=on -device virtio-tablet-pci,disable-legacy=on
else
    set -- "$@" -global virtio-mmio.force-legacy=false \
        -drive "if=none,id=bedrock-esp,format=raw,snapshot=on,file=fat:$esp_directory" -device virtio-blk-device,drive=bedrock-esp -device ramfb \
        -drive "if=none,id=bedrock-data,format=raw,file=$data_option" -device virtio-blk-device,drive=bedrock-data,serial=bedrock-data \
        -device virtio-keyboard-device -device virtio-tablet-device
    if [ "$architecture" = riscv64 ]; then set -- "$@" -bios default; fi
fi
if [ "$network_mode" = network ]; then
    set -- "$@" -netdev user,id=bedrock-net
    if [ "$architecture" = x86_64 ]; then
        set -- "$@" -device virtio-net-pci,disable-legacy=on,romfile=,netdev=bedrock-net,mac=52:54:00:12:34:57
    else
        set -- "$@" -device virtio-net-device,netdev=bedrock-net,mac=52:54:00:12:34:57
    fi
fi
exec "$qemu_executable" "$@"
