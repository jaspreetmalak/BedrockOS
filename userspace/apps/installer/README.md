# Bedrock Installer

Native UEFI bootstrap application with separate presentation and disk mechanisms:

- `src/view.zig`: borrowed drive models, AxisUI views and explicit erase consent.
- `src/source_path.zig`: bounded source-disk ancestry protection.
- `src/core.zig`: bounded sparse payload validation, GPT creation and checked copying.
- `src/uefi_main.zig`: firmware disk discovery, input, GOP/backdrop and disk authority.

The installer stays in firmware mode; it is not a sandboxed desktop process.
Ordinary desktop apps retain their existing filesystem grants. The installed OS
boots independently and mounts its persistent data partition.

See the [installer guide](../../../docs/installer.md) for the reference machine
scope, partition layout, ordinary-file QEMU commands and validation contract.
