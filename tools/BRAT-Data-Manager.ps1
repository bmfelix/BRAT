<#
.SYNOPSIS
  BRAT Data Manager (author tool): refresh the Warcraft Logs data that ships
  inside the addon, spec by spec. Players never need this.

.DESCRIPTION
  Start it by double-clicking "BRAT Data Manager.cmd" in this folder.
    Pull new data      download top-player parses into this PC's cache
                       (tools\cache\<Class>-<Spec>\; resumes, waits through the API limit)
    Export to addon    write the cache into Data\WCLRaw.lua (the raw cache BRAT ships)
    Pull & export      both
    Clear PC cache     delete the downloaded parses (the shipped data stays)
  Then publish the addon update. In game, players rebuild averages and the
  rotation from the new data (BRAT settings > Spec data; BRAT tells them).
  Other specs are never touched.

.EXAMPLE
  .\tools\BRAT-Data-Manager.ps1          # window
  .\tools\BRAT-Data-Manager.ps1 -List    # print status
#>
param([switch]$List)
$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "BRAT.psm1") -Force

$Root = Split-Path $PSScriptRoot
$CacheDir = Join-Path $PSScriptRoot "cache"
$Fetcher = Join-Path $PSScriptRoot "Fetch-WarcraftLogs.ps1"

# This PC's download cache for a spec (parse files per boss / dungeon).
function Get-CacheInfo($s) {
    $dir = Join-Path $CacheDir "$($s.Class)-$($s.Spec)"
    $files = @(if (Test-Path $dir) { Get-ChildItem $dir -File -Filter "*.xml" })
    @{ MB = [math]::Round((($files | Measure-Object Length -Sum).Sum) / 1MB, 1); Files = $files.Count }
}

function Get-Status {
    $shipped = Get-BratWclInfo
    foreach ($s in Get-BratSpecs) {
        $c = Get-CacheInfo $s
        $w = $shipped[$s.Id]
        [pscustomobject]@{
            Id = $s.Id; Name = "$($s.Spec) $($s.Class)"; Spec = $s.Spec
            Cache = "$($c.MB) MB, $($c.Files) files"
            Shipped = $(if ($w) { "$($w.Date), $($w.Players) parses (ranks $($w.Ranks))" } else { "none" })
        }
    }
}

function Remove-SpecCache($s) {
    $dir = Join-Path $CacheDir "$($s.Class)-$($s.Spec)"
    if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }
}

function Test-FetchRunning {
    [bool](Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -match 'Fetch-WarcraftLogs' })
}

# Run the fetcher for these specs in its own window (pull can take a while).
function Start-Fetch($specs, [string]$stage) {
    $names = ($specs | ForEach-Object { $_.Spec }) -join ","
    $wait = if ($stage -ne "export") { " -WaitForReset" } else { "" }
    $cmd = "& '$Fetcher' -Spec $names -Stage $stage$wait; Write-Host ''; Write-Host 'Done. You can close this window.'"
    Start-Process powershell -ArgumentList @("-NoExit", "-ExecutionPolicy", "Bypass", "-Command", $cmd) -WorkingDirectory $Root
}

if ($List) { Get-Status | Format-Table Name, Cache, Shipped -AutoSize; return }

# --- Window ---------------------------------------------------------------------
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$form = New-Object System.Windows.Forms.Form
$form.Text = "BRAT Data Manager (author: Warcraft Logs data shipped with the addon)"
$form.Size = New-Object System.Drawing.Size(720, 380)
$form.StartPosition = "CenterScreen"
$form.Font = New-Object System.Drawing.Font("Segoe UI", 10)

$label = New-Object System.Windows.Forms.Label
$label.Text = "Tick specs, then pick an action. Each spec is handled on its own; others are never touched."
$label.SetBounds(12, 10, 680, 24)
$form.Controls.Add($label)

$grid = New-Object System.Windows.Forms.ListView
$grid.View = "Details"; $grid.CheckBoxes = $true; $grid.FullRowSelect = $true
$grid.SetBounds(12, 40, 680, 150)
[void]$grid.Columns.Add("Spec", 150)
[void]$grid.Columns.Add("Cache on this PC", 170)
[void]$grid.Columns.Add("Shipped in the addon (Data\WCLRaw.lua)", 350)
$form.Controls.Add($grid)

function Fill-Grid {
    $grid.Items.Clear()
    foreach ($s in Get-Status) {
        $item = New-Object System.Windows.Forms.ListViewItem($s.Name)
        [void]$item.SubItems.Add($s.Cache)
        [void]$item.SubItems.Add($s.Shipped)
        $item.Tag = $s.Id
        [void]$grid.Items.Add($item)
    }
}

function Get-Checked {
    @($grid.Items | Where-Object { $_.Checked } | ForEach-Object { $id = $_.Tag; Get-BratSpecs | Where-Object { $_.Id -eq $id } })
}

function Add-ActionButton([string]$text, [int]$x, [int]$y, [string]$question, [scriptblock]$action) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.SetBounds($x, $y, 335, 32)
    $b.Add_Click({
        $specs = Get-Checked
        if (-not $specs) { [void][System.Windows.Forms.MessageBox]::Show("Tick at least one spec."); return }
        if (Test-FetchRunning) { [void][System.Windows.Forms.MessageBox]::Show("A pull or export is already running. Wait for it to finish."); return }
        $names = ($specs | ForEach-Object { "$($_.Spec) $($_.Class)" }) -join ", "
        if ([System.Windows.Forms.MessageBox]::Show("$question`n`nSpecs: $names", "BRAT", "OKCancel") -ne "OK") { return }
        & $action $specs
        Fill-Grid
    }.GetNewClosure())
    $form.Controls.Add($b)
}

Add-ActionButton "Pull new data (download to this PC)" 12 202 `
    "Download ranks 101-115 for every boss and dungeon into this PC's cache? About 10 minutes per spec (waits through the hourly API limit). Then Export to addon." `
    { param($specs) Start-Fetch $specs "pull" }
Add-ActionButton "Export to addon (write Data\WCLRaw.lua)" 357 202 `
    "Write the cached parses into Data\WCLRaw.lua (the raw cache the addon ships)? No download." `
    { param($specs) Start-Fetch $specs "export" }
Add-ActionButton "Pull & export" 12 240 `
    "Download fresh parses and write Data\WCLRaw.lua?" `
    { param($specs) foreach ($s in $specs) { Remove-SpecCache $s }; Start-Fetch $specs "all" }
Add-ActionButton "Clear PC cache" 357 240 `
    "Delete this PC's downloaded parses? The data shipped in the addon stays." `
    { param($specs) foreach ($s in $specs) { Remove-SpecCache $s } }

$refresh = New-Object System.Windows.Forms.Button
$refresh.Text = "Refresh"
$refresh.SetBounds(12, 282, 100, 30)
$refresh.Add_Click({ Fill-Grid })
$form.Controls.Add($refresh)

$note = New-Object System.Windows.Forms.Label
$note.Text = "After exporting, publish the addon update. Players then rebuild averages and the rotation in game (BRAT tells them)."
$note.SetBounds(122, 280, 570, 40)
$note.ForeColor = [System.Drawing.Color]::DimGray
$form.Controls.Add($note)

Fill-Grid
[void]$form.ShowDialog()
