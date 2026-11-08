<#
.SYNOPSIS
  Author tool: refreshes the Warcraft Logs data that ships inside BRAT
  (Data\WCLRaw.lua). Players never run this: they get the data with addon updates.

.DESCRIPTION
  Two stages, per spec (other specs are always kept as they are):
    pull    download top-player parses from the Warcraft Logs v2 API into this
            PC's cache (tools\cache\<Class>-<Spec>\, one file per boss/dungeon).
    export  turn the cache into Data\WCLRaw.lua: one compact record per parse
            (what followed what, at each enemy count, for its boss or dungeon).
    all     pull, then export (default).
  In game, players then Rebuild averages and Build rotation (BRAT settings >
  Spec data, or /brat averages, /brat rotation).

  Parses: 15 per raid boss and per Mythic+ dungeon, ranks 101-115 (strong players,
  less skewed by top-end setups); if a boss has fewer than 101 ranked parses, the
  lowest-ranked ones of the top 100 are used. Fetching is resumable, and raising
  -Players later only fetches the extra parses. The API allows about 300 parses
  per hour (one spec, ~10 minutes); -WaitForReset waits through the hourly limit.

  Needs a free API client: warcraftlogs.com -> your profile -> API Clients ->
  Create Client (any name, redirect URL can be http://localhost). Give it the
  Client ID and Secret as -ClientId / -ClientSecret, env vars WCL_CLIENT_ID /
  WCL_CLIENT_SECRET, or tools\wcl-creds.json {"clientId": "...", "clientSecret": "..."}.

.EXAMPLE
  .\tools\Fetch-WarcraftLogs.ps1 -Spec Holy -WaitForReset
  .\tools\Fetch-WarcraftLogs.ps1 -Spec Holy -Stage export        # rewrite WCLRaw.lua from the cache
  .\tools\Fetch-WarcraftLogs.ps1 -Spec Holy -Players 25 -DungeonPlayers 25
  .\tools\Fetch-WarcraftLogs.ps1 -ListZones
#>
param(
    [string]$ClientId,
    [string]$ClientSecret,
    [string[]]$Spec,              # e.g. Shadow, Holy. Default: the spec you last played.
    [int]$Players = 15,           # damage parses per raid boss (15 = about 10 minutes per spec)
    [int]$DungeonPlayers = 15,    # damage parses per M+ dungeon
    [int]$StartRank = 101,        # take parses starting at this rank (101 = ranks 101-115 with 15 players)
    [switch]$WaitForReset,        # at the hourly API limit, wait for the reset instead of stopping
    [int]$ZoneId,                 # raid zone; default: newest raid
    [int]$DungeonZoneId,          # M+ zone; default: newest active M+ season
    [switch]$NoDungeons,
    [int]$MaxTargets = 8,         # target counts 1..MaxTargets ("8" means 8 or more)
    [int]$PointsReserve = 150,    # stop fetching when this close to the hourly API limit
    [double]$CapTolerance = 0.15, # how different (0-1) a target count must be to stay its own bucket
    [int]$CapMinSamples = 150,    # buckets with fewer "A -> B" pairs don't vote on the cap
    [switch]$UseCache,            # only use what's cached, fetch nothing new
    [int]$WindowBeforeMs = 2500,  # target-count window around each cast
    [int]$WindowAfterMs = 750,
    [int]$MaxGapMs = 4000,        # casts further apart than this aren't a "next" (downtime)
    [switch]$ListZones,
    [ValidateSet("all", "pull", "export")]
    [string]$Stage = "all"
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "BRAT.psm1") -Force
$Api = "https://www.warcraftlogs.com/api/v2/client"

# The specs BRAT supports (tools\BRAT.psm1), and which one(s) to do.
$Specs = Get-BratSpecs
if (-not $Spec) {
    $last = Get-BratLastSpec
    if (-not $last) { throw "Don't know your spec yet: log in with BRAT and /reload once, or pass -Spec Holy." }
    $Spec = @($Specs | Where-Object { $_.Id -eq $last } | ForEach-Object { $_.Spec })
    if (-not $Spec) { throw "Your last spec ($last) isn't supported yet. Known: $(($Specs | ForEach-Object Spec) -join ', ')." }
    Write-Host "Spec: $Spec (the spec you last played; use -Spec to choose another)."
}
$Specs = @($Specs | Where-Object { $Spec -contains $_.Spec })
if (-not $Specs) { throw "No matching specs. Known: $((Get-BratSpecs | ForEach-Object Spec) -join ', ')." }

$Stage = $Stage.ToLower()
if ($Stage -eq "export") { $UseCache = $true } # export never downloads
$cacheDir = Join-Path $PSScriptRoot "cache"
$namesFile = Join-Path $cacheDir "spell-names.xml"
$zoneNames = $null

# --- Credentials & token -----------------------------------------------------
if (-not $ClientId) { $ClientId = $env:WCL_CLIENT_ID }
if (-not $ClientSecret) { $ClientSecret = $env:WCL_CLIENT_SECRET }
$credFile = @("wcl-creds.json", "wcl-credentials.json") | ForEach-Object { Join-Path $PSScriptRoot $_ } |
    Where-Object { Test-Path $_ } | Select-Object -First 1
if ((-not $ClientId -or -not $ClientSecret) -and $credFile) {
    $c = Get-Content $credFile -Raw | ConvertFrom-Json
    $ClientId = $c.clientId; $ClientSecret = $c.clientSecret
}
if (-not $ClientId -or -not $ClientSecret) { throw "No Warcraft Logs credentials. See: Get-Help $PSCommandPath" }

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

# --- Pick zones --------------------------------------------------------------
$world = Invoke-Wcl 'query { worldData { expansions { id name zones { id name frozen encounters { id name } } } } }'
$newestExp = $world.worldData.expansions | Sort-Object id -Descending | Select-Object -First 1
$zones = $newestExp.zones | Where-Object { $_.encounters.Count -gt 0 }

if ($ListZones) {
    Write-Host "Zones in $($newestExp.name):"
    $zones | ForEach-Object { Write-Host ("  {0,5}  {1}  ({2} bosses){3}" -f $_.id, $_.name, $_.encounters.Count, $(if ($_.frozen) { " [frozen]" } else { "" })) }
    return
}

function Find-Zone([int]$Id, [scriptblock]$Auto, [string]$What) {
    if ($Id) {
        $z = $zones | Where-Object { $_.id -eq $Id }
        if (-not $z) { throw "Zone $Id not found. Run with -ListZones." }
        return $z
    }
    $z = $zones | Where-Object $Auto | Sort-Object id -Descending | Select-Object -First 1
    if (-not $z) { throw "Couldn't pick a $What zone automatically. Run with -ListZones." }
    return $z
}

$sources = @()
$raid = Find-Zone $ZoneId { -not $_.frozen -and $_.name -notmatch 'Mythic\+|Beta|Complete|Delve|PTR|Dummy' } "raid"
$sources += @{ Zone = $raid; Count = $Players; Kind = "raid" }
Write-Host "Raid zone: $($raid.name) ($($raid.id)), $($raid.encounters.Count) bosses, $Players parses each from rank $StartRank."
if (-not $NoDungeons) {
    $mplus = Find-Zone $DungeonZoneId { -not $_.frozen -and $_.name -match 'Mythic\+' -and $_.name -notmatch 'PTR|Beta' } "Mythic+"
    $sources += @{ Zone = $mplus; Count = $DungeonPlayers; Kind = "mplus" }
    Write-Host "M+ zone:   $($mplus.name) ($($mplus.id)), $($mplus.encounters.Count) dungeons, $DungeonPlayers parses each from rank $StartRank."
}

# --- Queries -----------------------------------------------------------------
$qRank = @'
query($id: Int!, $cls: String!, $spec: String!, $page: Int!) {
  worldData { encounter(id: $id) { characterRankings(className: $cls, specName: $spec, metric: METRIC, page: $page) } }
}
'@
$qReport = @'
query($code: String!, $fid: Int!) {
  reportData { report(code: $code) {
    fights(fightIDs: [$fid]) { id startTime endTime }
    masterData { actors(type: "Player") { id name } }
  } }
}
'@
$qEvents = @'
query($code: String!, $fid: Int!, $sid: Int!, $start: Float!, $end: Float!) {
  reportData { report(code: $code) {
    events(fightIDs: [$fid], sourceID: $sid, dataType: DATATYPE, startTime: $start, endTime: $end, limit: 10000) {
      data nextPageTimestamp
    }
  } }
}
'@

function Get-AllEvents($code, $fid, $sid, $fight, $dataType) {
    $all = New-Object System.Collections.ArrayList
    $start = [double]$fight.startTime
    $q = $qEvents -creplace 'DATATYPE', $dataType
    while ($true) {
        $ev = (Invoke-Wcl $q @{ code = $code; fid = $fid; sid = $sid; start = $start; end = [double]$fight.endTime }).reportData.report.events
        foreach ($e in $ev.data) { [void]$all.Add($e) }
        if (-not $ev.nextPageTimestamp) { break }
        $start = [double]$ev.nextPageTimestamp
    }
    return , $all
}

# For each cast (sorted by time), how many distinct enemies did the player
# damage in [t - before, t + after]? Two-pointer sliding window.
function Get-TargetCounts($casts, $hits) {
    $counts = New-Object int[] $casts.Count
    $inWin = @{}; $lo = 0; $hi = 0
    for ($i = 0; $i -lt $casts.Count; $i++) {
        $t = $casts[$i][1]
        while ($hi -lt $hits.Count -and $hits[$hi][0] -le $t + $WindowAfterMs) {
            $k = $hits[$hi][1]; $inWin[$k] = [int]$inWin[$k] + 1; $hi++
        }
        while ($lo -lt $hi -and $hits[$lo][0] -lt $t - $WindowBeforeMs) {
            $k = $hits[$lo][1]; $inWin[$k]--; if ($inWin[$k] -le 0) { $inWin.Remove($k) }; $lo++
        }
        $counts[$i] = $inWin.Count
    }
    return , $counts
}

# --- Pull data ---------------------------------------------------------------
# Resumable: every boss/dungeon has its own cache file, tools\cache\<Class>-<Spec>\<kind>-<encounterID>.xml,
# holding the players fetched so far. Re-running only fetches players not in the
# cache yet, so a big fetch (top 100 everywhere) can be spread over several hours.
$seqs = @{}   # seqs[spec] = list of sequences, each @( @(spellID, timestamp, targets), ... )
$seqEnc = @{} # seqEnc[spec][i] = @{ id; name; kind } boss/dungeon of sequence i (id 0 = unknown, old cache)
$info = @{}   # info[spec] = @{ players; casts = int[] per target count }
$dmgIds = @{} # dmgIds[spec][abilityID] = $true for abilities that dealt damage
$allIds = @{}
$stop = $false; $sinceCheck = 0

# $true = keep fetching. Near the hourly limit: wait for the reset (-WaitForReset) or stop.
function Test-PointsLeft {
    try {
        $rl = (Invoke-Wcl 'query { rateLimitData { limitPerHour pointsSpentThisHour pointsResetIn } }').rateLimitData
        if (($rl.limitPerHour - $rl.pointsSpentThisHour) -gt $PointsReserve) { return $true }
        if (-not $WaitForReset) { return $false }
        $wait = [int]$rl.pointsResetIn + 30
        Write-Host ("  API limit nearly used; waiting {0} min for the hourly reset (Ctrl+C is safe: progress is saved)..." -f [int]($wait / 60))
        Start-Sleep -Seconds $wait
        return $true
    } catch { return $true }
}

$cacheDir = Join-Path $PSScriptRoot "cache"
$namesFile = Join-Path $cacheDir "spell-names.xml"
$names = @{}
if (Test-Path $namesFile) { $n = Import-Clixml $namesFile; foreach ($k in $n.Keys) { $names[[int]$k] = $n[$k] } }

function Save-EncCache($file, $ec) {
    $dir = Split-Path $file
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    $ec | Export-Clixml $file -Depth 6
}

foreach ($s in $Specs) {
    $seqs[$s.Id] = New-Object System.Collections.ArrayList
    $seqEnc[$s.Id] = New-Object System.Collections.ArrayList
    $info[$s.Id] = @{ players = 0; casts = (New-Object int[] ($MaxTargets + 1)) }
    $dmgIds[$s.Id] = @{}
    $specDir = Join-Path $cacheDir "$($s.Class)-$($s.Spec)"

    foreach ($src in $sources) {
        foreach ($enc in $src.Zone.encounters) {
            $cf = Join-Path $specDir "$($src.Kind)-$($enc.id).xml"
            $ec = if (Test-Path $cf) { Import-Clixml $cf } else { $null }
            # A cache built from a different rank range starts over (don't mix ranges).
            if ($ec -and [int]$ec.startRank -ne $StartRank) {
                if ($UseCache) { Write-Host "  ($($enc.name): cache is from rank $($ec.startRank); using it as is)" }
                else { $ec = $null }
            }
            if (-not $ec) {
                $ec = @{ id = [int]$enc.id; name = [string]$enc.name; kind = $src.Kind; startRank = $StartRank; tried = @{}
                         seqs = (New-Object System.Collections.ArrayList); dmg = @{} }
            }
            $have = $ec.seqs.Count
            if (-not $UseCache -and -not $stop -and $have -lt $src.Count) {
                Write-Host "[$($s.Spec)] $($enc.name): have $have, fetching up to $($src.Count) from rank $StartRank..."
                $ranks = @()
                # Rankings come 100 per page; start at the page holding $StartRank.
                # Fetch a few spare ranks too, to replace players whose logs fail.
                $want = $src.Count + 15
                $firstPage = [int][Math]::Floor(($StartRank - 1) / 100) + 1
                $page = $firstPage
                $skip = ($StartRank - 1) % 100
                function Get-RankPage([int]$p) {
                    $r = Invoke-Wcl ($qRank -creplace 'METRIC', $s.Metric) @{ id = [int]$enc.id; cls = $s.Class; spec = $s.Spec; page = $p }
                    return $r.worldData.encounter.characterRankings
                }
                try {
                    for ($n = 0; $ranks.Count -lt ($skip + $want) -and $n -lt 4; $n++, $page++) {
                        $cr = Get-RankPage $page
                        $ranks += @($cr.rankings)
                        if (-not $cr.hasMorePages) { break }
                    }
                    if ($ranks.Count -le $skip -and $firstPage -gt 1) {
                        # Fewer parses than the start rank (common for healer specs on
                        # damage): use the lowest-ranked ones of the top 100 instead of none.
                        $top = @((Get-RankPage 1).rankings)
                        if ($top.Count -gt 0) {
                            $from = [Math]::Max(0, $top.Count - $want)
                            Write-Host "  only $($top.Count) ranked players here; using ranks $($from + 1)-$($top.Count) instead of $StartRank+."
                            $ranks = @($top | Select-Object -Skip $from); $skip = 0
                        }
                    }
                } catch { Write-Warning "  rankings failed: $_" }
                if ($ranks.Count -le $skip) {
                    Write-Warning "  no ranked players here; skipping."
                    $ranks = @()
                } else { $ranks = @($ranks | Select-Object -Skip $skip -First $want) }
                $newHere = 0
                foreach ($rk in $ranks) {
                    if ($ec.seqs.Count -ge $src.Count) { break }
                    $key = "$($rk.report.code)-$($rk.report.fightID)-$($rk.name)"
                    if ($ec.tried[$key]) { continue }  # fetched (or failed) before
                    if (++$sinceCheck -ge 8) {
                        $sinceCheck = 0
                        if (-not (Test-PointsLeft)) {
                            Write-Warning "Close to the hourly Warcraft Logs API limit; saving and stopping. Run again later to continue (or use -WaitForReset)."
                            $stop = $true; break
                        }
                    }
                    $ec.tried[$key] = $true
                    try {
                        $code = $rk.report.code; $fid = [int]$rk.report.fightID
                        $rep = (Invoke-Wcl $qReport @{ code = $code; fid = $fid }).reportData.report
                        $fight = $rep.fights | Select-Object -First 1
                        $actor = $rep.masterData.actors | Where-Object { $_.name -eq $rk.name } | Select-Object -First 1
                        if (-not $fight -or -not $actor) { continue }
                        $sid = [int]$actor.id

                        $casts = @((Get-AllEvents $code $fid $sid $fight "Casts") | Where-Object { $_.type -eq "cast" } |
                            ForEach-Object { , @([int]$_.abilityGameID, [double]$_.timestamp) })
                        $hits = @((Get-AllEvents $code $fid $sid $fight "DamageDone") |
                            Where-Object { $_.type -eq "damage" -and $_.targetID } |
                            ForEach-Object { , @([double]$_.timestamp, "$($_.targetID).$([int]$_.targetInstance)", [int]$_.abilityGameID) })
                        foreach ($h in $hits) { $ec.dmg[$h[2]] = $true }
                        $tc = Get-TargetCounts $casts $hits

                        $seq = New-Object System.Collections.ArrayList
                        $multi = 0
                        for ($i = 0; $i -lt $casts.Count; $i++) {
                            $k = [Math]::Max(1, [Math]::Min($MaxTargets, $tc[$i]))
                            [void]$seq.Add(@($casts[$i][0], $casts[$i][1], $k))
                            if ($k -ge 2) { $multi++ }
                        }
                        [void]$ec.seqs.Add($seq)
                        $newHere++
                        $multiPct = if ($casts.Count) { [int](100 * $multi / $casts.Count) } else { 0 }
                        Write-Host "    $($ec.seqs.Count). $($rk.name): $($casts.Count) casts, $multiPct% on 2+ targets"
                        if ($newHere % 10 -eq 0) { Save-EncCache $cf $ec }
                    } catch { Write-Warning "    $($rk.name) skipped: $_" }
                }
                Save-EncCache $cf $ec
            }

            # Add this boss/dungeon's cached players to the spec's data.
            foreach ($seq in $ec.seqs) {
                [void]$seqs[$s.Id].Add($seq)
                [void]$seqEnc[$s.Id].Add(@{ id = [int]$ec.id; name = [string]$ec.name; kind = $ec.kind })
                $info[$s.Id].players++
                foreach ($e in $seq) { $allIds[[int]$e[0]] = $true; $info[$s.Id].casts[[int]$e[2]]++ }
            }
            foreach ($k in $ec.dmg.Keys) { $dmgIds[$s.Id][[int]$k] = $true; $allIds[[int]$k] = $true }
        }
    }
    Write-Host "[$($s.Spec)] $($info[$s.Id].players) players in total."
}

if ($Stage -eq "pull") {
    Write-Host "PC cache updated. Next: -Stage export (writes Data\WCLRaw.lua for the addon)."
    return
}

# --- Spell names, noise filter, and pair counting ----------------------------
$idList = @($allIds.Keys | Where-Object { $_ -gt 0 -and -not $names[$_] })  # WCL uses negative IDs for special events
for ($i = 0; $i -lt $idList.Count; $i += 80) {
    $chunk = $idList[$i..([Math]::Min($i + 79, $idList.Count - 1))]
    $parts = $chunk | ForEach-Object { "a$($_): ability(id: $_) { id name }" }
    try {
        $g = (Invoke-Wcl "query { gameData { $($parts -join ' ') } }").gameData
        foreach ($p in $g.PSObject.Properties) { if ($p.Value) { $names[[int]$p.Value.id] = $p.Value.name } }
    } catch { Write-Warning "Spell name lookup failed: $_" }
}
if ($idList.Count -gt 0) {
    if (-not (Test-Path $cacheDir)) { New-Item -ItemType Directory $cacheDir | Out-Null }
    $names | Export-Clixml $namesFile
}

# Consumables and other things nobody should be told to press as "next".
$NoiseNames = '(?i)potion|flask|phial|healthstone|augment rune|drums|food|feast'

$Specs = @($Specs | Where-Object { $info[$_.Id] -and $info[$_.Id].players -gt 0 })
if (-not $Specs) { throw "No player data cached; leaving Data\WCLRaw.lua unchanged." }

$data = @{}   # data[spec][targets][from][to] = count (all pooled; for the rotation cap)
$rawRec = @{}   # rawRec[spec] = list of per-parse records (Data\WCLRaw.lua)
foreach ($s in $Specs) { $rawRec[$s.Id] = New-Object System.Collections.ArrayList }
foreach ($s in $Specs) {
    $ignore = @{}
    foreach ($id in @($s.Ignore)) { if ($id) { $ignore[[int]$id] = $true } }
    foreach ($id in $names.Keys) { if ($names[$id] -match $NoiseNames) { $ignore[$id] = $true } }

    # Damage profile: keep a cast only if a damage event shares its ID or its name
    # (some spells, like Halo, deal damage under a different ID than the cast).
    $keep = $null
    if ($s.DamageOnly) {
        $dmgNames = @{}
        foreach ($id in $dmgIds[$s.Id].Keys) { if ($names[$id]) { $dmgNames[$names[$id]] = $true } }
        $keep = { param($id) $dmgIds[$s.Id][$id] -or ($names[$id] -and $dmgNames[$names[$id]]) }
    }

    $data[$s.Id] = @{}
    for ($si = 0; $si -lt $seqs[$s.Id].Count; $si++) {
        $seq = $seqs[$s.Id][$si]
        $enc = if ($seqEnc[$s.Id] -and $si -lt $seqEnc[$s.Id].Count) { $seqEnc[$s.Id][$si] } else { $null }
        # Pairs go into the pooled data (for the rotation cap) and this parse's record.
        $targetsets = @($data[$s.Id])
        # And into this parse's own record, for the raw cache shipped with the
        # addon (Data\WCLRaw.lua): the game rebuilds averages / rotations from it.
        $own = @{}
        $targetsets += , $own
        if ($enc -and [int]$enc.id -gt 0) {
            if ($enc.kind -eq "mplus") {
                # Dungeons are matched by name in game (lowercase, no apostrophes).
                $rk = @{ kind = "dungeon"; key = (Get-DungeonKey $enc.name); label = $enc.name; pairs = $own }
            } else {
                $rk = @{ kind = "boss"; key = [int]$enc.id; label = $enc.name; pairs = $own }
            }
            [void]$rawRec[$s.Id].Add($rk)
        }
        $clean = @($seq | Where-Object { -not $ignore[$_[0]] -and (-not $keep -or (& $keep $_[0])) })
        for ($i = 1; $i -lt $clean.Count; $i++) {
            $a = $clean[$i - 1]; $b = $clean[$i]
            if ($b[1] - $a[1] -gt $MaxGapMs) { continue }
            $bucket = [int]$a[2]
            $from = $a[0]; $to = $b[0]
            foreach ($d in $targetsets) {
                if (-not $d[$bucket]) { $d[$bucket] = @{} }
                $t = $d[$bucket]
                if (-not $t[$from]) { $t[$from] = @{} }
                $t[$from][$to] = [int]$t[$from][$to] + 1
            }
        }
    }
}

# --- Rotation cap -------------------------------------------------------------
# The target count where the rotation stops changing. For each candidate cap k,
# compare every bucket j >= k (with enough data) against all the other buckets
# >= k pooled together. If none differ by more than CapTolerance (total
# variation distance over "A -> B" pairs), everything from k up is one bucket.
function Get-PairDist($buckets) {
    $d = @{}; $total = 0
    foreach ($t in $buckets) {
        if (-not $t) { continue }
        foreach ($from in $t.Keys) { foreach ($to in $t[$from].Keys) {
            $n = $t[$from][$to]; $d["$from>$to"] = [int]$d["$from>$to"] + $n; $total += $n
        } }
    }
    return @{ d = $d; total = $total }
}
function Get-Distance($a, $b) {
    if ($a.total -eq 0 -or $b.total -eq 0) { return 0 }
    $keys = @{}; foreach ($k in $a.d.Keys) { $keys[$k] = 1 }; foreach ($k in $b.d.Keys) { $keys[$k] = 1 }
    $sum = 0.0
    foreach ($k in $keys.Keys) { $sum += [Math]::Abs([double]$a.d[$k] / $a.total - [double]$b.d[$k] / $b.total) }
    return $sum / 2
}
function Get-RotationCap($specData) {
    for ($k = 1; $k -le $MaxTargets; $k++) {
        $ok = $true
        for ($j = $k; $j -le $MaxTargets -and $ok; $j++) {
            $one = Get-PairDist @($specData[$j])
            if ($one.total -lt $CapMinSamples) { continue }
            $rest = Get-PairDist @($k..$MaxTargets | Where-Object { $_ -ne $j } | ForEach-Object { $specData[$_] })
            if ($rest.total -lt $CapMinSamples) { continue }
            if ((Get-Distance $one $rest) -gt $CapTolerance) { $ok = $false }
        }
        if ($ok) { return $k }
    }
    return $MaxTargets
}

# Merge every bucket above the cap into the cap bucket.
function Merge-AboveCap($sd, $cap) {
    if (-not $sd[$cap]) { $sd[$cap] = @{} }
    foreach ($j in @($sd.Keys | Where-Object { $_ -gt $cap })) {
        foreach ($from in $sd[$j].Keys) {
            if (-not $sd[$cap][$from]) { $sd[$cap][$from] = @{} }
            foreach ($to in $sd[$j][$from].Keys) { $sd[$cap][$from][$to] = [int]$sd[$cap][$from][$to] + $sd[$j][$from][$to] }
        }
        $sd.Remove($j)
    }
}

$caps = @{}
foreach ($s in $Specs) {
    $sd = $data[$s.Id]
    $cap = Get-RotationCap $sd
    $caps[$s.Id] = $cap
    Merge-AboveCap $sd $cap
    Write-Host "[$($s.Spec)] rotation cap: $cap target(s). Buckets: $((1..$cap | ForEach-Object { if ($_ -eq $cap) { "$_+" } else { "$_" } }) -join ', ')"
}

# --- Write Data\WCLRaw.lua: the raw cache that ships inside the addon ----------
# One record per parse: what followed what at each enemy count, for its boss or
# dungeon. The game builds the averages and the rotation from this (in game,
# Spec data page / /brat averages / /brat rotation). Each spec is its own
# marked block, so refreshing one spec keeps the others.
function ConvertTo-LuaPairs($p) {
    $parts = foreach ($tg in ($p.Keys | Sort-Object)) {
        $froms = foreach ($a in ($p[$tg].Keys | Sort-Object)) {
            $tos = ($p[$tg][$a].GetEnumerator() | Sort-Object Name | ForEach-Object { "[$($_.Key)]=$($_.Value)" }) -join ","
            "[$a]={$tos}"
        }
        "[$tg]={$($froms -join ',')}"
    }
    "{$($parts -join ',')}"
}

$rawOut = Join-Path (Resolve-Path (Join-Path $PSScriptRoot "..\Data")).Path "WCLRaw.lua"
$otherRaw = New-Object System.Collections.ArrayList
if (Test-Path $rawOut) {
    $keepIt = $false
    foreach ($line in [IO.File]::ReadAllLines($rawOut)) {
        if ($line -match '^-- BEGIN SPEC (\d+)') { $keepIt = -not ($Specs | Where-Object { $_.Id -eq [int]$Matches[1] }) }
        if ($keepIt) { [void]$otherRaw.Add($line) }
        if ($line -match '^-- END SPEC') { $keepIt = $false }
    }
}
$zoneNames = ($sources | ForEach-Object { $_.Zone.name -replace '"', '' }) -join " + "
$rb = New-Object System.Text.StringBuilder
[void]$rb.AppendLine("-- Warcraft Logs raw cache shipped with BRAT: one record per top-player parse (what followed what,")
[void]$rb.AppendLine("-- at each enemy count, for its raid boss or dungeon). BRAT builds averages and rotations from it in game.")
[void]$rb.AppendLine("-- GENERATED by tools\Fetch-WarcraftLogs.ps1 -- edits here will be overwritten.")
[void]$rb.AppendLine("local _, BRAT = ...")
[void]$rb.AppendLine("BRAT.WCLRaw = BRAT.WCLRaw or {}")
$builtNow = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
foreach ($s in $Specs) {
    $recs = @($rawRec[$s.Id] | Where-Object { $_.pairs.Count -gt 0 })
    [void]$rb.AppendLine("")
    [void]$rb.AppendLine("-- BEGIN SPEC $($s.Id) ($($s.Spec) $($s.Class), $(Get-Date -Format 'yyyy-MM-dd'))")
    [void]$rb.AppendLine("BRAT.WCLRaw[$($s.Id)] = { info = { built = $builtNow, date = `"$(Get-Date -Format 'yyyy-MM-dd')`", " +
        "players = $($recs.Count), cap = $($caps[$s.Id]), ranks = `"$StartRank-$($StartRank + $Players - 1)`", zone = `"$zoneNames`" }, fights = {")
    foreach ($r in $recs) {
        $key = if ($r.kind -eq "boss") { "$($r.key)" } else { "`"$($r.key -replace '"', '')`"" }
        [void]$rb.AppendLine("{kind=`"$($r.kind)`",key=$key,label=`"$($r.label -replace '"', '')`",pairs=$(ConvertTo-LuaPairs $r.pairs)},")
    }
    [void]$rb.AppendLine("} }")
    [void]$rb.AppendLine("-- END SPEC $($s.Id)")
}
foreach ($line in $otherRaw) { [void]$rb.AppendLine($line) }
[IO.File]::WriteAllText($rawOut, $rb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
Write-Host "Wrote $rawOut (shipped raw cache): $(($Specs | ForEach-Object { "$($_.Spec) $(@($rawRec[$_.Id]).Count) parses" }) -join ', ')."

foreach ($s in $Specs) {
    $i = $info[$s.Id]
    $dist =(1..$MaxTargets | ForEach-Object { "$($_)$(if ($_ -eq $MaxTargets) { '+' }):$($i.casts[$_])" }) -join " "
    Write-Host "  $($s.Spec): $($i.players) players. Casts by target count: $dist"
}

try {
    $rl = (Invoke-Wcl 'query { rateLimitData { limitPerHour pointsSpentThisHour pointsResetIn } }').rateLimitData
    Write-Host "API points: $([int]$rl.pointsSpentThisHour) / $($rl.limitPerHour) this hour (resets in $([int]($rl.pointsResetIn / 60)) min)."
} catch { }
