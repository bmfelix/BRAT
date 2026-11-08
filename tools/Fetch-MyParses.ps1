<#
.SYNOPSIS
  Pulls YOUR Warcraft Logs parses and matches each one to the NEXT source
  BRAT was using in that fight. Writes Data\MyParses.lua for the
  "Compare sources" settings page.

.DESCRIPTION
  1. Upload your logs to warcraftlogs.com as usual.
  2. /reload in game so BRAT's fight list is saved to disk.
  3. Run this script, then /reload again.
  Only raid boss kills are matched (Warcraft Logs ranks Mythic+ by whole run).
  Uses the same credentials as Fetch-WarcraftLogs.ps1 (tools\wcl-creds.json).

  Your character, realm and region are recorded by BRAT with every fight, so
  normally you don't pass anything. -Character/-Realm/-Region override them.

.EXAMPLE
  .\tools\Fetch-MyParses.ps1
  .\tools\Fetch-MyParses.ps1 -Character Bradpriest -Realm "Area 52"
#>
param(
    [string]$Character,
    [string]$Realm,
    [string]$Region,
    [string]$WowPath = "C:\Program Files (x86)\World of Warcraft\_retail_",
    [int]$MatchWindowSec = 180,   # how close a parse's start must be to BRAT's recorded pull time
    [string]$ClientId,
    [string]$ClientSecret
)

$ErrorActionPreference = "Stop"
$Api = "https://www.warcraftlogs.com/api/v2/client"
$Out = Join-Path $PSScriptRoot "..\Data\MyParses.lua"
# The specs BRAT supports come from the one list in tools\BRAT.psm1.
# (BRAT's healer profiles are damage profiles, so their metric is dps too.)
Import-Module (Join-Path $PSScriptRoot "BRAT.psm1") -Force
$SpecNames = @{}; $Metric = @{}
foreach ($s in Get-BratSpecs) { $SpecNames[$s.Id] = $s.Spec; $Metric[$s.Id] = $s.Metric }

# --- Credentials ---------------------------------------------------------------
if (-not $ClientId) { $ClientId = $env:WCL_CLIENT_ID }
if (-not $ClientSecret) { $ClientSecret = $env:WCL_CLIENT_SECRET }
$credFile = @("wcl-creds.json", "wcl-credentials.json") | ForEach-Object { Join-Path $PSScriptRoot $_ } |
    Where-Object { Test-Path $_ } | Select-Object -First 1
if ((-not $ClientId -or -not $ClientSecret) -and $credFile) {
    $c = Get-Content $credFile -Raw | ConvertFrom-Json
    $ClientId = $c.clientId; $ClientSecret = $c.clientSecret
}
if (-not $ClientId -or -not $ClientSecret) { throw "No Warcraft Logs credentials (see Fetch-WarcraftLogs.ps1)." }
$basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${ClientId}:${ClientSecret}"))
$token = (Invoke-RestMethod -Method Post -Uri "https://www.warcraftlogs.com/oauth/token" `
    -Headers @{ Authorization = "Basic $basic" } -Body @{ grant_type = "client_credentials" }).access_token

function Invoke-Wcl([string]$Query, [hashtable]$Vars = @{}) {
    $body = @{ query = $Query; variables = $Vars } | ConvertTo-Json -Depth 20 -Compress
    $r = Invoke-RestMethod -Method Post -Uri $Api -ContentType "application/json" `
        -Headers @{ Authorization = "Bearer $token" } -Body $body
    if ($r.errors) { throw "Warcraft Logs error: $($r.errors | ConvertTo-Json -Depth 6 -Compress)" }
    return $r.data
}

# --- Read BRAT's fight list from SavedVariables -------------------------------
$fights = @()
$files = Get-ChildItem -Path (Join-Path $WowPath "WTF\Account\*\SavedVariables\BRAT.lua") -ErrorAction SilentlyContinue
if (-not $files) { throw "No BRAT SavedVariables found. Play, then /reload in game first." }
foreach ($file in $files) {
    foreach ($line in [IO.File]::ReadAllLines($file.FullName)) {
        if ($line -match '^\s*"(t=[^"]+)"') {
            $f = @{}
            foreach ($kv in $Matches[1].Split(";")) { $p = $kv.Split("=", 2); if ($p.Count -eq 2) { $f[$p[0]] = $p[1] } }
            if ($f.kind -eq "boss" -and [int]$f.enc -gt 0) {
                $char = if ($Character) { $Character } else { $f.char }
                $realm = if ($Realm) { $Realm } else { $f.realm }
                $region = if ($Region) { $Region } elseif ($f.region) { $f.region } else { "US" }
                if (-not $char -or -not $realm) { continue } # fights recorded before BRAT saved character info
                $fights += [pscustomobject]@{
                    t = [double]$f.t; spec = [int]$f.spec; src = $f.src; enc = [int]$f.enc; diff = [int]$f.diff
                    char = $char; realm = $realm; region = $region
                }
            }
        }
    }
}
Write-Host "BRAT recorded $($fights.Count) raid boss fights."
if (-not $fights) { throw "No boss fights recorded yet. Raid with BRAT on, then /reload." }

# --- Query your rankings per character/boss/difficulty/spec, match by time ----
function Get-Slug([string]$realm) { ($realm.ToLower() -replace "'", "" -replace '\s+', '-') }
$q = @'
query($n: String!, $s: String!, $r: String!, $e: Int!, $d: Int, $spec: String) {
  characterData { character(name: $n, serverSlug: $s, serverRegion: $r) {
    encounterRankings(encounterID: $e, difficulty: $d, specName: $spec, metric: METRIC)
  } }
}
'@

$results = @{}   # results[spec] = list of @{ t; src; pct; enc; diff; char }
$who = @{}
foreach ($g in ($fights | Group-Object char, realm, region, spec, enc, diff)) {
    $first = $g.Group[0]
    $specName = $SpecNames[$first.spec]
    if (-not $specName) { continue }
    $label = "$($first.char)-$($first.realm) ($($first.region))"
    $vars = @{ n = $first.char; s = (Get-Slug $first.realm); r = $first.region; e = $first.enc; spec = $specName }
    # Blizzard difficulty IDs (from ENCOUNTER_START) -> Warcraft Logs raid difficulty IDs.
    $wclDiff = @{ 17 = 1; 14 = 3; 15 = 4; 16 = 5 }[$first.diff]
    if ($wclDiff) { $vars.d = $wclDiff }
    try {
        $d = Invoke-Wcl ($q -creplace 'METRIC', $Metric[$first.spec]) $vars
    } catch { Write-Warning "$label encounter $($first.enc): $_"; continue }
    $char = $d.characterData.character
    if (-not $char) { Write-Warning "$label not found on Warcraft Logs (have you uploaded logs?)."; continue }
    $who[$label] = $true
    $ranks = @($char.encounterRankings.ranks)
    $matched = 0
    foreach ($rk in $ranks) {
        $start = [double]$rk.startTime / 1000
        $f = $g.Group | Where-Object { [Math]::Abs($_.t - $start) -le $MatchWindowSec } | Select-Object -First 1
        if (-not $f) { continue }
        if (-not $results[$f.spec]) { $results[$f.spec] = New-Object System.Collections.ArrayList }
        [void]$results[$f.spec].Add(@{ t = [long]$f.t; src = $f.src; pct = [double]$rk.rankPercent; enc = $f.enc; diff = $f.diff })
        $matched++
    }
    Write-Host "  $label encounter $($first.enc) ($specName, difficulty $($first.diff)): $($ranks.Count) parses, $matched matched to BRAT fights"
}

# --- Write Data\MyParses.lua ---------------------------------------------------
$now = Get-Date -Format 'yyyy-MM-dd'
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("-- Your own Warcraft Logs parses, matched to the NEXT source BRAT was using.")
[void]$sb.AppendLine("-- GENERATED by tools\Fetch-MyParses.ps1 on $now -- edits here will be overwritten.")
[void]$sb.AppendLine("-- Format: [specID] = { { t = pull time, src = source BRAT used, pct = parse percentile, enc, diff }, ... }")
[void]$sb.AppendLine("-- BRAT averages these per source in game (and skips ones from before a comparison reset).")
[void]$sb.AppendLine("local _, BRAT = ...")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("BRAT.MyParses = {")
foreach ($spec in ($results.Keys | Sort-Object)) {
    [void]$sb.AppendLine("    [$spec] = { -- $($SpecNames[$spec])")
    foreach ($p in ($results[$spec] | Sort-Object { $_.t })) {
        [void]$sb.AppendLine(("        {{ t = {0}, src = `"{1}`", pct = {2:0.0}, enc = {3}, diff = {4} }}," -f $p.t, $p.src, $p.pct, $p.enc, $p.diff))
    }
    [void]$sb.AppendLine("    },")
    foreach ($src in "logs", "blizzard") {
        $m = @($results[$spec] | Where-Object { $_.src -eq $src }) | ForEach-Object { $_.pct } | Measure-Object -Average
        if ($m.Count) { Write-Host ("{0} / {1}: {2} parses, average {3:0.0}" -f $SpecNames[$spec], $src, $m.Count, $m.Average) }
    }
}
[void]$sb.AppendLine("}")
$names = ($who.Keys -join ", ") -replace '"', ''
[void]$sb.AppendLine("BRAT.MyParsesInfo = { date = `"$now`", character = `"$names`" }")

$outFull = Join-Path (Resolve-Path (Split-Path $Out)).Path "MyParses.lua"
[IO.File]::WriteAllText($outFull, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
Write-Host "Wrote $outFull. /reload in game to see it under BRAT > Compare sources."
