$ErrorActionPreference = "Stop"
$HudRoot = $PSScriptRoot
$IconPath = Join-Path $HudRoot "pr-radar.ico"
if (-not (Test-Path $IconPath)) {
  & pwsh -NoProfile -File (Join-Path $HudRoot "scripts\generate-icon.ps1") | Out-Null
}

$ProjPath = Join-Path $HudRoot "launcher\PrRadarLauncher.csproj"
$PubDir = Join-Path $HudRoot "launcher\bin\publish"
& dotnet publish $ProjPath -c Release -r win-x64 -o $PubDir --nologo | Out-Null

$BuiltExe = Join-Path $PubDir "PrRadarLauncher.exe"
Copy-Item -LiteralPath $BuiltExe -Destination (Join-Path $HudRoot "PR-Radar-Notu.exe") -Force
$BinDir = Join-Path $HudRoot "bin"
New-Item -ItemType Directory -Path $BinDir -Force | Out-Null
Copy-Item -LiteralPath $BuiltExe -Destination (Join-Path $BinDir "pr-radar.exe") -Force
Write-Output "BUILT: PR-Radar-Notu.exe & bin/pr-radar.exe"
