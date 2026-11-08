-- BRAT data sources: Warcraft Logs and Blizzard, the same three layers each,
-- handled by one class so every button and command works the same for both.
--   1. Raw cache  Warcraft Logs: shipped inside the addon (Data\WCLRaw.lua,
--                 refreshed with addon updates). Blizzard: your recorded fights.
--   2. Averages   Rebuild averages  (in game, from the raw cache)
--   3. Rotation   Build rotation    (in game, from the averages) -> served
-- Averages and rotations are kept in the save file, per source and spec.
local _, BRAT = ...
local RB = BRAT.RotationBuilder

local Source = {}
Source.__index = Source

local function say(msg) print("|cff66ccffBRAT|r: " .. msg) end

-- def: key, name, raw(spec) -> fights, stamp(spec) -> number that changes when
-- the raw cache changes, rawInfo(spec) -> text, cap(spec), clearRaw(spec) or nil.
function Source.New(def) return setmetatable(def, Source) end

local function store(layer, key)
    local db = BRAT.db
    db[layer] = db[layer] or {}
    db[layer][key] = db[layer][key] or {}
    return db[layer][key]
end

function Source:Avg(spec) return store("avg", self.key)[spec or BRAT.GetSpecID()] end
function Source:Rot(spec) return store("rot", self.key)[spec or BRAT.GetSpecID()] end

-- Layer 1 -> 2. Returns ok, message.
function Source:RebuildAverages(spec)
    spec = spec or BRAT.GetSpecID()
    local fights = self.raw(spec)
    if not fights or #fights == 0 then
        return false, ("the %s raw cache is empty for this spec. %s"):format(self.name, self.emptyHint)
    end
    local avg = RB.BuildAverages(fights, self.cap and self.cap(spec))
    avg.built, avg.fromRaw = GetServerTime(), self.stamp(spec)
    store("avg", self.key)[spec] = avg
    return true, ("%s averages rebuilt from %d %s (%d bosses, %d dungeons). Next: Build rotation."):format(
        self.name, avg.fights, self.unit, RB.Count(avg.bosses), RB.Count(avg.dungeons))
end

-- Layer 2 -> 3. Returns ok, message.
function Source:BuildRotation(spec)
    spec = spec or BRAT.GetSpecID()
    local avg = self:Avg(spec)
    if not avg then return false, ("no %s averages for this spec: Rebuild averages first."):format(self.name) end
    local rot = RB.BuildRotation(avg)
    rot.built, rot.fromAverages = GetServerTime(), avg.built
    store("rot", self.key)[spec] = rot
    if BRAT.Context then BRAT.Context:Refresh() end
    return true, ("%s rotation built and in use: %d bosses + generic single target, %d dungeons + generic dungeon."):format(
        self.name, RB.Count(rot.raid.bosses), RB.Count(rot.dungeon.dungeons))
end

function Source:ClearRaw(spec)
    if not self.clearRaw then return false, self.name .. "'s raw cache ships with the addon and can't be cleared." end
    self.clearRaw(spec)
    return true, self.name .. " raw cache cleared."
end
function Source:ClearAverages(spec) store("avg", self.key)[spec] = nil; return true, self.name .. " averages cleared." end
function Source:ClearRotation(spec)
    store("rot", self.key)[spec] = nil
    if BRAT.Context then BRAT.Context:Refresh() end
    return true, self.name .. " rotation cleared."
end

-- Run a step by name and announce the result in chat (buttons and commands).
local STEPS = { averages = "RebuildAverages", rotation = "BuildRotation", clearraw = "ClearRaw",
    clearavg = "ClearAverages", clearrot = "ClearRotation" }
function Source:Run(step, spec)
    local ok, msg = self[STEPS[step]](self, spec or BRAT.GetSpecID())
    say((ok and "" or "|cffff4040") .. msg .. (ok and "" or "|r"))
    if BRAT.Options then BRAT.Options:Refresh() end
    return ok
end

-- Serving -------------------------------------------------------------------------
function Source:HasRotation(spec)
    local rot = self:Rot(spec)
    return rot ~= nil and (rot.raid.generic ~= nil or rot.dungeon.generic ~= nil)
end

-- The rotation for where you are now (or for a given kind/key), and its label.
function Source:Data(kind, key, spec)
    if not kind then kind, key = BRAT.Context:Where() end
    return RB.Select(self:Rot(spec), kind, key)
end

function Source:Prio(tg, spec)
    local rot = self:Rot(spec)
    return rot and rot.prio and rot.prio[tg]
end

-- Status of the three layers, for the settings page and /brat check.
function Source:Status(spec)
    spec = spec or BRAT.GetSpecID()
    local fights = self.raw(spec) or {}
    local avg, rot = self:Avg(spec), self:Rot(spec)
    local stamp = self.stamp(spec)
    return {
        rawCount = #fights, rawInfo = self.rawInfo(spec), canClearRaw = self.clearRaw ~= nil,
        avgBuilt = avg and avg.built, avgFights = avg and avg.fights,
        avgBosses = avg and RB.Count(avg.bosses), avgDungeons = avg and RB.Count(avg.dungeons),
        avgStale = avg ~= nil and stamp ~= nil and (avg.fromRaw or 0) < stamp,
        rotBuilt = rot and rot.built,
        rotBosses = rot and RB.Count(rot.raid.bosses), rotDungeons = rot and RB.Count(rot.dungeon.dungeons),
        rotStale = rot ~= nil and avg ~= nil and (rot.fromAverages or 0) < (avg.built or 0),
    }
end

-- The two sources ------------------------------------------------------------------
BRAT.Sources = {}

-- Warcraft Logs: the raw cache ships in Data\WCLRaw.lua (BRAT.WCLRaw[spec] =
-- { info = { built, date, players, cap, zone }, fights = { records } }).
local function wcl(spec) return BRAT.WCLRaw and BRAT.WCLRaw[spec] end
BRAT.Sources.logs = Source.New({
    key = "logs", name = "Warcraft Logs", unit = "top-player parses",
    emptyHint = "This addon version has no Warcraft Logs data for it yet.",
    raw = function(spec) local r = wcl(spec); return r and r.fights end,
    stamp = function(spec) local r = wcl(spec); return r and r.info.built end,
    cap = function(spec) local r = wcl(spec); return r and r.info.cap end,
    rawInfo = function(spec)
        local r = wcl(spec)
        if not r then return nil end
        return ("%d parses (ranks %s), data from %s"):format(#r.fights, r.info.ranks or "?", r.info.date or "?")
    end,
})

-- Blizzard: the raw cache is your recorded fights (Learn.lua).
BRAT.Sources.blizzard = Source.New({
    key = "blizzard", name = "Blizzard", unit = "fights",
    emptyHint = "Play some fights (it fills as you play), or Fill from fight log.",
    raw = function(spec) local c = BRAT.db.bcache[spec]; return c and c.fights end,
    stamp = function(spec) local c = BRAT.db.bcache[spec]; return c and c.n end,
    cap = function(spec) local r = wcl(spec); return r and r.info.cap end,
    rawInfo = function(spec)
        local c = BRAT.db.bcache[spec]
        return c and #c.fights > 0 and ("%d recorded fights"):format(#c.fights) or nil
    end,
    clearRaw = function(spec) BRAT.db.bcache[spec] = nil end,
})

-- The source you chose (Where NOW and NEXT come from).
function BRAT.ActiveSourceObj() return BRAT.Sources[BRAT.ActiveSource() == "logs" and "logs" or "blizzard"] end

-- First use, and new data shipped with an addon update ------------------------------
-- No averages/rotation yet but a raw cache exists: build them once, so BRAT works
-- out of the box. Newer raw data than the averages: say so (you rebuild).
function BRAT.Sources.CheckOnLogin()
    local spec = BRAT.GetSpecID()
    for _, src in pairs(BRAT.Sources) do
        if type(src) == "table" and src.key then
            local st = src:Status(spec)
            if st.rawCount > 0 and not st.avgBuilt and not st.rotBuilt then
                src:RebuildAverages(spec)
                src:BuildRotation(spec)
                say(("%s rotation built for your spec from %s."):format(src.name, st.rawInfo or "the raw cache"))
            elseif st.avgStale and src.key == "logs" then
                say("new Warcraft Logs data came with this addon version: |cffffffff/brat averages wcl|r, then "
                    .. "|cffffffff/brat rotation wcl|r (or BRAT settings > Spec data).")
            end
        end
    end
end
