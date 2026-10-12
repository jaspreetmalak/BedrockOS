# Compatibility entry point; the generic runner owns timeout and boot checks.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)] [string]$QemuExecutable,
    [Parameter(Mandatory = $true, Position = 1)] [string]$FirmwareImage,
    [Parameter(Position = 2)] [int]$TimeoutSeconds = 20
)
& (Join-Path $PSScriptRoot 'test-boot.ps1') arm64 $QemuExecutable $FirmwareImage $TimeoutSeconds
exit $LASTEXITCODE