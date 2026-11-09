-- Priest tier set rules: loads BRAT's real Core, SpecRules, Cooldowns and
-- Predict with stubbed WoW APIs (tooltips stand in for gear).
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
StaticPopupDialogs, SlashCmdList = {}, {}
function IsPlayerSpell() return true end
function GetSpellBaseCooldown(id) return id == 1227280 and 20000 or 0 end -- base ignores set bonuses
local NAMES = { [47540] = "Penance", [8092] = "Mind Blast", [1227280] = "Tentacle Slam",
    [1242173] = "Void Volley", [34914] = "Vampiric Touch" }
C_Spell = {
    GetBaseSpell = function(id) return id end,
    GetOverrideSpell = function(id) return id end,
    GetSpellCooldown = function() return nil end,
    GetSpellCharges = function() return nil end,
    GetSpellName = function(id) return NAMES[id] or tostring(id) end,
    IsSpellUsable = function() return true end,
    GetSpellInfo = function() return nil end,
}
local GREEN, GRAY = { r = 0.1, g = 1, b = 0.1 }, { r = 0.5, g = 0.5, b = 0.5 }
local gearTip
function GetInventoryItemLink(_, slot) return gearTip and ("item:" .. slot) or nil end
C_TooltipInfo = { GetInventoryItem = function(_, slot) return gearTip and gearTip(slot) or nil end }
local function wearing(pieces, two, four)
    return function() return { lines = {
        { leftText = two, leftColor = pieces >= 2 and GREEN or GRAY },
        { leftText = four, leftColor = pieces >= 4 and GREEN or GRAY },
    } } end
end
local DISC2 = "(2) Set: Penance damage and healing increased by 20%. Casting Penance reduces the cooldown of Mind Blast by 2.0 sec."
local DISC4 = "(4) Set: After casting Mind Blast, your next Power Word: Shield or Void Shield absorbs 25% more damage."
local SHADOW2 = "(2) Set: Tentacle Slam cooldown is reduced by 3 sec and its damage is increased by 100%."
local SHADOW4_VV = "(4) Set: Tentacle Slam grants a free cast of Void Volley at full effectiveness."
local SHADOW4_VT = "(4) Set: After casting Tentacle Slam, your next Vampiric Touch is instant and conjures Shadowy Apparitions."
local OLD_SET2 = "(2) Set: Mind Flay damage increased by 10%."

local BRAT = {}
assert(loadfile(root .. "/Core.lua"))("BRAT", BRAT)
BRAT.db = { cds = {}, minSamples = 3 }
local spec = 256
BRAT.GetSpecID = function() return spec end
BRAT.Procs = { IsGlowing = function() return false end }
assert(loadfile(root .. "/Data/SpecRules.lua"))("BRAT", BRAT)
assert(loadfile(root .. "/Cooldowns.lua"))("BRAT", BRAT)
assert(loadfile(root .. "/Predict.lua"))("BRAT", BRAT)
local CD, P = BRAT.Cooldowns, BRAT.Predict
P.enemies = 1

local fails = 0
local function check(label, got, want)
    if type(got) == "boolean" then got = got and 1 or 0 end
    if type(want) == "boolean" then want = want and 1 or 0 end
    local ok = math.abs(got - want) < 0.01
    if not ok then fails = fails + 1 end
    print(("%s %-66s got %6.2f want %6.2f"):format(ok and "ok  " or "FAIL", label, got, want))
end
local function setup(s, tip)
    spec = s; CD:Clear(); now = now + 100
    gearTip = tip; fire("PLAYER_EQUIPMENT_CHANGED"); fire("PLAYER_REGEN_ENABLED")
end
local MB, PEN, TS, VV = 8092, 47540, 1227280, 1242173
BRAT.db.cds[MB] = { len = 24 }

-- Discipline 2-piece: Penance -> Mind Blast -2s.
setup(256, wearing(2, DISC2, DISC4))
CD:OnCast(MB); now = now + 2; CD:OnCast(PEN); now = now + 2; CD:OnCast(PEN)
check("Disc 2pc: Mind Blast after 4s and 2 Penances (24-4-4)", CD:Remaining(MB), 16)
setup(256, nil)
CD:OnCast(MB); now = now + 2; CD:OnCast(PEN); now = now + 2; CD:OnCast(PEN)
check("Disc no set: Penance doesn't touch Mind Blast (24-4)", CD:Remaining(MB), 20)
setup(256, wearing(4, OLD_SET2, DISC4))
CD:OnCast(MB); now = now + 2; CD:OnCast(PEN)
check("Disc, other set's 2pc active: no reduction (24-2)", CD:Remaining(MB), 22)

-- Shadow 2-piece: Tentacle Slam 17s (overrides the base 20s the game reports).
setup(258, wearing(2, SHADOW2, SHADOW4_VV))
check("Shadow 2pc: Tentacle Slam length 17", CD:Length(TS), 17)
setup(258, nil)
check("Shadow no set: Tentacle Slam length 20", CD:Length(TS), 20)
setup(258, wearing(4, SHADOW2, SHADOW4_VV))
CD:OnCast(TS); now = now + 5
check("Shadow 2pc: timer uses 17s (17-5)", CD:Remaining(TS), 12)

-- Shadow 4-piece: Tentacle Slam -> free Void Volley, only for the Void Volley version.
setup(258, wearing(4, SHADOW2, SHADOW4_VV))
check("Shadow 4pc (Void Volley version): known proc", P:HasKnownProc(VV), true)
check("  NOW = Tentacle Slam -> NEXT Void Volley is free", (P:IsFree(VV, TS)), true)
P:OnPlayerCast(TS)
check("  after casting Tentacle Slam: 1 free Void Volley", P:FreeLeft(VV), 1)
P:OnPlayerCast(VV)
check("  after casting it: used up", P:FreeLeft(VV), 0)
setup(258, wearing(4, SHADOW2, SHADOW4_VT))
check("Shadow 4pc (Vampiric Touch preview version): no Void Volley proc", P:HasKnownProc(VV), false)
check("  NOW = Tentacle Slam -> Void Volley not free", (P:IsFree(VV, TS)), false)
setup(258, wearing(3, SHADOW2, SHADOW4_VV))
check("Shadow 3 pieces: no Void Volley proc", P:HasKnownProc(VV), false)

-- Holy: no set rule (its set is healing only); nothing changes.
setup(257, wearing(4, "(2) Set: Renew grants 2% critical strike.", "(4) Set: Renew healing increased by 10%."))
check("Holy: rules have no set-bonus procs", #BRAT.Rules().procs, 1) -- just Empyreal Blaze

check("Holy: Empyreal Blaze (talent-only proc) still works via RuleOn", P:HasKnownProc(14914), true)
P:OnPlayerCast(88625)
check("  Chastise -> 2 free Holy Fires", P:FreeLeft(14914), 2)
print(fails == 0 and "ALL PASSED" or (fails .. " FAILED"))
os.exit(fails == 0 and 0 or 1)
