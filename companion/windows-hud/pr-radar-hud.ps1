param(
  [switch]$RefreshOnLaunch,
  [switch]$StartHidden,
  [switch]$Toggle,
  [ValidateSet("", "auto", "en", "tr")]
  [string]$Lang = "",
  [ValidateSet("", "dark", "sticky")]
  [string]$ForceTheme = "",
  [string]$SavePreview = "",
  [ValidateSet("", "ALL", "P1", "P2", "P34", "CAND")]
  [string]$PreviewFilter = "",
  [switch]$PreviewExpandBrief,
  [int]$PreviewHandoffIssue = 0,
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
$WatchReportPath = Join-Path $StateDir "watch-report.json"
$WatchStatePath = Join-Path $StateDir "watch-state.json"
$SurfaceBriefPath = Join-Path $StateDir "surface-brief.json"
$DetectedAgentsPath = Join-Path $StateDir "detected-agents.json"
$ActiveSessionsPath = Join-Path $StateDir "handoffs\active-sessions.json"
$IconPath = Join-Path $HudRoot "pr-radar.ico"

$LocalEngine = Join-Path $HudRoot "scripts\pr-radar-engine.mjs"
$RepoEngine = [System.IO.Path]::GetFullPath((Join-Path $HudRoot "..\..\templates\pr-review-radar\workspace\scripts\pr-radar-engine.mjs"))
$EngineScript = if (Test-Path -LiteralPath $LocalEngine) { $LocalEngine } else { $RepoEngine }

$LocalResolve = Join-Path $HudRoot "scripts\resolve-mergeability.mjs"
$RepoResolve = [System.IO.Path]::GetFullPath((Join-Path $HudRoot "..\..\templates\pr-review-radar\workspace\scripts\resolve-mergeability.mjs"))
$ResolveMergeScript = if (Test-Path -LiteralPath $LocalResolve) { $LocalResolve } else { $RepoResolve }

$LocalWatch = Join-Path $HudRoot "scripts\watch-and-vet-engine.mjs"
$RepoWatch = [System.IO.Path]::GetFullPath((Join-Path $HudRoot "..\..\templates\pr-review-radar\workspace\scripts\watch-and-vet-engine.mjs"))
$WatchScript = if (Test-Path -LiteralPath $LocalWatch) { $LocalWatch } else { $RepoWatch }

$FocusRunnerScript = Join-Path $HudRoot "scripts\surface-focus-runner.mjs"
$HandoffScript = Join-Path $HudRoot "scripts\handoff-launcher.mjs"

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
    InputBg           = "#0F172A"
    InputBorder       = "#334155"
    DrawerBg          = "#161D2B"
    DrawerBorder      = "#2B3A55"
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
    TileCandBg        = "#2B1F0A"
    TileCandBorder    = "#F59E0B"
    TileCandFg        = "#FCD34D"
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
    AccentGold        = "#FBBF24"
    BadgeGoldBg       = "#3D2806"
    BadgeGoldBorder   = "#F59E0B"
    BadgeGoldFg       = "#FDE68A"
    BadgeNewBg        = "#083344"
    BadgeNewBorder    = "#06B6D4"
    BadgeNewFg        = "#22D3EE"
    BadgeDraftBg      = "#1E293B"
    BadgeDraftBorder  = "#475569"
    BadgeDraftFg      = "#94A3B8"
    ActionBtnBg       = "#1E293B"
    ActionBtnBorder   = "#334155"
    ActionBtnFg       = "#E2E8F0"
    PrimaryBtnBg      = "#065F46"
    PrimaryBtnBorder  = "#10B981"
    PrimaryBtnFg      = "#ECFDF5"
  }
  sticky = @{
    Name              = "sticky"
    ToggleLabel       = "Koyu Mod"
    CardBg            = "#FFF9DB"
    CardBorder        = "#E5C653"
    HeaderBg          = "#FFE885"
    FooterBg          = "#FFF3B8"
    InputBg           = "#FFFDF5"
    InputBorder       = "#D97706"
    DrawerBg          = "#FEF9C3"
    DrawerBorder      = "#CA8A04"
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
    TileCandBg        = "#FFEDD5"
    TileCandBorder    = "#D97706"
    TileCandFg        = "#9A3412"
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
    AccentGold        = "#D97706"
    BadgeGoldBg       = "#FEF3C7"
    BadgeGoldBorder   = "#D97706"
    BadgeGoldFg       = "#92400E"
    BadgeNewBg        = "#FEF08A"
    BadgeNewBorder    = "#CA8A04"
    BadgeNewFg        = "#854D0E"
    BadgeDraftBg      = "#F5F5F4"
    BadgeDraftBorder  = "#A8A29E"
    BadgeDraftFg      = "#57534E"
    ActionBtnBg       = "#FDE68A"
    ActionBtnBorder   = "#D97706"
    ActionBtnFg       = "#1E293B"
    PrimaryBtnBg      = "#059669"
    PrimaryBtnBorder  = "#047857"
    PrimaryBtnFg      = "#FFFFFF"
  }
}

$Strings = @{
  en = @{
    ToggleSticky         = "Sticky Yellow"
    ToggleDark           = "Dark Neon"
    BtnRefresh           = "↻ Refresh"
    BtnRefreshing        = "Scanning..."
    BtnRefreshTip        = "Run live GitHub PR + Watch/Candidate sweep (F5)"
    BtnPinned            = "📌 Pinned"
    BtnPin               = "Pin"
    BtnPinTip            = "Keep always on top"
    BtnCloseTip          = "Hide to tray (Esc / {0}) · Quit: Ctrl+Q or tray menu"
    BtnMarkSeen          = "✓ Mark Seen"
    BtnMarkSeenTip       = "Mark current states as seen (clear NEW / UPDATED badges)"
    BtnThemeTip          = "Switch Dark Neon / Classic Sticky Yellow theme"
    ResizeTip            = "Resize"
    EmptyState           = "No PR sweep data yet. Click '↻ Refresh' above."
    NeverScanned         = "not scanned yet"
    JustNow              = "just now"
    MinAgo               = "{0}m ago"
    HrAgo                = "{0}h ago"
    DayAgo               = "{0}d ago"
    UpToDate             = "up to date"
    TileP1               = "BLOCKERS"
    TileP1WithDrafts     = "BLOCK (+{0}d)"
    TileP2               = "READY"
    TileP34              = "RADAR"
    TileCand             = "CANDIDATES"
    TileCandDelta        = "CAND · Δ{0}"
    SecP2                = "READY · MERGE OR AWAITING GATE ({0})"
    SecP1                = "BLOCKERS · ACTION NEEDED ({0})"
    SecP34               = "YOUR REVIEWS & SURFACE RADAR ({0})"
    SecDrafts            = "DRAFTS ({0})"
    SecPriorityCand      = "⭐ PRIORITY SURFACE CANDIDATES ({0})"
    SecCandidates        = "UNCLAIMED CANDIDATE ISSUES ({0})"
    SecWatchDeltas       = "RECENT WATCH DELTAS ({0})"
    SecTracked           = "TRACKED PRS & ISSUES ({0})"
    SecActiveHandoffs    = "ACTIVE CLAWHANDOFF SESSIONS ({0})"
    NoWatchChanges       = "No changes."
    NoCandidatesYet      = "No clean unclaimed candidates in queue right now."
    FocusPlaceholder     = "Focus area (e.g. sessions_spawn, blobster)..."
    BtnFocusRun          = "Analyze"
    BtnFocusRunning      = "Analyzing..."
    BtnFocusTip          = "Update focused surface & synthesize all-time brief with your AI agent"
    FocusAgentTip        = "Select AI agent for surface analysis"
    BriefToggleSummary   = "📊 Focus: {0} · {1} open PR · {2} issue"
    BriefExpand          = "▸ Open Brief"
    BriefCollapse        = "▾ Hide Brief"
    BriefClear           = "✕ Clear"
    BriefSecStatus       = "📌 Current Surface State"
    BriefSecOpps         = "🎯 Contribution Opportunities"
    BriefSecDevs         = "👥 Active Maintainers & Contributors"
    BriefPathsMeta       = "Paths: {0}"
    BadgeNew             = "NEW"
    BadgeChanged         = "UPDATED"
    BadgeCoAuthor        = "CO-OP: {0}"
    BadgeSecOne          = "SECURITY: {0}"
    BadgeSecMany         = "{0} SECURITY CHECKS"
    BadgeCiMany          = "CI ({0}): {1}+"
    BadgeCiFail          = "CI FAIL: {0}"
    BadgeConflict        = "CONFLICT · REBASE"
    BadgeChangesReq      = "CHANGES REQUESTED"
    BadgeDraft           = "DRAFT"
    BadgeGate            = "GREEN · AWAITING GATE"
    BadgeBehind          = "GREEN · BEHIND BASE"
    BadgeMergeCheck      = "GREEN · CHECKING MERGE"
    BadgeReady           = "READY TO MERGE · GREEN"
    BadgeReviewGreen     = "REVIEW YOU · GREEN"
    BadgeReview          = "REVIEW REQUESTED"
    BadgeWatchPath       = "OVERLAP: {0}"
    BadgeWatchFocus      = "FOCUS: {0}"
    BadgeWatchArea       = "AREA OVERLAP"
    BadgePriorityArea    = "⭐ PRIORITY SURFACE"
    BtnStartHandoff      = "🚀 Claim & Handoff"
    BtnDismissCand       = "✕"
    BtnOpenWorktree      = "📂 Worktree"
    BtnUntrack           = "✕ Untrack"
    BtnAddTrack          = "+ Track"
    TrackPlaceholder     = "pr:123 or issue:456"
    HandoffHeader        = "🚀 #{0} — Claim & Launch clawhandoff"
    HandoffAgentLabel    = "Target Agent:"
    HandoffClaimCheck    = "Post ownership comment to GitHub issue"
    HandoffConfirmBtn    = "✓ Confirm: Launch & Claim"
    HandoffLaunchingBtn  = "Launching..."
    HandoffCancelBtn     = "Cancel"
    HandoffLaunchedMsg   = "✓ #{0} launched on {1} ({2})"
    CardTipStatus        = "Status"
    CardTipNext          = "Next"
    CardTipClicks        = "(Left-click: Open in browser  |  Right-click: Copy link)"
    FooterIdle           = "{0} new · {1}: Show/Hide"
    FooterScanning       = "Scanning PR slices, tracked items & candidates..."
    FooterFocusing       = "Agent analyzing surface '{0}'..."
    FooterUpdated        = "Updated live ({0})"
    FooterError          = "Error: {0}"
    FooterFailed         = "Operation failed"
    FooterMarkedSeen     = "All items marked as seen"
    FooterCopied         = "Copied: {0}"
    TrayTipIdle          = "PR Radar · ({0})"
    TrayTipSummary       = "PR Radar · {0} blocked, {1} ready, {2} cand ({3})"
    TrayToggle           = "Show / Hide ({0})"
    TrayRefresh          = "↻ Refresh Now"
    TrayMarkSeen         = "✓ Mark All Seen"
    TrayTheme            = "🎨 Switch Theme (Dark / Sticky)"
    TrayAutoRefresh      = "Auto-Refresh (30 min)"
    TrayStartup          = "Launch at Windows Login (in Tray)"
    TrayLangMenu         = "🌐 Language / Dil"
    TrayLangAuto         = "System Default (Auto)"
    TrayExit             = "✕ Quit Completely (Ctrl+Q)"
    TrayFallbackKey      = "Tray icon"
    StartupDesc          = "PR Review Radar Sticky HUD (System Tray)"
  }
  tr = @{
    ToggleSticky         = "Sarı Not"
    ToggleDark           = "Koyu Mod"
    BtnRefresh           = "↻ Yenile"
    BtnRefreshing        = "Taranıyor..."
    BtnRefreshTip        = "Canlı PR + İzleme & Aday Issue taraması başlat (F5)"
    BtnPinned            = "📌 Sabit"
    BtnPin               = "Sabitle"
    BtnPinTip            = "Her zaman üstte tut (Always on Top)"
    BtnCloseTip          = "Tepsiye gizle (Esc / {0}) · Tam çıkış: Ctrl+Q veya tepsi menüsü"
    BtnMarkSeen          = "✓ Okundu İşaretle"
    BtnMarkSeenTip       = "Mevcut durumları okundu olarak kaydet (YENİ rozetlerini sıfırla)"
    BtnThemeTip          = "Koyu Mod / Klasik Sarı Yapışkan Not görünümü"
    ResizeTip            = "Boyutlandır"
    EmptyState           = "Henüz PR tarama verisi yok. Üstteki '↻ Yenile' butonuna tıklayın."
    NeverScanned         = "henüz taranmadı"
    JustNow              = "az önce"
    MinAgo               = "{0} dk önce"
    HrAgo                = "{0} sa önce"
    DayAgo               = "{0} gün önce"
    UpToDate             = "güncel"
    TileP1               = "ACİL ENGEL"
    TileP1WithDrafts     = "ENGEL (+{0}t)"
    TileP2               = "MERGE HAZIR"
    TileP34              = "RADAR/TEMAS"
    TileCand             = "ADAY/İZLEME"
    TileCandDelta        = "ADAY · Δ{0}"
    SecP2                = "HAZIR · MERGE VEYA ONAY BEKLEYEN ({0})"
    SecP1                = "ACİL ENGEL · AKSİYON GEREKTİREN ({0})"
    SecP34               = "SİZDEN REVIEW & ODAK TEMASI ({0})"
    SecDrafts            = "TASLAKLAR ({0})"
    SecPriorityCand      = "⭐ ÖNCELİKLİ ALAN ADAYLARI ({0})"
    SecCandidates        = "TEMİZ ADAY ISSUE'LAR · 5 KAPI ONAYLI ({0})"
    SecWatchDeltas       = "SON İZLEME DEĞİŞİKLİKLERİ ({0})"
    SecTracked           = "TAKİP EDİLEN PR & ISSUE'LAR ({0})"
    SecActiveHandoffs    = "AKTİF CLAWHANDOFF OTURUMLARI ({0})"
    NoWatchChanges       = "Değişiklik yok."
    NoCandidatesYet      = "Şu anda kuyrukta bekleyen yeni temiz aday issue yok."
    FocusPlaceholder     = "Takip edilecek alanı yaz (örn: sessions_spawn, blobster)..."
    BtnFocusRun          = "Analiz"
    BtnFocusRunning      = "Analiz..."
    BtnFocusTip          = "Temsilcinize bu alanı tüm zamanlarıyla taratıp odak raporunu hazırla"
    FocusAgentTip        = "Yüzey raporunu hazırlayacak yapay zeka temsilcisi"
    BriefToggleSummary   = "📊 Odak: {0} · {1} açık PR · {2} issue"
    BriefExpand          = "▸ Raporu Aç"
    BriefCollapse        = "▾ Raporu Kapat"
    BriefClear           = "✕ Temizle"
    BriefSecStatus       = "📌 Alanın Mevcut Durumu & Yorum"
    BriefSecOpps         = "🎯 Katkı Sunulabilecek Alanlar"
    BriefSecDevs         = "👥 İlgilenen Geliştiriciler"
    BriefPathsMeta       = "İzlenen yollar: {0}"
    BadgeNew             = "YENİ"
    BadgeChanged         = "DEĞİŞTİ"
    BadgeCoAuthor        = "ORTAK: {0}"
    BadgeSecOne          = "GÜVENLİK: {0}"
    BadgeSecMany         = "{0} GÜVENLİK KONTROLÜ"
    BadgeCiMany          = "CI ({0}): {1}+"
    BadgeCiFail          = "CI HATASI: {0}"
    BadgeConflict        = "ÇAKIŞMA · REBASE"
    BadgeChangesReq      = "REVİZYON İSTENDİ"
    BadgeDraft           = "TASLAK"
    BadgeGate            = "YEŞİL · ONAY BEKLİYOR"
    BadgeBehind      = "YEŞİL · DAL GERİDE"
    BadgeMergeCheck      = "YEŞİL · ÇAKIŞMA KONTROLÜ"
    BadgeReady           = "MERGE HAZIR · YEŞİL"
    BadgeReviewGreen     = "SİZDEN REVIEW · YEŞİL"
    BadgeReview          = "SİZDEN REVIEW"
    BadgeWatchPath       = "TEMAS: {0}"
    BadgeWatchFocus      = "ODAK: {0}"
    BadgeWatchArea       = "ALAN TEMASI"
    BadgePriorityArea    = "⭐ ÖNCELİKLİ ALAN"
    BtnStartHandoff      = "🚀 Sahiplen & Başlat"
    BtnDismissCand       = "✕"
    BtnOpenWorktree      = "📂 Worktree"
    BtnUntrack           = "✕ Bırak"
    BtnAddTrack          = "+ Takip"
    TrackPlaceholder     = "pr:123 veya issue:456"
    HandoffHeader        = "🚀 #{0} — Sahiplen & clawhandoff Başlat"
    HandoffAgentLabel    = "Temsilci:"
    HandoffClaimCheck    = "GitHub issue'suna sahiplik yorumu gönder"
    HandoffConfirmBtn    = "✓ Onayla: Başlat & Yorum At"
    HandoffLaunchingBtn  = "Başlatılıyor..."
    HandoffCancelBtn     = "Vazgeç"
    HandoffLaunchedMsg   = "✓ #{0} için {1} oturumu başlatıldı ({2})"
    CardTipStatus        = "Durum"
    CardTipNext          = "Öneri"
    CardTipClicks        = "(Sol tık: Tarayıcıda aç  |  Sağ tık: Bağlantıyı kopyala)"
    FooterIdle           = "{0} yeni · {1}: Aç/Gizle"
    FooterScanning       = "PR dilimleri, izlenenler ve aday issue'lar taranıyor..."
    FooterFocusing       = "Temsilci '{0}' alanını tüm zamanlarıyla analiz ediyor..."
    FooterUpdated        = "Canlı güncellendi ({0})"
    FooterError          = "Hata: {0}"
    FooterFailed         = "İşlem başarısız oldu"
    FooterMarkedSeen     = "Tüm durumlar okundu işaretlendi"
    FooterCopied         = "Kopyalandı: {0}"
    TrayTipIdle          = "PR Radar · ({0})"
    TrayTipSummary       = "PR Radar · {0} engel, {1} hazır, {2} aday ({3})"
    TrayToggle           = "Göster / Gizle ({0})"
    TrayRefresh          = "↻ Şimdi Yenile"
    TrayMarkSeen         = "✓ Okundu İşaretle"
    TrayTheme            = "🎨 Tema Değiştir (Koyu / Sarı Not)"
    TrayAutoRefresh      = "Otomatik Yenile (30 dk)"
    TrayStartup          = "Windows Açılışında Başlat (Tepside)"
    TrayLangMenu         = "🌐 Dil / Language"
    TrayLangAuto         = "Sistem Dili (Otomatik)"
    TrayExit             = "✕ Tamamen Çıkış (Ctrl+Q)"
    TrayFallbackKey      = "Tepsi ikonu"
    StartupDesc          = "PR Radar Yapışkan Notu (Sistem Tepsisi)"
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
    focusAgent  = "auto"
    left        = $null
    top         = $null
    width       = 456
    height      = 650
  }
  if (Test-Path $PrefsPath) {
    try {
      $raw = Get-Content $PrefsPath -Raw -Encoding utf8 | ConvertFrom-Json
      if ($raw.theme -in @("dark", "sticky")) { $defaults.theme = $raw.theme }
      if ($raw.lang -in @("auto", "en", "tr")) { $defaults.lang = $raw.lang }
      if ($null -ne $raw.topmost) { $defaults.topmost = [bool]$raw.topmost }
      if ($null -ne $raw.autoRefresh) { $defaults.autoRefresh = [bool]$raw.autoRefresh }
      if ($raw.focusAgent) { $defaults.focusAgent = [string]$raw.focusAgent }
      if ($null -ne $raw.left) { $defaults.left = [double]$raw.left }
      if ($null -ne $raw.top) { $defaults.top = [double]$raw.top }
      if ($null -ne $raw.width -and [double]$raw.width -ge 370) { $defaults.width = [double]$raw.width }
      if ($null -ne $raw.height -and [double]$raw.height -ge 400) { $defaults.height = [double]$raw.height }
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
      focusAgent  = [string]$script:FocusAgentPref
      left        = [math]::Round($Window.Left, 0)
      top         = [math]::Round($Window.Top, 0)
      width       = [math]::Round($Window.Width, 0)
      height      = [math]::Round($Window.Height, 0)
    }
    $payload | ConvertTo-Json | Set-Content -Path $PrefsPath -Encoding utf8
  } catch {}
}

function Read-JsonFileSafe([string]$PathToRead) {
  if (-not (Test-Path -LiteralPath $PathToRead)) { return $null }
  try {
    return (Get-Content -LiteralPath $PathToRead -Raw -Encoding utf8 | ConvertFrom-Json)
  } catch {
    return $null
  }
}

function Invoke-EngineScore {
  if (-not (Test-Path $SweepPath)) {
    return $null
  }
  $rawJson = & node $EngineScript --mode score --input "state/latest-sweep.json" --config "state/config.json" --cursors "state/cursors.json" --json 2>$null
  if (-not $rawJson) { return $null }
  $parsed = ($rawJson -join "`n") | ConvertFrom-Json
  $sweepMeta = Read-JsonFileSafe $SweepPath
  return [pscustomobject]@{
    Score      = $parsed
    CapturedAt = $sweepMeta.capturedAt
  }
}

function Reload-LocalAuxState {
  $script:WatchReport = Read-JsonFileSafe $WatchReportPath
  $script:WatchState = Read-JsonFileSafe $WatchStatePath
  $script:SurfaceBrief = Read-JsonFileSafe $SurfaceBriefPath
  $script:DetectedAgents = Read-JsonFileSafe $DetectedAgentsPath
  $script:ActiveSessions = Read-JsonFileSafe $ActiveSessionsPath
  $script:ConfigObj = Read-JsonFileSafe $ConfigPath
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
  $border.Padding = [System.Windows.Thickness]::new(5.5, 1.5, 5.5, 1.5)
  $border.Margin = [System.Windows.Thickness]::new(0, 0, 4, 2)
  $border.VerticalAlignment = [System.Windows.VerticalAlignment]::Center

  $tb = [System.Windows.Controls.TextBlock]::new()
  $tb.Text = $Text
  $tb.Foreground = ConvertFrom-BrushHex $FgHex
  $tb.FontSize = 10
  $tb.FontWeight = if ($Bold) { [System.Windows.FontWeights]::Bold } else { [System.Windows.FontWeights]::SemiBold }
  $border.Child = $tb
  return $border
}

[xml]$Xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="PR Review Radar"
        Width="456" Height="650"
        MinWidth="370" MinHeight="400"
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
                <Setter TargetName="BtnBorder" Property="Opacity" Value="0.86"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="BtnBorder" Property="Opacity" Value="0.48"/>
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
          <RowDefinition Height="40"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="36"/>
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
              <TextBlock x:Name="HeaderSub" Text="" FontSize="11" VerticalAlignment="Center"/>
            </StackPanel>
            <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
              <Button x:Name="BtnRefresh" Content="↻ Yenile"
                      Padding="8,3" Margin="0,0,4,0" FontSize="11" FontWeight="SemiBold" Cursor="Hand" BorderThickness="1"/>
              <Button x:Name="BtnPin" Content="📌 Sabit"
                      Padding="8,3" Margin="0,0,4,0" FontSize="11" FontWeight="SemiBold" Cursor="Hand" BorderThickness="1"/>
              <Button x:Name="BtnClose" Content="✕"
                      Width="25" Height="24" FontSize="11" FontWeight="Bold" Cursor="Hand" BorderThickness="0"/>
            </StackPanel>
          </Grid>
        </Border>

        <!-- Compact Surface Focus Input + Collapsible Brief -->
        <StackPanel Grid.Row="2" Margin="10,6,10,2">
          <Grid Margin="0,0,0,4">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <Border x:Name="FocusInputBorder" Grid.Column="0" CornerRadius="6" BorderThickness="1" Padding="7,3" Margin="0,0,4,0">
              <Grid>
                <TextBlock x:Name="FocusPlaceholder" Text="" FontSize="11" VerticalAlignment="Center" IsHitTestVisible="False" Opacity="0.7"/>
                <TextBox x:Name="FocusInputBox" Background="Transparent" BorderThickness="0" FontSize="11.5" VerticalAlignment="Center" Padding="0"/>
              </Grid>
            </Border>
            <Button x:Name="BtnFocusAgent" Grid.Column="1" Content="🤖 Oto ▾" Padding="7,4" Margin="0,0,4,0" FontSize="10.5" FontWeight="SemiBold" Cursor="Hand" BorderThickness="1"/>
            <Button x:Name="BtnFocusRun" Grid.Column="2" Content="Analiz" Padding="9,4" FontSize="10.5" FontWeight="Bold" Cursor="Hand" BorderThickness="1"/>
          </Grid>

          <!-- 1-Line Collapsible Brief Toggle Pill -->
          <Border x:Name="BriefToggleBorder" CornerRadius="6" BorderThickness="1" Padding="8,3.5" Margin="0,0,0,3" Cursor="Hand" Visibility="Collapsed">
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <TextBlock x:Name="BriefToggleText" Grid.Column="0" FontSize="10.5" FontWeight="SemiBold" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
              <TextBlock x:Name="BriefToggleChevron" Grid.Column="1" FontSize="10.5" FontWeight="Bold" VerticalAlignment="Center" Margin="6,0,0,0"/>
            </Grid>
          </Border>

          <!-- Expandable / Collapsible Surface Report Drawer -->
          <Border x:Name="BriefDrawerBorder" CornerRadius="8" BorderThickness="1" Padding="8,6" Margin="0,0,0,4" MaxHeight="215" Visibility="Collapsed">
            <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
              <StackPanel x:Name="BriefDrawerStack"/>
            </ScrollViewer>
          </Border>
        </StackPanel>

        <!-- Instant Glance 4-Column KPI Filter Strip -->
        <Grid x:Name="KpiGrid" Grid.Row="3" Margin="10,2,10,5">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>

          <Border x:Name="TileP1" Grid.Column="0" CornerRadius="8" BorderThickness="1.2" Padding="7,5" Margin="0,0,3,0" Cursor="Hand">
            <StackPanel>
              <TextBlock x:Name="TileP1Count" Text="0" FontSize="17" FontWeight="ExtraBold" LineHeight="18"/>
              <TextBlock x:Name="TileP1Label" Text="ACİL ENGEL" FontSize="9" FontWeight="Bold" TextTrimming="CharacterEllipsis"/>
            </StackPanel>
          </Border>

          <Border x:Name="TileP2" Grid.Column="1" CornerRadius="8" BorderThickness="1.2" Padding="7,5" Margin="1.5,0,1.5,0" Cursor="Hand">
            <StackPanel>
              <TextBlock x:Name="TileP2Count" Text="0" FontSize="17" FontWeight="ExtraBold" LineHeight="18"/>
              <TextBlock x:Name="TileP2Label" Text="MERGE HAZIR" FontSize="9" FontWeight="Bold" TextTrimming="CharacterEllipsis"/>
            </StackPanel>
          </Border>

          <Border x:Name="TileP34" Grid.Column="2" CornerRadius="8" BorderThickness="1.2" Padding="7,5" Margin="1.5,0,1.5,0" Cursor="Hand">
            <StackPanel>
              <TextBlock x:Name="TileP34Count" Text="0" FontSize="17" FontWeight="ExtraBold" LineHeight="18"/>
              <TextBlock x:Name="TileP34Label" Text="RADAR/TEMAS" FontSize="9" FontWeight="Bold" TextTrimming="CharacterEllipsis"/>
            </StackPanel>
          </Border>

          <Border x:Name="TileCand" Grid.Column="3" CornerRadius="8" BorderThickness="1.2" Padding="7,5" Margin="3,0,0,0" Cursor="Hand">
            <StackPanel>
              <TextBlock x:Name="TileCandCount" Text="0" FontSize="17" FontWeight="ExtraBold" LineHeight="18"/>
              <TextBlock x:Name="TileCandLabel" Text="ADAY/İZLEME" FontSize="9" FontWeight="Bold" TextTrimming="CharacterEllipsis"/>
            </StackPanel>
          </Border>
        </Grid>

        <!-- Inline Preview & Confirmation Box for Candidate Ownership + clawhandoff Launch -->
        <Border x:Name="HandoffConfirmBorder" Grid.Row="4" CornerRadius="8" BorderThickness="1.4" Padding="9,7" Margin="10,0,10,5" Visibility="Collapsed">
          <StackPanel>
            <TextBlock x:Name="HandoffHeaderTb" FontSize="11.5" FontWeight="Bold" TextTrimming="CharacterEllipsis" Margin="0,0,0,5"/>
            <Grid Margin="0,0,0,5">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <TextBlock x:Name="HandoffAgentLbl" Grid.Column="0" FontSize="10.5" VerticalAlignment="Center" Margin="0,0,6,0"/>
              <Button x:Name="BtnHandoffTarget" Grid.Column="1" Padding="7,3.5" FontSize="10.5" FontWeight="SemiBold" Cursor="Hand" BorderThickness="1" HorizontalContentAlignment="Left"/>
            </Grid>
            <CheckBox x:Name="ChkSendClaim" IsChecked="True" FontSize="10.5" Margin="0,0,0,4"/>
            <Border x:Name="ClaimCommentBorder" CornerRadius="5" BorderThickness="1" Padding="6,4" Margin="0,0,0,6">
              <TextBox x:Name="TxtClaimComment" Background="Transparent" BorderThickness="0" FontSize="11" AcceptsReturn="True" TextWrapping="Wrap" MaxHeight="48"/>
            </Border>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
              <Button x:Name="BtnCancelHandoff" Padding="9,3.5" Margin="0,0,5,0" FontSize="10.5" FontWeight="SemiBold" Cursor="Hand" BorderThickness="1"/>
              <Button x:Name="BtnConfirmHandoff" Padding="10,3.5" FontSize="10.5" FontWeight="Bold" Cursor="Hand" BorderThickness="1"/>
            </StackPanel>
          </StackPanel>
        </Border>

        <!-- PR & Candidate Cards Scroll List -->
        <ScrollViewer x:Name="CardsScroll" Grid.Row="5" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Padding="10,1,10,6">
          <StackPanel x:Name="CardsStack"/>
        </ScrollViewer>

        <!-- Sticky Footer Bar -->
        <Border x:Name="FooterBar" Grid.Row="6" CornerRadius="0,0,13,13" Padding="10,0,10,0">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <Button x:Name="BtnMarkSeen" Grid.Column="0" Content="✓ Okundu İşaretle"
                    Padding="8,3" Margin="0,0,6,0" FontSize="10.5" FontWeight="SemiBold" Cursor="Hand" BorderThickness="1" VerticalAlignment="Center"/>
            <Button x:Name="BtnTheme" Grid.Column="1" Content="Sarı Not"
                    Padding="8,3" FontSize="10.5" FontWeight="SemiBold" Cursor="Hand" BorderThickness="1" VerticalAlignment="Center"/>
            <TextBlock x:Name="FooterStatus" Grid.Column="2" Text="" FontSize="10.5" VerticalAlignment="Center" HorizontalAlignment="Right" Margin="6,0,6,0" TextTrimming="CharacterEllipsis"/>
            <Thumb x:Name="ResizeThumb" Grid.Column="3" Width="14" Height="14" Cursor="SizeNWSE" VerticalAlignment="Bottom" Margin="0,0,-4,3" Opacity="0.5">
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

$OuterCard            = $Window.FindName("OuterCard")
$HeaderBar            = $Window.FindName("HeaderBar")
$HeaderTitle          = $Window.FindName("HeaderTitle")
$HeaderSub            = $Window.FindName("HeaderSub")
$BtnRefresh           = $Window.FindName("BtnRefresh")
$BtnPin               = $Window.FindName("BtnPin")
$BtnClose             = $Window.FindName("BtnClose")
$FocusInputBorder     = $Window.FindName("FocusInputBorder")
$FocusPlaceholder     = $Window.FindName("FocusPlaceholder")
$FocusInputBox        = $Window.FindName("FocusInputBox")
$BtnFocusAgent        = $Window.FindName("BtnFocusAgent")
$BtnFocusRun          = $Window.FindName("BtnFocusRun")
$BriefToggleBorder    = $Window.FindName("BriefToggleBorder")
$BriefToggleText      = $Window.FindName("BriefToggleText")
$BriefToggleChevron   = $Window.FindName("BriefToggleChevron")
$BriefDrawerBorder    = $Window.FindName("BriefDrawerBorder")
$BriefDrawerStack     = $Window.FindName("BriefDrawerStack")
$TileP1               = $Window.FindName("TileP1")
$TileP1Count          = $Window.FindName("TileP1Count")
$TileP1Label          = $Window.FindName("TileP1Label")
$TileP2               = $Window.FindName("TileP2")
$TileP2Count          = $Window.FindName("TileP2Count")
$TileP2Label          = $Window.FindName("TileP2Label")
$TileP34              = $Window.FindName("TileP34")
$TileP34Count         = $Window.FindName("TileP34Count")
$TileP34Label         = $Window.FindName("TileP34Label")
$TileCand             = $Window.FindName("TileCand")
$TileCandCount        = $Window.FindName("TileCandCount")
$TileCandLabel        = $Window.FindName("TileCandLabel")
$HandoffConfirmBorder = $Window.FindName("HandoffConfirmBorder")
$HandoffHeaderTb      = $Window.FindName("HandoffHeaderTb")
$HandoffAgentLbl      = $Window.FindName("HandoffAgentLbl")
$BtnHandoffTarget     = $Window.FindName("BtnHandoffTarget")
$ChkSendClaim         = $Window.FindName("ChkSendClaim")
$ClaimCommentBorder   = $Window.FindName("ClaimCommentBorder")
$TxtClaimComment      = $Window.FindName("TxtClaimComment")
$BtnCancelHandoff     = $Window.FindName("BtnCancelHandoff")
$BtnConfirmHandoff    = $Window.FindName("BtnConfirmHandoff")
$CardsStack           = $Window.FindName("CardsStack")
$FooterBar            = $Window.FindName("FooterBar")
$BtnMarkSeen          = $Window.FindName("BtnMarkSeen")
$BtnTheme             = $Window.FindName("BtnTheme")
$FooterStatus         = $Window.FindName("FooterStatus")
$ResizeThumb          = $Window.FindName("ResizeThumb")

$Prefs = Read-HudPrefs
$script:CurrentTheme = $Prefs.theme
$script:LangPref = $Prefs.lang
$script:AutoRefresh = [bool]$Prefs.autoRefresh
$script:FocusAgentPref = if ($Prefs.focusAgent) { $Prefs.focusAgent } else { "auto" }
$script:ActiveFilter = if ($PreviewFilter) { $PreviewFilter } else { "ALL" }
$script:BriefExpanded = [bool]$PreviewExpandBrief
$script:PendingHandoffCandidate = $null
$script:SelectedHandoffAgentId = ""
$script:CachedData = $null
$script:WatchReport = $null
$script:WatchState = $null
$script:SurfaceBrief = $null
$script:DetectedAgents = $null
$script:ActiveSessions = $null
$script:ConfigObj = $null
$script:SweepJob = $null
$script:FocusJob = $null
$script:HandoffJob = $null
$script:IsRefreshing = $false
$script:IsFocusing = $false
$script:IsLaunchingHandoff = $false
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

function Get-FocusAgentDisplayLabel([string]$AgentKey) {
  switch ($AgentKey) {
    "openclaw" { return "🤖 OpenClaw ▾" }
    "ollama"   { return "🤖 Ollama ▾" }
    "codex"    { return "🤖 Codex ▾" }
    "gemini"   { return "🤖 Gemini ▾" }
    "claude"   { return "🤖 Claude ▾" }
    default    { return $(if ((Get-EffectiveLang) -eq "tr") { "🤖 Oto ▾" } else { "🤖 Auto ▾" }) }
  }
}

function Get-SelectedHandoffAgentObject {
  $agents = @()
  if ($script:DetectedAgents -and $script:DetectedAgents.agents) {
    $agents = @($script:DetectedAgents.agents)
  }
  if ($agents.Count -eq 0) { return $null }
  if ($script:SelectedHandoffAgentId) {
    $found = $agents | Where-Object { $_.id -eq $script:SelectedHandoffAgentId } | Select-Object -First 1
    if ($found) { return $found }
  }
  $readyFirst = $agents | Where-Object { $_.ready } | Select-Object -First 1
  if ($readyFirst) {
    $script:SelectedHandoffAgentId = [string]$readyFirst.id
    return $readyFirst
  }
  $script:SelectedHandoffAgentId = [string]$agents[0].id
  return $agents[0]
}

function Open-HandoffConfirmDialog($Candidate) {
  $L = Get-LangTable
  $script:PendingHandoffCandidate = $Candidate
  $HandoffHeaderTb.Text = ($L.HandoffHeader -f $Candidate.number)
  $defaultClaim = "I'm looking into this and working on a root-cause fix."
  if ($script:ConfigObj -and $script:ConfigObj.handoff -and $script:ConfigObj.handoff.defaultClaimComment) {
    $defaultClaim = [string]$script:ConfigObj.handoff.defaultClaimComment
  }
  $TxtClaimComment.Text = $defaultClaim
  $ChkSendClaim.IsChecked = $true
  $agentObj = Get-SelectedHandoffAgentObject
  $BtnHandoffTarget.Content = if ($agentObj) { "🤖 $($agentObj.label) ▾" } else { "🤖 auto ▾" }
  $HandoffConfirmBorder.Visibility = [System.Windows.Visibility]::Visible
}

function Update-FocusPlaceholderVisibility {
  if ([string]::IsNullOrEmpty($FocusInputBox.Text) -and -not $FocusInputBox.IsKeyboardFocused) {
    $FocusPlaceholder.Visibility = [System.Windows.Visibility]::Visible
  } else {
    $FocusPlaceholder.Visibility = [System.Windows.Visibility]::Collapsed
  }
}

function Populate-BriefDrawer($Pal) {
  $BriefDrawerStack.Children.Clear()
  if (-not $script:SurfaceBrief) {
    $BriefToggleBorder.Visibility = [System.Windows.Visibility]::Collapsed
    $BriefDrawerBorder.Visibility = [System.Windows.Visibility]::Collapsed
    return
  }

  $L = Get-LangTable
  $b = $script:SurfaceBrief
  $openPrCount = if ($b.counts -and $null -ne $b.counts.openPrs) { $b.counts.openPrs } else { 0 }
  $openIssCount = if ($b.counts -and $null -ne $b.counts.openIssues) { $b.counts.openIssues } else { 0 }

  $BriefToggleBorder.Visibility = [System.Windows.Visibility]::Visible
  $BriefToggleBorder.Background = ConvertFrom-BrushHex $Pal.DrawerBg
  $BriefToggleBorder.BorderBrush = ConvertFrom-BrushHex $Pal.DrawerBorder
  $BriefToggleText.Text = ($L.BriefToggleSummary -f $b.title, $openPrCount, $openIssCount)
  $BriefToggleText.Foreground = ConvertFrom-BrushHex $Pal.TitleFg
  $BriefToggleChevron.Text = if ($script:BriefExpanded) { $L.BriefCollapse } else { $L.BriefExpand }
  $BriefToggleChevron.Foreground = ConvertFrom-BrushHex $Pal.TileP34Fg

  if (-not $script:BriefExpanded) {
    $BriefDrawerBorder.Visibility = [System.Windows.Visibility]::Collapsed
    return
  }

  $BriefDrawerBorder.Visibility = [System.Windows.Visibility]::Visible
  $BriefDrawerBorder.Background = ConvertFrom-BrushHex $Pal.DrawerBg
  $BriefDrawerBorder.BorderBrush = ConvertFrom-BrushHex $Pal.DrawerBorder

  # Meta top bar
  $metaGrid = [System.Windows.Controls.Grid]::new()
  $c0 = [System.Windows.Controls.ColumnDefinition]::new()
  $c0.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
  $c1 = [System.Windows.Controls.ColumnDefinition]::new()
  $c1.Width = [System.Windows.GridLength]::Auto
  [void]$metaGrid.ColumnDefinitions.Add($c0)
  [void]$metaGrid.ColumnDefinitions.Add($c1)

  $age = Format-RelativeAge $b.generatedAt
  $metaTb = [System.Windows.Controls.TextBlock]::new()
  $metaTb.Text = "🤖 $($b.generatedBy) · $age"
  $metaTb.FontSize = 9.5
  $metaTb.Foreground = ConvertFrom-BrushHex $Pal.SubFg
  $metaTb.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
  [System.Windows.Controls.Grid]::SetColumn($metaTb, 0)
  [void]$metaGrid.Children.Add($metaTb)

  $clearBtn = [System.Windows.Controls.Button]::new()
  $clearBtn.Content = $L.BriefClear
  $clearBtn.FontSize = 9.5
  $clearBtn.Padding = [System.Windows.Thickness]::new(5, 1, 5, 1)
  $clearBtn.BorderThickness = [System.Windows.Thickness]::new(1)
  $clearBtn.Cursor = [System.Windows.Input.Cursors]::Hand
  Set-StyledButton $clearBtn $Pal.ActionBtnBg $Pal.ActionBtnBorder $Pal.SubFg
  $clearBtn.Add_Click({
    Remove-Item -LiteralPath $SurfaceBriefPath -Force -ErrorAction SilentlyContinue
    $script:SurfaceBrief = $null
    $script:BriefExpanded = $false
    Update-HudView
  })
  [System.Windows.Controls.Grid]::SetColumn($clearBtn, 1)
  [void]$metaGrid.Children.Add($clearBtn)
  [void]$BriefDrawerStack.Children.Add($metaGrid)

  if ($b.watchedPaths -and @($b.watchedPaths).Count -gt 0) {
    $pathsTb = [System.Windows.Controls.TextBlock]::new()
    $pathsTb.Text = ($L.BriefPathsMeta -f ((@($b.watchedPaths) | Select-Object -First 3) -join ", "))
    $pathsTb.FontSize = 9.5
    $pathsTb.Foreground = ConvertFrom-BrushHex $Pal.MutedFg
    $pathsTb.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
    $pathsTb.Margin = [System.Windows.Thickness]::new(0, 2, 0, 4)
    [void]$BriefDrawerStack.Children.Add($pathsTb)
  }

  # 1. Status Commentary
  $sec1 = [System.Windows.Controls.TextBlock]::new()
  $sec1.Text = $L.BriefSecStatus
  $sec1.FontSize = 10.5
  $sec1.FontWeight = [System.Windows.FontWeights]::Bold
  $sec1.Foreground = ConvertFrom-BrushHex $Pal.TileP34Fg
  $sec1.Margin = [System.Windows.Thickness]::new(0, 2, 0, 2)
  [void]$BriefDrawerStack.Children.Add($sec1)

  $commTb = [System.Windows.Controls.TextBlock]::new()
  $commTb.Text = [string]$b.statusCommentary
  $commTb.FontSize = 11
  $commTb.Foreground = ConvertFrom-BrushHex $Pal.TitleFg
  $commTb.TextWrapping = [System.Windows.TextWrapping]::Wrap
  $commTb.Margin = [System.Windows.Thickness]::new(0, 0, 0, 6)
  [void]$BriefDrawerStack.Children.Add($commTb)

  # 2. Contribution Opportunities
  $opps = @($b.contributionOpportunities)
  if ($opps.Count -gt 0) {
    $sec2 = [System.Windows.Controls.TextBlock]::new()
    $sec2.Text = $L.BriefSecOpps
    $sec2.FontSize = 10.5
    $sec2.FontWeight = [System.Windows.FontWeights]::Bold
    $sec2.Foreground = ConvertFrom-BrushHex $Pal.TileP2Fg
    $sec2.Margin = [System.Windows.Thickness]::new(0, 2, 0, 3)
    [void]$BriefDrawerStack.Children.Add($sec2)

    $repoSlug = if ($b.repo) { [string]$b.repo } else { "openclaw/openclaw" }
    foreach ($opp in $opps) {
      $oppRow = [System.Windows.Controls.StackPanel]::new()
      $oppRow.Margin = [System.Windows.Thickness]::new(0, 0, 0, 4)

      $oppTitle = [System.Windows.Controls.TextBlock]::new()
      $refsStr = if ($opp.refs -and @($opp.refs).Count -gt 0) { " ($(@($opp.refs) -join ', '))" } else { "" }
      $oppTitle.Text = "• $($opp.title)$refsStr"
      $oppTitle.FontSize = 10.5
      $oppTitle.FontWeight = [System.Windows.FontWeights]::SemiBold
      $oppTitle.Foreground = ConvertFrom-BrushHex $Pal.TitleFg
      $oppTitle.TextWrapping = [System.Windows.TextWrapping]::Wrap
      if ($opp.refs -and @($opp.refs).Count -gt 0) {
        $firstRefNum = ([string]@($opp.refs)[0]) -replace "[^0-9]", ""
        if ($firstRefNum) {
          $refUrl = "https://github.com/$repoSlug/issues/$firstRefNum"
          $oppTitle.Cursor = [System.Windows.Input.Cursors]::Hand
          $oppTitle.Add_MouseLeftButtonUp({ Start-Process $refUrl }.GetNewClosure())
        }
      }
      [void]$oppRow.Children.Add($oppTitle)

      if ($opp.detail) {
        $oppDet = [System.Windows.Controls.TextBlock]::new()
        $oppDet.Text = "  $($opp.detail)"
        $oppDet.FontSize = 10
        $oppDet.Foreground = ConvertFrom-BrushHex $Pal.SubFg
        $oppDet.TextWrapping = [System.Windows.TextWrapping]::Wrap
        [void]$oppRow.Children.Add($oppDet)
      }
      [void]$BriefDrawerStack.Children.Add($oppRow)
    }
  }

  # 3. Active Developers
  $devs = @($b.activeDevelopers)
  if ($devs.Count -gt 0) {
    $sec3 = [System.Windows.Controls.TextBlock]::new()
    $sec3.Text = $L.BriefSecDevs
    $sec3.FontSize = 10.5
    $sec3.FontWeight = [System.Windows.FontWeights]::Bold
    $sec3.Foreground = ConvertFrom-BrushHex $Pal.TileCandFg
    $sec3.Margin = [System.Windows.Thickness]::new(0, 3, 0, 2)
    [void]$BriefDrawerStack.Children.Add($sec3)

    foreach ($dev in $devs) {
      $devTb = [System.Windows.Controls.TextBlock]::new()
      $statsPart = if ($dev.stats) { " [$($dev.stats)]" } else { "" }
      $rolePart = if ($dev.roleSummary) { " — $($dev.roleSummary)" } else { "" }
      $devTb.Text = "• @$($dev.handle)$statsPart$rolePart"
      $devTb.FontSize = 10
      $devTb.Foreground = ConvertFrom-BrushHex $Pal.SubFg
      $devTb.TextWrapping = [System.Windows.TextWrapping]::Wrap
      $devTb.Margin = [System.Windows.Thickness]::new(0, 0, 0, 2)
      [void]$BriefDrawerStack.Children.Add($devTb)
    }
  }
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
    if ($reasonStr -match "matches focused surface \(([^)]+)\)") {
      $badges.Add(@{ Text = ($L.BadgeWatchFocus -f $Matches[1]); Bg = $Pal.BadgeWatchBg; Border = $Pal.BadgeWatchBorder; Fg = $Pal.BadgeWatchFg })
    } elseif ($reasonStr -match "touches watched path \(([^)]+)\)") {
      $badges.Add(@{ Text = ($L.BadgeWatchPath -f $Matches[1]); Bg = $Pal.BadgeWatchBg; Border = $Pal.BadgeWatchBorder; Fg = $Pal.BadgeWatchFg })
    } else {
      $badges.Add(@{ Text = $L.BadgeWatchArea; Bg = $Pal.BadgeWatchBg; Border = $Pal.BadgeWatchBorder; Fg = $Pal.BadgeWatchFg })
    }
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
  $tb.FontSize = 10
  $tb.FontWeight = [System.Windows.FontWeights]::Bold
  $tb.Margin = [System.Windows.Thickness]::new(2, 6, 2, 3)
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
  if ($isUnchanged) { $card.Opacity = 0.85 }

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
  $bodyStack.Margin = [System.Windows.Thickness]::new(8, 5.5, 8, 5.5)
  [System.Windows.Controls.Grid]::SetColumn($bodyStack, 1)

  $topWrap = [System.Windows.Controls.WrapPanel]::new()
  $topWrap.Orientation = [System.Windows.Controls.Orientation]::Horizontal
  $topWrap.Margin = [System.Windows.Thickness]::new(0, 0, 0, 2)

  $repoPrefix = if ($Item.repo -ne "openclaw/openclaw") { "$($Item.repo.Split('/')[-1])#" } else { "#" }
  $numBadge = New-BadgePill "$repoPrefix$($Item.number)" $Pal.PrNumBg $Pal.PrNumBorder $Pal.PrNumFg $true
  [void]$topWrap.Children.Add($numBadge)

  foreach ($b in $spec.Badges) {
    $pill = New-BadgePill $b.Text $b.Bg $b.Border $b.Fg $true
    [void]$topWrap.Children.Add($pill)
  }
  [void]$bodyStack.Children.Add($topWrap)

  $titleTb = [System.Windows.Controls.TextBlock]::new()
  $titleTb.Text = $Item.untrustedTitle
  $titleTb.Foreground = ConvertFrom-BrushHex $Pal.TitleFg
  $titleTb.FontSize = 11.5
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

  $card.Add_MouseEnter({ $this.Background = $hoverBrush }.GetNewClosure())
  $card.Add_MouseLeave({ $this.Background = $normalBrush }.GetNewClosure())
  $card.Add_MouseLeftButtonUp({
    if ($url -match "^https://github\.com/") { Start-Process $url }
  }.GetNewClosure())
  $card.Add_MouseRightButtonUp({
    [System.Windows.Clipboard]::SetText($copyText)
    $FooterStatus.Text = ((Get-LangTable).FooterCopied -f $itemKey)
  }.GetNewClosure())

  [void]$CardsStack.Children.Add($card)
}

function Add-CandidateCard($Cand, $Pal) {
  $L = Get-LangTable
  $isPriority = [bool]$Cand.priorityFocus
  $accentHex = if ($isPriority) { $Pal.AccentGold } else { $Pal.AccentReady }

  $card = [System.Windows.Controls.Border]::new()
  $card.Background = ConvertFrom-BrushHex $Pal.RowBg
  $card.BorderBrush = ConvertFrom-BrushHex $(if ($isPriority) { $Pal.BadgeGoldBorder } else { $Pal.RowBorder })
  $card.BorderThickness = [System.Windows.Thickness]::new($(if ($isPriority) { 1.4 } else { 1 }))
  $card.CornerRadius = [System.Windows.CornerRadius]::new(8)
  $card.Margin = [System.Windows.Thickness]::new(0, 0, 0, 5)

  $rowGrid = [System.Windows.Controls.Grid]::new()
  $colAccent = [System.Windows.Controls.ColumnDefinition]::new()
  $colAccent.Width = [System.Windows.GridLength]::new(4.5)
  $colBody = [System.Windows.Controls.ColumnDefinition]::new()
  $colBody.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
  [void]$rowGrid.ColumnDefinitions.Add($colAccent)
  [void]$rowGrid.ColumnDefinitions.Add($colBody)

  $stripe = [System.Windows.Controls.Border]::new()
  $stripe.Background = ConvertFrom-BrushHex $accentHex
  $stripe.CornerRadius = [System.Windows.CornerRadius]::new(7, 0, 0, 7)
  [System.Windows.Controls.Grid]::SetColumn($stripe, 0)
  [void]$rowGrid.Children.Add($stripe)

  $bodyStack = [System.Windows.Controls.StackPanel]::new()
  $bodyStack.Margin = [System.Windows.Thickness]::new(8, 6, 8, 6)
  [System.Windows.Controls.Grid]::SetColumn($bodyStack, 1)

  $topWrap = [System.Windows.Controls.WrapPanel]::new()
  $topWrap.Orientation = [System.Windows.Controls.Orientation]::Horizontal
  $topWrap.Margin = [System.Windows.Thickness]::new(0, 0, 0, 2)

  [void]$topWrap.Children.Add((New-BadgePill "#$($Cand.number)" $Pal.PrNumBg $Pal.PrNumBorder $Pal.PrNumFg $true))
  if ($isPriority) {
    [void]$topWrap.Children.Add((New-BadgePill $L.BadgePriorityArea $Pal.BadgeGoldBg $Pal.BadgeGoldBorder $Pal.BadgeGoldFg $true))
  }
  if ($Cand.priority) {
    [void]$topWrap.Children.Add((New-BadgePill ([string]$Cand.priority) $Pal.BadgeFailBg $Pal.BadgeFailBorder $Pal.BadgeFailFg $true))
  }
  foreach ($imp in @($Cand.impactLabels | Select-Object -First 2)) {
    [void]$topWrap.Children.Add((New-BadgePill ([string]$imp) $Pal.BadgeWatchBg $Pal.BadgeWatchBorder $Pal.BadgeWatchFg $false))
  }
  if ($Cand.issueRating) {
    $shortRating = ([string]$Cand.issueRating) -replace "^issue-rating:\s*", ""
    [void]$topWrap.Children.Add((New-BadgePill $shortRating $Pal.BadgeReadyBg $Pal.BadgeReadyBorder $Pal.BadgeReadyFg $false))
  }
  [void]$bodyStack.Children.Add($topWrap)

  $url = [string]$Cand.url
  $titleTb = [System.Windows.Controls.TextBlock]::new()
  $titleTb.Text = [string]$Cand.untrustedTitle
  $titleTb.Foreground = ConvertFrom-BrushHex $Pal.TitleFg
  $titleTb.FontSize = 11.5
  $titleTb.FontWeight = [System.Windows.FontWeights]::SemiBold
  $titleTb.TextWrapping = [System.Windows.TextWrapping]::Wrap
  $titleTb.Cursor = [System.Windows.Input.Cursors]::Hand
  $titleTb.Add_MouseLeftButtonUp({
    if ($url -match "^https://github\.com/") { Start-Process $url }
  }.GetNewClosure())
  [void]$bodyStack.Children.Add($titleTb)

  $paths = @($Cand.extractedPaths)
  if ($paths.Count -gt 0) {
    $pathTb = [System.Windows.Controls.TextBlock]::new()
    $pathTb.Text = "📄 " + (($paths | Select-Object -First 2) -join ", ")
    $pathTb.FontSize = 9.5
    $pathTb.Foreground = ConvertFrom-BrushHex $Pal.SubFg
    $pathTb.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
    $pathTb.Margin = [System.Windows.Thickness]::new(0, 2, 0, 0)
    [void]$bodyStack.Children.Add($pathTb)
  }

  # Action buttons row
  $btnRow = [System.Windows.Controls.StackPanel]::new()
  $btnRow.Orientation = [System.Windows.Controls.Orientation]::Horizontal
  $btnRow.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
  $btnRow.Margin = [System.Windows.Thickness]::new(0, 5, 0, 0)

  $candRef = $Cand
  $claimBtn = [System.Windows.Controls.Button]::new()
  $claimBtn.Content = $L.BtnStartHandoff
  $claimBtn.FontSize = 10
  $claimBtn.FontWeight = [System.Windows.FontWeights]::Bold
  $claimBtn.Padding = [System.Windows.Thickness]::new(8, 2.5, 8, 2.5)
  $claimBtn.Margin = [System.Windows.Thickness]::new(0, 0, 4, 0)
  $claimBtn.BorderThickness = [System.Windows.Thickness]::new(1)
  $claimBtn.Cursor = [System.Windows.Input.Cursors]::Hand
  Set-StyledButton $claimBtn $Pal.PrimaryBtnBg $Pal.PrimaryBtnBorder $Pal.PrimaryBtnFg
  $claimBtn.Add_Click({
    Open-HandoffConfirmDialog $candRef
    Update-HudView
  }.GetNewClosure())
  [void]$btnRow.Children.Add($claimBtn)

  $candNum = [int]$Cand.number
  $dismissBtn = [System.Windows.Controls.Button]::new()
  $dismissBtn.Content = $L.BtnDismissCand
  $dismissBtn.FontSize = 10
  $dismissBtn.Padding = [System.Windows.Thickness]::new(6, 2.5, 6, 2.5)
  $dismissBtn.BorderThickness = [System.Windows.Thickness]::new(1)
  $dismissBtn.Cursor = [System.Windows.Input.Cursors]::Hand
  Set-StyledButton $dismissBtn $Pal.ActionBtnBg $Pal.ActionBtnBorder $Pal.SubFg
  $dismissBtn.Add_Click({
    & node $WatchScript --mode dismiss-candidate --dismiss-candidate "$candNum" 2>$null | Out-Null
    Reload-LocalAuxState
    if ($script:WatchReport -and $script:WatchReport.activeCandidates) {
      $script:WatchReport.activeCandidates = @($script:WatchReport.activeCandidates | Where-Object { [int]$_.number -ne $candNum })
    }
    Update-HudView
  }.GetNewClosure())
  [void]$btnRow.Children.Add($dismissBtn)

  [void]$bodyStack.Children.Add($btnRow)
  [void]$rowGrid.Children.Add($bodyStack)
  $card.Child = $rowGrid
  [void]$CardsStack.Children.Add($card)
}

function Add-WatchDeltaCard($Ev, $Pal) {
  $card = [System.Windows.Controls.Border]::new()
  $card.Background = ConvertFrom-BrushHex $Pal.RowBg
  $card.BorderBrush = ConvertFrom-BrushHex $Pal.BadgeNewBorder
  $card.BorderThickness = [System.Windows.Thickness]::new(1)
  $card.CornerRadius = [System.Windows.CornerRadius]::new(8)
  $card.Margin = [System.Windows.Thickness]::new(0, 0, 0, 5)
  $card.Padding = [System.Windows.Thickness]::new(9, 6, 9, 6)
  $card.Cursor = [System.Windows.Input.Cursors]::Hand

  $stack = [System.Windows.Controls.StackPanel]::new()
  $kindLabel = if ($Ev.kind -eq "pr") { "PR #$($Ev.number)" } else { "ISSUE #$($Ev.number)" }

  $topWrap = [System.Windows.Controls.WrapPanel]::new()
  [void]$topWrap.Children.Add((New-BadgePill $kindLabel $Pal.BadgeNewBg $Pal.BadgeNewBorder $Pal.BadgeNewFg $true))
  if ($Ev.state) {
    [void]$topWrap.Children.Add((New-BadgePill ([string]$Ev.state) $Pal.PrNumBg $Pal.PrNumBorder $Pal.PrNumFg $true))
  }
  [void]$stack.Children.Add($topWrap)

  $titleTb = [System.Windows.Controls.TextBlock]::new()
  $titleTb.Text = [string]$Ev.title
  $titleTb.FontSize = 11
  $titleTb.FontWeight = [System.Windows.FontWeights]::SemiBold
  $titleTb.Foreground = ConvertFrom-BrushHex $Pal.TitleFg
  $titleTb.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
  [void]$stack.Children.Add($titleTb)

  foreach ($chg in @($Ev.changes)) {
    $chgTb = [System.Windows.Controls.TextBlock]::new()
    $chgTb.Text = "↳ $chg"
    $chgTb.FontSize = 10
    $chgTb.Foreground = ConvertFrom-BrushHex $Pal.TileCandFg
    $chgTb.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $chgTb.Margin = [System.Windows.Thickness]::new(0, 2, 0, 0)
    [void]$stack.Children.Add($chgTb)
  }

  $url = [string]$Ev.url
  $card.Add_MouseLeftButtonUp({
    if ($url -match "^https://github\.com/") { Start-Process $url }
  }.GetNewClosure())

  $card.Child = $stack
  [void]$CardsStack.Children.Add($card)
}

function Add-ActiveSessionCard($Sess, $Pal) {
  $L = Get-LangTable
  $card = [System.Windows.Controls.Border]::new()
  $card.Background = ConvertFrom-BrushHex $Pal.DrawerBg
  $card.BorderBrush = ConvertFrom-BrushHex $Pal.DrawerBorder
  $card.BorderThickness = [System.Windows.Thickness]::new(1)
  $card.CornerRadius = [System.Windows.CornerRadius]::new(8)
  $card.Margin = [System.Windows.Thickness]::new(0, 0, 0, 5)
  $card.Padding = [System.Windows.Thickness]::new(8, 5, 8, 5)

  $grid = [System.Windows.Controls.Grid]::new()
  $c0 = [System.Windows.Controls.ColumnDefinition]::new()
  $c0.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
  $c1 = [System.Windows.Controls.ColumnDefinition]::new()
  $c1.Width = [System.Windows.GridLength]::Auto
  [void]$grid.ColumnDefinitions.Add($c0)
  [void]$grid.ColumnDefinitions.Add($c1)

  $stStack = [System.Windows.Controls.StackPanel]::new()
  $phaseText = ([string]$Sess.phase).ToUpperInvariant()
  $topLine = [System.Windows.Controls.TextBlock]::new()
  $topLine.Text = "#$($Sess.issueNumber) · $($Sess.targetLabel) · [$phaseText]"
  $topLine.FontSize = 10.5
  $topLine.FontWeight = [System.Windows.FontWeights]::Bold
  $topLine.Foreground = ConvertFrom-BrushHex $Pal.TileP2Fg
  $topLine.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
  [void]$stStack.Children.Add($topLine)

  if ($Sess.summary -or $Sess.directiveReason) {
    $subLine = [System.Windows.Controls.TextBlock]::new()
    $subLine.Text = if ($Sess.summary) { [string]$Sess.summary } else { [string]$Sess.directiveReason }
    $subLine.FontSize = 9.5
    $subLine.Foreground = ConvertFrom-BrushHex $Pal.SubFg
    $subLine.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
    [void]$stStack.Children.Add($subLine)
  }
  [System.Windows.Controls.Grid]::SetColumn($stStack, 0)
  [void]$grid.Children.Add($stStack)

  if ($Sess.worktreePath) {
    $wtPath = [string]$Sess.worktreePath
    $wtBtn = [System.Windows.Controls.Button]::new()
    $wtBtn.Content = $L.BtnOpenWorktree
    $wtBtn.FontSize = 9.5
    $wtBtn.Padding = [System.Windows.Thickness]::new(6, 2, 6, 2)
    $wtBtn.BorderThickness = [System.Windows.Thickness]::new(1)
    $wtBtn.Cursor = [System.Windows.Input.Cursors]::Hand
    Set-StyledButton $wtBtn $Pal.ActionBtnBg $Pal.ActionBtnBorder $Pal.ActionBtnFg
    $wtBtn.Add_Click({
      if ($wtPath.StartsWith("/")) {
        Start-Process "explorer.exe" -ArgumentList ("\\wsl$\Ubuntu" + ($wtPath -replace "/", "\"))
      } elseif (Test-Path -LiteralPath $wtPath) {
        Start-Process "explorer.exe" -ArgumentList $wtPath
      }
    }.GetNewClosure())
    [System.Windows.Controls.Grid]::SetColumn($wtBtn, 1)
    [void]$grid.Children.Add($wtBtn)
  }

  $card.Child = $grid
  [void]$CardsStack.Children.Add($card)
}

function Add-TrackedSummarySection($Pal) {
  $L = Get-LangTable
  $trackedItems = @()
  if ($script:WatchState -and $script:WatchState.tracked) {
    $trackedItems = @($script:WatchState.tracked)
  }
  Add-SectionHeader ($L.SecTracked -f $trackedItems.Count) $Pal.SectionFg

  # Quick add tracked bar
  $addGrid = [System.Windows.Controls.Grid]::new()
  $addGrid.Margin = [System.Windows.Thickness]::new(0, 0, 0, 5)
  $ac0 = [System.Windows.Controls.ColumnDefinition]::new()
  $ac0.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
  $ac1 = [System.Windows.Controls.ColumnDefinition]::new()
  $ac1.Width = [System.Windows.GridLength]::Auto
  [void]$addGrid.ColumnDefinitions.Add($ac0)
  [void]$addGrid.ColumnDefinitions.Add($ac1)

  $inpBorder = [System.Windows.Controls.Border]::new()
  $inpBorder.Background = ConvertFrom-BrushHex $Pal.InputBg
  $inpBorder.BorderBrush = ConvertFrom-BrushHex $Pal.InputBorder
  $inpBorder.BorderThickness = [System.Windows.Thickness]::new(1)
  $inpBorder.CornerRadius = [System.Windows.CornerRadius]::new(6)
  $inpBorder.Padding = [System.Windows.Thickness]::new(6, 2.5, 6, 2.5)
  $inpBorder.Margin = [System.Windows.Thickness]::new(0, 0, 4, 0)

  $trackTb = [System.Windows.Controls.TextBox]::new()
  $trackTb.Background = [System.Windows.Media.Brushes]::Transparent
  $trackTb.BorderThickness = [System.Windows.Thickness]::new(0)
  $trackTb.Foreground = ConvertFrom-BrushHex $Pal.TitleFg
  $trackTb.CaretBrush = ConvertFrom-BrushHex $Pal.TitleFg
  $trackTb.FontSize = 10.5
  $trackTb.ToolTip = $L.TrackPlaceholder
  $inpBorder.Child = $trackTb
  [System.Windows.Controls.Grid]::SetColumn($inpBorder, 0)
  [void]$addGrid.Children.Add($inpBorder)

  $addBtn = [System.Windows.Controls.Button]::new()
  $addBtn.Content = $L.BtnAddTrack
  $addBtn.FontSize = 10
  $addBtn.FontWeight = [System.Windows.FontWeights]::SemiBold
  $addBtn.Padding = [System.Windows.Thickness]::new(8, 3, 8, 3)
  $addBtn.BorderThickness = [System.Windows.Thickness]::new(1)
  $addBtn.Cursor = [System.Windows.Input.Cursors]::Hand
  Set-StyledButton $addBtn $Pal.ActionBtnBg $Pal.ActionBtnBorder $Pal.ActionBtnFg
  $addBtn.Add_Click({
    $rawSpec = $trackTb.Text.Trim()
    if ($rawSpec -match "^(pr|issue):(\d+)$") {
      & node $WatchScript --mode track --track $rawSpec 2>$null | Out-Null
      Reload-LocalAuxState
      Update-HudView
    }
  }.GetNewClosure())
  [System.Windows.Controls.Grid]::SetColumn($addBtn, 1)
  [void]$addGrid.Children.Add($addBtn)
  [void]$CardsStack.Children.Add($addGrid)

  foreach ($trItem in $trackedItems) {
    $row = [System.Windows.Controls.Border]::new()
    $row.Background = ConvertFrom-BrushHex $Pal.RowDimBg
    $row.BorderBrush = ConvertFrom-BrushHex $Pal.RowBorder
    $row.BorderThickness = [System.Windows.Thickness]::new(1)
    $row.CornerRadius = [System.Windows.CornerRadius]::new(7)
    $row.Padding = [System.Windows.Thickness]::new(8, 4.5, 8, 4.5)
    $row.Margin = [System.Windows.Thickness]::new(0, 0, 0, 4)

    $rg = [System.Windows.Controls.Grid]::new()
    $rc0 = [System.Windows.Controls.ColumnDefinition]::new()
    $rc0.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
    $rc1 = [System.Windows.Controls.ColumnDefinition]::new()
    $rc1.Width = [System.Windows.GridLength]::Auto
    [void]$rg.ColumnDefinitions.Add($rc0)
    [void]$rg.ColumnDefinitions.Add($rc1)

    $kindTag = ([string]$trItem.kind).ToUpperInvariant()
    $titlePart = if ($trItem.title) { " — $($trItem.title)" } else { "" }
    $trText = [System.Windows.Controls.TextBlock]::new()
    $trText.Text = "$kindTag #$($trItem.number)$titlePart"
    $trText.FontSize = 10.5
    $trText.Foreground = ConvertFrom-BrushHex $Pal.TitleFg
    $trText.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
    $trText.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    $trUrl = [string]$trItem.url
    if ($trUrl -match "^https://github\.com/") {
      $trText.Cursor = [System.Windows.Input.Cursors]::Hand
      $trText.Add_MouseLeftButtonUp({ Start-Process $trUrl }.GetNewClosure())
    }
    [System.Windows.Controls.Grid]::SetColumn($trText, 0)
    [void]$rg.Children.Add($trText)

    $specStr = "$($trItem.kind):$($trItem.number)"
    $unBtn = [System.Windows.Controls.Button]::new()
    $unBtn.Content = $L.BtnUntrack
    $unBtn.FontSize = 9.5
    $unBtn.Padding = [System.Windows.Thickness]::new(5, 1.5, 5, 1.5)
    $unBtn.Margin = [System.Windows.Thickness]::new(6, 0, 0, 0)
    $unBtn.BorderThickness = [System.Windows.Thickness]::new(1)
    $unBtn.Cursor = [System.Windows.Input.Cursors]::Hand
    Set-StyledButton $unBtn $Pal.ActionBtnBg $Pal.ActionBtnBorder $Pal.SubFg
    $unBtn.Add_Click({
      & node $WatchScript --mode untrack --untrack $specStr 2>$null | Out-Null
      Reload-LocalAuxState
      Update-HudView
    }.GetNewClosure())
    [System.Windows.Controls.Grid]::SetColumn($unBtn, 1)
    [void]$rg.Children.Add($unBtn)

    $row.Child = $rg
    [void]$CardsStack.Children.Add($row)
  }
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

  # Focus Bar styling
  $FocusInputBorder.Background = ConvertFrom-BrushHex $Pal.InputBg
  $FocusInputBorder.BorderBrush = ConvertFrom-BrushHex $Pal.InputBorder
  $FocusInputBox.Foreground = ConvertFrom-BrushHex $Pal.TitleFg
  $FocusInputBox.CaretBrush = ConvertFrom-BrushHex $Pal.TitleFg
  $FocusPlaceholder.Text = $L.FocusPlaceholder
  $FocusPlaceholder.Foreground = ConvertFrom-BrushHex $Pal.MutedFg
  Update-FocusPlaceholderVisibility

  $BtnFocusAgent.Content = Get-FocusAgentDisplayLabel $script:FocusAgentPref
  $BtnFocusAgent.ToolTip = $L.FocusAgentTip
  Set-StyledButton $BtnFocusAgent $Pal.ActionBtnBg $Pal.ActionBtnBorder $Pal.ActionBtnFg

  $BtnFocusRun.Content = if ($script:IsFocusing) { $L.BtnFocusRunning } else { $L.BtnFocusRun }
  $BtnFocusRun.ToolTip = $L.BtnFocusTip
  $BtnFocusRun.IsEnabled = (-not $script:IsFocusing)
  Set-StyledButton $BtnFocusRun $Pal.TileP34Bg $Pal.TileP34Border $Pal.TileP34Fg

  Populate-BriefDrawer $Pal

  # Handoff Confirmation Dialog styling
  if ($null -ne $script:PendingHandoffCandidate) {
    $HandoffConfirmBorder.Visibility = [System.Windows.Visibility]::Visible
    $HandoffConfirmBorder.Background = ConvertFrom-BrushHex $Pal.DrawerBg
    $HandoffConfirmBorder.BorderBrush = ConvertFrom-BrushHex $Pal.BadgeGoldBorder
    $HandoffHeaderTb.Foreground = ConvertFrom-BrushHex $Pal.TileCandFg
    $HandoffAgentLbl.Text = $L.HandoffAgentLabel
    $HandoffAgentLbl.Foreground = ConvertFrom-BrushHex $Pal.SubFg
    Set-StyledButton $BtnHandoffTarget $Pal.InputBg $Pal.InputBorder $Pal.TitleFg
    $ChkSendClaim.Content = $L.HandoffClaimCheck
    $ChkSendClaim.Foreground = ConvertFrom-BrushHex $Pal.TitleFg
    $ClaimCommentBorder.Background = ConvertFrom-BrushHex $Pal.InputBg
    $ClaimCommentBorder.BorderBrush = ConvertFrom-BrushHex $Pal.InputBorder
    $ClaimCommentBorder.Opacity = if ($ChkSendClaim.IsChecked) { 1.0 } else { 0.45 }
    $TxtClaimComment.IsEnabled = [bool]$ChkSendClaim.IsChecked
    $TxtClaimComment.Foreground = ConvertFrom-BrushHex $Pal.TitleFg
    $TxtClaimComment.CaretBrush = ConvertFrom-BrushHex $Pal.TitleFg
    $BtnCancelHandoff.Content = $L.HandoffCancelBtn
    $BtnCancelHandoff.IsEnabled = (-not $script:IsLaunchingHandoff)
    Set-StyledButton $BtnCancelHandoff $Pal.ActionBtnBg $Pal.ActionBtnBorder $Pal.ActionBtnFg
    $BtnConfirmHandoff.Content = if ($script:IsLaunchingHandoff) { $L.HandoffLaunchingBtn } else { $L.HandoffConfirmBtn }
    $BtnConfirmHandoff.IsEnabled = (-not $script:IsLaunchingHandoff)
    Set-StyledButton $BtnConfirmHandoff $Pal.PrimaryBtnBg $Pal.PrimaryBtnBorder $Pal.PrimaryBtnFg
  } else {
    $HandoffConfirmBorder.Visibility = [System.Windows.Visibility]::Collapsed
  }

  $BtnRefresh.Content = if ($script:IsRefreshing) { $L.BtnRefreshing } else { $L.BtnRefresh }
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

  $activeCandidates = @()
  if ($script:WatchReport -and $script:WatchReport.activeCandidates) {
    $activeCandidates = @($script:WatchReport.activeCandidates)
  } elseif ($script:WatchState -and $script:WatchState.activeCandidates) {
    $activeCandidates = @($script:WatchState.activeCandidates)
  }
  $deltaEvents = @()
  if ($script:WatchReport -and $script:WatchReport.deltaEvents) {
    $deltaEvents = @($script:WatchReport.deltaEvents)
  }

  $TileCand.Background = ConvertFrom-BrushHex $Pal.TileCandBg
  $TileCand.BorderBrush = ConvertFrom-BrushHex $(if ($script:ActiveFilter -eq "CAND") { $Pal.TitleFg } else { $Pal.TileCandBorder })
  $TileCand.BorderThickness = [System.Windows.Thickness]::new($(if ($script:ActiveFilter -eq "CAND") { 2.2 } else { 1.2 }))
  $TileCandCount.Text = "$($activeCandidates.Count)"
  $TileCandCount.Foreground = ConvertFrom-BrushHex $Pal.TileCandFg
  $TileCandLabel.Text = if ($deltaEvents.Count -gt 0) { ($L.TileCandDelta -f $deltaEvents.Count) } else { $L.TileCand }
  $TileCandLabel.Foreground = ConvertFrom-BrushHex $Pal.TileCandFg

  if (-not $script:CachedData -or -not $script:CachedData.Score) {
    if ($script:ActiveFilter -eq "CAND") {
      foreach ($cand in $activeCandidates) { Add-CandidateCard $cand $Pal }
    } else {
      $emptyTb = [System.Windows.Controls.TextBlock]::new()
      $emptyTb.Text = $L.EmptyState
      $emptyTb.Foreground = ConvertFrom-BrushHex $Pal.SubFg
      $emptyTb.TextWrapping = [System.Windows.TextWrapping]::Wrap
      $emptyTb.Margin = [System.Windows.Thickness]::new(8, 20, 8, 20)
      [void]$CardsStack.Children.Add($emptyTb)
    }
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

  if ($script:ActiveFilter -eq "CAND") {
    $sessionsList = if ($script:ActiveSessions) { @($script:ActiveSessions) } else { @() }
    if ($sessionsList.Count -gt 0) {
      Add-SectionHeader ($L.SecActiveHandoffs -f $sessionsList.Count) $Pal.TileP2Fg
      foreach ($s in ($sessionsList | Select-Object -First 4)) { Add-ActiveSessionCard $s $Pal }
    }

    Add-SectionHeader ($L.SecWatchDeltas -f $deltaEvents.Count) $Pal.BadgeNewFg
    if ($deltaEvents.Count -eq 0) {
      $quietTb = [System.Windows.Controls.TextBlock]::new()
      $quietTb.Text = $L.NoWatchChanges
      $quietTb.FontSize = 11
      $quietTb.Foreground = ConvertFrom-BrushHex $Pal.SubFg
      $quietTb.Margin = [System.Windows.Thickness]::new(4, 0, 4, 6)
      [void]$CardsStack.Children.Add($quietTb)
    } else {
      foreach ($ev in $deltaEvents) { Add-WatchDeltaCard $ev $Pal }
    }

    Add-SectionHeader ($L.SecCandidates -f $activeCandidates.Count) $Pal.TileCandFg
    if ($activeCandidates.Count -eq 0) {
      $noCandTb = [System.Windows.Controls.TextBlock]::new()
      $noCandTb.Text = $L.NoCandidatesYet
      $noCandTb.FontSize = 11
      $noCandTb.Foreground = ConvertFrom-BrushHex $Pal.SubFg
      $noCandTb.Margin = [System.Windows.Thickness]::new(4, 0, 4, 6)
      [void]$CardsStack.Children.Add($noCandTb)
    } else {
      foreach ($cand in $activeCandidates) { Add-CandidateCard $cand $Pal }
    }

    Add-TrackedSummarySection $Pal
  } else {
    if ($script:ActiveFilter -in @("ALL", "P1") -and $p1Active.Count -gt 0) {
      Add-SectionHeader ($L.SecP1 -f $p1Active.Count) $Pal.TileP1Fg
      foreach ($item in $p1Active) { Add-PrCard $item $Pal }
    }

    if ($script:ActiveFilter -in @("ALL", "P2") -and $p2List.Count -gt 0) {
      Add-SectionHeader ($L.SecP2 -f $p2List.Count) $Pal.TileP2Fg
      foreach ($item in $p2List) { Add-PrCard $item $Pal }
    }

    $priorityCands = @($activeCandidates | Where-Object { $_.priorityFocus })
    if ($script:ActiveFilter -eq "ALL" -and $priorityCands.Count -gt 0) {
      Add-SectionHeader ($L.SecPriorityCand -f $priorityCands.Count) $Pal.TileCandFg
      foreach ($cand in $priorityCands) { Add-CandidateCard $cand $Pal }
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
  }

  if (-not $script:IsRefreshing -and -not $script:IsFocusing -and -not $script:IsLaunchingHandoff) {
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

  $candCount = if ($script:WatchReport -and $script:WatchReport.activeCandidates) { @($script:WatchReport.activeCandidates).Count } else { 0 }

  if ($script:CachedData -and $script:CachedData.Score) {
    $sc = $script:CachedData.Score
    $p1All = @($sc.tiers.P1)
    $p1ActiveCount = @($p1All | Where-Object { -not $_.isDraft }).Count
    $p2Count = @($sc.tiers.P2).Count
    if ($p1ActiveCount -gt 0) {
      $dotHex = "#FF4D6D"
    } elseif ($p2Count -gt 0) {
      $dotHex = "#10E88A"
    } elseif ($candCount -gt 0) {
      $dotHex = "#F59E0B"
    }
    $tipText = ($L.TrayTipSummary -f $p1ActiveCount, $p2Count, $candCount, $script:HotKeyLabel)
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
  foreach ($j in @($script:SweepJob, $script:FocusJob, $script:HandoffJob)) {
    if ($j) { Remove-Job -Job $j -Force -ErrorAction SilentlyContinue }
  }
  $script:SweepJob = $null
  $script:FocusJob = $null
  $script:HandoffJob = $null
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
  $effLang = Get-EffectiveLang
  $script:IsRefreshing = $true
  $script:LastAutoSweepUtc = [datetime]::UtcNow
  $BtnRefresh.Content = $L.BtnRefreshing
  $BtnRefresh.IsEnabled = $false
  $FooterStatus.Text = $L.FooterScanning

  $script:SweepJob = Start-Job -ScriptBlock {
    param($StateDirInner, $ConfigPathInner, $CursorsPathInner, $EngineScriptInner, $ResolveMergeScriptInner, $WatchScriptInner, $HandoffScriptInner, $EffLangInner)
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
      $focusRel         = "state/$slug-focus.json"
      $mergeabilityRel  = "state/$slug-mergeability.json"

      $aOut = & gh pr list --repo $repo --author $cfg.viewerHandle --state open --limit 20 --json "number,title,url,isDraft,author,headRefName,headRefOid,mergeable,mergeStateStatus,reviewDecision,labels,statusCheckRollup,updatedAt,createdAt"
      Set-Content -Path (Join-Path $rootDir $authoredRel) -Value ($aOut -join "`n") -Encoding utf8

      $coOut = & gh pr list --repo $repo --search "$($cfg.viewerHandle) -author:$($cfg.viewerHandle)" --state open --limit 20 --json "number,title,url,isDraft,author,headRefName,headRefOid,mergeable,mergeStateStatus,reviewDecision,labels,commits,statusCheckRollup,updatedAt,createdAt"
      Set-Content -Path (Join-Path $rootDir $coauthoredRel) -Value ($coOut -join "`n") -Encoding utf8

      $rOut = & gh pr list --repo $repo --search "review-requested:$($cfg.viewerHandle)" --state open --limit 20 --json "number,title,url,isDraft,author,headRefName,headRefOid,mergeable,mergeStateStatus,reviewDecision,reviewRequests,labels,statusCheckRollup,updatedAt,createdAt"
      Set-Content -Path (Join-Path $rootDir $reviewsRel) -Value ($rOut -join "`n") -Encoding utf8

      $cOut = & gh pr list --repo $repo --state open --limit 25 --json "number,title,url,isDraft,author,headRefName,headRefOid,labels,files,updatedAt,createdAt"
      Set-Content -Path (Join-Path $rootDir $recentRel) -Value ($cOut -join "`n") -Encoding utf8

      if ($cfg.focusTopic -and $repo -eq $cfg.repositories[0]) {
        try {
          $fOut = & gh search prs --repo $repo --state open "$($cfg.focusTopic)" --limit 20 --json "number,title,url,isDraft,author,labels,updatedAt,createdAt"
          Set-Content -Path (Join-Path $rootDir $focusRel) -Value ($fOut -join "`n") -Encoding utf8
        } catch {}
      }

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
      if (Test-Path -LiteralPath (Join-Path $rootDir $focusRel)) {
        $sliceArgs += @("--slice", "$repo=$focusRel")
      }
    }

    Push-Location $rootDir
    try {
      & node $EngineScriptInner --mode score @sliceArgs --save-sweep --input "state/latest-sweep.json" --config "state/config.json" --cursors "state/cursors.json" --json | Out-Null
      if (Test-Path -LiteralPath $WatchScriptInner) {
        & node $WatchScriptInner --mode sweep --lang $EffLangInner --json | Out-Null
      }
      if ((Test-Path -LiteralPath $HandoffScriptInner) -and -not (Test-Path -LiteralPath (Join-Path $StateDirInner "detected-agents.json"))) {
        & node $HandoffScriptInner --mode detect-agents | Out-Null
      }
    } finally {
      Pop-Location
    }
    return "OK"
  } -ArgumentList $StateDir, $ConfigPath, $CursorsPath, $EngineScript, $ResolveMergeScript, $WatchScript, $HandoffScript, $effLang
}

function Start-FocusAnalysis {
  if ($script:IsFocusing) { return }
  $topic = $FocusInputBox.Text.Trim()
  if (-not $topic) { return }
  if (-not (Test-Path -LiteralPath $FocusRunnerScript)) { return }

  $L = Get-LangTable
  $effLang = Get-EffectiveLang
  $script:IsFocusing = $true
  $FooterStatus.Text = ($L.FooterFocusing -f $topic)
  Update-HudView

  $script:FocusJob = Start-Job -ScriptBlock {
    param($RootDirInner, $FocusRunnerInner, $EngineScriptInner, $TopicInner, $AgentInner, $LangInner)
    $ErrorActionPreference = "Stop"
    $env:OPENCLAW_RADAR_WORKSPACE = $RootDirInner
    Push-Location $RootDirInner
    try {
      & node $FocusRunnerInner --topic $TopicInner --agent $AgentInner --lang $LangInner --json | Out-Null
      $cfg = Get-Content (Join-Path $RootDirInner "state\config.json") -Raw -Encoding utf8 | ConvertFrom-Json
      $sliceArgs = @()
      foreach ($repo in $cfg.repositories) {
        $slug = $repo -replace "/", "__"
        foreach ($suffix in @("authored", "coauthored", "reviews", "recent", "mergeability", "focus")) {
          $rel = "state/$slug-$suffix.json"
          if (Test-Path -LiteralPath (Join-Path $RootDirInner $rel)) {
            $sliceArgs += @("--slice", "$repo=$rel")
          }
        }
      }
      if ($sliceArgs.Count -gt 0) {
        & node $EngineScriptInner --mode score @sliceArgs --save-sweep --input "state/latest-sweep.json" --config "state/config.json" --cursors "state/cursors.json" --json | Out-Null
      }
    } finally {
      Pop-Location
    }
    return "OK"
  } -ArgumentList $HudRoot, $FocusRunnerScript, $EngineScript, $topic, $script:FocusAgentPref, $effLang
}

function Start-CandidateHandoffLaunch {
  if ($script:IsLaunchingHandoff -or $null -eq $script:PendingHandoffCandidate) { return }
  if (-not (Test-Path -LiteralPath $HandoffScript)) { return }

  $cand = $script:PendingHandoffCandidate
  $agentObj = Get-SelectedHandoffAgentObject
  $agentId = if ($agentObj) { [string]$agentObj.id } else { "" }
  $sendClaim = [bool]$ChkSendClaim.IsChecked
  $claimBody = $TxtClaimComment.Text.Trim()

  $claimFile = ""
  if ($sendClaim -and $claimBody.Length -gt 0) {
    $handoffsDir = Join-Path $StateDir "handoffs"
    if (-not (Test-Path $handoffsDir)) { New-Item -ItemType Directory -Path $handoffsDir -Force | Out-Null }
    $claimFile = Join-Path $handoffsDir "claim-comment-$($cand.number).txt"
    Set-Content -LiteralPath $claimFile -Value $claimBody -Encoding utf8 -NoNewline
  }

  $script:IsLaunchingHandoff = $true
  Update-HudView

  $script:HandoffJob = Start-Job -ScriptBlock {
    param($RootDirInner, $HandoffScriptInner, $RepoInner, $IssueNumInner, $AgentIdInner, $ClaimFileInner, $SendClaimInner)
    $env:OPENCLAW_RADAR_WORKSPACE = $RootDirInner
    $argsList = @($HandoffScriptInner, "--mode", "launch", "--repo", $RepoInner, "--issue", "$IssueNumInner", "--agent-id", $AgentIdInner)
    if ($SendClaimInner -and $ClaimFileInner) {
      $argsList += @("--claim-comment-file", $ClaimFileInner)
    } else {
      $argsList += @("--no-claim")
    }
    $out = & node @argsList 2>&1
    return ($out -join "`n")
  } -ArgumentList $HudRoot, $HandoffScript, ([string]$cand.repo), ([int]$cand.number), $agentId, $claimFile, $sendClaim
}

# Global Hotkey + System Tray setup (skipped during headless PNG preview)
if (-not $SavePreview) {
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
$PollTimer.Interval = [TimeSpan]::FromMilliseconds(250)
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
  if ($script:SweepJob -and $script:SweepJob.State -in @("Completed", "Failed", "Stopped")) {
    $L = Get-LangTable
    $failed = ($script:SweepJob.State -ne "Completed")
    $errText = ""
    if ($failed) {
      try { $errText = ($script:SweepJob.ChildJobs[0].JobStateInfo.Reason.Message) } catch {}
    }
    Remove-Job -Job $script:SweepJob -Force -ErrorAction SilentlyContinue
    $script:SweepJob = $null
    $script:IsRefreshing = $false
    $BtnRefresh.IsEnabled = $true
    if (-not $failed) {
      $script:CachedData = Invoke-EngineScore
      Reload-LocalAuxState
      Update-HudView
      $FooterStatus.Text = ($L.FooterUpdated -f (Get-Date -Format 'HH:mm'))
    } else {
      Update-HudView
      $FooterStatus.Text = if ($errText) { ($L.FooterError -f $errText) } else { $L.FooterFailed }
    }
  }
  if ($script:FocusJob -and $script:FocusJob.State -in @("Completed", "Failed", "Stopped")) {
    $L = Get-LangTable
    $failed = ($script:FocusJob.State -ne "Completed")
    $errText = ""
    if ($failed) {
      try { $errText = ($script:FocusJob.ChildJobs[0].JobStateInfo.Reason.Message) } catch {}
    }
    Remove-Job -Job $script:FocusJob -Force -ErrorAction SilentlyContinue
    $script:FocusJob = $null
    $script:IsFocusing = $false
    Reload-LocalAuxState
    $script:CachedData = Invoke-EngineScore
    if (-not $failed -and $script:SurfaceBrief) {
      $script:BriefExpanded = $true
    }
    Update-HudView
    if ($failed) {
      $FooterStatus.Text = if ($errText) { ($L.FooterError -f $errText) } else { $L.FooterFailed }
    } else {
      $FooterStatus.Text = ($L.FooterUpdated -f (Get-Date -Format 'HH:mm'))
    }
  }
  if ($script:HandoffJob -and $script:HandoffJob.State -in @("Completed", "Failed", "Stopped")) {
    $L = Get-LangTable
    $rawOut = ""
    try { $rawOut = (Receive-Job -Job $script:HandoffJob -ErrorAction SilentlyContinue) -join "`n" } catch {}
    Remove-Job -Job $script:HandoffJob -Force -ErrorAction SilentlyContinue
    $script:HandoffJob = $null
    $script:IsLaunchingHandoff = $false
    $resObj = $null
    try { $resObj = $rawOut | ConvertFrom-Json } catch {}
    if ($resObj -and $resObj.ok) {
      $script:PendingHandoffCandidate = $null
      Reload-LocalAuxState
      Update-HudView
      $FooterStatus.Text = ($L.HandoffLaunchedMsg -f $resObj.issueNumber, $resObj.agentLabel, $resObj.handoffId)
    } else {
      Update-HudView
      $msg = if ($resObj -and $resObj.message) { [string]$resObj.message } elseif ($rawOut) { $rawOut } else { $L.FooterFailed }
      $FooterStatus.Text = ($L.FooterError -f $msg)
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

$FocusInputBox.Add_TextChanged({ Update-FocusPlaceholderVisibility })
$FocusInputBox.Add_GotKeyboardFocus({ Update-FocusPlaceholderVisibility })
$FocusInputBox.Add_LostKeyboardFocus({ Update-FocusPlaceholderVisibility })
$FocusInputBox.Add_KeyDown({
  param($sender, $e)
  if ($e.Key -eq [System.Windows.Input.Key]::Return) {
    $e.Handled = $true
    Start-FocusAnalysis
  }
})

$BtnFocusRun.Add_Click({ Start-FocusAnalysis })

$BtnFocusAgent.Add_Click({
  $cm = [System.Windows.Controls.ContextMenu]::new()
  foreach ($opt in @(
    @{ Key = "auto";     Label = $(if ((Get-EffectiveLang) -eq "tr") { "Otomatik (En Uygun Yerel Temsilci)" } else { "Auto (Best Available Agent)" }) },
    @{ Key = "openclaw"; Label = "OpenClaw" },
    @{ Key = "ollama";   Label = "Ollama (Local LLM)" },
    @{ Key = "codex";    Label = "Codex (WSL)" },
    @{ Key = "gemini";   Label = "Gemini CLI (WSL)" },
    @{ Key = "claude";   Label = "Claude Code" }
  )) {
    $mi = [System.Windows.Controls.MenuItem]::new()
    $mi.Header = $opt.Label
    $mi.IsCheckable = $true
    $mi.IsChecked = ($script:FocusAgentPref -eq $opt.Key)
    $k = $opt.Key
    $mi.Add_Click({
      $script:FocusAgentPref = $k
      Save-HudPrefs
      Update-HudView
    }.GetNewClosure())
    [void]$cm.Items.Add($mi)
  }
  $cm.PlacementTarget = $BtnFocusAgent
  $cm.IsOpen = $true
})

$BriefToggleBorder.Add_MouseLeftButtonUp({
  $script:BriefExpanded = -not $script:BriefExpanded
  Update-HudView
})

$BtnHandoffTarget.Add_Click({
  Reload-LocalAuxState
  $agents = if ($script:DetectedAgents -and $script:DetectedAgents.agents) { @($script:DetectedAgents.agents) } else { @() }
  if ($agents.Count -eq 0) { return }
  $cm = [System.Windows.Controls.ContextMenu]::new()
  foreach ($ag in $agents) {
    $mi = [System.Windows.Controls.MenuItem]::new()
    $prefix = if ($ag.ready) { "✓ " } else { "⚠ " }
    $mi.Header = "$prefix$($ag.label)"
    $mi.IsCheckable = $true
    $mi.IsChecked = ($script:SelectedHandoffAgentId -eq [string]$ag.id)
    $aid = [string]$ag.id
    $albl = [string]$ag.label
    $mi.Add_Click({
      $script:SelectedHandoffAgentId = $aid
      $BtnHandoffTarget.Content = "🤖 $albl ▾"
    }.GetNewClosure())
    [void]$cm.Items.Add($mi)
  }
  $cm.PlacementTarget = $BtnHandoffTarget
  $cm.IsOpen = $true
})

$ChkSendClaim.Add_Click({ Update-HudView })
$BtnCancelHandoff.Add_Click({
  $script:PendingHandoffCandidate = $null
  Update-HudView
})
$BtnConfirmHandoff.Add_Click({ Start-CandidateHandoffLaunch })

$BtnClose.Add_Click({ Hide-HudToTray })

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

$BtnRefresh.Add_Click({ Start-BackgroundSweep })

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
$TileCand.Add_MouseLeftButtonUp({
  $script:ActiveFilter = if ($script:ActiveFilter -eq "CAND") { "ALL" } else { "CAND" }
  Update-HudView
})

$Window.Add_KeyDown({
  param($sender, $e)
  if ($e.Key -eq [System.Windows.Input.Key]::Escape) {
    if ($null -ne $script:PendingHandoffCandidate) {
      $e.Handled = $true
      $script:PendingHandoffCandidate = $null
      Update-HudView
    } elseif ($script:BriefExpanded) {
      $e.Handled = $true
      $script:BriefExpanded = $false
      Update-HudView
    } else {
      $e.Handled = $true
      Hide-HudToTray
    }
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

Reload-LocalAuxState
$script:CachedData = Invoke-EngineScore
if ($script:ConfigObj -and $script:ConfigObj.focusTopic) {
  $FocusInputBox.Text = [string]$script:ConfigObj.focusTopic
}
if ($PreviewHandoffIssue -gt 0 -and $script:WatchReport -and $script:WatchReport.activeCandidates) {
  $matchCand = @($script:WatchReport.activeCandidates | Where-Object { [int]$_.number -eq $PreviewHandoffIssue }) | Select-Object -First 1
  if ($matchCand) {
    Open-HandoffConfirmDialog $matchCand
  }
}
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
