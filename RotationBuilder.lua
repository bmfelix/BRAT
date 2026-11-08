-- BRAT rotation builder: the one engine that turns a raw cache into averages
-- and averages into the rotation BRAT serves. Both data sources (Warcraft Logs
-- and Blizzard, Sources.lua) use it, so the logic exists once.
--
--   Raw cache  list of fight records:
--              { kind = "boss"|"dungeon"|"raid"|"mplus", key = encounterID or
--                dungeon name (lowercase), label = name, pairs = P, prio = Q }
--              P[targets][fromSpell][toSpell] = count     ("after A came B")
--              Q[targets][spell] = { w = wins, g = match-ups }  (optional)
--   Averages   per boss, per dungeon, a raid average (bosses + other raid-like
--              fights, each counted equally) and a dungeon average (dungeons +
--              other dungeon-like fights), plus everything pooled.
--   Rotation   what's served: raid = per boss + generic single target;
--              dungeon = per dungeon + generic dungeon. Noisy follow-ups removed.
local _, BRAT = ...
local RB = {}
BRAT.RotationBuilder = RB

RB.MIN_COUNT = 3     -- follow-ups seen fewer times are noise
RB.MIN_SHARE = 0.15  -- ... or under this share of what follows a spell

-- P += Q (pairs tables).
function RB.AddPairs(into, from)
    for tg, froms in pairs(from or {}) do
        into[tg] = into[tg] or {}
        for a, tos in pairs(froms) do
            local row = into[tg][a] or {}
            into[tg][a] = row
            for b, n in pairs(tos) do row[b] = (row[b] or 0) + n end
        end
    end
    return into
end

-- Priority match-ups: sum wins and games.
function RB.AddPrio(into, from)
    for tg, spells in pairs(from or {}) do
        into[tg] = into[tg] or {}
        for id, s in pairs(spells) do
            local r = into[tg][id] or { w = 0, g = 0 }
            r.w, r.g = r.w + (s.w or 0), r.g + (s.g or 0)
            into[tg][id] = r
        end
    end
    return into
end

-- Merge target buckets above the rotation cap into the cap bucket.
function RB.MergeAboveCap(p, cap)
    if not cap then return p end
    for tg in pairs(p) do
        if tg > cap then
            RB.AddPairs(p, { [cap] = p[tg] })
            p[tg] = nil
        end
    end
    return p
end

-- Average of several pairs tables where each counts equally (a boss with more
-- casts doesn't drown out the others): for every "after A", average each one's
-- share of "A -> B", then scale back to counts at their average size.
function RB.Average(list)
    if #list == 0 then return nil end
    if #list == 1 then return list[1] end
    local out, tgs = {}, {}
    for _, p in ipairs(list) do for tg in pairs(p) do tgs[tg] = true end end
    for tg in pairs(tgs) do
        local froms = {}
        for _, p in ipairs(list) do for a in pairs(p[tg] or {}) do froms[a] = true end end
        for a in pairs(froms) do
            local shares, size, n = {}, 0, 0
            for _, p in ipairs(list) do
                local tos = p[tg] and p[tg][a]
                if tos then
                    local total = 0
                    for _, c in pairs(tos) do total = total + c end
                    if total > 0 then
                        for b, c in pairs(tos) do shares[b] = (shares[b] or 0) + c / total end
                        size, n = size + total, n + 1
                    end
                end
            end
            for b, s in pairs(shares) do
                local c = math.floor(s / n * size / n + 0.5)
                if c > 0 then
                    out[tg] = out[tg] or {}
                    out[tg][a] = out[tg][a] or {}
                    out[tg][a][b] = c
                end
            end
        end
    end
    return out
end

-- Drop noisy follow-ups. Returns nil if nothing is left.
function RB.Filter(p)
    if not p then return nil end
    local out = {}
    for tg, froms in pairs(p) do
        for a, tos in pairs(froms) do
            local total = 0
            for _, n in pairs(tos) do total = total + n end
            for b, n in pairs(tos) do
                if n >= RB.MIN_COUNT and n / total >= RB.MIN_SHARE then
                    out[tg] = out[tg] or {}
                    out[tg][a] = out[tg][a] or {}
                    out[tg][a][b] = n
                end
            end
        end
    end
    return next(out) and out or nil
end

-- Raw cache -> averages. `cap` merges buckets above the rotation cap (optional).
function RB.BuildAverages(fights, cap)
    local groups, pooled, prio = {}, {}, {}
    for _, f in ipairs(fights or {}) do
        local gkey = tostring(f.kind) .. ":" .. tostring(f.key or "")
        local g = groups[gkey]
        if not g then g = { kind = f.kind, key = f.key, label = f.label, pairs = {} }; groups[gkey] = g end
        RB.AddPairs(g.pairs, f.pairs)
        RB.AddPairs(pooled, f.pairs)
        RB.AddPrio(prio, f.prio)
    end
    local avg = { bosses = {}, dungeons = {}, labels = {}, pooled = RB.MergeAboveCap(pooled, cap), prio = prio,
        fights = #(fights or {}) }
    local raidList, dungeonList = {}, {}
    for _, g in pairs(groups) do
        local p = RB.MergeAboveCap(g.pairs, cap)
        if g.kind == "boss" then
            avg.bosses[g.key] = p; avg.labels[g.key] = g.label; raidList[#raidList + 1] = p
        elseif g.kind == "dungeon" then
            avg.dungeons[g.key] = p; avg.labels[g.key] = g.label; dungeonList[#dungeonList + 1] = p
        elseif g.kind == "mplus" then
            dungeonList[#dungeonList + 1] = p
        else
            raidList[#raidList + 1] = p
        end
    end
    avg.raid = RB.Average(raidList)
    avg.dungeon = RB.Average(dungeonList)
    avg.raidCount, avg.dungeonCount = #raidList, #dungeonList
    return avg
end

-- Averages -> the served rotation.
function RB.BuildRotation(avg)
    local rot = { labels = avg.labels, prio = avg.prio,
        raid = { bosses = {}, generic = RB.Filter(avg.raid) or RB.Filter(avg.pooled) },
        dungeon = { dungeons = {}, generic = RB.Filter(avg.dungeon) or RB.Filter(avg.pooled) } }
    for k, p in pairs(avg.bosses or {}) do rot.raid.bosses[k] = RB.Filter(p) end
    for k, p in pairs(avg.dungeons or {}) do rot.dungeon.dungeons[k] = RB.Filter(p) end
    return rot
end

-- The served rotation for where you are (Context:Where kind/key), and a label:
--   boss -> that boss, else generic single target;  raid -> generic single target
--   dungeon -> that dungeon, else generic dungeon;  mplus -> generic dungeon
function RB.Select(rot, kind, key)
    if not rot then return nil end
    if kind == "boss" and rot.raid.bosses[key] then return rot.raid.bosses[key], rot.labels[key] end
    if kind == "dungeon" and rot.dungeon.dungeons[key] then return rot.dungeon.dungeons[key], rot.labels[key] end
    if kind == "boss" or kind == "raid" then
        if rot.raid.generic then return rot.raid.generic, "generic single target" end
        return rot.dungeon.generic, "generic dungeon"
    end
    if rot.dungeon.generic then return rot.dungeon.generic, "generic dungeon" end
    return rot.raid.generic, "generic single target"
end

-- Counts for status lines.
function RB.Count(t) local n = 0; for _ in pairs(t or {}) do n = n + 1 end; return n end
