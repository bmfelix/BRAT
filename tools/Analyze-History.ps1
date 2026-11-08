<#
.SYNOPSIS
  Analyzes BRAT's fight history (every pick, prediction and cast) to show how
  close BRAT is to Blizzard's rotation and what it should learn next.

.DESCRIPTION
  Reads WTF\Account\*\SavedVariables\BRAT.lua (do /reload or log out first so
  WoW writes it) and prints, per spec:
    1. Fights recorded.
    2. NEXT accuracy: how often the NEXT icon matched what Blizzard picked after
       you cast NOW, split by source (logs / learned / proc / list) and enemy count.
    3. Learned priority: Blizzard's rotation as a ranked list per enemy count,
       worked out from every pick ("it chose A while B was also ready").
    4. Procs: how often Blizzard picks a glowing spell straight away.
    5. Cooldown tracker: picks where BRAT's in-combat estimate wrongly thought a
       spell was still on cooldown (that blocks it from NEXT).
    6. You: how often you pressed the NOW spell.
    7. Compared with Warcraft Logs: success % for BRAT's NEXT, Blizzard's picks
       and your own casts, against the Warcraft Logs rotation BRAT served in game
       (built from the data shipped in Data\WCLRaw.lua; saved in the save file).
    8. Trend of those numbers across earlier runs.
  Each run is saved as tools\logs\BRAT-WCL-<date>_<time>.log.

.EXAMPLE
  .\tools\Analyze-History.ps1
  .\tools\Analyze-History.ps1 -Spec 257 -LastFights 10
#>
param(
    [string]$WowPath = "C:\Program Files (x86)\World of Warcraft\_retail_",
    [int]$Spec = 0,         # spec ID to analyze (0 = the spec you last played)
    [int]$LastFights = 0,   # only the most recent N fights per spec (0 = all)
    [string]$Boss = "",     # only fights whose boss/place contains this text, e.g. -Boss "Vexis"
    [double]$ReadyWindow = 1.5  # a spell counts as ready if its cooldown has this little left
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "BRAT.psm1") -Force
$files = Get-ChildItem -Path (Join-Path $WowPath "WTF\Account\*\SavedVariables\BRAT.lua") -ErrorAction SilentlyContinue
if (-not $files) { throw "No BRAT SavedVariables found under $WowPath\WTF. Play a fight, /reload, then run this again." }

$specNames = @{}; foreach ($sp in Get-BratSpecs) { $specNames[$sp.Id] = "$($sp.Spec) $($sp.Class)" }
$diffNames = @{ 1 = "Normal"; 2 = "Heroic"; 8 = "Mythic+"; 14 = "Normal"; 15 = "Heroic"; 16 = "Mythic"; 17 = "LFR"; 23 = "Mythic" }
$names = @{}
$fights = New-Object System.Collections.ArrayList

foreach ($file in $files) {
    $text = [IO.File]::ReadAllText($file.FullName)
    if (-not $Spec) {
        $m = [regex]::Match($text, '\["lastSpec"\]\s*=\s*(\d+)')
        if ($m.Success) { $Spec = [int]$m.Groups[1].Value }
    }
    foreach ($m in [regex]::Matches($text, '(?m)^\s*\[(\d+)\]\s*=\s*"((?:[^"\\]|\\.)*)",\s*$')) {
        $names[[int]$m.Groups[1].Value] = $m.Groups[2].Value
    }
    $cur = $null
    foreach ($m in [regex]::Matches($text, '"H1;([^"]*)"')) {
        $f = $m.Groups[1].Value.Split(';')
        switch ($f[0]) {
            "F" {
                # Where: instance name unless it's the open world (type "none").
                $where = if ($f.Count -gt 5 -and $f[4] -and $f[5] -ne "none") { $f[4] } else { "Open world / target dummy" }
                $inst = if ($f.Count -gt 5 -and $f[4] -and $f[5] -ne "none") { $f[4] } else { $null }
                $instType = if ($f.Count -gt 5 -and $f[5]) { $f[5] } else { "none" }
                $level = if ($f.Count -gt 8 -and $f[8]) { [int]$f[8] } else { 0 }
                $section = switch ($instType) { "party" { "Mythic+ / dungeons (whole dungeon)" } "raid" { "Raid (per boss)" } default { "Other" } }
                if ($instType -eq "raid") { $where = "$inst (trash)" }
                $cur = [pscustomobject]@{ Time = [int64]$f[1]; Spec = [int]$f[2]; Char = $f[3]; Enc = 0; Diff = 0
                    Inst = $inst; InstType = $instType; Level = $level; Section = $section; CtxKind = $null; Label = $where; Events = New-Object System.Collections.ArrayList; Length = 0.0 }
                [void]$fights.Add($cur)
            }
            "N" {
                if ($cur) {
                    $cur.Enc = [int]$f[2]; $cur.Diff = [int]$f[3]
                    $bn = if ($f.Count -gt 4 -and $f[4]) { $f[4] } else { "boss $($f[2])" }
                    $dn = $diffNames[$cur.Diff]
                    # Dungeons stay one place (the whole run); raids split per boss.
                    if ($cur.InstType -ne "party") { $cur.Label = if ($dn) { "$bn ($dn)" } else { $bn } }
                }
            }
            "X" { if ($cur -and -not $cur.CtxKind) { $cur.CtxKind = $f[2] } }
            "E" { if ($cur) { $cur.Length = [double]$f[1] }; $cur = $null }
            "P" {
                if ($cur) {
                    $cds = @{}
                    if ($f[9]) {
                        foreach ($c in $f[9].Split('/')) {
                            $kv = $c.Split(':')
                            $est = $kv[1].StartsWith('~')
                            $cds[[int]$kv[0]] = [pscustomobject]@{ Left = [double]$kv[1].TrimStart('~'); Est = $est }
                        }
                    }
                    $glow = @(); if ($f[8]) { $glow = @($f[8].Split('/') | ForEach-Object { [int]$_ }) }
                    [void]$cur.Events.Add([pscustomobject]@{ Type = "P"; T = [double]$f[1]; Pick = [int]$f[2]
                        Now = [int]$f[3]; Next = [int]$f[4]; Kind = $f[5]; Real = [int]$f[6]; Used = [int]$f[7]
                        Glow = $glow; Cds = $cds })
                }
            }
            "C" {
                if ($cur) {
                    [void]$cur.Events.Add([pscustomobject]@{ Type = "C"; T = [double]$f[1]; Spell = [int]$f[2]
                        Now = [int]$f[3]; Next = [int]$f[4] })
                }
            }
        }
    }
}

# ---- Warcraft Logs rotation: exactly what BRAT served in game ----------------
# BRAT builds its Warcraft Logs rotation in game from the data shipped in
# Data\WCLRaw.lua, and keeps it in the save file (rot.logs[spec]). Fights are
# judged against that, chosen the same way the game chooses it.
$wclRot = Read-BratDbTable "rot" $WowPath
$wclRot = if ($wclRot) { $wclRot["logs"] } else { $null }
$wclInfo = Get-BratWclInfo

# Which served rotation this fight used: the dungeon (whole run), else generic
# dungeon; the raid boss, else generic single target; elsewhere the kind BRAT
# logged at the start of the fight. $null = no Warcraft Logs rotation.
function BossDataFor($sp, $fight) {
    $rot = if ($wclRot) { $wclRot[[int]$sp] } else { $null }
    if (-not $rot) { return $null }
    if ($fight.InstType -eq "party") { $kind = "dungeon"; $key = Get-DungeonKey $fight.Inst }
    elseif ($fight.Enc) { $kind = "boss"; $key = [int]$fight.Enc }
    elseif ($fight.InstType -eq "raid") { $kind = "raid"; $key = $null }
    else { $kind = $(if ($fight.CtxKind -eq "mplus") { "mplus" } else { "raid" }); $key = $null }
    $sel = Select-BratRotation $rot $kind $key
    if ($sel) { return $sel.Data }
    return $null
}

# How does "after $from, cast $to" compare with top players? $null = no data for $from.
function WclEval([int]$sp, [int]$tg, [int]$from, [int]$to, $Data = $null) {
    $d = $Data; if (-not $d) { return $null }
    $cap = if ($wclInfo[$sp]) { $wclInfo[$sp].Cap } else { 8 }
    $tg = [Math]::Min([Math]::Max($tg, 1), $cap)
    $tos = $null
    for ($r = 0; $r -le 8 -and -not $tos; $r++) {   # nearest bucket that knows $from
        foreach ($k in @(($tg - $r), ($tg + $r))) { if (-not $tos -and $d[$k] -and $d[$k][$from]) { $tos = $d[$k][$from] } }
    }
    if (-not $tos) { return $null }
    $total = ($tos.Values | Measure-Object -Sum).Sum
    $best = ($tos.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Key
    return [pscustomobject]@{ Top = ($to -eq $best); Known = $tos.ContainsKey($to)
        Share = $(if ($tos.ContainsKey($to)) { $tos[$to] / $total } else { 0 }) }
}

function N([int]$id) { if ($names[$id]) { $names[$id] } else { "spell $id" } }
function Pct($a, $b) { if ($b -gt 0) { "{0,5:N1}%" -f (100.0 * $a / $b) } else { "    -" } }

$out = New-Object System.Collections.ArrayList
function Say([string]$s = "") { [void]$out.Add($s); Write-Host $s }

if ($fights.Count -eq 0) {
    Say "No fights recorded yet. Fight something in game (history recording is on by default), /reload, then run this again."
    exit
}

if ($Boss) { $fights = [System.Collections.ArrayList]@($fights | Where-Object { $_.Label -like "*$Boss*" }) }
if ($Spec) { $fights = [System.Collections.ArrayList]@($fights | Where-Object { $_.Spec -eq $Spec }) }
if ($fights.Count -eq 0) { Say "No fights match -Boss '$Boss' / -Spec $Spec."; exit }

# Log name tag: the boss filter, the one boss/place if all fights share it, else "All".
$places = @($fights | Select-Object -ExpandProperty Label -Unique)
$tag = if ($Boss) { $Boss } elseif ($places.Count -eq 1) { $places[0] } else { "All" }
$tag = ($tag -replace '[^\w\-]+', '-').Trim('-')

$bySpec = $fights | Group-Object Spec
foreach ($g in $bySpec) {
    $specId = [int]$g.Name
    if ($Spec -and $specId -ne $Spec) { continue }
    $list = @($g.Group | Sort-Object Time)
    if ($LastFights -gt 0 -and $list.Count -gt $LastFights) { $list = $list[($list.Count - $LastFights)..($list.Count - 1)] }
    $sn = $specNames[$specId]; if (-not $sn) { $sn = "spec $specId" }

    Say ("=" * 78)
    Say "$sn ($specId)"
    Say ("=" * 78)
    $secs = ($list | Measure-Object Length -Sum).Sum
    $bosses = @($list | Where-Object { $_.Enc -gt 0 }).Count
    Say ("1. Fights: {0} ({1} boss pulls), {2:N1} minutes in combat" -f $list.Count, $bosses, ($secs / 60))
    Say ""

    # ---- 2. NEXT accuracy -----------------------------------------------------
    $acc = @{}      # key "kind|targets" -> @(hits, total)
    $misses = @{}   # "predicted>actual" -> count
    $casts = 0; $followed = 0
    # ---- 3. priority ----------------------------------------------------------
    $universe = @{} # targets -> set of spells Blizzard ever picked
    foreach ($fight in $list) {
        foreach ($e in $fight.Events) {
            if ($e.Type -eq "P" -and $e.Pick) {
                if (-not $universe[$e.Used]) { $universe[$e.Used] = @{} }
                $universe[$e.Used][$e.Pick] = $true
            }
        }
    }
    $wins = @{}; $games = @{}   # targets -> spell -> count
    $glowSeen = @{}; $glowUsed = @{}
    $late = @{}; $lateSum = @{}; $picks = @{}
    # ---- 7. vs Warcraft Logs: [n compared, #1 matches, known follow-ups, share sum]
    $vs = @{ next = @(0, 0, 0, 0.0); blizz = @(0, 0, 0, 0.0); you = @(0, 0, 0, 0.0) }
    function Tally($key, $r) {
        if (-not $r) { return }
        $vs[$key][0]++
        if ($r.Top) { $vs[$key][1]++ }
        if ($r.Known) { $vs[$key][2]++ }
        $vs[$key][3] += $r.Share
    }

    $byBoss = @{}; $bossMatched = 0
    foreach ($fight in $list) {
        if (-not $byBoss[$fight.Label]) {
            $byBoss[$fight.Label] = [pscustomobject]@{ Section = $fight.Section; Fights = 0; Pred = 0; Hit = 0; NextN = 0; NextOk = 0; YouN = 0; YouOk = 0 }
        }
        $byBoss[$fight.Label].Fights++
        $bd = BossDataFor $specId $fight
        if ($bd) { $bossMatched++ }
        $ev = $fight.Events
        $lastP = $null; $prevC = $null
        for ($i = 0; $i -lt $ev.Count; $i++) {
            $e = $ev[$i]
            if ($e.Type -eq "P") {
                $lastP = $e
                if (-not $e.Pick) { continue }
                $tg = $e.Used
                # Priority: the pick beat every other spell that was ready.
                if (-not $wins[$tg]) { $wins[$tg] = @{}; $games[$tg] = @{} }
                foreach ($o in $universe[$tg].Keys) {
                    if ($o -eq $e.Pick) { continue }
                    $c = $e.Cds[$o]
                    if ($c -and $c.Left -gt $ReadyWindow) { continue }
                    $wins[$tg][$e.Pick] = [int]$wins[$tg][$e.Pick] + 1
                    $games[$tg][$e.Pick] = [int]$games[$tg][$e.Pick] + 1
                    $games[$tg][$o] = [int]$games[$tg][$o] + 1
                }
                foreach ($gl in $e.Glow) {
                    $glowSeen[$gl] = [int]$glowSeen[$gl] + 1
                    if ($gl -eq $e.Pick) { $glowUsed[$gl] = [int]$glowUsed[$gl] + 1 }
                }
                $picks[$e.Pick] = [int]$picks[$e.Pick] + 1
                $c = $e.Cds[$e.Pick]
                if ($c -and $c.Est -and $c.Left -gt $ReadyWindow) {
                    $late[$e.Pick] = [int]$late[$e.Pick] + 1
                    $lateSum[$e.Pick] = [double]$lateSum[$e.Pick] + $c.Left
                }
            }
            elseif ($e.Type -eq "C") {
                $casts++
                $tgNow = if ($lastP) { $lastP.Used } else { 1 }
                # Your own sequence vs top players: consecutive casts within this
                # fight (combat start to combat end), however far apart.
                $bb = $byBoss[$fight.Label]
                if ($prevC) {
                    $r = WclEval $specId $tgNow $prevC.Spell $e.Spell $bd
                    Tally "you" $r
                    if ($r) { $bb.YouN++; if ($r.Known) { $bb.YouOk++ } }
                }
                $prevC = $e
                if ($e.Spell -eq $e.Now) { $followed++ } else { continue }
                if (-not $e.Next) { continue }
                # What did Blizzard pick after this cast? The last pick before your
                # next cast; none at all means it repeated the same spell.
                $actual = $e.Spell; $kindP = $lastP
                for ($j = $i + 1; $j -lt $ev.Count; $j++) {
                    if ($ev[$j].Type -eq "C") { break }
                    if ($ev[$j].Type -eq "P" -and $ev[$j].Pick) { $actual = $ev[$j].Pick }
                }
                $kind = if ($kindP -and $kindP.Kind) { $kindP.Kind } else { "?" }
                $tg = if ($kindP) { $kindP.Used } else { 1 }
                $r = WclEval $specId $tg $e.Spell $e.Next $bd
                Tally "next" $r
                if ($r) { $bb.NextN++; if ($r.Known) { $bb.NextOk++ } }
                Tally "blizz" (WclEval $specId $tg $e.Spell $actual $bd)
                $bb.Pred++; if ($actual -eq $e.Next) { $bb.Hit++ }
                foreach ($key in @("$kind|all", "all|$tg", "all|all")) {
                    if (-not $acc[$key]) { $acc[$key] = @(0, 0) }
                    $acc[$key][1]++
                    if ($actual -eq $e.Next) { $acc[$key][0]++ }
                }
                if ($actual -ne $e.Next) {
                    $mk = "$($e.Spell)|$($e.Next)|$actual"
                    $misses[$mk] = [int]$misses[$mk] + 1
                }
            }
        }
    }

    Say "2. NEXT accuracy (did NEXT match Blizzard's pick after you cast NOW?)"
    $all = $acc["all|all"]
    if ($all) {
        Say ("   overall: {0}  ({1} of {2})" -f (Pct $all[0] $all[1]), $all[0], $all[1])
        foreach ($k in @("logs", "learned", "proc", "list")) {
            $a = $acc["$k|all"]; if ($a) { Say ("   {0,-8} {1}  ({2} predictions)" -f $k, (Pct $a[0] $a[1]), $a[1]) }
        }
        foreach ($k in ($acc.Keys | Where-Object { $_ -like "all|*" -and $_ -ne "all|all" } | Sort-Object { [int]($_.Split('|')[1]) })) {
            $a = $acc[$k]; Say ("   {0} target(s): {1}  ({2} predictions)" -f $k.Split('|')[1], (Pct $a[0] $a[1]), $a[1])
        }
        Say "   most common misses (after X, NEXT said Y, Blizzard picked Z):"
        foreach ($m in ($misses.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 8)) {
            $p = $m.Key.Split('|')
            Say ("     {0,4}x  after {1}: NEXT {2}, Blizzard {3}" -f $m.Value, (N $p[0]), (N $p[1]), (N $p[2]))
        }
    } else { Say "   no predictions recorded yet" }
    Say ""

    Say "3. Blizzard's priority, learned from every pick (top = chosen first when ready)"
    foreach ($tg in ($wins.Keys | Sort-Object)) {
        $rows = foreach ($s in $games[$tg].Keys) {
            $gm = [int]$games[$tg][$s]; if ($gm -lt 5) { continue }
            [pscustomobject]@{ Id = $s; Score = [int]$wins[$tg][$s] / $gm; Games = $gm }
        }
        $rows = @($rows | Sort-Object Score -Descending)
        if ($rows.Count -eq 0) { continue }
        Say "   $tg target(s):"
        $r = 1
        foreach ($row in $rows) {
            Say ("     {0,2}. {1,-32} wins {2}  ({3} comparisons)" -f $r, (N $row.Id), (Pct ($row.Score * 100) 100), $row.Games)
            $r++
        }
    }
    Say ""

    Say "4. Procs (glowing spells): how often Blizzard picked it while it glowed"
    if ($glowSeen.Count -eq 0) { Say "   no glowing spells recorded (none procced, or the game hides glows from addons)" }
    foreach ($gl in ($glowSeen.Keys | Sort-Object { -$glowSeen[$_] })) {
        Say ("   {0,-32} {1}  ({2} picks while glowing)" -f (N $gl), (Pct $glowUsed[$gl] $glowSeen[$gl]), $glowSeen[$gl])
    }
    Say ""

    Say "5. Cooldown tracker: Blizzard picked a spell BRAT estimated was still on cooldown"
    $any = $false
    foreach ($s in ($late.Keys | Sort-Object { -$late[$_] })) {
        $any = $true
        Say ("   {0,-32} {1} of {2} picks, BRAT was {3:N1}s too slow on average" -f (N $s), $late[$s], $picks[$s], ($lateSum[$s] / $late[$s]))
    }
    if (-not $any) { Say "   none: the estimates never blocked a spell Blizzard wanted" }
    Say ""

    Say "6. You: pressed the NOW spell $(Pct $followed $casts) of the time ($casts casts)"
    Say ""

    foreach ($section in @("Raid (per boss)", "Mythic+ / dungeons (whole dungeon)", "Other")) {
        $rows = @($byBoss.GetEnumerator() | Where-Object { $_.Value.Section -eq $section } | Sort-Object { -$_.Value.Fights })
        if ($rows.Count -eq 0) { continue }
        Say $section
        Say ("   {0,-40} {1,6} {2,10} {3,10} {4,9}" -f "", "fights", "NEXT=Bliz", "NEXT=WCL", "You=WCL")
        foreach ($kv in $rows) {
            $b = $kv.Value; $lbl = $kv.Key; if ($lbl.Length -gt 40) { $lbl = $lbl.Substring(0, 40) }
            Say ("   {0,-40} {1,6} {2,10} {3,10} {4,9}" -f $lbl, $b.Fights, (Pct $b.Hit $b.Pred), (Pct $b.NextOk $b.NextN), (Pct $b.YouOk $b.YouN))
        }
        Say ""
    }

    $info = $wclInfo[$specId]
    if ($info -and $wclRot -and $wclRot[[int]$specId]) {
        Say ("7. Compared with Warcraft Logs ({0} parses, ranks {1}, data from {2}; the rotation BRAT built in game)" -f
            $info.Players, $info.Ranks, $info.Date)
        Say "   success = the step is something top players do after that spell; #1 = their most common choice"
        Say "   $bossMatched of $($list.Count) fights compared with the matching rotation (that boss / dungeon, else the generic one)"
        $labels = [ordered]@{ next = "BRAT's NEXT"; blizz = "Blizzard's pick"; you = "Your casts" }
        foreach ($k in $labels.Keys) {
            $v = $vs[$k]
            if ($v[0] -eq 0) { Say ("   {0,-16} no steps to compare yet" -f $labels[$k]); continue }
            Say ("   {0,-16} success {1}   #1 match {2}   ({3} steps)" -f $labels[$k], (Pct $v[2] $v[0]), (Pct $v[1] $v[0]), $v[0])
        }
    } else {
        Say ("7. Compared with Warcraft Logs: no Warcraft Logs rotation saved for this spec. In game: BRAT settings > " +
            "Spec data > Build rotation (Warcraft Logs), then /reload so the save file has it.")
    }
    Say ""

    # Machine-readable line, used for the trend below on future runs.
    function P1($v) { if ($v[0]) { "{0:N1}" -f (100.0 * $v[2] / $v[0]) } else { "-" } }
    $nextAcc = if ($acc["all|all"]) { "{0:N1}" -f (100.0 * $acc["all|all"][0] / $acc["all|all"][1]) } else { "-" }
    $summary = "SUMMARY spec=$specId tag=$tag fights=$($list.Count) nextVsBlizzard=$nextAcc nextVsWcl=$(P1 $vs.next) blizzardVsWcl=$(P1 $vs.blizz) youVsWcl=$(P1 $vs.you)"

    Say "8. Trend for '$tag' (success %, oldest to newest run)"
    $logDir = Join-Path $PSScriptRoot "logs"
    $prev = @(Get-ChildItem (Join-Path $logDir "BRAT-WCL-*.log") -ErrorAction SilentlyContinue | Sort-Object LastWriteTime |
        Where-Object { Select-String -Path $_.FullName -Pattern "^SUMMARY spec=$specId tag=$([regex]::Escape($tag)) " -Quiet } |
        Select-Object -Last 5)
    Say ("   {0,-20} {1,10} {2,10} {3,12} {4,8}" -f "run", "NEXT=Bliz", "NEXT=WCL", "Blizz=WCL", "You=WCL")
    foreach ($p in $prev) {
        $line = Select-String -Path $p.FullName -Pattern "^SUMMARY spec=$specId tag=$([regex]::Escape($tag)) " | Select-Object -Last 1
        $kv = @{}; foreach ($m in [regex]::Matches($line.Line, '(\w+)=(\S+)')) { $kv[$m.Groups[1].Value] = $m.Groups[2].Value }
        Say ("   {0,-20} {1,10} {2,10} {3,12} {4,8}" -f ($p.BaseName -replace '^BRAT-WCL-.*?(\d{4}-)', '$1'), $kv.nextVsBlizzard, $kv.nextVsWcl, $kv.blizzardVsWcl, $kv.youVsWcl)
    }
    Say ("   {0,-20} {1,10} {2,10} {3,12} {4,8}" -f "this run", $nextAcc, (P1 $vs.next), (P1 $vs.blizz), (P1 $vs.you))
    Say ""
    Say $summary
    Say ""
}

$logDir = Join-Path $PSScriptRoot "logs"
New-Item -ItemType Directory -Force $logDir | Out-Null
$report = Join-Path $logDir ("BRAT-WCL-{0}-{1}.log" -f $tag, (Get-Date -Format "yyyy-MM-dd_HH-mm-ss"))
[IO.File]::WriteAllLines($report, [string[]]$out)
Write-Host "Saved to $report"
