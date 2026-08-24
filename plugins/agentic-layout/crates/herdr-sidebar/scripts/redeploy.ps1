# redeploy.ps1 -- refresh every workspace onto the latest plugin builds.
#
# Windows locks a running exe, so a successful `cargo build --release` implies
# the old TUI processes are already dead -- but their PANES linger, and a
# lingering Explorer/Sidebar pane blocks the ensure hook from re-docking a
# fresh one. This closes every sidebar pane in EVERY workspace and reaps only
# the short-lived ensure sidecar; tab-focus hooks then re-dock fresh panes
# (running the newest binaries) the moment each workspace is next focused.
#
# Invoke after rebuilding either plugin:
#   herdr plugin action invoke herdr-sidebar.redeploy-windows

$ErrorActionPreference = 'Continue'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $Utf8NoBom
$OutputEncoding = $Utf8NoBom

$HerdrBin = if ($env:HERDR_BIN_PATH) { $env:HERDR_BIN_PATH } else { 'herdr' }

# Preview panes may hold an experimental editor buffer. Leave them alive so a
# routine sidebar redeploy cannot discard unsaved work.
$Labels = @('Explorer', 'Source Control', 'Sidebar')

$workspaces = (& $HerdrBin workspace list | Out-String | ConvertFrom-Json).result.workspaces
foreach ($ws in $workspaces) {
    $panes = (& $HerdrBin pane list --workspace $ws.workspace_id | Out-String | ConvertFrom-Json).result.panes
    foreach ($pane in $panes) {
        $isPlugin = $Labels -contains $pane.label
        if (-not $isPlugin -and $pane.tokens) {
            foreach ($name in $pane.tokens.PSObject.Properties.Name) {
                if ($name -like 'herdr-aa*' -or
                    $name -eq 'herdr-sidebar-explorer' -or
                    $name -eq 'herdr-sidebar-git') {
                    $isPlugin = $true
                    break
                }
            }
        }
        if ($isPlugin) {
            & $HerdrBin pane close $pane.pane_id *> $null
            Write-Output "closed $($ws.workspace_id) $($pane.pane_id) ($($pane.label))"
        }
    }
}

# The short-lived ensure sidecar is safe to reap. Never kill herdr-sidebar.exe
# by name here: a surviving Preview pane may hold an unsaved editor buffer.
Get-CimInstance Win32_Process -Filter "Name = 'herdr-sidebar-ensure.exe'" | ForEach-Object {
    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    Write-Output "killed $($_.ProcessId) $($_.Name)"
}

# Re-dock the focused workspace right away; the rest refresh on next focus.
& $HerdrBin plugin action invoke herdr-sidebar.open-sidebar-windows *> $null
Write-Output 'redeploy complete - other workspaces re-dock on next focus'
