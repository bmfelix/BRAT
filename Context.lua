-- BRAT context: where you are, and the Warcraft Logs rotation for it.
--   Raid boss                    -> that boss's rotation, else generic single target
--   Raid instance / raid group   -> generic single target
--   Mythic+ / 5-player dungeon   -> that dungeon's rotation, else generic dungeon
--   Party (not in a dungeon)     -> generic dungeon
--   Dungeoneer's Training Dummy  -> generic single target (single-target boss)
--   Cleave Training Dummy        -> generic dungeon (AoE)
--   Solo / anything else         -> generic single target
-- The rotations themselves are built and selected by Sources.lua /
-- RotationBuilder.lua (the same for Blizzard). Within each rotation, the enemy
-- count (nameplates) still picks the target bucket.
local _, BRAT = ...
local Context = {}
BRAT.Context = Context

local encounter -- { id, name } while a boss fight is on
local cached, cachedAt, lastLabel = nil, 0, nil

-- Compared without apostrophes: the game may use a curly one (’) in "Dungeoneer’s".
local DUMMY_SINGLE = "dungeoneers training dummy"
local DUMMY_AOE = "cleave training dummy"

local function lower(s)
    if type(s) ~= "string" then return nil end
    return (s:lower():gsub("\226\128\153", ""):gsub("'", ""))
end
Context.Lower = lower -- dungeon names are matched this way everywhere

-- Where you are (no data needed):
--   "boss", encounterID, name   a raid boss fight
--   "dungeon", name-lowercase   a 5-player / Mythic+ dungeon (bosses included: the whole dungeon)
--   "raid" / "mplus"            raid-like / dungeon-like elsewhere (dummies, groups, solo)
function Context:Where()
    local target = lower(BRAT.Safe(UnitName, "target"))
    if target and target:find(DUMMY_SINGLE, 1, true) then return "raid", nil, "Raid (single-target dummy)" end
    if target and target:find(DUMMY_AOE, 1, true) then return "mplus", nil, "Mythic+ (cleave dummy)" end
    local inInstance, instType = IsInInstance()
    local instName = GetInstanceInfo()
    if inInstance and instType == "party" then return "dungeon", lower(instName), instName end
    if encounter then return "boss", encounter.id, encounter.name end
    if (inInstance and instType == "raid") or IsInRaid() then return "raid", nil, "Raid" end
    if IsInGroup() then return "mplus", nil, "Mythic+" end
    return "raid", nil, "Raid"
end

-- Targeting the Dungeoneer's Training Dummy (a single-target boss)?
function Context:IsSingleTargetDummy()
    local target = lower(BRAT.Safe(UnitName, "target"))
    return target ~= nil and target:find(DUMMY_SINGLE, 1, true) ~= nil
end

-- Returns the Warcraft Logs rotation for here, the kind of place, and a label.
function Context:Resolve()
    local kind, key, where = self:Where()
    local data, label = BRAT.Sources.logs:Data(kind, key)
    if not data then return nil, kind, "no Warcraft Logs rotation" end
    return data, kind, label or where
end

-- Cached for half a second (called every display update).
function Context:Get()
    local now = GetTime()
    if not cached or now - cachedAt > 0.5 then
        local d, kind, label = self:Resolve()
        cached = { data = d, kind = kind, label = label }
        cachedAt = now
        if label ~= lastLabel then
            lastLabel = label
            if BRAT.History then BRAT.History:OnContext(kind, label) end
        end
    end
    return cached.data, cached.kind, cached.label
end

function Context:Data() return (self:Get()) end
function Context:Label() return select(3, self:Get()) end
function Context:Refresh() cached = nil end

-- Re-pick now and report it to the fight log even if it didn't change.
function Context:Announce()
    cached, lastLabel = nil, nil
    self:Get()
end

local f = CreateFrame("Frame")
f:RegisterEvent("ENCOUNTER_START")
f:RegisterEvent("ENCOUNTER_END")
f:RegisterEvent("PLAYER_TARGET_CHANGED")
f:RegisterEvent("ZONE_CHANGED_NEW_AREA")
f:RegisterEvent("GROUP_ROSTER_UPDATE")
f:SetScript("OnEvent", function(_, event, id, name)
    if event == "ENCOUNTER_START" then
        encounter = { id = tonumber(id) or 0, name = name or ("boss " .. tostring(id)) }
    elseif event == "ENCOUNTER_END" then
        encounter = nil
    end
    cached = nil -- re-pick right away (start of combat / boss pull)
end)
