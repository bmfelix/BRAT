-- Loads BRAT's real SpecRules.lua + Cooldowns.lua with stubbed WoW APIs and
-- checks the Fire Breath timer through Mass Disintegrate / Pyre sequences and
-- the tier 4-piece detection (read from item tooltips).
local root = arg[1] or (((arg[0] or ""):match("^(.*)[/\\]") or ".") .. "/..")
local now = 100
function GetTime() return now end
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
local frames = {}
function CreateFrame()
    local f = { ev = {} }
    function f:RegisterEvent(e) self.ev[e] = true end
    function f:RegisterUnitEvent(e) self.ev[e] = true end
    function f:SetScript(_, fn) self.fn = fn end
    frames[#frames + 1] = f
    return f
end
local function fire(e, ...) for _, f in ipairs(frames) do if f.ev[e] and f.fn then f.fn(f, e, ...) end end end
function UnitAffectingCombat() return true end
C_Timer = { After = function() end }
local known = { [375777] = true, [433874] = true, [436335] = true } -- Causality, Scalecommander
function IsPlayerSpell(id) return known[id] == true end
function GetSpellBaseCooldown() return 0 end
C_Spell = {
    GetBaseSpell = function(id) return id end,
    GetOverrideSpell = function(id) return id end,
    GetSpellCooldown = function() return nil end, -- secret in combat: BRAT's own timer
    GetSpellCharges = function() return nil end,
    GetSpellName = function(id) return id == 375777 and "Causality" or tostring(id) end,
}

-- Tooltips. GREEN = active set bonus, GRAY = needs more pieces.
local GREEN, GRAY, WHITE = { r = 0.1, g = 1, b = 0.1 }, { r = 0.5, g = 0.5, b = 0.5 }, { r = 1, g = 1, b = 1 }
local S2_2PC = "(2) Set: Shattering Star deals 50% increased damage and always casts at maximum empower level."
local S2_4PC = "(4) Set: Causality reduces the remaining cooldown of your Empower spells by an additional 0.1 sec each time it triggers."
local S1_4PC = "(4) Set: Fire Breath deals 20% increased damage." -- an older set: no Causality
local gearTip -- function(slot) -> tooltip data
function GetInventoryItemLink(_, slot) return gearTip and ("item:" .. slot) or nil end -- equipped while a tooltip is set
C_TooltipInfo = { GetInventoryItem = function(_, slot) return gearTip and gearTip(slot) or nil end }
local function wearing(pieces, fourPcText)
    return function(slot)
        return { lines = {
            { leftText = "Some Tier Helm", leftColor = WHITE },
            { leftText = S2_2PC, leftColor = pieces >= 2 and GREEN or GRAY },
            { leftText = fourPcText, leftColor = pieces >= 4 and GREEN or GRAY },
        } }
    end
end

-- The real Core.lua (secret-safe helpers, BRAT.SetBonus), with UI globals stubbed.
StaticPopupDialogs, SlashCmdList = {}, {}
local BRAT = {}
assert(loadfile(root .. "/Core.lua"))("BRAT", BRAT)
BRAT.db = { cds = {} }
BRAT.GetSpecID = function() return 1467 end
BRAT.Procs = { IsGlowing = function() return false end }
BRAT.Predict = { enemies = 5, freeCasts = {}, FreeLeft = function() return 0 end, Unspent = function() return nil end }
assert(loadfile(root .. "/Data/SpecRules.lua"))("BRAT", BRAT)
assert(loadfile(root .. "/Cooldowns.lua"))("BRAT", BRAT)
local CD = BRAT.Cooldowns
local FB, ES, DIS, PYRE = 357208, 359073, 356995, 357211
BRAT.db.cds[FB] = { len = 30 }; BRAT.db.cds[ES] = { len = 30 }

-- Same order as Core's UNIT_SPELLCAST_SUCCEEDED handler.
local function cast(id) CD:OnCast(id); BRAT.Rules().onCast(id) end
local fails = 0
local function check(label, got, want)
    local ok = math.abs(got - want) < 0.01
    if not ok then fails = fails + 1 end
    print(("%s %-62s got %6.2f want %6.2f"):format(ok and "ok  " or "FAIL", label, got, want))
end
local function scenario(tip, enemies)
    CD:Clear(); fire("PLAYER_REGEN_ENABLED"); now = now + 100
    gearTip = tip
    fire("PLAYER_EQUIPMENT_CHANGED")
    BRAT.Predict.enemies = enemies
end
-- Seconds one (Mass) Disintegrate takes off Fire Breath under the current gear.
local function massDisReduction()
    cast(FB); cast(ES); cast(DIS)
    return 30 - CD:Remaining(FB)
end

-- Full AoE sequence, Season 2 4-piece.
scenario(wearing(4, S2_4PC), 5)
cast(FB); now = now + 1.5
cast(ES); now = now + 1.5
check("S2 4pc, 5 tg: FB 3s after cast", CD:Remaining(FB), 27)
cast(DIS); now = now + 3
check("S2 4pc, 5 tg: + Mass Disintegrate (2.4*1.25 = 3.0)", CD:Remaining(FB), 27 - 3 - 3.0)
cast(DIS); now = now + 3
check("S2 4pc, 5 tg: + 2nd Mass Disintegrate (3.0)", CD:Remaining(FB), 21 - 3 - 3.0)
cast(DIS); now = now + 3
check("S2 4pc, 5 tg: + plain Disintegrate (2.4)", CD:Remaining(FB), 15 - 3 - 2.4)
cast(PYRE); now = now + 1.5
check("S2 4pc, 5 tg: + Pyre (0.5*5 capped at 2)", CD:Remaining(FB), 9.6 - 1.5 - 2)

-- Single target, no set: Mass Disintegrate hits 1 target.
scenario(nil, 1)
cast(FB); now = now + 1.5
cast(DIS); now = now + 3
check("no set, 1 tg: Mass Disintegrate on 1 target (2.0)", CD:Remaining(FB), 30 - 4.5 - 2.0)
cast(PYRE); now = now + 1.5
check("no set, 1 tg: + Pyre (0.4)", CD:Remaining(FB), 23.5 - 1.5 - 0.4)

-- The point of this change: which gear gets the bonus.
scenario(wearing(4, S1_4PC), 5)
check("Season 1 set, 4 pieces: NO Causality bonus (2.5)", massDisReduction(), 2.5)
scenario(wearing(3, S2_4PC), 5)
check("Season 2 set, 3 pieces (4pc line gray): no bonus (2.5)", massDisReduction(), 2.5)
scenario(wearing(5, S2_4PC), 5)
check("Season 2 set, 5 pieces: bonus (3.0)", massDisReduction(), 3.0)

-- Tooltips not readable yet -> safe side, then picked up after the retry delay.
scenario(function() return nil end, 5)
check("tooltips not readable: no bonus (2.5)", massDisReduction(), 2.5)
gearTip = wearing(4, S2_4PC)
now = now + 1
check("readable 1s later: still waiting for retry (2.5)", (function() CD:Clear() return massDisReduction() end)(), 2.5)
now = now + 2
check("readable after 2s retry: bonus (3.0)", (function() CD:Clear() return massDisReduction() end)(), 3.0)

-- Gear change from S2 4pc to an S1 set must drop the bonus.
scenario(wearing(4, S2_4PC), 5)
check("before swap: bonus (3.0)", massDisReduction(), 3.0)
gearTip = wearing(4, S1_4PC); fire("PLAYER_EQUIPMENT_CHANGED"); CD:Clear()
check("after swapping to the Season 1 set: no bonus (2.5)", massDisReduction(), 2.5)

-- Blizzard's pick: stale right after the cast, proof later.
scenario(wearing(4, S2_4PC), 5)
cast(FB); now = now + 2
CD:OnPicked(FB)
check("Blizzard picks FB 2s after cast: ignored (stale)", CD:Remaining(FB), 28)
now = now + 6
CD:OnPicked(FB)
check("Blizzard picks FB 8s after cast: timer says ready", CD:Remaining(FB), 0)


-- Shared helper: 2-piece and 4-piece answers are kept apart.
local SS = 370452 -- Shattering Star
C_Spell.GetSpellName = function(id)
    return (id == 375777 and "Causality") or (id == SS and "Shattering Star") or tostring(id)
end
scenario(wearing(2, S2_4PC), 5)
check("2 pieces: SetBonus(2, Shattering Star) = true", BRAT.SetBonus(2, SS) and 1 or 0, 1)
check("2 pieces: SetBonus(4, Causality) = false", BRAT.SetBonus(4, 375777) == false and 1 or 0, 1)
check("2 pieces: SetBonus(4, Shattering Star) = false (2pc line not 4)", BRAT.SetBonus(4, SS) == false and 1 or 0, 1)
check("2 pieces: one active bonus listed (deduped across 5 items)", #BRAT.SetBonuses(), 1)
scenario(wearing(4, S2_4PC), 5)
check("4 pieces: two active bonuses listed", #BRAT.SetBonuses(), 2)
-- No flicker: item info arriving marks it stale, but the old answer stands
-- until a re-read succeeds (tooltips hidden in combat).
gearTip = function() return nil end
fire("GET_ITEM_INFO_RECEIVED")
now = now + 3
check("tooltips hidden after item info event: keeps last answer", BRAT.SetBonus(4, 375777) and 1 or 0, 1)
-- Taking the set off (empty slots) drops the bonus.
scenario(wearing(4, S2_4PC), 5)
check("wearing S2 4pc: bonus", BRAT.SetBonus(4, 375777) and 1 or 0, 1)
gearTip = nil; fire("PLAYER_EQUIPMENT_CHANGED")
check("all tier slots emptied: no bonus (false, not unknown)", BRAT.SetBonus(4, 375777) == false and 1 or 0, 1)
print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
