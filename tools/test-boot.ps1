[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('arm64', 'x86_64', 'riscv64', 'x86_64-uefi', 'x86_64-uefi-image', 'arm64-uefi', 'riscv64-uefi')]
    [string]$Architecture,

    [Parameter(Mandatory = $true, Position = 1)]
    [ValidateNotNullOrEmpty()]
    [string]$QemuExecutable,

    [Parameter(Mandatory = $true, Position = 2)]
    [ValidateNotNullOrEmpty()]
    [string]$FirmwareImage,

    [Parameter(Position = 3)]
    [ValidateRange(1, 3600)]
    [int]$TimeoutSeconds = 60,

    [Parameter(Position = 4)]
    [ValidateRange(16, 65536)]
    [int]$RamMiB = 128,

    [Parameter(Position = 5)]
    [string]$UefiCode,

    [Parameter(Position = 6)]
    [string]$UefiVars
)

$ErrorActionPreference = 'Stop'
$bedrockArchTag = switch ($Architecture) {
    'arm64' { 'ARM64' }
    'arm64-uefi' { 'ARM64' }
    'x86_64' { 'x86_64' }
    'x86_64-uefi' { 'x86_64' }
    'x86_64-uefi-image' { 'x86_64' }
    'riscv64' { 'riscv64' }
    'riscv64-uefi' { 'riscv64' }
}
# isa-debug-exit transforms the x86 smoke value 0x10 into (0x10 << 1) | 1.
$bedrockIsUefi = $Architecture.Contains('-uefi')
$bedrockExpectedExitCode = if ($Architecture.StartsWith('x86_64')) { 33 } else { 0 }

# ProcessStartInfo.ArgumentList is unavailable in Windows PowerShell 5.
# Escape a single argv entry using the Windows/.NET command-line quoting rules.
function ConvertTo-BedrockQuotedArgument {
    param([string]$Argument)
    $bedrockQuoted = [regex]::Replace($Argument, '(\\*)"', '$1$1\"')
    $bedrockQuoted = [regex]::Replace($bedrockQuoted, '(\\+)$', '$1$1')
    return '"' + $bedrockQuoted + '"'
}

$bedrockProcess = $null
$bedrockStarted = $false
$bedrockStdout = ''
$bedrockStderr = ''
$bedrockFailure = $null
$bedrockDataDirectory = $null
$bedrockDataImage = $null

try {
    if (-not (Test-Path -LiteralPath $FirmwareImage -PathType Leaf)) {
        throw "Firmware image does not exist: $FirmwareImage"
    }
    $bedrockImagePath = (Resolve-Path -LiteralPath $FirmwareImage).ProviderPath
    $bedrockMachine = switch ($Architecture) {
        'arm64' { 'virt-10.1,secure=off,virtualization=off' }
        'arm64-uefi' { 'virt-10.1,secure=off,virtualization=off,acpi=off' }
        'x86_64' { 'pc-i440fx-10.1' }
        'x86_64-uefi' { 'pc-q35-10.1' }
        'x86_64-uefi-image' { 'pc-q35-10.1' }
        # Installed QEMU has no versioned RISC-V virt machine alias.
        'riscv64' { 'virt' }
        'riscv64-uefi' { 'virt,acpi=off' }
    }
    $bedrockCpu = switch ($Architecture) {
        'arm64' { 'cortex-a57' }
        'arm64-uefi' { 'cortex-a57' }
        'x86_64' { 'qemu64' }
        'x86_64-uefi' { 'qemu64' }
        'x86_64-uefi-image' { 'qemu64' }
        'riscv64' { 'rv64' }
        'riscv64-uefi' { 'rv64' }
    }
    $bedrockArguments = @(
        '-machine', $bedrockMachine,
        '-cpu', $bedrockCpu,
        '-accel', 'tcg',
        '-smp', '1',
        '-m', "${RamMiB}M",
        '-display', 'none',
        '-serial', 'stdio',
        '-monitor', 'none'
    )
    if ($bedrockIsUefi) {
        if (-not (Test-Path -LiteralPath $UefiCode -PathType Leaf) -or -not (Test-Path -LiteralPath $UefiVars -PathType Leaf)) {
            throw 'UEFI smoke tests require matching firmware code and variable-store files.'
        }
        $bedrockDataDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('bedrock-data-' + [guid]::NewGuid().ToString('N'))
        [System.IO.Directory]::CreateDirectory($bedrockDataDirectory) | Out-Null
        $bedrockDataImage = Join-Path $bedrockDataDirectory 'data.img'
        $bedrockPython = (Get-Command python -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
        & $bedrockPython (Join-Path $PSScriptRoot 'make-data-image.py') $bedrockDataImage
        if ($LASTEXITCODE -ne 0) { throw 'Could not create the temporary Bedrock data image.' }
        # The variable-store template is read only; snapshot writes are private
        # to this QEMU process. Never mutate the installed firmware files.
        $bedrockArguments += @(
            '-drive', "if=pflash,format=raw,readonly=on,file=$UefiCode",
            '-drive', "if=pflash,format=raw,snapshot=on,file=$UefiVars"
        )
        $bedrockArguments += @('-drive', "if=none,id=bedrock-data,format=raw,file=$($bedrockDataImage.Replace(',', ',,'))")
        if ($Architecture.StartsWith('x86_64')) {
            $bedrockArguments += @('-device', 'virtio-blk-pci,drive=bedrock-data,disable-legacy=on,serial=bedrock-data')
        } else {
            $bedrockArguments += @('-global', 'virtio-mmio.force-legacy=false', '-device', 'virtio-blk-device,drive=bedrock-data,serial=bedrock-data')
        }
        if ($Architecture -eq 'x86_64-uefi-image') {
            $bedrockArguments += @('-drive', "format=raw,snapshot=on,file=$bedrockImagePath")
        } else {
            $bedrockEsp = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $bedrockImagePath))
            if ($Architecture.StartsWith('x86_64')) {
                $bedrockArguments += @('-drive', "format=raw,snapshot=on,file=fat:$bedrockEsp")
            } else {
                $bedrockArguments += @('-drive', "if=none,id=bedrock-esp,format=raw,snapshot=on,file=fat:$bedrockEsp", '-device', 'virtio-blk-device,drive=bedrock-esp')
            }
        }
    } else {
        $bedrockArguments += @('-bios', $bedrockImagePath)
    }
    switch ($Architecture) {
        'arm64' { $bedrockArguments += @('-semihosting-config', 'enable=on,target=native') }
        'arm64-uefi' { $bedrockArguments += @('-semihosting-config', 'enable=on,target=native', '-no-reboot') }
        'x86_64' { $bedrockArguments += @('-no-reboot', '-device', 'isa-debug-exit,iobase=0xf4,iosize=4') }
        'x86_64-uefi' { $bedrockArguments += @('-no-reboot', '-device', 'isa-debug-exit,iobase=0xf4,iosize=4') }
        'x86_64-uefi-image' { $bedrockArguments += @('-no-reboot', '-device', 'isa-debug-exit,iobase=0xf4,iosize=4') }
        'riscv64' { $bedrockArguments += @('-no-reboot') }
        'riscv64-uefi' { $bedrockArguments += @('-no-reboot', '-bios', 'default') }
    }

    $bedrockStartInfo = New-Object System.Diagnostics.ProcessStartInfo
    $bedrockStartInfo.FileName = $QemuExecutable
    $bedrockStartInfo.Arguments = (($bedrockArguments | ForEach-Object {
        ConvertTo-BedrockQuotedArgument $_
    }) -join ' ')
    $bedrockStartInfo.UseShellExecute = $false
    $bedrockStartInfo.CreateNoWindow = $true
    $bedrockStartInfo.RedirectStandardInput = $true
    $bedrockStartInfo.RedirectStandardOutput = $true
    $bedrockStartInfo.RedirectStandardError = $true

    $bedrockProcess = New-Object System.Diagnostics.Process
    $bedrockProcess.StartInfo = $bedrockStartInfo
    if (-not $bedrockProcess.Start()) { throw 'QEMU failed to start.' }
    $bedrockStarted = $true
    $bedrockProcess.StandardInput.Close()
    # Drain both streams concurrently so a full error pipe cannot block QEMU.
    $bedrockStdoutTask = $bedrockProcess.StandardOutput.ReadToEndAsync()
    $bedrockStderrTask = $bedrockProcess.StandardError.ReadToEndAsync()

    if (-not $bedrockProcess.WaitForExit($TimeoutSeconds * 1000)) {
        $bedrockFailure = "QEMU exceeded the $TimeoutSeconds-second timeout."
        $bedrockProcess.Kill()
        if (-not $bedrockProcess.WaitForExit(5000)) {
            throw 'QEMU did not terminate after the timeout.'
        }
    }

    # Finite waits also protect against an unexpected descendant holding a pipe.
    if (-not $bedrockStdoutTask.Wait(5000) -or -not $bedrockStderrTask.Wait(5000)) {
        throw 'QEMU output capture did not finish.'
    }
    $bedrockStdout = $bedrockStdoutTask.Result
    $bedrockStderr = $bedrockStderrTask.Result

    if ($null -eq $bedrockFailure) {
        $bedrockCombinedOutput = $bedrockStdout + "`n" + $bedrockStderr
        if ($bedrockCombinedOutput.Contains('[panic]') -or $bedrockCombinedOutput.Contains('[fault]')) {
            throw 'QEMU reported a panic or fault.'
        }
        if ($bedrockProcess.ExitCode -ne $bedrockExpectedExitCode) {
            throw "QEMU exited with code $($bedrockProcess.ExitCode); expected $bedrockExpectedExitCode for $bedrockArchTag."
        }

        # Serial stdio is stdout; require order within that stream instead of
        # inventing an ordering between independently captured output streams.
        $bedrockMarkers = @(
            "[bootloader] $bedrockArchTag firmware entry",
            '[bootloader] kernel image copied',
            '[bootloader] handoff ready',
            "[kernel] $bedrockArchTag entry",
            '[kernel] handoff valid',
            '[kernel] allocator ready pages=',
            '[kernel] page allocation verified',
            '[kernel] page reuse verified',
            '[kernel] kernel heap verified',
            '[kernel] exception handled'
        )
        if ($bedrockIsUefi) {
            $bedrockMarkers += @(
                '[kernel] protected mappings ready',
                '[kernel] user mode verified',
                '[kernel] syscall checks verified',
                '[kernel] isolation probes verified',
                '[kernel] second task survived',
                '[kernel] timer ready',
                '[kernel] no-yield tasks preempted',
                '[kernel] context resume verified',
                '[kernel] preemptive scheduling verified',
                '[kernel] page-table rollback verified',
                '[kernel] task teardown verified',
                '[kernel] resource reuse verified',
                '[kernel] persistent filesystem mounted',
                '[kernel] exec capacity rollback verified',
                '[kernel] native ELF init ready',
                '[user] service ipc verified',
                '[user] file and pipe io verified',
                '[user] same pid exec verified',
                '[user] init lifecycle verified',
                '[kernel] filesystem I/O verified',
                '[kernel] pipe lifecycle verified',
                '[kernel] filesystem exec replacement verified',
                '[kernel] native process lifecycle verified',
                '[kernel] blocking wait verified',
                '[kernel] sleep wakeup verified',
                '[kernel] cooperative sleep progress verified',
                '[kernel] capability IPC verified',
                '[kernel] native process cleanup verified'
            )
        }
        $bedrockMarkers += "[kernel] $bedrockArchTag boot complete"
        $bedrockSearchFrom = 0
        foreach ($bedrockMarker in $bedrockMarkers) {
            $bedrockMarkerIndex = $bedrockStdout.IndexOf($bedrockMarker, $bedrockSearchFrom, [StringComparison]::Ordinal)
            if ($bedrockMarkerIndex -lt 0) {
                throw "Missing or out-of-order serial marker: $bedrockMarker"
            }
            $bedrockSearchFrom = $bedrockMarkerIndex + $bedrockMarker.Length
        }
        if (-not $bedrockStdout.Contains('[kernel] memory regions=')) {
            throw 'Kernel did not report its discovered memory map.'
        }
        if ($bedrockIsUefi) {
            if ([regex]::Matches($bedrockStdout, '\[kernel\] user fault contained mode=').Count -ne 5) {
                throw 'Kernel did not contain all five user fault probes.'
            }
            if ([regex]::Matches($bedrockStdout, '\[kernel\] timer preempted task=').Count -ne 6) {
                throw 'Kernel did not preempt both tasks for three quanta each.'
            }
            if (-not $bedrockStdout.Contains('[bootloader] exit boot services')) {
                throw 'UEFI loader did not confirm ExitBootServices.'
            }
        } else {
            $bedrockExpectedRam = 'RAM discovered length=0x{0:x16}' -f ([uint64]$RamMiB * 1024 * 1024)
            if (-not $bedrockStdout.Contains($bedrockExpectedRam)) {
                throw "Bootloader did not discover the configured RAM size: $bedrockExpectedRam"
            }
        }
    }
} catch {
    $bedrockFailure = $_.Exception.Message
} finally {
    if ($null -ne $bedrockProcess) {
        # A launch/capture exception must not leave a headless emulator running.
        if ($bedrockStarted -and -not $bedrockProcess.HasExited) {
            try {
                $bedrockProcess.Kill()
                $bedrockProcess.WaitForExit(5000) | Out-Null
            } catch {
                if ($null -eq $bedrockFailure) {
                    $bedrockFailure = $_.Exception.Message
                }
            }
        }
        $bedrockProcess.Dispose()
    }
    if ($null -ne $bedrockDataDirectory) {
        try {
            # Remove only the explicitly created file and its empty unique
            # directory after the owned QEMU process releases its disk handle.
            if ($null -ne $bedrockDataImage -and (Test-Path -LiteralPath $bedrockDataImage -PathType Leaf)) {
                Remove-Item -LiteralPath $bedrockDataImage -Force
            }
            if (Test-Path -LiteralPath $bedrockDataDirectory -PathType Container) {
                Remove-Item -LiteralPath $bedrockDataDirectory
            }
        } catch {
            if ($null -eq $bedrockFailure) { $bedrockFailure = $_.Exception.Message }
        }
    }
}

[Console]::Out.Write($bedrockStdout)
[Console]::Error.Write($bedrockStderr)
if ($null -ne $bedrockFailure) {
    [Console]::Error.WriteLine("$bedrockArchTag smoke test failed: $bedrockFailure")
    exit 1
}
[Console]::Out.WriteLine("$Architecture smoke test passed ($RamMiB MiB).")
exit 0
