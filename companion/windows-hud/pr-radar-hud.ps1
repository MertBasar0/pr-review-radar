param(
  [switch]$RefreshOnLaunch,
  [switch]$StartHidden,
  [switch]$Toggle,
  [ValidateSet("", "auto", "en", "tr")]
  [string]$Lang = "",
  [ValidateSet("", "dark", "sticky")]
  [string]$ForceTheme = "",
  [string]$SavePreview = "",
  [switch]$AutoCloseAfterPreview
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not ("HudWin32" -as [type])) {
  Add-Type -ReferencedAssemblies ([System.Windows.Forms.NativeWindow].Assembly.Location, [System.Windows.Forms.Message].Assembly.Location) @"
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public static class HudWin32 {
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool AllowSetForegroundWindow(int dwProcessId);
  [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr hIcon);
}

public sealed class HotKeyWindow : NativeWindow, IDisposable {
  [DllImport("user32.dll")] private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
  [DllImport("user32.dll")] private static extern bool UnregisterHotKey(IntPtr hWnd, int id);
  private readonly int _id;
  public Action OnHotKey;
  public bool IsRegistered { get; private set; }
  public HotKeyWindow(int id, uint mods, uint vk) {
    _id = id;
    CreateHandle(new CreateParams());
    IsRegistered = RegisterHotKey(Handle, _id, mods, vk);
  }
  protected override void WndProc(ref Message m) {
    if (m.Msg == 0x0312 && m.WParam.ToInt32() == _id) {
      OnHotKey?.Invoke();
    }
    base.WndProc(ref m);
  }
  public void Dispose() {
    if (Handle != IntPtr.Zero) {
      if (IsRegistered) UnregisterHotKey(Handle, _id);
      DestroyHandle();
    }
  }
}
"@
}

$HudRoot = $PSScriptRoot
Set-Location -LiteralPath $HudRoot
$env:OPENCLAW_RADAR_WORKSPACE = $HudRoot
$StateDir = Join-Path $HudRoot "state"
$ConfigPath = Join-Path $StateDir "config.json"
$SweepPath = Join-Path $StateDir "latest-sweep.json"
$CursorsPath = Join-Path $StateDir "cursors.json"
$PrefsPath = Join-Path $StateDir "hud-prefs.json"
$IconPath = Join-Path $HudRoot "pr-radar.ico"
$LocalEngine = Join-Path $HudRoot "scripts\pr-radar-engine.mjs"
$RepoEngine = [System.IO.Path]::GetFullPath((Join-Path $HudRoot "..\..\templates\pr-review-radar\workspace\scripts\pr-radar-engine.mjs"))
$EngineScript = if (Test-Path -LiteralPath $LocalEngine) { $LocalEngine } else { $RepoEngine }
$LocalResolve = Join-Path $HudRoot "scripts\resolve-mergeability.mjs"
$RepoResolve = [System.IO.Path]::GetFullPath((Join-Path $HudRoot "..\..\templates\pr-review-radar\workspace\scripts\resolve-mergeability.mjs"))
$ResolveMergeScript = if (Test-Path -LiteralPath $LocalResolve) { $LocalResolve } else { $RepoResolve }

if (-not (Test-Path $StateDir)) {
  New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
}
if (-not (Test-Path $CursorsPath)) {
  Set-Content -Path $CursorsPath -Value '{"version":1,"updatedAt":null,"items":{}}' -Encoding utf8
}

# Single-instance wake / toggle signals (skip when rendering headless preview)
$WakeEventName = "Local\PrReviewRadarStickyHudWakeV1"
$ToggleEventName = "Local\PrReviewRadarStickyHudToggleV1"
$MutexName = "Local\PrReviewRadarStickyHudMutexV1"
$script:SingleMutex = $null
$script:WakeEvent = $null
$script:ToggleEvent = $null

if (-not $SavePreview) {
  $createdNew = $false
  $script:SingleMutex = [System.Threading.Mutex]::new($true, $MutexName, [ref]$createdNew)
  if (-not $createdNew) {
    try {
      [void][HudWin32]::AllowSetForegroundWindow(-1)
      $targetEventName = if ($Toggle) { $ToggleEventName } else { $WakeEventName }
      $existingEvent = [System.Threading.EventWaitHandle]::OpenExisting($targetEventName)
      [void]$existingEvent.Set()
      $existingEvent.Dispose()
    } catch {}
    exit 0
  }
  $script:WakeEvent = [System.Threading.EventWaitHandle]::new(
    $false,
    [System.Threading.EventResetMode]::AutoReset,
    $WakeEventName
  )
  $script:ToggleEvent = [System.Threading.EventWaitHandle]::new(
    $false,
    [System.Threading.EventResetMode]::AutoReset,
    $ToggleEventName
  )
}

function ConvertFrom-BrushHex([string]$Hex) {
  return [System.Windows.Media.BrushConverter]::new().ConvertFromString($Hex)
}

function ConvertFrom-ColorHex([string]$Hex) {
  return [System.Windows.Media.ColorConverter]::ConvertFromString($Hex)
}

$Palettes = @{
  dark = @{
    Name              = "dark"
    ToggleLabel       = "Sarı Not"
    CardBg            = "#F4131720"
    CardBorder        = "#334155"
    HeaderBg          = "#1B2130"
    FooterBg          = "#171C28"
    TitleFg           = "#F8FAFC"
    SubFg             = "#94A3B8"
    MutedFg           = "#64748B"
    HoverBtnBg        = "#293246"
    PinActiveBg       = "#1E3A8A"
    PinActiveFg       = "#93C5FD"
    SectionFg         = "#94A3B8"
    RowBg             = "#1B2232"
    RowHoverBg        = "#232D42"
    RowBorder         = "#293449"
    RowDimBg          = "#151B27"
    PrNumBg           = "#0F172A"
    PrNumFg           = "#E2E8F0"
    PrNumBorder       = "#334155"
    TileAllBg         = "#1E293B"
    TileAllBorder     = "#475569"
    TileAllFg         = "#F1F5F9"
    TileP1Bg          = "#2C1219"
    TileP1Border      = "#F43F5E"
    TileP1Fg          = "#FF6B88"
    TileP2Bg          = "#0B291E"
    TileP2Border      = "#10B981"
    TileP2Fg          = "#34F5A6"
    TileP34Bg         = "#112240"
    TileP34Border     = "#38BDF8"
    TileP34Fg         = "#7DD3FC"
    AccentFail        = "#FF4D6D"
    BadgeFailBg       = "#3F111D"
    BadgeFailBorder   = "#F43F5E"
    BadgeFailFg       = "#FF758F"
    AccentSec         = "#FF2E4C"
    BadgeSecBg        = "#4A0E19"
    BadgeSecBorder    = "#FF2E4C"
    BadgeSecFg        = "#FF8FA3"
    AccentDirty       = "#FF9F1C"
    BadgeDirtyBg      = "#3D2408"
    BadgeDirtyBorder  = "#F59E0B"
    BadgeDirtyFg      = "#FFD166"
    AccentReady       = "#10E88A"
    BadgeReadyBg      = "#093323"
    BadgeReadyBorder  = "#10B981"
    BadgeReadyFg      = "#4ADE80"
    AccentGate        = "#2DD4BF"
    BadgeGateBg       = "#0C2F2E"
    BadgeGateBorder   = "#14B8A6"
    BadgeGateFg       = "#5EEAD4"
    AccentReview      = "#C084FC"
    BadgeReviewBg     = "#2D1546"
    BadgeReviewBorder = "#A855F7"
    BadgeReviewFg     = "#D8B4FE"
    AccentWatch       = "#38BDF8"
    BadgeWatchBg      = "#0F2744"
    BadgeWatchBorder  = "#0284C7"
    BadgeWatchFg      = "#7DD3FC"
    BadgeNewBg        = "#083344"
    BadgeNewBorder    = "#06B6D4"
    BadgeNewFg        = "#22D3EE"
    BadgeDraftBg      = "#1E293B"
    BadgeDraftBorder  = "#475569"
    BadgeDraftFg      = "#94A3B8"
    ActionBtnBg       = "#1E293B"
    ActionBtnBorder   = "#334155"
    ActionBtnFg       = "#E2E8F0"
  }
  sticky = @{
    Name              = "sticky"
    ToggleLabel       = "Koyu Mod"
    CardBg            = "#FFF9DB"
    CardBorder        = "#E5C653"
    HeaderBg          = "#FFE885"
    FooterBg          = "#FFF3B8"
    TitleFg           = "#1E293B"
    SubFg             = "#57534E"
    MutedFg           = "#78716C"
    HoverBtnBg        = "#FACC15"
    PinActiveBg       = "#92400E"
    PinActiveFg       = "#FEF3C7"
    SectionFg         = "#57534E"
    RowBg             = "#FFFDF0"
    RowHoverBg        = "#FEF08A"
    RowBorder         = "#E7D37F"
    RowDimBg          = "#FAF3CE"
    PrNumBg           = "#FEF3C7"
    PrNumFg           = "#1E293B"
    PrNumBorder       = "#D97706"
    TileAllBg         = "#FEF08A"
    TileAllBorder     = "#CA8A04"
    TileAllFg         = "#1E293B"
    TileP1Bg          = "#FFE4E6"
    TileP1Border      = "#E11D48"
    TileP1Fg          = "#BE123C"
    TileP2Bg          = "#D1FAE5"
    TileP2Border      = "#059669"
    TileP2Fg          = "#047857"
    TileP34Bg         = "#DBEAFE"
    TileP34Border     = "#2563EB"
    TileP34Fg         = "#1D4ED8"
    AccentFail        = "#E11D48"
    BadgeFailBg       = "#FFE4E6"
    BadgeFailBorder   = "#E11D48"
    BadgeFailFg       = "#9F1239"
    AccentSec         = "#BE123C"
    BadgeSecBg        = "#FECDD3"
    BadgeSecBorder    = "#BE123C"
    BadgeSecFg        = "#881337"
    AccentDirty       = "#D97706"
    BadgeDirtyBg      = "#FFEDD5"
    BadgeDirtyBorder  = "#EA580C"
    BadgeDirtyFg      = "#9A3412"
    AccentReady       = "#059669"
    BadgeReadyBg      = "#D1FAE5"
    BadgeReadyBorder  = "#059669"
    BadgeReadyFg      = "#065F46"
    AccentGate        = "#0D9488"
    BadgeGateBg       = "#CCFBF1"
    BadgeGateBorder   = "#0D9488"
    BadgeGateFg       = "#115E59"
    AccentReview      = "#7C3AED"
    BadgeReviewBg     = "#F3E8FF"
    BadgeReviewBorder = "#7C3AED"
    BadgeReviewFg     = "#5B21B6"
    AccentWatch       = "#2563EB"
    BadgeWatchBg      = "#DBEAFE"
    BadgeWatchBorder  = "#2563EB"
    BadgeWatchFg      = "#1E40AF"
    BadgeNewBg        = "#FEF08A"
    BadgeNewBorder    = "#CA8A04"
    BadgeNewFg        = "#854D0E"
    BadgeDraftBg      = "#F5F5F4"
    BadgeDraftBorder  = "#A8A29E"
    BadgeDraftFg      = "#57534E"
    ActionBtnBg       = "#FDE68A"
    ActionBtnBorder   = "#D97706"
    ActionBtnFg       = "#1E293B"
  }
}

$Strings = @{
  en = @{
    ToggleSticky     = "Sticky Yellow"
    ToggleDark       = "Dark Neon"
    BtnRefresh       = "↻ Refresh"
    BtnRefreshing    = "Scanning..."
    BtnRefreshTip    = "Run live GitHub PR sweep (F5)"
    BtnPinned        = "📌 Pinned"
    BtnPin           = "Pin"
    BtnPinTip        = "Keep always on top"
    BtnCloseTip      = "Hide to tray (Esc / {0}) · Quit: Ctrl+Q or tray menu"
    BtnMarkSeen      = "✓ Mark Seen"
    BtnMarkSeenTip   = "Mark current states as seen (clear NEW / UPDATED badges)"
    BtnThemeTip      = "Switch Dark Neon / Classic Sticky Yellow theme"
    ResizeTip        = "Resize"
    EmptyState       = "No PR sweep data yet. Click '↻ Refresh' above."
    NeverScanned     = "not scanned yet"
    JustNow          = "just now"
    MinAgo           = "{0}m ago"
    HrAgo            = "{0}h ago"
    DayAgo           = "{0}d ago"
    UpToDate         = "up to date"
    TileP1           = "BLOCKERS (P1)"
    TileP1WithDrafts = "BLOCKERS (+{0} draft)"
    TileP2           = "READY TO LAND (P2)"
    TileP34          = "REVIEWS / WATCH"
    SecP2            = "READY · MERGE OR AWAITING GATE ({0})"
    SecP1            = "BLOCKERS · ACTION NEEDED ({0})"
    SecP34           = "YOUR REVIEWS & OVERLAP WATCH ({0})"
    SecDrafts        = "DRAFTS ({0})"
    BadgeNew         = "NEW"
    BadgeChanged     = "UPDATED"
    BadgeCoAuthor    = "CO-OP: {0}"
    BadgeSecOne      = "SECURITY: {0}"
    BadgeSecMany     = "{0} SECURITY CHECKS"
    BadgeCiMany      = "CI ({0}): {1}+"
    BadgeCiFail      = "CI FAIL: {0}"
    BadgeConflict    = "CONFLICT · REBASE"
    BadgeChangesReq  = "CHANGES REQUESTED"
    BadgeDraft       = "DRAFT"
    BadgeGate        = "GREEN · AWAITING GATE"
    BadgeBehind      = "GREEN · BEHIND BASE"
    BadgeMergeCheck  = "GREEN · CHECKING MERGE"
    BadgeReady       = "READY TO MERGE · GREEN"
    BadgeReviewGreen = "REVIEW YOU · GREEN"
    BadgeReview      = "REVIEW REQUESTED"
    BadgeWatchPath   = "OVERLAP: {0}"
    BadgeWatchArea   = "AREA OVERLAP"
    CardTipStatus    = "Status"
    CardTipNext      = "Next"
    CardTipClicks    = "(Left-click: Open in browser  |  Right-click: Copy link)"
    FooterIdle       = "{0} new · {1}: Show/Hide"
    FooterScanning   = "Fetching GitHub slices & merge state..."
    FooterUpdated    = "Updated live ({0})"
    FooterError      = "Error: {0}"
    FooterFailed     = "Refresh failed"
    FooterMarkedSeen = "All items marked as seen"
    FooterCopied     = "Copied: {0}"
    TrayTipIdle      = "PR Radar · ({0})"
    TrayTipSummary   = "PR Radar · {0} blocked, {1} ready ({2})"
    TrayToggle       = "Show / Hide ({0})"
    TrayRefresh      = "↻ Refresh Now"
    TrayMarkSeen     = "✓ Mark All Seen"
    TrayTheme        = "🎨 Switch Theme (Dark / Sticky)"
    TrayAutoRefresh  = "Auto-Refresh (30 min)"
    TrayStartup      = "Launch at Windows Login (in Tray)"
    TrayLangMenu     = "🌐 Language / Dil"
    TrayLangAuto     = "System Default (Auto)"
    TrayExit         = "✕ Quit Completely (Ctrl+Q)"
    TrayFallbackKey  = "Tray icon"
    StartupDesc      = "PR Review Radar Sticky HUD (System Tray)"
  }
  tr = @{
    ToggleSticky     = "Sarı Not"
    ToggleDark       = "Koyu Mod"
    BtnRefresh       = "↻ Yenile"
    BtnRefreshing    = "Taranıyor..."
    BtnRefreshTip    = "GitHub üzerinden canlı PR taraması başlat (F5)"
    BtnPinned        = "📌 Sabit"
    BtnPin           = "Sabitle"
    BtnPinTip        = "Her zaman üstte tut (Always on Top)"
    BtnCloseTip      = "Tepsiye gizle (Esc / {0}) · Tam çıkış: Ctrl+Q veya tepsi menüsü"
    BtnMarkSeen      = "✓ Okundu İşaretle"
    BtnMarkSeenTip   = "Mevcut durumları okundu olarak kaydet (YENİ rozetlerini sıfırla)"
    BtnThemeTip      = "Koyu Mod / Klasik Sarı Yapışkan Not görünümü"
    ResizeTip        = "Boyutlandır"
    EmptyState       = "Henüz PR tarama verisi yok. Üstteki '↻ Yenile' butonuna tıklayın."
    NeverScanned     = "henüz taranmadı"
    JustNow          = "az önce"
    MinAgo           = "{0} dk önce"
    HrAgo            = "{0} sa önce"
    DayAgo           = "{0} gün önce"
    UpToDate         = "güncel"
    TileP1           = "ACİL ENGEL (P1)"
    TileP1WithDrafts = "ENGEL (+{0} taslak)"
    TileP2           = "MERGE HAZIR (P2)"
    TileP34          = "REVIEW / TEMAS"
    SecP2            = "HAZIR · MERGE VEYA ONAY BEKLEYEN ({0})"
    SecP1            = "ACİL ENGEL · AKSİYON GEREKTİREN ({0})"
    SecP34           = "SİZDEN REVIEW & ALAN TEMASI ({0})"
    SecDrafts        = "TASLAKLAR ({0})"
    BadgeNew         = "YENİ"
    BadgeChanged     = "DEĞİŞTİ"
    BadgeCoAuthor    = "ORTAK: {0}"
    BadgeSecOne      = "GÜVENLİK: {0}"
    BadgeSecMany     = "{0} GÜVENLİK KONTROLÜ"
    BadgeCiMany      = "CI ({0}): {1}+"
    BadgeCiFail      = "CI HATASI: {0}"
    BadgeConflict    = "ÇAKIŞMA · REBASE"
    BadgeChangesReq  = "REVİZYON İSTENDİ"
    BadgeDraft       = "TASLAK"
    BadgeGate        = "YEŞİL · ONAY BEKLİYOR"
    BadgeBehind      = "YEŞİL · DAL GERİDE"
    BadgeMergeCheck  = "YEŞİL · ÇAKIŞMA KONTROLÜ"
    BadgeReady       = "MERGE HAZIR · YEŞİL"
    BadgeReviewGreen = "SİZDEN REVIEW · YEŞİL"
    BadgeReview      = "SİZDEN REVIEW"
    BadgeWatchPath   = "TEMAS: {0}"
    BadgeWatchArea   = "ALAN TEMASI"
    CardTipStatus    = "Durum"
    CardTipNext      = "Öneri"
    CardTipClicks    = "(Sol tık: Tarayıcıda aç  |  Sağ tık: Bağlantıyı kopyala)"
    FooterIdle       = "{0} yeni · {1}: Aç/Gizle"
    FooterScanning   = "GitHub dilimleri ve çakışma durumu çekiliyor..."
    FooterUpdated    = "Canlı güncellendi ({0})"
    FooterError      = "Hata: {0}"
    FooterFailed     = "Yenileme başarısız oldu"
    FooterMarkedSeen = "Tüm durumlar okundu işaretlendi"
    FooterCopied     = "Kopyalandı: {0}"
    TrayTipIdle      = "PR Radar · ({0})"
    TrayTipSummary   = "PR Radar · {0} engel, {1} hazır ({2})"
    TrayToggle       = "Göster / Gizle ({0})"
    TrayRefresh      = "↻ Şimdi Yenile"
    TrayMarkSeen     = "✓ Okundu İşaretle"
    TrayTheme        = "🎨 Tema Değiştir (Koyu / Sarı Not)"
    TrayAutoRefresh  = "Otomatik Yenile (30 dk)"
    TrayStartup      = "Windows Açılışında Başlat (Tepside)"
    TrayLangMenu     = "🌐 Dil / Language"
    TrayLangAuto     = "Sistem Dili (Otomatik)"
    TrayExit         = "✕ Tamamen Çıkış (Ctrl+Q)"
    TrayFallbackKey  = "Tepsi ikonu"
    StartupDesc      = "PR Radar Yapışkan Notu (Sistem Tepsisi)"
  }
}

function Get-EffectiveLang {
  if ($script:LangPref -in @("en", "tr")) {
    return $script:LangPref
  }
  $uiLang = [System.Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName.ToLowerInvariant()
  if ($uiLang -eq "tr") {
    return "tr"
  }
  return "en"
}

function Get-LangTable {
  return $Strings[(Get-EffectiveLang)]
}

function Read-HudPrefs {
  $defaults = [ordered]@{
    theme       = "dark"
    lang        = "auto"
    topmost     = $true
    autoRefresh = $false
    left        = $null
    top         = $null
    width       = 450
    height      = 660
  }
  if (Test-Path $PrefsPath) {
    try {
      $raw = Get-Content $PrefsPath -Raw -Encoding utf8 | ConvertFrom-Json
      if ($raw.theme -in @("dark", "sticky")) { $defaults.theme = $raw.theme }
      if ($raw.lang -in @("auto", "en", "tr")) { $defaults.lang = $raw.lang }
      if ($null -ne $raw.topmost) { $defaults.topmost = [bool]$raw.topmost }
      if ($null -ne $raw.autoRefresh) { $defaults.autoRefresh = [bool]$raw.autoRefresh }
      if ($null -ne $raw.left) { $defaults.left = [double]$raw.left }
      if ($null -ne $raw.top) { $defaults.top = [double]$raw.top }
      if ($null -ne $raw.width -and [double]$raw.width -ge 360) { $defaults.width = [double]$raw.width }
      if ($null -ne $raw.height -and [double]$raw.height -ge 380) { $defaults.height = [double]$raw.height }
    } catch {}
  }
  if ($ForceTheme -in @("dark", "sticky")) {
    $defaults.theme = $ForceTheme
  }
  if ($Lang -in @("auto", "en", "tr")) {
    $defaults.lang = $Lang
  }
  return $defaults
}

function Save-HudPrefs {
  if ($SavePreview) { return }
  try {
    $payload = [ordered]@{
      theme       = $script:CurrentTheme
      lang        = $script:LangPref
      topmost     = [bool]$Window.Topmost
      autoRefresh = [bool]$script:AutoRefresh
      left        = [math]::Round($Window.Left, 0)
      top         = [math]::Round($Window.Top, 0)
      width       = [math]::Round($Window.Width, 0)
      height      = [math]::Round($Window.Height, 0)
    }
    $payload | ConvertTo-Json | Set-Content -Path $PrefsPath -Encoding utf8
  } catch {}
}

function Invoke-EngineScore {
  if (-not (Test-Path $SweepPath)) {
    return $null
  }
  $rawJson = & node $EngineScript --mode score --input "state/latest-sweep.json" --config "state/config.json" --cursors "state/cursors.json" --json 2>$null
  if (-not $rawJson) { return $null }
  $parsed = ($rawJson -join "`n") | ConvertFrom-Json
  $sweepMeta = $null
  try {
    $sweepMeta = Get-Content $SweepPath -Raw -Encoding utf8 | ConvertFrom-Json
  } catch {}
  return [pscustomobject]@{
    Score      = $parsed
    CapturedAt = $sweepMeta.capturedAt
  }
}

function Invoke-CommitCursor {
  if (-not (Test-Path $SweepPath)) { return }
  & node $EngineScript --mode commit-cursor --input "state/latest-sweep.json" --config "state/config.json" --cursors "state/cursors.json" --json 2>$null | Out-Null
}

function Format-RelativeAge($RawValue) {
  $L = Get-LangTable
  if (-not $RawValue) { return $L.NeverScanned }
  try {
    $utcDt = if ($RawValue -is [datetimeoffset]) {
      $RawValue.UtcDateTime
    } elseif ($RawValue -is [datetime]) {
      $RawValue.ToUniversalTime()
    } else {
      ([datetimeoffset]::Parse([string]$RawValue, [System.Globalization.CultureInfo]::InvariantCulture)).UtcDateTime
    }
    $diff = [datetime]::UtcNow - $utcDt
    if ($diff.TotalSeconds -lt 60) { return $L.JustNow }
    if ($diff.TotalMinutes -lt 60) { return ($L.MinAgo -f [int]$diff.TotalMinutes) }
    if ($diff.TotalHours -lt 24) { return ($L.HrAgo -f [int]$diff.TotalHours) }
    return ($L.DayAgo -f [int]$diff.TotalDays)
  } catch {
    return $L.UpToDate
  }
}

function New-BadgePill([string]$Text, [string]$BgHex, [string]$BorderHex, [string]$FgHex, [bool]$Bold = $true) {
  $border = [System.Windows.Controls.Border]::new()
  $border.Background = ConvertFrom-BrushHex $BgHex
  $border.BorderBrush = ConvertFrom-BrushHex $BorderHex
  $border.BorderThickness = [System.Windows.Thickness]::new(1)
  $border.CornerRadius = [System.Windows.CornerRadius]::new(5)
  $border.Padding = [System.Windows.Thickness]::new(6, 1.5, 6, 1.5)
  $border.Margin = [System.Windows.Thickness]::new(0, 0, 5, 0)
  $border.VerticalAlignment = [System.Windows.VerticalAlignment]::Center

  $tb = [System.Windows.Controls.TextBlock]::new()
  $tb.Text = $Text
  $tb.Foreground = ConvertFrom-BrushHex $FgHex
  $tb.FontSize = 10.5
  $tb.FontWeight = if ($Bold) { [System.Windows.FontWeights]::Bold } else { [System.Windows.FontWeights]::SemiBold }
  $border.Child = $tb
  return $border
}

[xml]$Xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="PR Review Radar"
        Width="436" Height="600"
        MinWidth="360" MinHeight="380"
        WindowStyle="None"
        AllowsTransparency="True"
        Background="Transparent"
        ShowInTaskbar="True"
        Topmost="True">
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="BtnBorder"
                    Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}"
                    CornerRadius="6"
                    Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="BtnBorder" Property="Opacity" Value="0.85"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="BtnBorder" Property="Opacity" Value="0.5"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="6"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent" Width="6" Margin="2,2,0,2">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.Thumb>
                  <Thumb>
                    <Thumb.Template>
                      <ControlTemplate TargetType="Thumb">
                        <Border Background="#5594A3B8" CornerRadius="3"/>
                      </ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Grid Margin="12">
    <Border x:Name="OuterCard"
            CornerRadius="14"
            BorderThickness="1"
            ClipToBounds="False">
      <Border.Effect>
        <DropShadowEffect BlurRadius="22" ShadowDepth="4" Direction="270" Color="#000000" Opacity="0.48"/>
      </Border.Effect>
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="5"/>
          <RowDefinition Height="42"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="38"/>
        </Grid.RowDefinitions>

        <!-- Sticky Top Color Strip -->
        <Border Grid.Row="0" CornerRadius="13,13,0,0">
          <Border.Background>
            <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
              <GradientStop Color="#FF4D6D" Offset="0.0"/>
              <GradientStop Color="#FF9F1C" Offset="0.48"/>
              <GradientStop Color="#10E88A" Offset="1.0"/>
            </LinearGradientBrush>
          </Border.Background>
        </Border>

        <!-- Draggable Sticky Header -->
        <Border x:Name="HeaderBar" Grid.Row="1" Padding="12,0,8,0" Cursor="SizeAll">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
              <TextBlock x:Name="HeaderTitle" Text="PR RADAR" FontWeight="ExtraBold" FontSize="12.5" VerticalAlignment="Center"/>
              <TextBlock x:Name="HeaderSub" Text="" FontSize="11.5" VerticalAlignment="Center"/>
            </StackPanel>
            <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
              <Button x:Name="BtnRefresh" Content="↻ Yenile" ToolTip="GitHub üzerinden canlı PR taraması başlat (F5)"
                      Padding="8,3" Margin="0,0,4,0" FontSize="11" FontWeight="SemiBold" Cursor="Hand" BorderThickness="1"/>
              <Button x:Name="BtnPin" Content="📌 Sabit" ToolTip="Her zaman üstte tut (Always on Top)"
                      Padding="8,3" Margin="0,0,4,0" FontSize="11" FontWeight="SemiBold" Cursor="Hand" BorderThickness="1"/>
              <Button x:Name="BtnClose" Content="✕" ToolTip="Tepsiye gizle (Esc / Ctrl+Alt+R) · Tam çıkış: Ctrl+Q veya tepsi menüsü"
                      Width="26" Height="24" FontSize="11" FontWeight="Bold" Cursor="Hand" BorderThickness="0"/>
            </StackPanel>
          </Grid>
        </Border>

        <!-- Instant Glance KPI Filter Strip -->
        <Grid x:Name="KpiGrid" Grid.Row="2" Margin="10,8,10,6">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>

          <Border x:Name="TileP1" Grid.Column="0" CornerRadius="9" BorderThickness="1.2" Padding="9,6" Margin="0,0,4,0" Cursor="Hand">
            <StackPanel>
              <TextBlock x:Name="TileP1Count" Text="0" FontSize="19" FontWeight="ExtraBold" LineHeight="20"/>
              <TextBlock x:Name="TileP1Label" Text="ACIL ENGEL" FontSize="10" FontWeight="Bold"/>
            </StackPanel>
          </Border>

          <Border x:Name="TileP2" Grid.Column="1" CornerRadius="9" BorderThickness="1.2" Padding="9,6" Margin="2,0,2,0" Cursor="Hand">
            <StackPanel>
              <TextBlock x:Name="TileP2Count" Text="0" FontSize="19" FontWeight="ExtraBold" LineHeight="20"/>
              <TextBlock x:Name="TileP2Label" Text="MERGE HAZIR" FontSize="10" FontWeight="Bold"/>
            </StackPanel>
          </Border>

          <Border x:Name="TileP34" Grid.Column="2" CornerRadius="9" BorderThickness="1.2" Padding="9,6" Margin="4,0,0,0" Cursor="Hand">
            <StackPanel>
              <TextBlock x:Name="TileP34Count" Text="0" FontSize="19" FontWeight="ExtraBold" LineHeight="20"/>
              <TextBlock x:Name="TileP34Label" Text="RADAR / TEMAS" FontSize="10" FontWeight="Bold"/>
            </StackPanel>
          </Border>
        </Grid>

        <!-- PR Cards Scroll List -->
        <ScrollViewer x:Name="CardsScroll" Grid.Row="3" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Padding="10,2,10,6">
          <StackPanel x:Name="CardsStack"/>
        </ScrollViewer>

        <!-- Sticky Footer Bar -->
        <Border x:Name="FooterBar" Grid.Row="4" CornerRadius="0,0,13,13" Padding="10,0,10,0">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <Button x:Name="BtnMarkSeen" Grid.Column="0" Content="✓ Okundu İşaretle" ToolTip="Mevcut durumları okundu olarak kaydet (YENİ rozetlerini sıfırla)"
                    Padding="8,3" Margin="0,0,6,0" FontSize="10.5" FontWeight="SemiBold" Cursor="Hand" BorderThickness="1" VerticalAlignment="Center"/>
            <Button x:Name="BtnTheme" Grid.Column="1" Content="Sarı Not" ToolTip="Koyu Mod / Klasik Sarı Yapışkan Not görünümü"
                    Padding="8,3" FontSize="10.5" FontWeight="SemiBold" Cursor="Hand" BorderThickness="1" VerticalAlignment="Center"/>
            <TextBlock x:Name="FooterStatus" Grid.Column="2" Text="" FontSize="10.5" VerticalAlignment="Center" HorizontalAlignment="Right" Margin="6,0,6,0" TextTrimming="CharacterEllipsis"/>
            <Thumb x:Name="ResizeThumb" Grid.Column="3" Width="14" Height="14" Cursor="SizeNWSE" VerticalAlignment="Bottom" Margin="0,0,-4,3" Opacity="0.5" ToolTip="Boyutlandır">
              <Thumb.Template>
                <ControlTemplate TargetType="Thumb">
                  <Grid Background="Transparent">
                    <TextBlock Text="◢" FontSize="9" Foreground="#94A3B8" HorizontalAlignment="Right" VerticalAlignment="Bottom"/>
                  </Grid>
                </ControlTemplate>
              </Thumb.Template>
            </Thumb>
          </Grid>
        </Border>
      </Grid>
    </Border>
  </Grid>
</Window>
"@

$Reader = [System.Xml.XmlNodeReader]::new($Xaml)
$Window = [System.Windows.Markup.XamlReader]::Load($Reader)

$OuterCard   = $Window.FindName("OuterCard")
$HeaderBar   = $Window.FindName("HeaderBar")
$HeaderTitle = $Window.FindName("HeaderTitle")
$HeaderSub   = $Window.FindName("HeaderSub")
$BtnRefresh  = $Window.FindName("BtnRefresh")
$BtnPin      = $Window.FindName("BtnPin")
$BtnClose    = $Window.FindName("BtnClose")
$TileP1      = $Window.FindName("TileP1")
$TileP1Count = $Window.FindName("TileP1Count")
$TileP1Label = $Window.FindName("TileP1Label")
$TileP2      = $Window.FindName("TileP2")
$TileP2Count = $Window.FindName("TileP2Count")
$TileP2Label = $Window.FindName("TileP2Label")
$TileP34     = $Window.FindName("TileP34")
$TileP34Count= $Window.FindName("TileP34Count")
$TileP34Label= $Window.FindName("TileP34Label")
$CardsStack  = $Window.FindName("CardsStack")
$FooterBar   = $Window.FindName("FooterBar")
$BtnMarkSeen = $Window.FindName("BtnMarkSeen")
$BtnTheme    = $Window.FindName("BtnTheme")
$FooterStatus= $Window.FindName("FooterStatus")
$ResizeThumb = $Window.FindName("ResizeThumb")

$Prefs = Read-HudPrefs
$script:CurrentTheme = $Prefs.theme
$script:LangPref = $Prefs.lang
$script:AutoRefresh = [bool]$Prefs.autoRefresh
$script:ActiveFilter = "ALL"
$script:CachedData = $null
$script:SweepJob = $null
$script:IsRefreshing = $false
$script:AllowExit = $false
$script:TrayIcon = $null
$script:CurrentTrayHIcon = [IntPtr]::Zero
$script:HotKeyHost = $null
$script:HotKeyLabel = "Ctrl+Alt+R"
$script:LastAutoSweepUtc = [datetime]::UtcNow
$StartupLnkName = if ((Get-EffectiveLang) -eq "tr") { "PR Radar Notu.lnk" } else { "PR Review Radar.lnk" }
$StartupLnkPath = Join-Path ([Environment]::GetFolderPath("Startup")) $StartupLnkName

if (Test-Path $IconPath) {
  try {
    $Window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri]::new($IconPath))
  } catch {}
}

$Window.Width = $Prefs.width
$Window.Height = $Prefs.height
$Window.Topmost = [bool]$Prefs.topmost

$WorkArea = [System.Windows.SystemParameters]::WorkArea
$VirtLeft = [System.Windows.SystemParameters]::VirtualScreenLeft
$VirtTop = [System.Windows.SystemParameters]::VirtualScreenTop
$VirtRight = $VirtLeft + [System.Windows.SystemParameters]::VirtualScreenWidth
$VirtBottom = $VirtTop + [System.Windows.SystemParameters]::VirtualScreenHeight
if ($null -ne $Prefs.left -and $null -ne $Prefs.top -and
    $Prefs.left -ge ($VirtLeft - 40) -and $Prefs.left -le ($VirtRight - 120) -and
    $Prefs.top -ge ($VirtTop - 20) -and $Prefs.top -le ($VirtBottom - 120)) {
  $Window.Left = $Prefs.left
  $Window.Top = $Prefs.top
} else {
  $Window.Left = [math]::Max($WorkArea.Left + 16, $WorkArea.Right - $Window.Width - 18)
  $Window.Top = $WorkArea.Top + 18
}

function Set-StyledButton($Button, [string]$BgHex, [string]$BorderHex, [string]$FgHex) {
  $Button.Background = ConvertFrom-BrushHex $BgHex
  $Button.BorderBrush = ConvertFrom-BrushHex $BorderHex
  $Button.Foreground = ConvertFrom-BrushHex $FgHex
}

function Get-PrVisualSpec($Item, $Pal) {
  $L = Get-LangTable
  $badges = [System.Collections.Generic.List[object]]::new()
  $accentHex = $Pal.AccentWatch

  if ($Item.changeState -eq "new") {
    $badges.Add(@{ Text = $L.BadgeNew; Bg = $Pal.BadgeNewBg; Border = $Pal.BadgeNewBorder; Fg = $Pal.BadgeNewFg })
  } elseif ($Item.changeState -eq "changed") {
    $badges.Add(@{ Text = $L.BadgeChanged; Bg = $Pal.BadgeNewBg; Border = $Pal.BadgeNewBorder; Fg = $Pal.BadgeNewFg })
  }

  if ($Item.ownership -eq "coauthored" -and $Item.author) {
    $shortAuthor = ($Item.author -replace "-bot$", "").ToUpperInvariant()
    $badges.Add(@{ Text = ($L.BadgeCoAuthor -f $shortAuthor); Bg = $Pal.BadgeReviewBg; Border = $Pal.BadgeReviewBorder; Fg = $Pal.BadgeReviewFg })
  }

  if ($Item.tier -eq "P1") {
    $failingArr = @()
    if ($Item.checks -and $Item.checks.failing) {
      $failingArr = @($Item.checks.failing)
    }
    $isDirty = ($Item.mergeState -in @("DIRTY", "CONFLICTING")) -or ($Item.mergeable -eq "CONFLICTING")
    $hasSecurityFail = ($failingArr | Where-Object { $_ -match "Security" }).Count -gt 0

    if ($failingArr.Count -gt 0) {
      if ($hasSecurityFail) {
        $accentHex = $Pal.AccentSec
        $label = if ($failingArr.Count -eq 1) { ($L.BadgeSecOne -f $failingArr[0]) } else { ($L.BadgeSecMany -f $failingArr.Count) }
        $badges.Add(@{ Text = $label; Bg = $Pal.BadgeSecBg; Border = $Pal.BadgeSecBorder; Fg = $Pal.BadgeSecFg })
      } else {
        $accentHex = $Pal.AccentFail
        $shortNames = ($failingArr | ForEach-Object { $_ -replace "^openclaw/", "" } | Select-Object -First 2) -join ", "
        $label = if ($failingArr.Count -gt 2) { ($L.BadgeCiMany -f $Item.checks.failingTotal, $shortNames) } else { ($L.BadgeCiFail -f $shortNames) }
        $badges.Add(@{ Text = $label; Bg = $Pal.BadgeFailBg; Border = $Pal.BadgeFailBorder; Fg = $Pal.BadgeFailFg })
      }
    }
    if ($isDirty) {
      if ($failingArr.Count -eq 0) { $accentHex = $Pal.AccentDirty }
      $badges.Add(@{ Text = $L.BadgeConflict; Bg = $Pal.BadgeDirtyBg; Border = $Pal.BadgeDirtyBorder; Fg = $Pal.BadgeDirtyFg })
    }
    if ($Item.reviewDecision -eq "CHANGES_REQUESTED") {
      $accentHex = $Pal.AccentFail
      $badges.Add(@{ Text = $L.BadgeChangesReq; Bg = $Pal.BadgeFailBg; Border = $Pal.BadgeFailBorder; Fg = $Pal.BadgeFailFg })
    }
    if ($Item.isDraft) {
      $badges.Add(@{ Text = $L.BadgeDraft; Bg = $Pal.BadgeDraftBg; Border = $Pal.BadgeDraftBorder; Fg = $Pal.BadgeDraftFg })
    }
  } elseif ($Item.tier -eq "P2") {
    $isBehind = ($Item.mergeState -eq "BEHIND")
    $isUnknownMerge = ($Item.mergeable -eq "UNKNOWN") -or (-not $Item.mergeable -and $Item.mergeState -eq "UNKNOWN")
    $awaitingGate = ($Item.mergeState -eq "BLOCKED") -or ($Item.reviewDecision -eq "REVIEW_REQUIRED")
    if ($isUnknownMerge) {
      $accentHex = $Pal.AccentGate
      $badges.Add(@{ Text = $L.BadgeMergeCheck; Bg = $Pal.BadgeGateBg; Border = $Pal.BadgeGateBorder; Fg = $Pal.BadgeGateFg })
    } elseif ($isBehind) {
      $accentHex = $Pal.AccentGate
      $badges.Add(@{ Text = $L.BadgeBehind; Bg = $Pal.BadgeGateBg; Border = $Pal.BadgeGateBorder; Fg = $Pal.BadgeGateFg })
    } elseif ($awaitingGate) {
      $accentHex = $Pal.AccentGate
      $badges.Add(@{ Text = $L.BadgeGate; Bg = $Pal.BadgeGateBg; Border = $Pal.BadgeGateBorder; Fg = $Pal.BadgeGateFg })
    } else {
      $accentHex = $Pal.AccentReady
      $badges.Add(@{ Text = $L.BadgeReady; Bg = $Pal.BadgeReadyBg; Border = $Pal.BadgeReadyBorder; Fg = $Pal.BadgeReadyFg })
    }
  } elseif ($Item.tier -eq "P3") {
    $accentHex = $Pal.AccentReview
    $checkLabel = if ($Item.checks.state -eq "passing") { $L.BadgeReviewGreen } else { $L.BadgeReview }
    $badges.Add(@{ Text = $checkLabel; Bg = $Pal.BadgeReviewBg; Border = $Pal.BadgeReviewBorder; Fg = $Pal.BadgeReviewFg })
  } else {
    $accentHex = $Pal.AccentWatch
    $reasonStr = ($Item.reasons -join "; ")
    $pathMatch = ""
    if ($reasonStr -match "touches watched path \(([^)]+)\)") {
      $pathMatch = $Matches[1]
    }
    $watchText = if ($pathMatch) { ($L.BadgeWatchPath -f $pathMatch) } else { $L.BadgeWatchArea }
    $badges.Add(@{ Text = $watchText; Bg = $Pal.BadgeWatchBg; Border = $Pal.BadgeWatchBorder; Fg = $Pal.BadgeWatchFg })
  }

  return @{
    AccentHex = $accentHex
    Badges    = $badges
  }
}

function Add-SectionHeader([string]$Title, [string]$FgHex) {
  $tb = [System.Windows.Controls.TextBlock]::new()
  $tb.Text = $Title
  $tb.Foreground = ConvertFrom-BrushHex $FgHex
  $tb.FontSize = 10.5
  $tb.FontWeight = [System.Windows.FontWeights]::Bold
  $tb.Margin = [System.Windows.Thickness]::new(2, 6, 2, 4)
  [void]$CardsStack.Children.Add($tb)
}

function Add-PrCard($Item, $Pal) {
  $L = Get-LangTable
  $spec = Get-PrVisualSpec $Item $Pal
  $isUnchanged = ($Item.changeState -eq "unchanged")

  $cardBg = if ($isUnchanged) { $Pal.RowDimBg } else { $Pal.RowBg }
  $card = [System.Windows.Controls.Border]::new()
  $card.Background = ConvertFrom-BrushHex $cardBg
  $card.BorderBrush = ConvertFrom-BrushHex $Pal.RowBorder
  $card.BorderThickness = [System.Windows.Thickness]::new(1)
  $card.CornerRadius = [System.Windows.CornerRadius]::new(8)
  $card.Margin = [System.Windows.Thickness]::new(0, 0, 0, 5)
  $card.Cursor = [System.Windows.Input.Cursors]::Hand
  if ($isUnchanged) { $card.Opacity = 0.84 }

  $tooltipText = "$($Item.key)`n$($Item.untrustedTitle)`n$($L.CardTipStatus): $($Item.reasons -join ' | ')`n$($L.CardTipNext): $($Item.nextAction)`n$($L.CardTipClicks)"
  $card.ToolTip = $tooltipText

  $rowGrid = [System.Windows.Controls.Grid]::new()
  $colAccent = [System.Windows.Controls.ColumnDefinition]::new()
  $colAccent.Width = [System.Windows.GridLength]::new(4.5)
  $colBody = [System.Windows.Controls.ColumnDefinition]::new()
  $colBody.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
  [void]$rowGrid.ColumnDefinitions.Add($colAccent)
  [void]$rowGrid.ColumnDefinitions.Add($colBody)

  $stripe = [System.Windows.Controls.Border]::new()
  $stripe.Background = ConvertFrom-BrushHex $spec.AccentHex
  $stripe.CornerRadius = [System.Windows.CornerRadius]::new(7, 0, 0, 7)
  [System.Windows.Controls.Grid]::SetColumn($stripe, 0)
  [void]$rowGrid.Children.Add($stripe)

  $bodyStack = [System.Windows.Controls.StackPanel]::new()
  $bodyStack.Margin = [System.Windows.Thickness]::new(9, 6, 9, 6)
  [System.Windows.Controls.Grid]::SetColumn($bodyStack, 1)

  # Top badge strip (#number + vivid highlight pills)
  $topWrap = [System.Windows.Controls.WrapPanel]::new()
  $topWrap.Orientation = [System.Windows.Controls.Orientation]::Horizontal
  $topWrap.Margin = [System.Windows.Thickness]::new(0, 0, 0, 3)

  $repoPrefix = if ($Item.repo -ne "openclaw/openclaw") { "$($Item.repo.Split('/')[-1])#" } else { "#" }
  $numBadge = New-BadgePill "$repoPrefix$($Item.number)" $Pal.PrNumBg $Pal.PrNumBorder $Pal.PrNumFg $true
  [void]$topWrap.Children.Add($numBadge)

  foreach ($b in $spec.Badges) {
    $pill = New-BadgePill $b.Text $b.Bg $b.Border $b.Fg $true
    [void]$topWrap.Children.Add($pill)
  }
  [void]$bodyStack.Children.Add($topWrap)

  # Clean single-line PR title
  $titleTb = [System.Windows.Controls.TextBlock]::new()
  $titleTb.Text = $Item.untrustedTitle
  $titleTb.Foreground = ConvertFrom-BrushHex $Pal.TitleFg
  $titleTb.FontSize = 12
  $titleTb.FontWeight = if ($isUnchanged) { [System.Windows.FontWeights]::Normal } else { [System.Windows.FontWeights]::Medium }
  $titleTb.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
  [void]$bodyStack.Children.Add($titleTb)

  [void]$rowGrid.Children.Add($bodyStack)
  $card.Child = $rowGrid

  $normalBrush = ConvertFrom-BrushHex $cardBg
  $hoverBrush = ConvertFrom-BrushHex $Pal.RowHoverBg
  $url = [string]$Item.url
  $itemKey = [string]$Item.key
  $copyText = "$itemKey $url"

  $card.Add_MouseEnter({
    $this.Background = $hoverBrush
  }.GetNewClosure())

  $card.Add_MouseLeave({
    $this.Background = $normalBrush
  }.GetNewClosure())

  $card.Add_MouseLeftButtonUp({
    if ($url -match "^https://github\.com/") {
      Start-Process $url
    }
  }.GetNewClosure())

  $card.Add_MouseRightButtonUp({
    [System.Windows.Clipboard]::SetText($copyText)
    $FooterStatus.Text = ((Get-LangTable).FooterCopied -f $itemKey)
  }.GetNewClosure())

  [void]$CardsStack.Children.Add($card)
}

function Update-HudView {
  $L = Get-LangTable
  $Pal = $Palettes[$script:CurrentTheme]

  $OuterCard.Background = ConvertFrom-BrushHex $Pal.CardBg
  $OuterCard.BorderBrush = ConvertFrom-BrushHex $Pal.CardBorder
  $HeaderBar.Background = ConvertFrom-BrushHex $Pal.HeaderBg
  $FooterBar.Background = ConvertFrom-BrushHex $Pal.FooterBg
  $HeaderTitle.Foreground = ConvertFrom-BrushHex $Pal.TitleFg
  $HeaderSub.Foreground = ConvertFrom-BrushHex $Pal.SubFg
  $FooterStatus.Foreground = ConvertFrom-BrushHex $Pal.SubFg

  if (-not $script:IsRefreshing) {
    $BtnRefresh.Content = $L.BtnRefresh
  } else {
    $BtnRefresh.Content = $L.BtnRefreshing
  }
  $BtnRefresh.ToolTip = $L.BtnRefreshTip
  $BtnPin.ToolTip = $L.BtnPinTip
  $BtnClose.ToolTip = ($L.BtnCloseTip -f $script:HotKeyLabel)
  $BtnMarkSeen.Content = $L.BtnMarkSeen
  $BtnMarkSeen.ToolTip = $L.BtnMarkSeenTip
  $BtnTheme.ToolTip = $L.BtnThemeTip
  $ResizeThumb.ToolTip = $L.ResizeTip

  Set-StyledButton $BtnRefresh $Pal.ActionBtnBg $Pal.ActionBtnBorder $Pal.ActionBtnFg
  if ($Window.Topmost) {
    $BtnPin.Content = $L.BtnPinned
    Set-StyledButton $BtnPin $Pal.PinActiveBg $Pal.PinActiveFg $Pal.PinActiveFg
  } else {
    $BtnPin.Content = $L.BtnPin
    Set-StyledButton $BtnPin $Pal.ActionBtnBg $Pal.ActionBtnBorder $Pal.SubFg
  }
  Set-StyledButton $BtnClose "Transparent" "Transparent" $Pal.SubFg
  Set-StyledButton $BtnMarkSeen $Pal.ActionBtnBg $Pal.ActionBtnBorder $Pal.ActionBtnFg
  $BtnTheme.Content = if ($script:CurrentTheme -eq "dark") { $L.ToggleSticky } else { $L.ToggleDark }
  Set-StyledButton $BtnTheme $Pal.ActionBtnBg $Pal.ActionBtnBorder $Pal.ActionBtnFg

  $CardsStack.Children.Clear()

  if (-not $script:CachedData -or -not $script:CachedData.Score) {
    $emptyTb = [System.Windows.Controls.TextBlock]::new()
    $emptyTb.Text = $L.EmptyState
    $emptyTb.Foreground = ConvertFrom-BrushHex $Pal.SubFg
    $emptyTb.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $emptyTb.Margin = [System.Windows.Thickness]::new(8, 20, 8, 20)
    [void]$CardsStack.Children.Add($emptyTb)
    Update-TrayVisuals
    return
  }

  $score = $script:CachedData.Score
  $handle = if ($score.viewerHandle) { "@$($score.viewerHandle)" } else { "@github" }
  $ageText = Format-RelativeAge $script:CachedData.CapturedAt
  $HeaderSub.Text = "  ·  $handle  ·  $ageText"

  $p1All = @($score.tiers.P1)
  $p1Active = @($p1All | Where-Object { -not $_.isDraft })
  $p1Drafts = @($p1All | Where-Object { $_.isDraft })
  $p2List = @($score.tiers.P2)
  $p3List = @($score.tiers.P3)
  $p4List = @($score.tiers.P4)
  $p34Count = $p3List.Count + $p4List.Count

  # Populate Vivid KPI Tiles
  $TileP1.Background = ConvertFrom-BrushHex $Pal.TileP1Bg
  $TileP1.BorderBrush = ConvertFrom-BrushHex $(if ($script:ActiveFilter -eq "P1") { $Pal.TitleFg } else { $Pal.TileP1Border })
  $TileP1.BorderThickness = [System.Windows.Thickness]::new($(if ($script:ActiveFilter -eq "P1") { 2.2 } else { 1.2 }))
  $TileP1Count.Text = "$($p1Active.Count)"
  $TileP1Count.Foreground = ConvertFrom-BrushHex $Pal.TileP1Fg
  $TileP1Label.Text = if ($p1Drafts.Count -gt 0) { ($L.TileP1WithDrafts -f $p1Drafts.Count) } else { $L.TileP1 }
  $TileP1Label.Foreground = ConvertFrom-BrushHex $Pal.TileP1Fg

  $TileP2.Background = ConvertFrom-BrushHex $Pal.TileP2Bg
  $TileP2.BorderBrush = ConvertFrom-BrushHex $(if ($script:ActiveFilter -eq "P2") { $Pal.TitleFg } else { $Pal.TileP2Border })
  $TileP2.BorderThickness = [System.Windows.Thickness]::new($(if ($script:ActiveFilter -eq "P2") { 2.2 } else { 1.2 }))
  $TileP2Count.Text = "$($p2List.Count)"
  $TileP2Count.Foreground = ConvertFrom-BrushHex $Pal.TileP2Fg
  $TileP2Label.Text = $L.TileP2
  $TileP2Label.Foreground = ConvertFrom-BrushHex $Pal.TileP2Fg

  $TileP34.Background = ConvertFrom-BrushHex $Pal.TileP34Bg
  $TileP34.BorderBrush = ConvertFrom-BrushHex $(if ($script:ActiveFilter -eq "P34") { $Pal.TitleFg } else { $Pal.TileP34Border })
  $TileP34.BorderThickness = [System.Windows.Thickness]::new($(if ($script:ActiveFilter -eq "P34") { 2.2 } else { 1.2 }))
  $TileP34Count.Text = "$p34Count"
  $TileP34Count.Foreground = ConvertFrom-BrushHex $Pal.TileP34Fg
  $TileP34Label.Text = $L.TileP34
  $TileP34Label.Foreground = ConvertFrom-BrushHex $Pal.TileP34Fg

  # Render Filtered or Full Sections (P1 Active blockers first, then P2 Ready, P3/P4, Drafts)
  if ($script:ActiveFilter -in @("ALL", "P1") -and $p1Active.Count -gt 0) {
    Add-SectionHeader ($L.SecP1 -f $p1Active.Count) $Pal.TileP1Fg
    foreach ($item in $p1Active) { Add-PrCard $item $Pal }
  }

  if ($script:ActiveFilter -in @("ALL", "P2") -and $p2List.Count -gt 0) {
    Add-SectionHeader ($L.SecP2 -f $p2List.Count) $Pal.TileP2Fg
    foreach ($item in $p2List) { Add-PrCard $item $Pal }
  }

  if ($script:ActiveFilter -in @("ALL", "P34") -and ($p3List.Count + $p4List.Count) -gt 0) {
    Add-SectionHeader ($L.SecP34 -f $p34Count) $Pal.TileP34Fg
    foreach ($item in $p3List) { Add-PrCard $item $Pal }
    foreach ($item in $p4List) { Add-PrCard $item $Pal }
  }

  if ($script:ActiveFilter -in @("ALL", "P1") -and $p1Drafts.Count -gt 0) {
    Add-SectionHeader ($L.SecDrafts -f $p1Drafts.Count) $Pal.MutedFg
    foreach ($item in $p1Drafts) { Add-PrCard $item $Pal }
  }

  if (-not $script:IsRefreshing) {
    $FooterStatus.Text = ($L.FooterIdle -f $score.changedCount, $script:HotKeyLabel)
  }
  Update-TrayVisuals
}

function ConvertTo-GdiColor([string]$Hex, [int]$Alpha = 255) {
  $clean = $Hex.TrimStart('#')
  if ($clean.Length -eq 8) {
    $Alpha = [Convert]::ToInt32($clean.Substring(0, 2), 16)
    $clean = $clean.Substring(2)
  }
  $r = [Convert]::ToInt32($clean.Substring(0, 2), 16)
  $g = [Convert]::ToInt32($clean.Substring(2, 2), 16)
  $b = [Convert]::ToInt32($clean.Substring(4, 2), 16)
  return [System.Drawing.Color]::FromArgb($Alpha, $r, $g, $b)
}

function New-TrayStatusHIcon([string]$DotHex) {
  $bmp = [System.Drawing.Bitmap]::new(32, 32, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  try {
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)

    $bgBrush = [System.Drawing.SolidBrush]::new((ConvertTo-GdiColor "#0F172A"))
    $ringPen = [System.Drawing.Pen]::new((ConvertTo-GdiColor "#38BDF8" 210), [single]2.1)
    $arcPen  = [System.Drawing.Pen]::new((ConvertTo-GdiColor "#10E88A" 235), [single]2.4)
    $centerBrush = [System.Drawing.SolidBrush]::new((ConvertTo-GdiColor "#E2E8F0"))
    $haloBrush   = [System.Drawing.SolidBrush]::new((ConvertTo-GdiColor "#0F172A"))
    $dotBrush    = [System.Drawing.SolidBrush]::new((ConvertTo-GdiColor $DotHex))
    try {
      $g.FillEllipse($bgBrush, 1, 1, 28, 28)
      $g.DrawEllipse($ringPen, 3, 3, 24, 24)
      $g.DrawArc($arcPen, 7, 7, 16, 16, -65, 135)
      $g.FillEllipse($centerBrush, 13, 13, 4, 4)

      # High-contrast status badge dot in bottom-right corner
      $g.FillEllipse($haloBrush, 18, 18, 14, 14)
      $g.FillEllipse($dotBrush, 20, 20, 10, 10)
    } finally {
      $bgBrush.Dispose()
      $ringPen.Dispose()
      $arcPen.Dispose()
      $centerBrush.Dispose()
      $haloBrush.Dispose()
      $dotBrush.Dispose()
    }
    return $bmp.GetHicon()
  } finally {
    $g.Dispose()
    $bmp.Dispose()
  }
}

function Update-TrayVisuals {
  if ($SavePreview -or -not $script:TrayIcon) { return }

  $L = Get-LangTable
  $dotHex = "#38BDF8"
  $tipText = ($L.TrayTipIdle -f $script:HotKeyLabel)

  if ($script:CachedData -and $script:CachedData.Score) {
    $sc = $script:CachedData.Score
    $p1All = @($sc.tiers.P1)
    $p1ActiveCount = @($p1All | Where-Object { -not $_.isDraft }).Count
    $p2Count = @($sc.tiers.P2).Count
    if ($p1ActiveCount -gt 0) {
      $dotHex = "#FF4D6D"
    } elseif ($p2Count -gt 0) {
      $dotHex = "#10E88A"
    }
    $tipText = ($L.TrayTipSummary -f $p1ActiveCount, $p2Count, $script:HotKeyLabel)
  }

  if ($tipText.Length -gt 60) {
    $tipText = $tipText.Substring(0, 60)
  }
  $script:TrayIcon.Text = $tipText

  $newHIcon = New-TrayStatusHIcon $dotHex
  $prevIcon = $script:TrayIcon.Icon
  $prevHIcon = $script:CurrentTrayHIcon
  $script:TrayIcon.Icon = [System.Drawing.Icon]::FromHandle($newHIcon)
  $script:CurrentTrayHIcon = $newHIcon
  if ($prevIcon) {
    try { $prevIcon.Dispose() } catch {}
  }
  if ($prevHIcon -ne [IntPtr]::Zero) {
    [void][HudWin32]::DestroyIcon($prevHIcon)
  }
}

function Show-HudWindow {
  $Window.ShowInTaskbar = $true
  if (-not $Window.IsVisible) {
    $Window.Show()
  }
  if ($Window.WindowState -eq [System.Windows.WindowState]::Minimized) {
    $Window.WindowState = [System.Windows.WindowState]::Normal
  }
  $hwnd = ([System.Windows.Interop.WindowInteropHelper]::new($Window)).Handle
  if ($hwnd -ne [IntPtr]::Zero) {
    [void][HudWin32]::ShowWindow($hwnd, 5)
    [void][HudWin32]::SetForegroundWindow($hwnd)
  }
  [void]$Window.Activate()
}

function Hide-HudToTray {
  Save-HudPrefs
  $Window.Hide()
  $Window.ShowInTaskbar = $false
}

function Toggle-HudWindow {
  if (-not $Window.IsVisible -or $Window.WindowState -eq [System.Windows.WindowState]::Minimized) {
    Show-HudWindow
  } elseif (-not $Window.Topmost -and -not $Window.IsActive) {
    Show-HudWindow
  } else {
    Hide-HudToTray
  }
}

function Set-StartupEnabled([bool]$Enable) {
  if ($Enable) {
    $L = Get-LangTable
    $exeTarget = Join-Path $HudRoot "PR-Radar-Notu.exe"
    $wsh = New-Object -ComObject WScript.Shell
    $sc = $wsh.CreateShortcut($StartupLnkPath)
    $sc.TargetPath = $exeTarget
    $sc.Arguments = "-StartHidden"
    $sc.WorkingDirectory = $HudRoot
    $sc.Description = $L.StartupDesc
    if (Test-Path $IconPath) {
      $sc.IconLocation = "$IconPath,0"
    }
    $sc.Save()
  } else {
    if (Test-Path $StartupLnkPath) {
      Remove-Item -LiteralPath $StartupLnkPath -Force -ErrorAction SilentlyContinue
    }
  }
}

function Invoke-ExitHud {
  if ($script:AllowExit) { return }
  $script:AllowExit = $true
  Save-HudPrefs
  if ($PollTimer) { $PollTimer.Stop() }
  if ($script:SweepJob) {
    Remove-Job -Job $script:SweepJob -Force -ErrorAction SilentlyContinue
    $script:SweepJob = $null
  }
  if ($script:HotKeyHost) {
    try { $script:HotKeyHost.Dispose() } catch {}
    $script:HotKeyHost = $null
  }
  if ($script:TrayIcon) {
    $script:TrayIcon.Visible = $false
    try { $script:TrayIcon.Dispose() } catch {}
    $script:TrayIcon = $null
  }
  if ($script:CurrentTrayHIcon -ne [IntPtr]::Zero) {
    [void][HudWin32]::DestroyIcon($script:CurrentTrayHIcon)
    $script:CurrentTrayHIcon = [IntPtr]::Zero
  }
  if ($script:WakeEvent) {
    try { $script:WakeEvent.Dispose() } catch {}
    $script:WakeEvent = $null
  }
  if ($script:ToggleEvent) {
    try { $script:ToggleEvent.Dispose() } catch {}
    $script:ToggleEvent = $null
  }
  if ($script:SingleMutex) {
    try { $script:SingleMutex.ReleaseMutex() } catch {}
    try { $script:SingleMutex.Dispose() } catch {}
    $script:SingleMutex = $null
  }
  try { $Window.Close() } catch {}
  if ($script:App) {
    $script:App.Shutdown()
  }
}

function Start-BackgroundSweep {
  if ($script:IsRefreshing) { return }
  $L = Get-LangTable
  $script:IsRefreshing = $true
  $script:LastAutoSweepUtc = [datetime]::UtcNow
  $BtnRefresh.Content = $L.BtnRefreshing
  $BtnRefresh.IsEnabled = $false
  $FooterStatus.Text = $L.FooterScanning

  $script:SweepJob = Start-Job -ScriptBlock {
    param($StateDirInner, $ConfigPathInner, $CursorsPathInner, $EngineScriptInner, $ResolveMergeScriptInner)
    $ErrorActionPreference = "Stop"
    $rootDir = Split-Path $StateDirInner -Parent
    $env:OPENCLAW_RADAR_WORKSPACE = $rootDir
    $cfg = Get-Content $ConfigPathInner -Raw -Encoding utf8 | ConvertFrom-Json
    $sliceArgs = @()
    foreach ($repo in $cfg.repositories) {
      $slug = $repo -replace "/", "__"
      $authoredRel      = "state/$slug-authored.json"
      $coauthoredRel    = "state/$slug-coauthored.json"
      $reviewsRel       = "state/$slug-reviews.json"
      $recentRel        = "state/$slug-recent.json"
      $mergeabilityRel  = "state/$slug-mergeability.json"

      $aOut = & gh pr list --repo $repo --author $cfg.viewerHandle --state open --limit 20 --json "number,title,url,isDraft,author,headRefName,headRefOid,mergeable,mergeStateStatus,reviewDecision,labels,statusCheckRollup,updatedAt,createdAt"
      Set-Content -Path (Join-Path $rootDir $authoredRel) -Value ($aOut -join "`n") -Encoding utf8

      $coOut = & gh pr list --repo $repo --search "$($cfg.viewerHandle) -author:$($cfg.viewerHandle)" --state open --limit 20 --json "number,title,url,isDraft,author,headRefName,headRefOid,mergeable,mergeStateStatus,reviewDecision,labels,commits,statusCheckRollup,updatedAt,createdAt"
      Set-Content -Path (Join-Path $rootDir $coauthoredRel) -Value ($coOut -join "`n") -Encoding utf8

      $rOut = & gh pr list --repo $repo --search "review-requested:$($cfg.viewerHandle)" --state open --limit 20 --json "number,title,url,isDraft,author,headRefName,headRefOid,mergeable,mergeStateStatus,reviewDecision,reviewRequests,labels,statusCheckRollup,updatedAt,createdAt"
      Set-Content -Path (Join-Path $rootDir $reviewsRel) -Value ($rOut -join "`n") -Encoding utf8

      $cOut = & gh pr list --repo $repo --state open --limit 25 --json "number,title,url,isDraft,author,headRefName,headRefOid,labels,files,updatedAt,createdAt"
      Set-Content -Path (Join-Path $rootDir $recentRel) -Value ($cOut -join "`n") -Encoding utf8

      Push-Location $rootDir
      try {
        & node $ResolveMergeScriptInner --repo $repo --slice $authoredRel --slice $coauthoredRel --slice $reviewsRel --out $mergeabilityRel | Out-Null
      } finally {
        Pop-Location
      }

      $sliceArgs += @(
        "--slice", "$repo=$authoredRel",
        "--slice", "$repo=$coauthoredRel",
        "--slice", "$repo=$reviewsRel",
        "--slice", "$repo=$recentRel",
        "--slice", "$repo=$mergeabilityRel"
      )
    }
    Push-Location $rootDir
    try {
      & node $EngineScriptInner --mode score @sliceArgs --save-sweep --input "state/latest-sweep.json" --config "state/config.json" --cursors "state/cursors.json" --json | Out-Null
    } finally {
      Pop-Location
    }
    return "OK"
  } -ArgumentList $StateDir, $ConfigPath, $CursorsPath, $EngineScript, $ResolveMergeScript
}

# Global Hotkey + System Tray setup (skipped during headless PNG preview)
if (-not $SavePreview) {
  # Register Ctrl+Alt+R (MOD_CONTROL|MOD_ALT|MOD_NOREPEAT = 0x4003, VK_R = 0x52)
  $script:HotKeyHost = [HotKeyWindow]::new(0x5241, 0x4003, 0x52)
  if (-not $script:HotKeyHost.IsRegistered) {
    $script:HotKeyHost.Dispose()
    $script:HotKeyHost = [HotKeyWindow]::new(0x5242, 0x4007, 0x52)
    $script:HotKeyLabel = if ($script:HotKeyHost.IsRegistered) { "Ctrl+Alt+Shift+R" } else { (Get-LangTable).TrayFallbackKey }
  }
  $script:HotKeyHost.OnHotKey = {
    $Window.Dispatcher.Invoke({ Toggle-HudWindow })
  }

  $TrayMenu = [System.Windows.Forms.ContextMenuStrip]::new()

  $script:MenuToggle = [System.Windows.Forms.ToolStripMenuItem]::new("")
  $script:MenuToggle.Font = [System.Drawing.Font]::new($script:MenuToggle.Font, [System.Drawing.FontStyle]::Bold)
  $script:MenuToggle.Add_Click({ $Window.Dispatcher.Invoke({ Toggle-HudWindow }) })

  $script:MenuRefresh = [System.Windows.Forms.ToolStripMenuItem]::new("")
  $script:MenuRefresh.Add_Click({ $Window.Dispatcher.Invoke({ Start-BackgroundSweep }) })

  $script:MenuMarkSeen = [System.Windows.Forms.ToolStripMenuItem]::new("")
  $script:MenuMarkSeen.Add_Click({
    $Window.Dispatcher.Invoke({
      Invoke-CommitCursor
      $script:CachedData = Invoke-EngineScore
      Update-HudView
      $FooterStatus.Text = (Get-LangTable).FooterMarkedSeen
    })
  })

  $script:MenuTheme = [System.Windows.Forms.ToolStripMenuItem]::new("")
  $script:MenuTheme.Add_Click({
    $Window.Dispatcher.Invoke({
      $script:CurrentTheme = if ($script:CurrentTheme -eq "dark") { "sticky" } else { "dark" }
      Save-HudPrefs
      Update-HudView
    })
  })

  $script:MenuLang = [System.Windows.Forms.ToolStripMenuItem]::new("")
  $script:MenuLangAuto = [System.Windows.Forms.ToolStripMenuItem]::new("")
  $script:MenuLangEn   = [System.Windows.Forms.ToolStripMenuItem]::new("English")
  $script:MenuLangTr   = [System.Windows.Forms.ToolStripMenuItem]::new("Türkçe")

  function Update-TrayMenuStrings {
    if ($SavePreview -or -not $script:MenuToggle) { return }
    $L = Get-LangTable
    $script:MenuToggle.Text      = ($L.TrayToggle -f $script:HotKeyLabel)
    $script:MenuRefresh.Text     = $L.TrayRefresh
    $script:MenuMarkSeen.Text    = $L.TrayMarkSeen
    $script:MenuTheme.Text       = $L.TrayTheme
    $script:MenuAutoRefresh.Text = $L.TrayAutoRefresh
    $script:MenuStartup.Text     = $L.TrayStartup
    $script:MenuLang.Text        = $L.TrayLangMenu
    $script:MenuLangAuto.Text    = $L.TrayLangAuto
    $script:MenuExit.Text        = $L.TrayExit
    $script:MenuLangAuto.Checked = ($script:LangPref -eq "auto")
    $script:MenuLangEn.Checked   = ($script:LangPref -eq "en")
    $script:MenuLangTr.Checked   = ($script:LangPref -eq "tr")
  }

  $script:MenuLangAuto.Add_Click({
    $Window.Dispatcher.Invoke({
      $script:LangPref = "auto"
      Save-HudPrefs
      Update-TrayMenuStrings
      Update-HudView
    })
  })
  $script:MenuLangEn.Add_Click({
    $Window.Dispatcher.Invoke({
      $script:LangPref = "en"
      Save-HudPrefs
      Update-TrayMenuStrings
      Update-HudView
    })
  })
  $script:MenuLangTr.Add_Click({
    $Window.Dispatcher.Invoke({
      $script:LangPref = "tr"
      Save-HudPrefs
      Update-TrayMenuStrings
      Update-HudView
    })
  })
  [void]$script:MenuLang.DropDownItems.Add($script:MenuLangAuto)
  [void]$script:MenuLang.DropDownItems.Add($script:MenuLangEn)
  [void]$script:MenuLang.DropDownItems.Add($script:MenuLangTr)

  $script:MenuAutoRefresh = [System.Windows.Forms.ToolStripMenuItem]::new("")
  $script:MenuAutoRefresh.Checked = [bool]$script:AutoRefresh
  $script:MenuAutoRefresh.Add_Click({
    $Window.Dispatcher.Invoke({
      $script:AutoRefresh = -not $script:AutoRefresh
      $script:MenuAutoRefresh.Checked = $script:AutoRefresh
      $script:LastAutoSweepUtc = [datetime]::UtcNow
      Save-HudPrefs
    })
  })

  $script:MenuStartup = [System.Windows.Forms.ToolStripMenuItem]::new("")
  $script:MenuStartup.Checked = (Test-Path $StartupLnkPath)
  $script:MenuStartup.Add_Click({
    $Window.Dispatcher.Invoke({
      $nextState = -not (Test-Path $StartupLnkPath)
      Set-StartupEnabled $nextState
      $script:MenuStartup.Checked = (Test-Path $StartupLnkPath)
    })
  })

  $script:MenuExit = [System.Windows.Forms.ToolStripMenuItem]::new("")
  $script:MenuExit.Add_Click({ $Window.Dispatcher.Invoke({ Invoke-ExitHud }) })

  [void]$TrayMenu.Items.Add($script:MenuToggle)
  [void]$TrayMenu.Items.Add($script:MenuRefresh)
  [void]$TrayMenu.Items.Add($script:MenuMarkSeen)
  [void]$TrayMenu.Items.Add($script:MenuTheme)
  [void]$TrayMenu.Items.Add($script:MenuLang)
  [void]$TrayMenu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())
  [void]$TrayMenu.Items.Add($script:MenuAutoRefresh)
  [void]$TrayMenu.Items.Add($script:MenuStartup)
  [void]$TrayMenu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())
  [void]$TrayMenu.Items.Add($script:MenuExit)

  Update-TrayMenuStrings

  $script:TrayIcon = [System.Windows.Forms.NotifyIcon]::new()
  $script:TrayIcon.ContextMenuStrip = $TrayMenu
  $script:TrayIcon.Add_MouseClick({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
      $Window.Dispatcher.Invoke({ Toggle-HudWindow })
    }
  })
  Update-TrayVisuals
  $script:TrayIcon.Visible = $true
}

# Timer for background job completion + single-instance wake/toggle + 30m auto-refresh
$PollTimer = [System.Windows.Threading.DispatcherTimer]::new()
$PollTimer.Interval = [TimeSpan]::FromMilliseconds(200)
$PollTimer.Add_Tick({
  if ($script:WakeEvent -and $script:WakeEvent.WaitOne(0)) {
    Show-HudWindow
  }
  if ($script:ToggleEvent -and $script:ToggleEvent.WaitOne(0)) {
    Toggle-HudWindow
  }
  if ($script:AutoRefresh -and -not $script:IsRefreshing -and -not $SavePreview) {
    if ((([datetime]::UtcNow) - $script:LastAutoSweepUtc).TotalMinutes -ge 30) {
      Start-BackgroundSweep
    }
  }
  if ($script:SweepJob) {
    if ($script:SweepJob.State -in @("Completed", "Failed", "Stopped")) {
      $L = Get-LangTable
      $failed = ($script:SweepJob.State -ne "Completed")
      $errText = ""
      if ($failed) {
        try { $errText = ($script:SweepJob.ChildJobs[0].JobStateInfo.Reason.Message) } catch {}
      }
      Remove-Job -Job $script:SweepJob -Force -ErrorAction SilentlyContinue
      $script:SweepJob = $null
      $script:IsRefreshing = $false
      $BtnRefresh.Content = $L.BtnRefresh
      $BtnRefresh.IsEnabled = $true
      if (-not $failed) {
        $script:CachedData = Invoke-EngineScore
        Update-HudView
        $FooterStatus.Text = ($L.FooterUpdated -f (Get-Date -Format 'HH:mm'))
      } else {
        $FooterStatus.Text = if ($errText) { ($L.FooterError -f $errText) } else { $L.FooterFailed }
      }
    }
  }
})
$PollTimer.Start()

# Event Handlers
$HeaderBar.Add_MouseLeftButtonDown({
  param($sender, $e)
  if ($e.ButtonState -eq [System.Windows.Input.MouseButtonState]::Pressed) {
    $Window.DragMove()
    Save-HudPrefs
  }
})

$ResizeThumb.Add_DragDelta({
  param($sender, $e)
  $Window.Width = [math]::Max($Window.MinWidth, $Window.Width + $e.HorizontalChange)
  $Window.Height = [math]::Max($Window.MinHeight, $Window.Height + $e.VerticalChange)
})
$ResizeThumb.Add_DragCompleted({ Save-HudPrefs })

$BtnClose.Add_Click({
  Hide-HudToTray
})

$BtnPin.Add_Click({
  $Window.Topmost = -not $Window.Topmost
  Save-HudPrefs
  Update-HudView
})

$BtnTheme.Add_Click({
  $script:CurrentTheme = if ($script:CurrentTheme -eq "dark") { "sticky" } else { "dark" }
  Save-HudPrefs
  Update-HudView
})

$BtnMarkSeen.Add_Click({
  Invoke-CommitCursor
  $script:CachedData = Invoke-EngineScore
  Update-HudView
  $FooterStatus.Text = (Get-LangTable).FooterMarkedSeen
})

$BtnRefresh.Add_Click({
  Start-BackgroundSweep
})

$TileP1.Add_MouseLeftButtonUp({
  $script:ActiveFilter = if ($script:ActiveFilter -eq "P1") { "ALL" } else { "P1" }
  Update-HudView
})
$TileP2.Add_MouseLeftButtonUp({
  $script:ActiveFilter = if ($script:ActiveFilter -eq "P2") { "ALL" } else { "P2" }
  Update-HudView
})
$TileP34.Add_MouseLeftButtonUp({
  $script:ActiveFilter = if ($script:ActiveFilter -eq "P34") { "ALL" } else { "P34" }
  Update-HudView
})

$Window.Add_KeyDown({
  param($sender, $e)
  if ($e.Key -eq [System.Windows.Input.Key]::Escape) {
    $e.Handled = $true
    Hide-HudToTray
  } elseif ($e.Key -eq [System.Windows.Input.Key]::F5) {
    $e.Handled = $true
    Start-BackgroundSweep
  } elseif ($e.Key -eq [System.Windows.Input.Key]::Q -and
            ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -eq [System.Windows.Input.ModifierKeys]::Control) {
    $e.Handled = $true
    Invoke-ExitHud
  }
})

$Window.Add_Closing({
  param($sender, $e)
  if (-not $script:AllowExit -and -not $SavePreview) {
    $e.Cancel = $true
    Hide-HudToTray
  }
})

$Window.Add_ContentRendered({
  if ($SavePreview) {
    $Window.UpdateLayout()
    $dpi = [System.Windows.Media.VisualTreeHelper]::GetDpi($Window)
    $pixelW = [int][math]::Ceiling($Window.ActualWidth * $dpi.DpiScaleX)
    $pixelH = [int][math]::Ceiling($Window.ActualHeight * $dpi.DpiScaleY)
    $rtb = [System.Windows.Media.Imaging.RenderTargetBitmap]::new(
      $pixelW,
      $pixelH,
      $dpi.PixelsPerInchX,
      $dpi.PixelsPerInchY,
      [System.Windows.Media.PixelFormats]::Pbgra32
    )
    $rtb.Render($Window)
    $encoder = [System.Windows.Media.Imaging.PngBitmapEncoder]::new()
    $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
    $previewDir = Split-Path $SavePreview -Parent
    if ($previewDir -and -not (Test-Path $previewDir)) {
      New-Item -ItemType Directory -Path $previewDir -Force | Out-Null
    }
    $stream = [System.IO.File]::Create($SavePreview)
    try {
      $encoder.Save($stream)
    } finally {
      $stream.Dispose()
    }
    if ($AutoCloseAfterPreview) {
      Invoke-ExitHud
      return
    }
  }
  $hwnd = ([System.Windows.Interop.WindowInteropHelper]::new($Window)).Handle
  if ($hwnd -ne [IntPtr]::Zero) {
    [void][HudWin32]::ShowWindow($hwnd, 5)
    [void][HudWin32]::SetForegroundWindow($hwnd)
  }
  [void]$Window.Activate()
})

$script:App = [System.Windows.Application]::Current
if (-not $script:App) {
  $script:App = [System.Windows.Application]::new()
}
$script:App.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown

$script:CachedData = Invoke-EngineScore
Update-HudView

if (-not $SavePreview -and ($RefreshOnLaunch -or -not (Test-Path $SweepPath))) {
  Start-BackgroundSweep
}

if ($StartHidden -and -not $SavePreview) {
  $Window.ShowInTaskbar = $false
} else {
  Show-HudWindow
}

[void]$script:App.Run()
