-- BRAT Blizzard recording: fills the Blizzard raw cache (layer 1, db.bcache)
-- with what Blizzard's assistant picked during your fights. Recorded in memory
-- while you fight, written to the raw cache when combat ends; it can also be
-- filled from the fight log. Averages (layer 2) and the served rotation
-- (layer 3) are built by the shared engine for both sources (Sources.lua,
-- RotationBuilder.lua). After fights it suggests rebuilding when there's
-- enough new data.
local _, BRAT = ...
local Learn = {}
BRAT.Learn = Learn

local MAX_FIGHTS = 400   -- per spec; oldest fights drop off
local PROMPT_EVERY = 5   -- suggest a rebuild every this many new fights

local session -- the fight being recorded: { kind, key, label, pairs, prio }

local function cache(spec, create)
    local c = BRAT.db.bcache
    if create and not c[spec] then c[spec] = { n = 0, fights = {} } end
    return c[spec]
end

-- Recording (called by Predict while you fight) -------------------------------
-- After casting `from`, Blizzard picked `to`, with `tg` enemies.
function Learn:Record(tg, from, to)
    if not session or not from or not to then return end
    local p = session.pairs
    p[tg] = p[tg] or {}
    p[tg][from] = p[tg][from] or {}
    p[tg][from][to] = (p[tg][from][to] or 0) + 1
end

-- Priority match-ups for this fight (Priority.lua writes into it).
function Learn:SessionPrio(tg)
    if not session then return nil end
    session.prio[tg] = session.prio[tg] or {}
    return session.prio[tg]
end

-- Combat start/end: record a fight, write it to the cache when it ends.
local function startFight()
    local kind, key, label = BRAT.Context:Where()
    session = { kind = kind, key = key, label = label, pairs = {}, prio = {}, spec = BRAT.GetSpecID() }
end

local function endFight()
    local s = session
    session = nil
    if not s or not next(s.pairs) then return end
    local c = cache(s.spec, true)
    c.n = c.n + 1
    c.fights[#c.fights + 1] = { t = GetServerTime(), kind = s.kind, key = s.key, label = s.label,
        pairs = s.pairs, prio = s.prio }
    while #c.fights > MAX_FIGHTS do table.remove(c.fights, 1) end
    Learn:Prompt(s.spec)
end

-- Suggest a rebuild when there's enough new data since the last one.
function Learn:Prompt(spec)
    local c = cache(spec)
    if not c then return end
    local avg = BRAT.Sources.blizzard:Avg(spec)
    local new = c.n - (avg and avg.fromRaw or 0)
    if new <= 0 or new == c.prompted then return end
    if not avg or new % PROMPT_EVERY == 0 then
        c.prompted = new
        print(("|cff66ccffBRAT|r: %d new fight%s in the Blizzard raw cache%s. Rebuild the averages, then the "
            .. "rotation: |cffffffff/brat averages blizzard|r, then |cffffffff/brat rotation blizzard|r (or BRAT "
            .. "settings > Spec data)."):format(new, new == 1 and "" or "s", avg and "" or " and no averages yet"))
    end
end

-- Averages, rotation, serving: the shared engine and data source do this for
-- both sources (RotationBuilder.lua, Sources.lua). These are thin shortcuts.
local function src() return BRAT.Sources.blizzard end
function Learn:BuildAverages(spec) return (src():RebuildAverages(spec)) end
function Learn:BuildRotation(spec) return (src():BuildRotation(spec)) end
function Learn:HasRotation(spec) return src():HasRotation(spec) end
function Learn:Data() return src():Data() end
function Learn:Prio(tg) return src():Prio(tg) end
function Learn:ClearCache(spec) BRAT.db.bcache[spec] = nil end
function Learn:Status(spec) return src():Status(spec) end

-- Fill the cache from the fight log -----------------------------------------
-- The fight log (History.lua) has every fight's Blizzard picks, your casts,
-- enemy counts and boss / dungeon, the same data the analysis uses. This turns
-- each logged fight into a cache entry: what Blizzard picked after each cast,
-- and the priority match-ups. Replaces the spec's cache.
local MIN_FIGHT = 20
local READY = 1.5

local function split(s)
    local f = {}
    for v in (s .. ";"):gmatch("([^;]*);") do f[#f + 1] = v end
    return f
end

local function lowerName(s) return s and s ~= "" and s:lower() or nil end

local function fightRecord(fight)
    local pairsT, prio = {}, {}
    local ev = fight.events
    local lastP
    for i, e in ipairs(ev) do
        if e.type == "P" and e.pick and e.pick ~= 0 then
            lastP = e
            -- Priority: the pick beat every other spell Blizzard picked in this
            -- fight that was ready then (same as the analysis).
            prio[e.used] = prio[e.used] or {}
            local pt = prio[e.used]
            pt[e.pick] = pt[e.pick] or { w = 0, g = 0 }
            for other, o in pairs(pt) do
                if other ~= e.pick then
                    local c = e.cds[other]
                    if not (c and c > READY) then
                        pt[e.pick].w = pt[e.pick].w + 1
                        pt[e.pick].g = pt[e.pick].g + 1
                        o.g = o.g + 1
                    end
                end
            end
        elseif e.type == "C" and e.spell == e.now and e.spell ~= 0 then
            -- After you cast NOW, Blizzard's next pick: the last pick before your
            -- next cast (none = it repeated the same spell).
            local actual = e.spell
            for j = i + 1, #ev do
                if ev[j].type == "C" then break end
                if ev[j].type == "P" and ev[j].pick ~= 0 then actual = ev[j].pick end
            end
            local tg = lastP and lastP.used or 1
            pairsT[tg] = pairsT[tg] or {}
            pairsT[tg][e.spell] = pairsT[tg][e.spell] or {}
            pairsT[tg][e.spell][actual] = (pairsT[tg][e.spell][actual] or 0) + 1
        end
    end
    return pairsT, prio
end

function Learn:ImportLog(spec)
    spec = spec or BRAT.GetSpecID()
    local h = BRAT.db.history or {}
    local fights, cur = {}, nil
    local function finish()
        if not cur then return end
        if cur.length >= MIN_FIGHT then
            local p, pr = fightRecord(cur)
            if next(p) then
                local kind, key, label
                if cur.instType == "party" then
                    kind, key, label = "dungeon", lowerName(cur.inst), cur.inst
                elseif cur.enc then
                    kind, key, label = "boss", cur.enc, cur.boss
                elseif cur.instType == "raid" then
                    kind, label = "raid", cur.inst
                else
                    kind = (cur.ctxKind == "mplus") and "mplus" or "raid"
                    label = cur.ctxLabel or "Open world"
                end
                fights[#fights + 1] = { t = cur.time, kind = kind, key = key, label = label, pairs = p, prio = pr }
            end
        end
        cur = nil
    end
    for _, line in ipairs(h) do
        local p = split(line)
        local k = p[2]
        if k == "F" then
            finish()
            if tonumber(p[4]) == spec then
                cur = { time = tonumber(p[3]), inst = p[6], instType = p[7] or "none", events = {}, length = 0, lastT = 0 }
            end
        elseif cur then
            if k == "P" then
                local cds = {}
                for id, left in (p[11] or ""):gmatch("(%d+):~?([%d%.]+)") do cds[tonumber(id)] = tonumber(left) end
                cur.lastT = tonumber(p[3]) or cur.lastT
                cur.events[#cur.events + 1] = { type = "P", pick = tonumber(p[4]), used = tonumber(p[9]) or 1, cds = cds }
            elseif k == "C" then
                cur.lastT = tonumber(p[3]) or cur.lastT
                cur.events[#cur.events + 1] = { type = "C", spell = tonumber(p[4]), now = tonumber(p[5]) }
            elseif k == "N" then
                cur.enc, cur.boss = tonumber(p[4]), p[6]
            elseif k == "X" then
                cur.ctxKind = cur.ctxKind or p[4]
                cur.ctxLabel = cur.ctxLabel or p[5]
            elseif k == "E" then
                cur.length = tonumber(p[3]) or cur.lastT
                finish()
            end
        end
    end
    if cur then cur.length = cur.lastT; finish() end

    local old = cache(spec)
    BRAT.db.bcache[spec] = { n = (old and old.n or 0) + #fights, fights = fights }
    while #fights > MAX_FIGHTS do table.remove(fights, 1) end
    return #fights
end

-- First run with the cache: fill it from the fight log (the data the analysis
-- uses) and build the rotation, so nothing recorded so far is lost. If a spec
-- has no logged fights, its old learned counts become its first cache entry.
function Learn:Migrate()
    local db = BRAT.db
    -- Earlier storage (bavg / brot): the averages carry over; the rotation is
    -- rebuilt from them with the shared builder.
    if db.bavg or db.brot then
        local avgStore = db.avg.blizzard or {}
        db.avg.blizzard = avgStore
        for spec, a in pairs(db.bavg or {}) do
            if not avgStore[spec] then a.fromRaw = a.fromRaw or a.builtAt; avgStore[spec] = a end
        end
        for spec, r in pairs(db.brot or {}) do
            if r.pooled and not avgStore[spec] then r.fromRaw = r.builtAt; avgStore[spec] = r end
        end
        for spec in pairs(avgStore) do self:BuildRotation(spec) end
        db.bavg, db.brot = nil, nil
    end
    if db.bcacheMigrated then return end
    local specs = {}
    for spec in pairs(db.learn or {}) do specs[spec] = true end
    for _, line in ipairs(db.history or {}) do
        local spec = line:match("^H1;F;%d+;(%d+);")
        if spec then specs[tonumber(spec)] = true end
    end
    for spec in pairs(specs) do
        if not db.bcache[spec] then
            local n = self:ImportLog(spec)
            if n == 0 and type(db.learn[spec]) == "table" and next(db.learn[spec]) then
                local c = cache(spec, true)
                c.n = 1
                c.fights[1] = { t = GetServerTime(), kind = "raid", label = "learned before the cache",
                    pairs = db.learn[spec], prio = (db.prio or {})[spec] or {} }
            end
            if self:BuildAverages(spec) then self:BuildRotation(spec) end
        end
    end
    db.learn, db.prio = {}, {}
    db.bcacheMigrated = true
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_REGEN_DISABLED")
f:RegisterEvent("PLAYER_REGEN_ENABLED")
f:SetScript("OnEvent", function(_, event)
    if not BRAT.db then return end
    if event == "PLAYER_REGEN_DISABLED" then startFight() else endFight() end
end)
