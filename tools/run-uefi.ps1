[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)][string]$QemuExecutable,
    [Parameter(Mandatory = $true, Position = 1)][string]$EspDirectory,
    [Parameter(Mandatory = $true, Position = 2)][string]$UefiCode,
    [Parameter(Mandatory = $true, Position = 3)][string]$UefiVars,
    [Parameter(Position = 4)][ValidateRange(128, 65536)][int]$RamMiB = 128,
    [Parameter(Position = 5)][ValidateSet('x86_64', 'arm64', 'riscv64')][string]$Architecture = 'x86_64',
    [Parameter(Position = 6)][string]$DataImage,
    [switch]$Network
)
$ErrorActionPreference = 'Stop'
foreach ($bedrockFile in @($UefiCode, $UefiVars)) {
    if (-not (Test-Path -LiteralPath $bedrockFile -PathType Leaf)) { throw "Missing UEFI firmware: $bedrockFile" }
}
$bedrockFilename = switch ($Architecture) { 'arm64' { 'BOOTAA64.EFI' } 'riscv64' { 'BOOTRISCV64.EFI' } default { 'BOOTX64.EFI' } }
if (-not (Test-Path -LiteralPath (Join-Path $EspDirectory "EFI\BOOT\$bedrockFilename") -PathType Leaf)) {
    throw "The ESP directory must contain EFI\BOOT\$bedrockFilename."
}
$bedrockPython = (Get-Command python -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$bedrockImageTool = Join-Path $PSScriptRoot 'make-data-image.py'
if ([string]::IsNullOrWhiteSpace($DataImage)) {
    $DataImage = Join-Path (Split-Path -Parent $PSScriptRoot) "zig-out\data\$Architecture.img"
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $DataImage)) | Out-Null
}
# Reuse existing media without formatting. Reject device namespaces, non-files
# and symlinks before any writable QEMU attachment.
$bedrockValidateImage = 'import runpy,sys; from pathlib import Path; runpy.run_path(sys.argv[1])[sys.argv[3]](Path(sys.argv[2]))'
& $bedrockPython -c $bedrockValidateImage $bedrockImageTool $DataImage validate_output
if ($LASTEXITCODE -ne 0) { throw 'The data image must be an ordinary file in an existing directory.' }
if (-not (Test-Path -LiteralPath $DataImage -PathType Leaf)) {
    & $bedrockPython $bedrockImageTool $DataImage
    if ($LASTEXITCODE -ne 0) { throw 'Could not create the missing Bedrock data image.' }
}
$bedrockDataPath = (Resolve-Path -LiteralPath $DataImage).ProviderPath.Replace(',', ',,')
$bedrockMachine = switch ($Architecture) { 'arm64' { 'virt-10.1,secure=off,virtualization=off,acpi=off' } 'riscv64' { 'virt,acpi=off' } default { 'pc-q35-10.1' } }
$bedrockCpu = switch ($Architecture) { 'arm64' { 'cortex-a57' } 'riscv64' { 'rv64' } default { 'qemu64' } }
$bedrockArgs = @(
    '-machine', $bedrockMachine, '-cpu', $bedrockCpu, '-accel', 'tcg',
    '-smp', '1', '-m', "${RamMiB}M", '-serial', 'stdio', '-monitor', 'none',
    '-no-reboot', '-nic', 'none',
    '-drive', "if=pflash,format=raw,readonly=on,file=$UefiCode",
    '-drive', "if=pflash,format=raw,snapshot=on,file=$UefiVars"
)
if ($Architecture -eq 'x86_64') {
    $bedrockArgs += @('-drive', "format=raw,snapshot=on,file=fat:$EspDirectory",
        '-drive', "if=none,id=bedrock-data,format=raw,file=$bedrockDataPath",
        '-device', 'virtio-blk-pci,drive=bedrock-data,disable-legacy=on,serial=bedrock-data',
        '-device', 'virtio-keyboard-pci,disable-legacy=on', '-device', 'virtio-tablet-pci,disable-legacy=on')
} else {
    $bedrockArgs += @('-global', 'virtio-mmio.force-legacy=false',
        '-drive', "if=none,id=bedrock-esp,format=raw,snapshot=on,file=fat:$EspDirectory", '-device', 'virtio-blk-device,drive=bedrock-esp', '-device', 'ramfb',
        '-drive', "if=none,id=bedrock-data,format=raw,file=$bedrockDataPath", '-device', 'virtio-blk-device,drive=bedrock-data,serial=bedrock-data',
        '-device', 'virtio-keyboard-device', '-device', 'virtio-tablet-device')
    if ($Architecture -eq 'riscv64') { $bedrockArgs += @('-bios', 'default') }
}
if ($Network) {
    $bedrockArgs += @('-netdev', 'user,id=bedrock-net')
    $bedrockNetworkDevice = if ($Architecture -eq 'x86_64') { 'virtio-net-pci,disable-legacy=on,romfile=' } else { 'virtio-net-device' }
    $bedrockArgs += @('-device', "$bedrockNetworkDevice,netdev=bedrock-net,mac=52:54:00:12:34:57")
}
& $QemuExecutable @bedrockArgs
exit $LASTEXITCODE
