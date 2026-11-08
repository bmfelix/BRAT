-- BRAT history: a complete record of every fight, saved in BRATDB.history so
-- tools\Analyze-History.ps1 can study it on your PC and narrow the rotation down.
-- One string per event (compact, and easy to read outside the game):
--   H1;F;serverTime;spec;char-realm;instance;instanceType;difficulty;mapID;keystoneLevel   fight start
--   H1;N;t;encounterID;difficulty;bossName      boss pull
--   H1;X;t;kind;label                            rotation in use (boss/dungeon/raid/mplus/pooled)
--   H1;P;t;pick;now;next;kind;real;used;glow;cds  Blizzard's pick changed
--        pick = Blizzard's raw pick, now/next = what BRAT showed, kind = NEXT source,
--        real/used = enemy count seen / rotation used, glow = glowing spells (a/b),
--        cds = rotation spells on cooldown "id:secs" ("~" = BRAT's estimate, combat)
--   H1;C;t;spell;now;next                         you cast a spell (+ what was shown)
--   H1;E;t                                        fight end
-- t = seconds since the fight started.
local _, BRAT = ...
local History = {}
BRAT.History = History

local MAX_LINES = 60000 -- about 3-4 MB of SavedVariables; oldest fights drop first
local start            -- GetTime() at fight start, nil out of combat
local shownNow, shownNext

local function add(line)
    local h = BRAT.db.history
    h[#h + 1] = "H1;" .. line
    if #h > MAX_LINES then
        -- Drop the oldest fight(s) in one go.
        local cut = math.floor(MAX_LINES * 0.1)
        while h[cut + 1] and not h[cut + 1]:find("^H1;F;") do cut = cut + 1 end
        local keep = {}
        for i = cut + 1, #h do keep[#keep + 1] = h[i] end
        BRAT.db.history = keep
    end
end

-- Spell names for the analyzer (it runs outside the game, so it cant look them up).
local function named(id)
    if id and id ~= 0 and not BRAT.IsSecret(id) and not BRAT.db.spellNames[id] then
        BRAT.db.spellNames[id] = BRAT.Safe(C_Spell.GetSpellName, id)
    end
    return id
end

local function t() return ("%.2f"):format(GetTime() - start) end

-- Names go inside ";"-separated lines, so strip any ";" out of them.
local function clean(s) return (tostring(s or ""):gsub(";", ",")) end

function History:Recording()
    return start ~= nil and BRAT.db.recordHistory
end

-- Rotation spells (and overrides) currently on cooldown, "id:secs/id:~secs".
local function cooldownList()
    local list = BRAT.Safe(C_AssistedCombat and C_AssistedCombat.GetRotationSpells)
    if type(list) ~= "table" then return "" end
    local out, seen = {}, {}
    local function one(id)
        if not id or seen[id] or BRAT.IsSecret(id) then return end
        seen[id] = true
        local left, estimated = BRAT.Cooldowns:Left(id)
        if left > 0.1 then out[#out + 1] = ("%d:%s%.1f"):format(named(id), estimated and "~" or "", left) end
    end
    for _, id in ipairs(list) do
        one(id)
        one(BRAT.Safe(C_Spell.GetOverrideSpell, id))
    end
    return table.concat(out, "/")
end

local function glowList()
    local s = BRAT.Procs:Snapshot()
    if not s then return "" end
    local out = {}
    for id in pairs(s) do out[#out + 1] = named(id) end
    table.sort(out)
    return table.concat(out, "/")
end

-- Called by Predict when Blizzard's pick changes.
function History:OnPick(pick, now, nxt, kind)
    shownNow, shownNext = now, nxt
    if not self:Recording() then return end
    local P = BRAT.Predict
    add(("P;%s;%d;%d;%d;%s;%d;%d;%s;%s"):format(t(), named(pick) or 0, named(now) or 0, named(nxt) or 0, kind or "",
        P.realTargets or 1, P.targets or 1, glowList(), cooldownList()))
end

-- Keep what's on screen current even when the pick didn't change.
function History:OnShown(now, nxt) shownNow, shownNext = now, nxt end

-- Out of combat only the most recent cast is kept (not logged); when combat
-- starts it's written as the fight's first line with a negative time, since the
-- spell that pulls usually finishes just before the game flags you in combat.
local preCast

function History:OnCast(spellID)
    if not start then
        preCast = { time = GetTime(), spell = spellID, now = shownNow, nxt = shownNext }
        return
    end
    if not self:Recording() then return end
    add(("C;%s;%d;%d;%d"):format(t(), named(spellID), shownNow or 0, shownNext or 0))
end

-- The rotation in use changed (boss pulled, entered a dungeon, targeted a dummy).
function History:OnContext(kind, label)
    if not self:Recording() then return end
    add(("X;%s;%s;%s"):format(t(), clean(kind), clean(label)))
end

function History:Count()
    local fights = 0
    for _, l in ipairs(BRAT.db.history) do if l:find("^H1;F;") then fights = fights + 1 end end
    return fights, #BRAT.db.history
end

function History:Clear() BRAT.db.history = {} end

-- The boss being fought. ENCOUNTER_START can fire just before you're flagged in
-- combat, so it's remembered until ENCOUNTER_END and written into the fight.
local encounter -- { id, name, diff, at }

local function writeEncounter()
    if encounter then
        add(("N;%.2f;%d;%d;%s"):format(encounter.at - start, encounter.id, encounter.diff, clean(encounter.name)))
    end
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_REGEN_DISABLED")
f:RegisterEvent("PLAYER_REGEN_ENABLED")
f:RegisterEvent("ENCOUNTER_START")
f:RegisterEvent("ENCOUNTER_END")
f:SetScript("OnEvent", function(_, event, a1, a2, a3)
    if not BRAT.db then return end
    if event == "PLAYER_REGEN_DISABLED" then
        start = GetTime()
        if BRAT.db.recordHistory then
            -- Where: instance name, type (raid/party/none), difficulty, map ID.
            local inst, instType, diff, _, _, _, _, mapID = GetInstanceInfo()
            -- Mythic+ keystone level (0 = not in a keystone run).
            local level = 0
            if C_ChallengeMode and C_ChallengeMode.GetActiveKeystoneInfo then
                level = tonumber((BRAT.Safe(C_ChallengeMode.GetActiveKeystoneInfo))) or 0
            end
            add(("F;%d;%d;%s-%s;%s;%s;%d;%d;%d"):format(GetServerTime(), BRAT.GetSpecID(),
                clean(UnitName("player") or "?"), clean(GetNormalizedRealmName() or "?"),
                clean(inst), clean(instType), tonumber(diff) or 0, tonumber(mapID) or 0, level))
            writeEncounter()
            -- Log which rotation BRAT is using as the fight starts.
            BRAT.Context:Announce()
            if preCast then
                add(("C;%.2f;%d;%d;%d"):format(preCast.time - start, named(preCast.spell),
                    preCast.now or 0, preCast.nxt or 0))
            end
            -- Log what Blizzard is showing as the fight starts, even if it hasn't changed.
            BRAT.Predict.prevPick = nil
        end
        preCast = nil
    elseif event == "PLAYER_REGEN_ENABLED" then
        if History:Recording() then add("E;" .. t()) end
        start = nil
    elseif event == "ENCOUNTER_START" then
        encounter = { id = tonumber(a1) or 0, name = a2, diff = tonumber(a3) or 0, at = GetTime() }
        if History:Recording() then writeEncounter() end
    elseif event == "ENCOUNTER_END" then
        encounter = nil
    end
end)
