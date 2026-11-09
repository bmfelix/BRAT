-- BRAT core: saved variables, secret-safe helpers, events, slash commands.
local ADDON, BRAT = ...
_G.BRAT = BRAT

local DEFAULTS = {
    locked = false,
    scale = 1.0,
    keySize = 14,           -- keybind text size on the icons (8-32)
    nextCount = 1,          -- upcoming spells shown after NOW: 0, 1 (NEXT) or 2 (NEXT + THEN)
    soonSeconds = 3,        -- SOON heads-up: warn this many seconds before a better spell is ready (0 = off)
    point = { "CENTER", "UIParent", "CENTER", 0, -180 },
    showOutOfCombat = true, -- show when you have an attackable target
    minSamples = 3,         -- learned follow-ups need this many sightings
    source = "logs",        -- "logs" (default) | "blizzard": only if chosen in settings / /brat source
    targets = "auto",       -- "auto" or a forced enemy count "1".."8"
    remap = {},             -- [specID][enemyCount] = rotation bucket to use instead
    abTest = false,         -- alternate NEXT source each fight to compare DPS
    acc = {},               -- [specID][source] prediction accuracy (Stats.lua)
    fights = {},            -- one encoded string per fight (Stats.lua)
    resetAt = {},           -- [specID] = server time of last comparison reset
    recordHistory = true,   -- keep a full record of every fight (History.lua)
    history = {},           -- one string per event, read by tools\Analyze-History.ps1
    spellNames = {},        -- [spellID] = name, so the analyzer can print names
    runs = {},              -- one summary per analysis run, for the trend (Report.lua)
    priority = {},          -- [specID][targets][spellID] = {w, g}: Blizzard's priority from the last analysis
    procs = {},             -- [specID][spellID] = {seen, used}: glowing spell picked next? (Procs.lua)
    hidden = {},            -- [specID][spellID] = true: never recommend (/brat hide)
    -- Blizzard data (Learn.lua): the cache is what Blizzard picked during your
    -- fights (written when combat ends); the rotation is built from the cache.
    bcache = {},            -- [specID] = { fight records }  (Blizzard layer 1: raw cache)
    -- Layers 2 and 3 for both sources (Sources.lua). The Warcraft Logs raw cache
    -- ships inside the addon (Data\WCLRaw.lua).
    avg = { logs = {}, blizzard = {} },  -- [source][specID] = averages
    rot = { logs = {}, blizzard = {} },  -- [source][specID] = served rotation
    cds = {},               -- [spellID] = cooldown length/charges/learned gap (Cooldowns.lua)
    -- Old (pre-cache) learning, converted into the Blizzard cache on load:
    prio = {},              -- [specID][targets][spellID] = {w, g}
    learnVersion = 2,
    learn = {},             -- [specID][targets][fromSpell][toSpell] = count
}

BRAT.MAX_TARGETS = 8 -- bucket 8 means "8 or more"

---------------------------------------------------------------------------
-- Secret-value-safe helpers. In Midnight, some combat data is "secret":
-- we may pass it to widgets but can't compare or branch on it.
---------------------------------------------------------------------------
local issecretvalue = _G.issecretvalue

function BRAT.IsSecret(v)
    return issecretvalue ~= nil and issecretvalue(v) or false
end

-- Returns a plain value, or nil if the call failed or the value is secret.
function BRAT.Safe(fn, ...)
    if not fn then return nil end
    local ok, a, b = pcall(fn, ...)
    if not ok or BRAT.IsSecret(a) then return nil end
    return a, (not BRAT.IsSecret(b)) and b or nil
end

function BRAT.GetSpecID()
    local idx = GetSpecialization and GetSpecialization()
    if not idx then return 0 end
    return (GetSpecializationInfo(idx)) or 0
end

-- Uses the game's cooldown when readable; in combat (secret) it falls back to
-- BRAT's own tracking from your casts (Cooldowns.lua).
function BRAT.IsReadySoon(spellID, window)
    window = window or 1.5
    -- DoTs (Shadow Word: Pain) are "ready" when due for a refresh: BRAT's timer.
    if BRAT.Cooldowns:IsDot(spellID) then return BRAT.Cooldowns:Remaining(spellID) <= window end
    local info = BRAT.Safe(C_Spell.GetSpellCooldown, spellID)
    local start, dur, onGCD
    if info then start, dur, onGCD = info.startTime, info.duration, info.isOnGCD end
    if not info or BRAT.IsSecret(start) or BRAT.IsSecret(dur) or BRAT.IsSecret(onGCD) then
        return BRAT.Cooldowns:Remaining(spellID) <= window
    end
    if onGCD or not dur or dur == 0 then return true end
    return (start + dur - GetTime()) <= window
end

-- Never recommend this spell (spec rules: never), under any of its IDs.
-- Also spells you hid yourself (/brat hide), per spec.
function BRAT.Never(spellID)
    if not spellID then return false end
    local key = BRAT.Cooldowns:Key(spellID)
    local h = BRAT.db and BRAT.db.hidden and BRAT.db.hidden[BRAT.GetSpecID()]
    if h and (h[spellID] or h[key]) then return true end
    local rules = BRAT.Rules()
    -- Can't be cast right now (spec rules: available), e.g. Unbound Flame out of uses.
    local av = rules.available and (rules.available[key] or rules.available[spellID])
    if av and not av() then return true end
    local n = rules.never
    if not n then return false end
    return n[spellID] or n[key] or false
end

-- Is this a spell the player actually has? (Logs data can include talents you skipped.)
function BRAT.Knows(spellID)
    local known = BRAT.Safe(IsPlayerSpell, spellID)
    if known == nil then return true end
    return known
end

-- Is this unit a training dummy? If the game hides its name, a nameplate next to
-- the dummy you're targeting counts as one too (they stand in a group).
function BRAT.IsDummyUnit(unit)
    local name = BRAT.Safe(UnitName, unit)
    if type(name) ~= "string" then return BRAT.Context ~= nil and BRAT.Context:IsDummy() end
    return name:lower():find("dummy", 1, true) ~= nil
end

-- Is this enemy fighting *you* (not just in combat with someone nearby)?
-- True if it's your target or you're on its threat list. If the game hides
-- threat (secret value), it counts, as before.
function BRAT.FightingMe(unit)
    if BRAT.Safe(UnitIsUnit, unit, "target") then return true end
    -- Training dummies keep no threat list: one in combat counts (else a pack of
    -- dummies reads as 1 target).
    if BRAT.IsDummyUnit(unit) then return true end
    local ok, threat = pcall(UnitThreatSituation, "player", unit)
    if not ok or BRAT.IsSecret(threat) then return true end
    return threat ~= nil
end

-- Unit IDs of every nameplate on screen ("nameplate1".."nameplate40"). Read
-- from the unit IDs themselves, not plate frame fields: those changed in
-- Midnight (unitToken), and nameplate addons (MF Nameplates, EllesmereUI)
-- replace the Blizzard frame that held the unit.
local MAX_PLATES = 40
function BRAT.PlateUnits()
    local out = {}
    for i = 1, MAX_PLATES do
        local unit = "nameplate" .. i
        if BRAT.Safe(UnitExists, unit) then out[#out + 1] = unit end
    end
    return out
end

-- How many enemies are we fighting? Counts hostile, in-combat enemy
-- nameplates that are in range of `probeSpell` (when range is readable).
-- Needs enemy nameplates turned on. Throttled; returns 1..MAX_TARGETS.
local countCache, countTime, warnedUnknown = 1, 0, false
function BRAT.EnemyCount(probeSpell)
    local forced = tonumber(BRAT.db.targets)
    if forced then return math.max(1, math.min(BRAT.MAX_TARGETS, forced)) end
    -- A single-target training dummy is a single-target boss, whatever stands nearby.
    if BRAT.Context and BRAT.Context:IsSingleTargetDummy() then return 1 end

    local now = GetTime()
    if now - countTime < 0.25 then return countCache end
    countTime = now

    local n, unknown = 0, false
    -- Training dummies don't act like mobs (the game can call them out of
    -- combat while you hit them, and they keep no threat): when you're on a
    -- dummy, every dummy plate in range counts.
    local onDummy = BRAT.Context and BRAT.Context:IsDummy()
    local stats = { plates = 0, hostile = 0, combat = 0, me = 0, range = 0 }
    for _, unit in ipairs(BRAT.PlateUnits()) do
        stats.plates = stats.plates + 1
        -- Midnight may hide either answer (secret value = nil here). A hidden
        -- answer isn't a "no": skip only units known to be friendly or out of
        -- combat, and count the rest that are fighting you and in range.
        local hostile = BRAT.Safe(UnitCanAttack, "player", unit)
        local fighting = BRAT.Safe(UnitAffectingCombat, unit)
        local dummy = onDummy and BRAT.IsDummyUnit(unit)
        if hostile ~= false then stats.hostile = stats.hostile + 1 end
        if fighting ~= false or dummy then stats.combat = stats.combat + 1 end
        if hostile == nil and fighting == nil and not dummy then
            unknown = true
        elseif hostile ~= false and (dummy or (fighting ~= false and BRAT.FightingMe(unit))) then
            stats.me = stats.me + 1
            local inRange = probeSpell and BRAT.Safe(C_Spell.IsSpellInRange, probeSpell, unit)
            if inRange ~= false then n = n + 1; stats.range = stats.range + 1 end
        end
    end
    BRAT.countStats = stats -- for /brat check

    if n == 0 and unknown and not warnedUnknown and UnitAffectingCombat("player") then
        warnedUnknown = true
        print("|cff66ccffBRAT|r: can't read enemy nameplates in combat, assuming 1 target. Use /brat targets <n> to set it.")
    end
    countCache = math.max(1, math.min(BRAT.MAX_TARGETS, n))
    return countCache
end

-- Info about the Warcraft Logs data shipped with this addon version for a spec
-- (Data\WCLRaw.lua): { built, date, players, cap, zone, ranks }, or nil.
function BRAT.WCLInfo(spec)
    local r = BRAT.WCLRaw and BRAT.WCLRaw[spec or BRAT.GetSpecID()]
    return r and r.info
end

-- Rotation cap for the current spec (from Warcraft Logs data), else MAX_TARGETS.
function BRAT.GetCap()
    local info = BRAT.WCLInfo()
    return (info and info.cap) or BRAT.MAX_TARGETS
end

-- Which rotation bucket to use when fighting `count` enemies (user remap).
function BRAT.GetRemap(count)
    local cap = BRAT.GetCap()
    count = math.min(count, cap)
    local m = BRAT.db.remap[BRAT.GetSpecID()]
    local b = m and m[count]
    return (b and math.min(b, cap)) or count
end

function BRAT.SetRemap(count, bucket)
    local spec = BRAT.GetSpecID()
    BRAT.db.remap[spec] = BRAT.db.remap[spec] or {}
    BRAT.db.remap[spec][count] = (bucket ~= count) and bucket or nil
end

-- Is the buff this spell applies already on you? (e.g. Power Word: Fortitude)
-- Aura data can be secret in combat, so remember the last readable answer.
local buffKnown = {}
function BRAT.HasOwnBuff(spellID)
    if not (C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID) then return false end
    local ok, aura = pcall(C_UnitAuras.GetPlayerAuraBySpellID, spellID)
    if ok and not BRAT.IsSecret(aura) then
        buffKnown[spellID] = aura ~= nil
    end
    return buffKnown[spellID] == true
end

-- Your global cooldown in seconds, from haste (1.5s base, never under 0.75s).
function BRAT.GCD()
    local haste = BRAT.Safe(UnitSpellHaste, "player")
    if type(haste) ~= "number" then haste = 0 end
    return math.max(0.75, 1.5 / (1 + haste / 100))
end

-- Cast time in seconds (0 = instant or unknown).
function BRAT.CastTime(spellID)
    local info = BRAT.Safe(C_Spell.GetSpellInfo, spellID)
    local ms = info and info.castTime
    if type(ms) ~= "number" or BRAT.IsSecret(ms) then return 0 end
    return ms / 1000
end

-- Are you moving (so cast-time spells can't be cast)?
function BRAT.IsMoving()
    local speed = BRAT.Safe(GetUnitSpeed, "player")
    return type(speed) == "number" and speed > 0
end

-- Can't be cast while moving? Cast-time spells (unless a proc makes them
-- instant: `free`), and spells the spec rules mark as needing you to stand
-- still even though the game reports no cast time: channels and empowered
-- spells (Evoker: Disintegrate, Fire Breath, Eternity Surge). A spec's
-- "cast while moving" buff (Evoker: Hover) lifts it.
function BRAT.MustStand(spellID, free)
    local rules = BRAT.Rules()
    if rules.moveBuff and BRAT.HasOwnBuff(rules.moveBuff) then return false end
    if rules.stationary and rules.stationary[BRAT.Cooldowns:Key(spellID)] then return true end
    return BRAT.CastTime(spellID) > 0 and not free
end

---------------------------------------------------------------------------
-- Tier set bonuses, for any spec. Read from your gear's tooltips: each
-- tier-slot item lists its set's bonuses, "(2) Set: ..." / "(4) Set: ...",
-- active ones in green, the rest gray. Reading the bonus itself (not counting
-- set pieces or hard-coding set IDs) means an older season's set never passes
-- for this one's, and it keeps working next season. Spec rules ask with
-- BRAT.SetBonus(pieces, spellID): is the active N-piece bonus about that spell?
---------------------------------------------------------------------------
local TIER_SLOTS = { 1, 3, 5, 7, 10 } -- head, shoulders, chest, legs, hands
local bonusList            -- last read: { {pieces, text}, ... } (active only)
local bonusStale = true    -- gear or item info changed since it was read
local bonusTry = -math.huge
local RETRY = 2            -- seconds between reads (it's asked very often)

local function activeLine(line)
    local c = line.leftColor
    if type(c) ~= "table" or BRAT.IsSecret(c.r) or BRAT.IsSecret(c.g) then return false end
    return type(c.r) == "number" and type(c.g) == "number" and c.g > 0.8 and c.r < 0.5
end

-- Active set bonuses: { {pieces = 2, text = "(2) Set: ..."}, ... }, or nil if
-- your gear can't be read yet. A stale list is kept until a new read works
-- (in combat tooltips may be hidden), so answers don't flicker.
function BRAT.SetBonuses()
    local now = GetTime()
    if bonusList and not bonusStale then return bonusList end
    if now - bonusTry < RETRY then return bonusList end
    bonusTry = now
    if not (C_TooltipInfo and C_TooltipInfo.GetInventoryItem) then return bonusList end
    local out, seen, readAny = {}, {}, false
    for _, slot in ipairs(TIER_SLOTS) do
        -- An empty slot is known (nothing there), not "unreadable".
        local data = GetInventoryItemLink("player", slot) == nil and { lines = {} }
            or BRAT.Safe(C_TooltipInfo.GetInventoryItem, "player", slot)
        if type(data) == "table" and type(data.lines) == "table" then
            readAny = true
            for _, line in ipairs(data.lines) do
                local t = line.leftText
                if type(t) == "string" and not BRAT.IsSecret(t) then
                    local n = tonumber(t:match("^%((%d)%)"))
                    -- Every set piece lists the same bonuses: keep each once.
                    if n and not seen[t] and activeLine(line) then
                        seen[t] = true
                        out[#out + 1] = { pieces = n, text = t }
                    end
                end
            end
        end
    end
    if readAny then bonusList, bonusStale = out, false end
    return bonusList
end

-- Is your active `pieces`-piece set bonus (2 or 4, exactly: the 2-piece line
-- never answers for the 4-piece) about this spell (named in its text)?
-- true / false, or nil = gear not readable yet (treat as no bonus).
-- The spell name comes from the game, so any client language works.
function BRAT.SetBonus(pieces, spellID)
    local list = BRAT.SetBonuses()
    if not list then return nil end
    local name = BRAT.Safe(C_Spell.GetSpellName, spellID)
    if type(name) ~= "string" then return nil end
    for _, b in ipairs(list) do
        if b.pieces == pieces and b.text:find(name, 1, true) then return true end
    end
    return false
end

-- Does a spec-rule entry (a reduction or proc) apply right now? Its optional
-- conditions: `talent` = spell ID you must know; `bonus` = { pieces, spellID }:
-- that set bonus must be active (unreadable gear = no, the safe side).
function BRAT.RuleOn(e)
    if e.talent and not BRAT.Knows(e.talent) then return false end
    if e.bonus and BRAT.SetBonus(e.bonus[1], e.bonus[2]) ~= true then return false end
    return true
end

local bf = CreateFrame("Frame")
bf:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
bf:RegisterEvent("GET_ITEM_INFO_RECEIVED")
bf:SetScript("OnEvent", function(_, event)
    bonusStale = true
    -- Gear changed: the old answer is about other gear. Forget it (no bonus
    -- until the new gear reads: the safe side) and read now. Item info
    -- arriving (fires a lot): keep the answer, re-read within RETRY.
    if event == "PLAYER_EQUIPMENT_CHANGED" then bonusList, bonusTry = nil, -math.huge end
end)

-- Evoker Essence: current, max. nil when the game hides it (secret in combat),
-- so spec rules that use it fall back to learning from Blizzard.
local ESSENCE = (Enum and Enum.PowerType and Enum.PowerType.Essence) or 19
function BRAT.Essence()
    local cur = BRAT.Safe(UnitPower, "player", ESSENCE)
    local max = BRAT.Safe(UnitPowerMax, "player", ESSENCE)
    if type(cur) ~= "number" or type(max) ~= "number" or max == 0 then return nil end
    return cur, max
end

-- Essence you'll have `seconds` from now: current + progress on the next one
-- + regen (1 per 5s, faster with haste), whole points, at most max. Parts the
-- game hides are left out (never more optimistic than the plain count).
function BRAT.EssenceIn(seconds)
    local cur, max = BRAT.Essence()
    if not cur then return nil end
    local partial = BRAT.Safe(UnitPartialPower, "player", ESSENCE)
    local inactive, active = BRAT.Safe(GetPowerRegenForPowerType, ESSENCE) -- per second
    local regen = math.max(tonumber(inactive) or 0, tonumber(active) or 0)
    local e = cur
    if type(partial) == "number" then e = e + partial / 1000 end
    e = e + regen * (seconds or 0)
    return math.min(max, math.floor(e + 0.05)), max
end

-- Essence cost of a spell right now (talents like Imminent Destruction lower
-- it), or `default` if the game won't say.
function BRAT.EssenceCost(spellID, default)
    local costs = BRAT.Safe(C_Spell.GetSpellPowerCost, spellID)
    if type(costs) == "table" then
        for _, c in ipairs(costs) do
            if c.type == ESSENCE and type(c.cost) == "number" and not BRAT.IsSecret(c.cost) then return c.cost end
        end
    end
    return default
end

function BRAT.IsUsable(spellID)
    local usable, noMana = BRAT.Safe(C_Spell.IsSpellUsable, spellID)
    if usable == nil then return true end
    return usable or noMana == true -- out of mana now may be fine next GCD
end

---------------------------------------------------------------------------
-- Source choice (asked once on first load; change with /brat source)
---------------------------------------------------------------------------
local function say(msg) print("|cff66ccffBRAT|r: " .. msg) end

function BRAT.SetSource(src)
    BRAT.db.source = src
    if src == "logs" then
        if BRAT.Sources.logs:HasRotation() then
            say("NOW and NEXT use the Warcraft Logs rotation (top players).")
        else
            say("NOW and NEXT use Warcraft Logs, but there's no Warcraft Logs rotation for this spec yet: "
                .. "NOW shows Blizzard's pick (BRAT settings > Spec data).")
        end
    else
        say("NEXT will learn from Blizzard's assistant.")
    end
end

StaticPopupDialogs["BRAT_CHOOSE_SOURCE"] = {
    text = "|cff66ccffBRAT|r: Where should the NEXT spell come from?\n\n"
        .. "|cffffd100Warcraft Logs|r: what top players cast next (pre-built).\n"
        .. "|cffffd100Learn from Blizzard|r: learns Blizzard's assistant as you play.\n\n"
        .. "You can change this any time: type /brat, or Esc > Options > AddOns > BRAT.",
    button1 = "Warcraft Logs",
    button2 = "Learn from Blizzard",
    OnAccept = function() BRAT.SetSource("logs") end,
    OnCancel = function(_, _, reason)
        if reason == "clicked" then BRAT.SetSource("blizzard") end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = false,
    preferredIndex = 3,
}

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local f = CreateFrame("Frame")
BRAT.eventFrame = f

f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
f:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
f:RegisterEvent("UPDATE_BINDINGS")
f:RegisterEvent("ACTIONBAR_SLOT_CHANGED")

f:SetScript("OnEvent", function(_, event, arg1, _, arg3)
    if event == "ADDON_LOADED" and arg1 == ADDON then
        BRATDB = BRATDB or {}
        if BRATDB.learn and BRATDB.learnVersion ~= DEFAULTS.learnVersion then
            BRATDB.learn = nil -- old format (no target counts); start fresh
            BRATDB.learnVersion = nil
        end
        -- v4 of cooldown learning: drop reductions that drifted (unknown charges).
        if BRATDB.cds and BRATDB.cdsVersion ~= 4 then
            for _, i in pairs(BRATDB.cds) do i.red = nil end
        end
        BRATDB.cdsVersion = 4
        for k, v in pairs(DEFAULTS) do
            if BRATDB[k] == nil then
                BRATDB[k] = type(v) == "table" and CopyTable(v) or v
            end
        end
        BRAT.db = BRATDB
    elseif event == "PLAYER_LOGIN" then
        BRAT.db.lastSpec = BRAT.GetSpecID() -- the PC tools work on this spec only
        BRAT.Learn:Migrate() -- first run: fill the Blizzard cache from the fight log, build the rotation
        BRAT.Sources.CheckOnLogin() -- first use / new Warcraft Logs data shipped with an update
        BRAT.Display:Init()
        BRAT.Options:Build()
        if not BRAT.db.source then StaticPopup_Show("BRAT_CHOOSE_SOURCE") end
        C_Timer.After(5, function() BRAT.Check:LoginNotice() end)
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" and arg1 == "player" then
        -- Automatic casts that aren't button presses (Evoker: Charged Blast, four
        -- per Disintegrate tick) would pass for "the spell you just cast".
        if not BRAT.IsSecret(arg3) and not (BRAT.Rules().ignoreCasts or {})[arg3] then
            BRAT.History:OnCast(arg3) -- before anything changes what's shown
            BRAT.Cooldowns:OnCast(arg3)
            BRAT.Predict:OnPlayerCast(arg3)
            -- Spec state that follows your casts (Evoker: Mass Disintegrate), after
            -- the cooldown tracker so it counted the cast with the state before it.
            local onCast = BRAT.Rules().onCast
            if onCast then onCast(arg3) end
        end
    elseif event == "UPDATE_BINDINGS" or event == "ACTIONBAR_SLOT_CHANGED"
        or event == "PLAYER_SPECIALIZATION_CHANGED" then
        if event == "PLAYER_SPECIALIZATION_CHANGED" then
            BRAT.Cooldowns:Clear()
            local spec = BRAT.GetSpecID()
            if spec ~= 0 then BRAT.db.lastSpec = spec end
        end
        if BRAT.Display.ClearKeyCache then BRAT.Display:ClearKeyCache() end
    end
end)

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
SLASH_BRAT1 = "/brat"
SlashCmdList.BRAT = function(input)
    local cmd, rest = (input or ""):lower():match("^(%S*)%s*(.-)$")
    local db = BRAT.db
    if cmd == "lock" then
        db.locked = true; BRAT.Display:ApplySettings(); say("locked.")
    elseif cmd == "unlock" then
        db.locked = false; BRAT.Display:ApplySettings(); say("unlocked, drag to move.")
    elseif cmd == "scale" and tonumber(rest) then
        db.scale = math.max(0.5, math.min(3, tonumber(rest)))
        BRAT.Display:ApplySettings(); say("scale " .. db.scale)
    elseif cmd == "soon" and tonumber(rest) then
        db.soonSeconds = math.max(0, math.min(10, tonumber(rest)))
        say(db.soonSeconds > 0 and ("SOON warns %.1fs ahead."):format(db.soonSeconds) or "SOON heads-up off.")
    elseif cmd == "next" and tonumber(rest) then
        db.nextCount = math.max(0, math.min(2, math.floor(tonumber(rest))))
        BRAT.Display:ApplySettings(); say("showing " .. db.nextCount .. " upcoming spell(s) after NOW.")
    elseif cmd == "keysize" and tonumber(rest) then
        db.keySize = math.max(8, math.min(32, math.floor(tonumber(rest))))
        BRAT.Display:ApplySettings(); say("keybind text size " .. db.keySize)
    elseif cmd == "reset" then
        db.point = CopyTable(DEFAULTS.point); db.scale = 1
        BRAT.Display:ApplySettings(); say("position reset.")
    elseif cmd == "forget" then
        local spec = BRAT.GetSpecID()
        local b = BRAT.Sources.blizzard
        b:ClearRaw(spec); b:ClearAverages(spec); b:ClearRotation(spec); db.procs[spec] = nil
        say("Blizzard raw cache, averages and rotation cleared for this spec (the raw cache refills as you play).")
    elseif cmd == "averages" or cmd == "rotation" or cmd == "rebuild" then
        -- /brat averages [wcl|blizzard]: raw cache -> averages.
        -- /brat rotation [wcl|blizzard]: averages -> rotation. Default: your source.
        local src = (rest == "wcl" or rest == "logs") and BRAT.Sources.logs
            or (rest == "blizzard" and BRAT.Sources.blizzard) or BRAT.ActiveSourceObj()
        src:Run((cmd == "rebuild") and "averages" or cmd)
    elseif cmd == "analyze" or cmd == "analyse" then
        BRAT.Report:Run(tonumber(rest))
    elseif cmd == "history" then
        if rest == "clear" then
            BRAT.History:Clear(); say("fight history cleared.")
        elseif rest == "off" or rest == "on" then
            db.recordHistory = rest == "on"; say("fight history recording " .. rest .. ".")
        else
            local fights, lines = BRAT.History:Count()
            say(("history: %d fights, %d events recorded (%s). /brat history on|off|clear"):format(
                fights, lines, db.recordHistory and "recording" or "off"))
            say("To analyze: /reload, then run tools\\Analyze-History.ps1 on your PC.")
        end
    elseif cmd == "hide" or cmd == "unhide" then
        -- /brat hide [next]: never recommend the spell in NOW (or NEXT) again.
        -- /brat unhide: show everything again. /brat hide list: what's hidden.
        local spec = BRAT.GetSpecID()
        db.hidden[spec] = db.hidden[spec] or {}
        local h = db.hidden[spec]
        local function nm(id) return C_Spell.GetSpellName(id) or tostring(id) end
        if cmd == "unhide" then
            db.hidden[spec] = {}
            say("hidden spells cleared for this spec: everything can be recommended again.")
        elseif rest == "list" then
            local names = {}
            for id in pairs(h) do names[#names + 1] = nm(id) end
            say(#names > 0 and ("hidden for this spec: " .. table.concat(names, ", ") .. ". /brat unhide to clear.")
                or "nothing hidden for this spec.")
        else
            local id = (rest == "next") and BRAT.Predict.shownNext or BRAT.Predict.shownNow
            if not id then
                say("nothing in " .. (rest == "next" and "NEXT" or "NOW") .. " to hide right now.")
            else
                h[id] = true
                h[BRAT.Cooldowns:Key(id)] = true
                say(nm(id) .. " won't be recommended again on this spec. /brat hide list | /brat unhide")
            end
        end
    elseif cmd == "why" then
        BRAT.Predict:Why(say)
    elseif cmd == "watch" then
        BRAT.Predict.watch = not BRAT.Predict.watch
        BRAT.Predict.watchLast, BRAT.Predict.watchNow = nil, nil
        say(BRAT.Predict.watch and "watch on: a line in chat every time NOW/NEXT changes. /brat watch again to stop."
            or "watch off.")
    elseif cmd == "check" then
        BRAT.Check:Print()
    elseif cmd == "help" then
        say("/brat (settings) | check | why | watch | hide [next] | hide list | unhide | lock | unlock | scale <0.5-3> | keysize <8-32> | next <0-2> | soon <0-10> | analyze [last N fights] | history | averages [wcl|blizzard] | rotation [wcl|blizzard] | reset | stats | forget | source [logs|blizzard] | targets [auto|1-8]")
    elseif cmd == "stats" then
        BRAT.Predict:PrintStats(say)
    elseif cmd == "targets" then
        local n = tonumber(rest)
        if n and n >= 1 then
            db.targets = tostring(math.min(BRAT.MAX_TARGETS, math.floor(n)))
            say("targets forced to " .. db.targets .. ". /brat targets auto to go back.")
        else
            db.targets = "auto"; say("targets: auto (counts enemy nameplates).")
        end
    elseif cmd == "source" then
        if rest == "logs" or rest == "blizzard" then BRAT.SetSource(rest)
        else StaticPopup_Show("BRAT_CHOOSE_SOURCE") end
    elseif cmd == "" or cmd == "config" or cmd == "options" then
        BRAT.Options:Open()
    else
        say("/brat (settings) | lock | unlock | scale <0.5-3> | reset | stats | forget | source [logs|blizzard] | targets [auto|1-8]")
    end
    if BRAT.Options then BRAT.Options:Refresh() end
end
