$ErrorActionPreference = 'Stop'
$bedrockWorkspaceRoot = Split-Path -Parent $PSScriptRoot
$bedrockZigVersion = (Get-Content -LiteralPath (Join-Path $bedrockWorkspaceRoot '.zigversion') -Raw).Trim()
& zvm run $bedrockZigVersion @args
exit $LASTEXITCODE
