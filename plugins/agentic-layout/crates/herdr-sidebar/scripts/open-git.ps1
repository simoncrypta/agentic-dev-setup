# open-git-panel.ps1 -- Windows launcher for the herdr-aa-git source control pane.
#
# Idempotent "launch-or-focus, toggle on repeat", scoped to the current tab:
#   - no Source Control pane in the current tab      -> open at the configured dock edge
#   - a Source Control pane exists but isn't focused -> focus it
#   - the focused pane IS the Source Control pane    -> close it (toggle off)
#
# Left docking splits the leftmost pane and swaps into its narrow slot. Right
# docking splits the rightmost pane with the inverse original-pane ratio and
# needs no swap. The unit-tested --open-plan output owns that choice.
#
# Windows caveats inherited from herdr-file-viewer (see its herdr-plugin.toml):
# herdr cannot spawn a relative [[panes]] command on Windows (ERROR_PATH_NOT_FOUND),
# so we use `pane split`, prepend the binary directory to that pane's PATH, and
# type a shell-agnostic bare executable name. Pane-id / target / ratio decisions
# come from the binary's tested stdin modes, never from ad-hoc parsing.

$ErrorActionPreference = 'Continue'

# PowerShell 5.1 otherwise decodes herdr's UTF-8 JSON with the legacy console code
# page; non-ASCII pane titles or paths would corrupt the JSON.
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $Utf8NoBom
$OutputEncoding = $Utf8NoBom

$HerdrBin = if ($env:HERDR_BIN_PATH) { $env:HERDR_BIN_PATH } else { 'herdr' }

function Strip-Verbatim([string]$p) {
    if ($p -and $p.StartsWith('\\?\')) { return $p.Substring(4) }
    return $p
}
$PluginRoot = Strip-Verbatim (Split-Path -Parent $PSScriptRoot)
$Bin = Join-Path $PluginRoot 'target\release\herdr-sidebar.exe'
$BinDir = Split-Path -Parent $Bin
$LaunchPath = "$BinDir;$env:PATH"

if (-not (Test-Path $Bin)) {
    Write-Error "herdr-sidebar.exe not found at $Bin -- run 'cargo build --release' in the plugin directory first."
    exit 1
}

# Extract the first `pane_id` from a herdr CLI JSON reply.
function Get-PaneId([string]$json) {
    return ([regex]'"pane_id":"([^"]+)"').Match($json).Groups[1].Value
}

$PanesJson = (& $HerdrBin pane list | Out-String)

function Open-Pane {
    # Focused pane = where the user is working; its cwd picks the repository.
    $fp = ($PanesJson | & $Bin --focused-pane).Trim()
    if (-not $fp) {
        # No focused pane known: best-effort plain split beside the current pane.
        $splitArgs = @('pane', 'split', '--current', '--direction', 'right', '--ratio', '0.75',
            '--env', "PATH=$LaunchPath")
        if ($env:HERDR_PLUGIN_STATE_DIR) {
            $splitArgs += @('--env', "HERDR_PLUGIN_STATE_DIR=$env:HERDR_PLUGIN_STATE_DIR")
        }
        $out = (& $HerdrBin @splitArgs | Out-String)
        $np = Get-PaneId $out
        if ($np) { & $HerdrBin pane run $np 'herdr-sidebar --view git' }
        exit 0
    }
    $FocusedId, $FocusedCwd = $fp -split "`t", 2

    $Target = $FocusedId
    if ((& $Bin --dock-right).Trim() -eq 'right') {
        $Ratio = '0.75'
        $NeedsSwap = $false
    } else {
        $Ratio = '0.25'
        $NeedsSwap = $true
    }
    $plan = ((& $HerdrBin pane layout --pane $FocusedId | Out-String) | & $Bin --open-plan).Trim()
    if ($plan) {
        $Target, $Ratio, $swapText = $plan -split "`t", 3
        $NeedsSwap = $swapText -eq 'true'
    }

    $splitArgs = @('pane', 'split', $Target, '--direction', 'right', '--ratio', $Ratio,
        '--no-focus', '--env', "PATH=$LaunchPath")
    if ($FocusedCwd) { $splitArgs += @('--cwd', $FocusedCwd) }
    if ($env:HERDR_PLUGIN_STATE_DIR) {
        $splitArgs += @('--env', "HERDR_PLUGIN_STATE_DIR=$env:HERDR_PLUGIN_STATE_DIR")
    }
    $out = (& $HerdrBin @splitArgs | Out-String)
    $np = Get-PaneId $out
    if (-not $np) { exit 1 }

    # Left docking swaps into the narrow left slot; right docking is already
    # in place. PATH makes the bare launch independent of the pane's shell.
    if ($NeedsSwap) {
        & $HerdrBin pane swap --source-pane $np --target-pane $Target *> $null
    }
    & $HerdrBin pane run $np 'herdr-sidebar --view git'
    & $HerdrBin pane rename $np 'Source Control' *> $null
    # Wait for the TUI's identity token so queued ensure hooks see a LIVE
    # pane (the corpse rule replaces label-without-token panes).
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 200
        $tok = ((& $HerdrBin pane list --json | ConvertFrom-Json).result.panes |
            Where-Object { $_.pane_id -eq $np }).tokens
        if ($tok) { break }
    }
    # herdr has no focus-by-id; a zoom on/off cycle focuses deterministically.
    & $HerdrBin pane zoom $np --on *> $null
    & $HerdrBin pane zoom $np --off *> $null
    exit 0
}

$Decision = ($PanesJson | & $Bin --launch-decision git 2>$null)
if ($LASTEXITCODE -ne 0 -or -not $Decision) { $Decision = 'OPEN' }
$Decision = $Decision.Trim()

if ($Decision -like 'FOCUS *') {
    $PaneId = $Decision.Substring(6)
    & $HerdrBin pane zoom $PaneId --on *> $null
    & $HerdrBin pane zoom $PaneId --off
    exit $LASTEXITCODE
} elseif ($Decision -like 'CLOSE *') {
    $PaneId = $Decision.Substring(6)
    & $HerdrBin pane close $PaneId
    exit $LASTEXITCODE
} elseif ($Decision -like 'REPLACE *') {
    # Dead pane (stale heartbeat): close the corpse, then dock a fresh one.
    $PaneId = $Decision.Substring(8)
    & $HerdrBin pane close $PaneId *> $null
    $PanesJson = (& $HerdrBin pane list | Out-String)
    Open-Pane
} else {
    Open-Pane
}
