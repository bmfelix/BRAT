# BRAT shared PowerShell module: things every PC tool needs, in one place.
#   Get-BratSpecs            the specs BRAT supports (the one list)
#   Get-BratLastSpec         the spec you last played
#   Get-BratSavedVariables   path of the newest BRAT SavedVariables file
#   Read-BratDbTable         read one top-level table of BRATDB (e.g. "rot") as hashtables
#   ConvertFrom-LuaTable     parse a Lua table literal (SavedVariables format)
#   Get-BratWclInfo          info about the Warcraft Logs data shipped in Data\WCLRaw.lua
#   Get-DungeonKey           dungeon name -> the key the addon uses (lowercase, no apostrophes)
#   Select-BratRotation      the served rotation for a fight (mirrors RotationBuilder.Select)

$script:Root = Split-Path $PSScriptRoot

# The specs BRAT supports, for every PC tool (the one list to extend).
#   Ignore     = spell IDs that show up as casts but aren't buttons (auto-procs).
#   DamageOnly = keep only casts of spells that dealt damage (a healer's damage
#                profile: heals between damage casts aren't counted as "next").
function Get-BratSpecs {
    @(
        [pscustomobject]@{ Id = 256; Class = "Priest"; Spec = "Discipline"; Metric = "dps"; Ignore = @(); DamageOnly = $true },
        [pscustomobject]@{ Id = 257; Class = "Priest"; Spec = "Holy";       Metric = "dps"; Ignore = @(); DamageOnly = $true },
        [pscustomobject]@{ Id = 258; Class = "Priest"; Spec = "Shadow";     Metric = "dps"; Ignore = @(341263); DamageOnly = $false }, # Shadowy Apparition
        # Devastation: movement, defensives, utility and potions sit between rotation casts
        # (Hover alone ~20x a fight). Not DamageOnly: Dragonrage and Tip the Scales deal no damage themselves.
        [pscustomobject]@{ Id = 1467; Class = "Evoker"; Spec = "Devastation"; Metric = "dps"; DamageOnly = $false
            Ignore = @(358267, 358733, 363916, 374348, 374968, 374227, 370665, 360995, 361195, 361509, 355913, # Hover, Glide, Obsidian Scales, Renewing Blaze, Time Spiral, Zephyr, Rescue, Verdant Embrace x2, Living Flame (heal), Emerald Blossom
                       365585, 374251, 351338, 364342, 406732, 357214, 358385, 390386, 1236616, 1236998, 370454) } # Charged Blast (auto), Expunge, Cauterizing Flame, Quell, Blessing of the Bronze, Spatial Paradox, Wing Buffet, Landslide, Fury of the Aspects, Light's Potential, Draught of Rampant Abandon
    )
}

# The spec you last played (BRAT saves it on login and spec change), or $null.
function Get-BratLastSpec([string]$WowPath = "C:\Program Files (x86)\World of Warcraft\_retail_") {
    $sv = Get-BratSavedVariables $WowPath
    if (-not $sv) { return $null }
    $m = [regex]::Match([IO.File]::ReadAllText($sv.FullName), '\["lastSpec"\]\s*=\s*(\d+)')
    if ($m.Success) { return [int]$m.Groups[1].Value }
    return $null
}

function Get-BratSavedVariables([string]$WowPath = "C:\Program Files (x86)\World of Warcraft\_retail_") {
    Get-ChildItem (Join-Path $WowPath "WTF\Account\*\SavedVariables\BRAT.lua") -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

# Lua table literal -> nested hashtables. Keys become [int] or [string]; values are
# [int]/[double]/[string]/[bool]/$null or hashtables. Handles the SavedVariables
# format (["key"] = value, [1] = value, plain list values, -- comments).
function ConvertFrom-LuaTable([string]$Text) {
    $pattern = '"(?:[^"\\]|\\.)*"|--[^\n]*|-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?|[{}\[\]=,;]|true|false|nil|[A-Za-z_]\w*'
    $tokens = @([regex]::Matches($Text, $pattern) | ForEach-Object { $_.Value } | Where-Object { -not $_.StartsWith("--") })
    $script:luaTokens = $tokens; $script:luaPos = 0
    return Read-LuaValue
}

function Read-LuaValue {
    $t = $script:luaTokens[$script:luaPos]; $script:luaPos++
    if ($t -eq "{") { return Read-LuaTableBody }
    if ($t.StartsWith('"')) { return [regex]::Unescape($t.Substring(1, $t.Length - 2)) }
    if ($t -eq "true") { return $true }
    if ($t -eq "false") { return $false }
    if ($t -eq "nil") { return $null }
    if ($t -match '^-?\d+$') { return [int64]$t }
    return [double]::Parse($t, [Globalization.CultureInfo]::InvariantCulture)
}

function Read-LuaTableBody {
    $tbl = @{}; $n = 0
    while ($script:luaTokens[$script:luaPos] -ne "}") {
        $t = $script:luaTokens[$script:luaPos]
        if ($t -eq "," -or $t -eq ";") { $script:luaPos++; continue }
        if ($t -eq "[") {
            $script:luaPos++
            $k = Read-LuaValue
            $script:luaPos += 2            # ']' '='
            $tbl[$(if ($k -is [int64]) { [int]$k } else { $k })] = Read-LuaValue
        } elseif ($script:luaTokens[$script:luaPos + 1] -eq "=" -and $t -match '^[A-Za-z_]\w*$') {
            $script:luaPos += 2            # name '='
            $tbl[$t] = Read-LuaValue
        } else {
            $n++; $tbl[$n] = Read-LuaValue
        }
    }
    $script:luaPos++                       # '}'
    return $tbl
}

# One top-level table of BRATDB, e.g. Read-BratDbTable "rot" -> rot[source][spec]...
# Only that table is parsed (the save file also holds a long fight log).
function Read-BratDbTable([string]$Name, [string]$WowPath = "C:\Program Files (x86)\World of Warcraft\_retail_") {
    $sv = Get-BratSavedVariables $WowPath
    if (-not $sv) { return $null }
    $text = [IO.File]::ReadAllText($sv.FullName)
    $m = [regex]::Match($text, "(?m)^\s*\[""$Name""\]\s*=\s*\{")
    if (-not $m.Success) { return $null }
    # Find the matching closing brace (skipping braces inside strings).
    $start = $m.Index + $m.Length - 1; $depth = 0; $inStr = $false
    for ($i = $start; $i -lt $text.Length; $i++) {
        $ch = $text[$i]
        if ($inStr) { if ($ch -eq '\') { $i++ } elseif ($ch -eq '"') { $inStr = $false }; continue }
        if ($ch -eq '"') { $inStr = $true }
        elseif ($ch -eq '{') { $depth++ }
        elseif ($ch -eq '}') { $depth--; if ($depth -eq 0) { break } }
    }
    return ConvertFrom-LuaTable $text.Substring($start, $i - $start + 1)
}

# Info lines from Data\WCLRaw.lua: @{ specID = @{ Built; Date; Players; Cap; Ranks } }.
function Get-BratWclInfo {
    $file = Join-Path $script:Root "Data\WCLRaw.lua"
    $info = @{}
    if (-not (Test-Path $file)) { return $info }
    foreach ($line in [IO.File]::ReadAllLines($file)) {
        if ($line -match '^BRAT\.WCLRaw\[(\d+)\] = \{ info = \{ built = (\d+), date = "([^"]*)", players = (\d+), cap = (\d+), ranks = "([^"]*)"') {
            $info[[int]$Matches[1]] = @{ Built = [int64]$Matches[2]; Date = $Matches[3]; Players = [int]$Matches[4]
                Cap = [int]$Matches[5]; Ranks = $Matches[6] }
        }
    }
    return $info
}

# Same normalization as Context.Lower in the addon.
function Get-DungeonKey([string]$Name) { if ($Name) { ($Name.ToLower() -replace "[\u2019']", "") } }

# The served rotation for a place (mirrors RotationBuilder.Select in the addon):
#   boss -> that boss, else generic single target; raid -> generic single target
#   dungeon -> that dungeon, else generic dungeon;  mplus -> generic dungeon
# Returns @{ Data; Label } or $null.
function Select-BratRotation($Rot, [string]$Kind, $Key) {
    if (-not $Rot) { return $null }
    $raid = $Rot["raid"]; $dung = $Rot["dungeon"]; $labels = $Rot["labels"]
    function pick($d, $l) { if ($d) { @{ Data = $d; Label = $l } } }
    if ($Kind -eq "boss" -and $raid["bosses"] -and $raid["bosses"][$Key]) { return pick $raid["bosses"][$Key] $labels[$Key] }
    if ($Kind -eq "dungeon" -and $dung["dungeons"] -and $dung["dungeons"][$Key]) { return pick $dung["dungeons"][$Key] $labels[$Key] }
    if ($Kind -eq "boss" -or $Kind -eq "raid") {
        if ($raid["generic"]) { return pick $raid["generic"] "generic single target" }
        return pick $dung["generic"] "generic dungeon"
    }
    if ($dung["generic"]) { return pick $dung["generic"] "generic dungeon" }
    return pick $raid["generic"] "generic single target"
}

Export-ModuleMember -Function Get-BratSpecs, Get-BratLastSpec, Get-BratSavedVariables, ConvertFrom-LuaTable,
    Read-BratDbTable, Get-BratWclInfo, Get-DungeonKey, Select-BratRotation
