param(
  [switch]$EnableStartup,
  [switch]$Uninstall
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if (-not ("EnvBroadcastWin32" -as [type])) {
  Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class EnvBroadcastWin32 {
  [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
  public static extern IntPtr SendMessageTimeout(
    IntPtr hWnd,
    uint Msg,
    UIntPtr wParam,
    string lParam,
    uint fuFlags,
    uint uTimeout,
    out UIntPtr lpdwResult
  );

  public static void BroadcastEnvironmentChange() {
    UIntPtr result;
    SendMessageTimeout((IntPtr)0xffff, 0x001A, UIntPtr.Zero, "Environment", 0x0002, 2000, out result);
  }
}
"@
}

$HudRoot = $PSScriptRoot
$ExePath = Join-Path $HudRoot "PR-Radar-Notu.exe"
$BinDir = Join-Path $HudRoot "bin"
$BinExePath = Join-Path $BinDir "pr-radar.exe"
$IconPath = Join-Path $HudRoot "pr-radar.ico"

$IsTr = ([System.Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName.ToLowerInvariant() -eq "tr")
$ShortcutFileName = if ($IsTr) { "PR Radar Notu.lnk" } else { "PR Review Radar.lnk" }
$StartMenuDesc = if ($IsTr) { "PR Radar Yapışkan Notu (Ctrl+Alt+R ile aç/gizle)" } else { "PR Review Radar Sticky HUD (Ctrl+Alt+R to toggle)" }
$StartupDesc = if ($IsTr) { "PR Radar Yapışkan Notu (Sistem Tepsisi)" } else { "PR Review Radar Sticky HUD (System Tray)" }

$StartMenuDir = [Environment]::GetFolderPath("Programs")
$StartMenuLnk = Join-Path $StartMenuDir $ShortcutFileName
$StartupDir = [Environment]::GetFolderPath("Startup")
$StartupLnk = Join-Path $StartupDir $ShortcutFileName
$AppPathsKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\pr-radar.exe"

function Normalize-PathEntry([string]$Entry) {
  return $Entry.Trim().TrimEnd('\', '/').ToLowerInvariant()
}

if ($Uninstall) {
  foreach ($lnkName in @("PR Radar Notu.lnk", "PR Review Radar.lnk")) {
    $sm = Join-Path $StartMenuDir $lnkName
    $su = Join-Path $StartupDir $lnkName
    if (Test-Path -LiteralPath $sm) { Remove-Item -LiteralPath $sm -Force }
    if (Test-Path -LiteralPath $su) { Remove-Item -LiteralPath $su -Force }
  }
  if (Test-Path -LiteralPath $AppPathsKey) {
    Remove-Item -LiteralPath $AppPathsKey -Recurse -Force
  }

  $currentUserPath = [Environment]::GetEnvironmentVariable("Path", "User")
  if ($currentUserPath) {
    $targetNorm = Normalize-PathEntry $BinDir
    $kept = @(
      $currentUserPath -split ';' |
      Where-Object { $_ -and (Normalize-PathEntry $_) -ne $targetNorm }
    )
    [Environment]::SetEnvironmentVariable("Path", ($kept -join ';'), "User")
    [EnvBroadcastWin32]::BroadcastEnvironmentChange()
  }

  Write-Output $(if ($IsTr) { "Kısayollar ve 'pr-radar' komutu kaldırıldı." } else { "Shortcuts and 'pr-radar' command removed." })
  exit 0
}

# 0. Build WinExe launcher automatically if not present
if (-not (Test-Path -LiteralPath $ExePath) -or -not (Test-Path -LiteralPath $BinExePath)) {
  & pwsh -NoProfile -File (Join-Path $HudRoot "Build-Launcher.ps1") | Out-Null
}

# 1. Start Menu shortcut
$wsh = New-Object -ComObject WScript.Shell
$sc = $wsh.CreateShortcut($StartMenuLnk)
$sc.TargetPath = $ExePath
$sc.WorkingDirectory = $HudRoot
$sc.Description = $StartMenuDesc
if (Test-Path -LiteralPath $IconPath) {
  $sc.IconLocation = "$IconPath,0"
}
$sc.Save()

# 2. Optional Windows Startup shortcut (-StartHidden in System Tray)
if ($EnableStartup) {
  $scStart = $wsh.CreateShortcut($StartupLnk)
  $scStart.TargetPath = $ExePath
  $scStart.Arguments = "-StartHidden"
  $scStart.WorkingDirectory = $HudRoot
  $scStart.Description = $StartupDesc
  if (Test-Path -LiteralPath $IconPath) {
    $scStart.IconLocation = "$IconPath,0"
  }
  $scStart.Save()
}

# 3. Instant Win+R registration via HKCU App Paths
New-Item -Path $AppPathsKey -Force | Out-Null
Set-ItemProperty -LiteralPath $AppPathsKey -Name "(default)" -Value $BinExePath
Set-ItemProperty -LiteralPath $AppPathsKey -Name "Path" -Value $HudRoot

# 4. User PATH registration for terminals (PowerShell / CMD / VS Code)
$currentUserPath = [Environment]::GetEnvironmentVariable("Path", "User")
$entries = if ($currentUserPath) { @($currentUserPath -split ';' | Where-Object { $_ }) } else { @() }
$targetNorm = Normalize-PathEntry $BinDir
$alreadyPresent = $false
foreach ($e in $entries) {
  if ((Normalize-PathEntry $e) -eq $targetNorm) {
    $alreadyPresent = $true
    break
  }
}
if (-not $alreadyPresent) {
  $newUserPath = (@($entries) + @($BinDir)) -join ';'
  [Environment]::SetEnvironmentVariable("Path", $newUserPath, "User")
}
[EnvBroadcastWin32]::BroadcastEnvironmentChange()

[pscustomobject]@{
  StartMenuShortcut = (Test-Path -LiteralPath $StartMenuLnk)
  AppPathsRegistered = (Test-Path -LiteralPath $AppPathsKey)
  UserPathAdded = $true
  StartupEnabled = (Test-Path -LiteralPath $StartupLnk)
} | ConvertTo-Json -Compress
