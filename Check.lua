-- BRAT self-check: /brat check prints the state of every game API and data
-- source BRAT depends on, with a fix for anything that's wrong.
-- At login it runs quietly and only prints a one-line notice if something fails.
local _, BRAT = ...
local Check = {}
BRAT.Check = Check

local OK = "|TInterface\\RaidFrame\\ReadyCheck-Ready:0|t"
local BAD = "|TInterface\\RaidFrame\\ReadyCheck-NotReady:0|t"
local WARN = "|TInterface\\RaidFrame\\ReadyCheck-Waiting:0|t"

local function count(t) local n = 0; if type(t) == "table" then for _ in pairs(t) do n = n + 1 end end; return n end
local function name(id) return (id and C_Spell.GetSpellName and C_Spell.GetSpellName(id)) or tostring(id) end

-- Each check returns status ("ok" | "warn" | "bad"), text, and an optional fix.
local checks = {}
local function add(label, fn) checks[#checks + 1] = { label = label, fn = fn } end

add("Game version", function()
    local _, build, _, toc = GetBuildInfo()
    if toc and toc ~= 120105 and toc ~= 120100 then
        return "warn", ("client is %s (interface %d), BRAT targets 12.1.x"):format(build or "?", toc),
            "If WoW lists BRAT as out of date, tick 'Load out of date AddOns' or update BRAT.toc."
    end
    return "ok", ("interface %d"):format(toc or 0)
end)

add("Assisted Combat", function()
    if not C_AssistedCombat then
        return "bad", "C_AssistedCombat API missing", "Blizzard's rotation API isn't in this client; BRAT can't work."
    end
    local avail, reason = BRAT.Safe(C_AssistedCombat.IsAvailable)
    if avail == false then
        return "bad", "not available: " .. tostring(reason or "no reason given"),
            "Check that Blizzard's Assisted Combat / rotation assistant is supported for this spec."
    end
    local raw = C_AssistedCombat.GetNextCastSpell and select(2, pcall(C_AssistedCombat.GetNextCastSpell, false))
    if BRAT.IsSecret(raw) then
        return "bad", "the current pick is a secret value", "Midnight hides it from addons here; NOW can't be shown."
    end
    local pick = BRAT.Predict:GetBlizzardPick()
    if not pick then
        return "warn", "available, but no current pick", "Target an enemy and run the check again."
    end
    return "ok", "current pick: " .. name(pick)
end)

add("Rotation list", function()
    local list = BRAT.Safe(C_AssistedCombat and C_AssistedCombat.GetRotationSpells)
    if type(list) ~= "table" or #list == 0 then
        return "warn", "Blizzard returned no rotation spells",
            "NEXT can still use data, but Warcraft Logs suggestions can't be limited to your rotation."
    end
    local names = {}
    for i = 1, math.min(6, #list) do names[i] = name(list[i]) end
    return "ok", ("%d spells: %s%s"):format(#list, table.concat(names, ", "), #list > 6 and ", ..." or "")
end)

add("Cooldown info", function()
    local info = select(2, pcall(C_Spell.GetSpellCooldown, 61304))
    if type(info) ~= "table" then return "warn", "couldn't read cooldowns", "NEXT won't skip spells on cooldown." end
    local learned = BRAT.Cooldowns:Describe(3)
    local tail = #learned > 0 and ("; learned: " .. table.concat(learned, "; "))
        or "; no cooldown reductions learned yet (fight a dummy for a minute)"
    if BRAT.IsSecret(info.duration) then
        return "ok", "secret right now (normal in combat), BRAT tracks them from your casts" .. tail
    end
    return "ok", "readable" .. tail
end)

add("Spec", function()
    local spec = BRAT.GetSpecID()
    if spec == 0 then return "bad", "no specialization", "Pick a specialization." end
    local _, specName = GetSpecializationInfo(GetSpecialization())
    return "ok", ("%s (%d)"):format(specName or "?", spec)
end)

add("NEXT source", function()
    local src = BRAT.db.source
    if not src then return "warn", "not chosen yet", "Type /brat and pick a source." end
    local label = BRAT.Stats.LABEL[src]
    return "ok", label .. (BRAT.db.abTest and " (A/B test on: switches each pull)" or "")
end)

-- The three layers of a data source (Sources.lua), same check for both.
local function sourceCheck(key)
    return function()
        local src = BRAT.Sources[key]
        local st = src:Status()
        local inUse = BRAT.ActiveSourceObj() == src
        local function problem(text, fix) return inUse and "bad" or "warn", text, fix end
        if st.rawCount == 0 and not st.avgBuilt then
            return problem("raw cache and averages empty", src.emptyHint)
        end
        if not st.avgBuilt then
            return problem(("raw cache: %s; no averages"):format(st.rawInfo or "?"),
                ("Type /brat averages %s, then /brat rotation %s."):format(key, key))
        end
        if not st.rotBuilt then
            return problem("averages built, no rotation", ("Type /brat rotation %s."):format(key))
        end
        local text = ("raw: %s; averages from %d; rotation: %d bosses, %d dungeons + generic%s"):format(
            st.rawInfo or "none", st.avgFights or 0, st.rotBosses or 0, st.rotDungeons or 0,
            inUse and ("; here: " .. (BRAT.Context:Label() or "?")) or "")
        if st.avgStale or st.rotStale then
            return "warn", text, ("Newer data than the %s: rebuild (/brat averages %s, /brat rotation %s)."):format(
                st.avgStale and "averages" or "rotation", key, key)
        end
        return "ok", text
    end
end

add("Warcraft Logs data", sourceCheck("logs"))
add("Blizzard data", sourceCheck("blizzard"))

add("Target", function()
    local raw = UnitName and select(2, pcall(UnitName, "target"))
    if raw == nil then return "ok", "no target" end
    if BRAT.IsSecret(raw) then return "warn", "target name is hidden by the game", "Dummy detection can't work here." end
    local dummy = BRAT.Context:IsSingleTargetDummy() and " = single-target dummy (counts as 1 target)" or ""
    return "ok", ("%s%s; rotation: %s; NEXT source: %s"):format(tostring(raw), dummy,
        BRAT.Context:Label() or "?", tostring(BRAT.Predict.lastKind or "?"))
end)

add("Enemy count", function()
    if BRAT.db.targets ~= "auto" then return "ok", "fixed at " .. BRAT.db.targets end
    local plates = BRAT.PlateUnits()
    -- Only call nameplates "off" when the setting explicitly says so and none are
    -- on screen: nameplate addons (EllesmereUI, ...) and Midnight's settings
    -- don't always use this setting.
    if #plates == 0 then
        if GetCVar and GetCVar("nameplateShowEnemies") == "0" then
            return "bad", "enemy nameplates are off", "Press V (or Options > Nameplates) so Auto can count enemies."
        end
        return "ok", "auto, no nameplates on screen right now (target a group of enemies and check again)"
    end
    local readable, secret = 0, 0
    for _, unit in ipairs(plates) do
        local ok, v = pcall(UnitCanAttack, "player", unit)
        if ok and BRAT.IsSecret(v) then secret = secret + 1 elseif ok then readable = readable + 1 end
    end
    if secret > 0 and readable == 0 then
        return "bad", "nameplate info is secret", "Auto can't count here; set a fixed count in /brat > Rotations."
    end
    -- Where plates drop out of the count (from the last count, in combat).
    local s = BRAT.countStats
    local why = s and (" (of %d plates: %d hostile, %d in combat, %d fighting you, %d in range)"):format(
        s.plates, s.hostile, s.combat, s.me, s.range) or ""
    return "ok", ("auto, %d nameplates visible, counting %d enemies now%s"):format(#plates,
        BRAT.Predict.enemies or BRAT.Predict.realTargets or 1, why)
end)

add("Keybinds", function()
    local list = BRAT.Safe(C_AssistedCombat and C_AssistedCombat.GetRotationSpells)
    if type(list) ~= "table" or #list == 0 then return "warn", "no rotation list to check" end
    local found, missing = 0, {}
    for _, id in ipairs(list) do
        if BRAT.Display:GetKey(id) ~= "" then found = found + 1 else missing[#missing + 1] = name(id) end
    end
    if found == 0 then
        return "warn", "none found on action bars",
            "Icons work but won't show keys. Bars from other addons (ElvUI, Bartender) aren't read yet."
    end
    if #missing > 0 then
        return "warn", ("%d of %d found; missing: %s"):format(found, #list, table.concat(missing, ", ")),
            "Put those spells on a bound action bar slot to see their keys."
    end
    return "ok", ("all %d rotation spells have a key"):format(#list)
end)

add("Damage meter", function()
    if not C_DamageMeter or not C_DamageMeter.GetCombatSessionFromType then
        return "bad", "C_DamageMeter API missing", "DPS per source can't be recorded (parses still work)."
    end
    local spec, last = BRAT.GetSpecID(), nil
    for _, f in ipairs(BRAT.Stats:Fights(spec)) do last = f end
    if not last then
        return "warn", "no fight recorded yet",
            "Fight something for 20+ seconds, then check again. If it stays empty, tell Claude: reading the meter failed."
    end
    return "ok", ("%d fights recorded, last: %d DPS over %ds"):format(#BRAT.Stats:Fights(spec), last.dps, last.dur)
end)

add("Your parses", function()
    local _, ps = BRAT.Stats:Winner(BRAT.GetSpecID())
    local p = { logs = ps.raw.logs, blizzard = ps.raw.blizzard }
    local n = p.logs.n + p.blizzard.n
    if n == 0 then
        return "warn", "none yet", "After a raid: upload logs, /reload, run tools\\Fetch-MyParses.ps1, /reload."
    end
    return "ok", ("%d with Warcraft Logs, %d with Learn from Blizzard"):format(p.logs.n, p.blizzard.n)
end)

add("Settings panel", function()
    if not BRAT.Options:IsRegistered() then
        return "bad", "not registered in the game menu", "Use the slash commands (/brat help) and tell Claude."
    end
    return "ok", "Esc > Options > AddOns > BRAT"
end)

-- Runs every check; a check that errors is reported as a failure, not a crash.
function Check:RunAll()
    local results = {}
    for _, c in ipairs(checks) do
        local ok, status, text, fix = pcall(c.fn)
        if not ok then status, text, fix = "bad", "check errored: " .. tostring(status), "Paste this line to Claude." end
        results[#results + 1] = { label = c.label, status = status, text = text, fix = fix }
    end
    return results
end

function Check:Print()
    local icon = { ok = OK, warn = WARN, bad = BAD }
    print("|cff66ccffBRAT check|r")
    for _, r in ipairs(self:RunAll()) do
        print(("%s |cffffd100%s|r: %s"):format(icon[r.status] or WARN, r.label, r.text or ""))
        if r.fix and r.status ~= "ok" then print("      |cff999999" .. r.fix .. "|r") end
    end
end

-- At login: stay quiet unless something is actually broken; then say what's
-- wrong and how to fix it right here (no second command needed).
function Check:LoginNotice()
    local bad = {}
    for _, r in ipairs(self:RunAll()) do if r.status == "bad" then bad[#bad + 1] = r end end
    if #bad == 0 then return end
    print(("|cff66ccffBRAT|r: %d problem%s found:"):format(#bad, #bad == 1 and "" or "s"))
    for _, r in ipairs(bad) do
        print(("%s |cffffd100%s|r: %s"):format(BAD, r.label, r.text or ""))
        if r.fix then print("      |cff999999Fix: " .. r.fix .. "|r") end
    end
    print("      |cff999999(/brat check lists every check, including the ones that pass.)|r")
end
