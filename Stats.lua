-- BRAT stats: how well each source predicts, DPS per source, A/B testing,
-- and the "ready for 90%+ parses" verdict. Everything is per spec.
local _, BRAT = ...
local Stats = {}
BRAT.Stats = Stats

local WINDOW = 300        -- recent predictions kept for accuracy %
local MIN_FIGHT = 20      -- seconds; shorter fights are too noisy for DPS
local MAX_FIGHTS = 1000

Stats.MIN_PARSES = 5

local SOURCES = { "logs", "blizzard" }
Stats.SOURCES = SOURCES
Stats.LABEL = { logs = "Warcraft Logs", blizzard = "Learn from Blizzard" }

local function say(msg) print("|cff66ccffBRAT|r: " .. msg) end

---------------------------------------------------------------------------
-- Which source is active (A/B test can override the chosen one per fight)
---------------------------------------------------------------------------
function BRAT.ActiveSource()
    return Stats.abSource or BRAT.db.source or "logs"
end

---------------------------------------------------------------------------
-- Prediction accuracy: after you cast Blizzard's pick, did each source's
-- NEXT guess match what Blizzard recommended next?
-- db.acc[spec][src] = { pos, buf = ring of 1 hit / 0 wrong / -1 no guess,
--                       buckets[targets] = { seen, hit } }
---------------------------------------------------------------------------
function Stats:Score(preds, actual, bucket)
    local spec = BRAT.GetSpecID()
    local acc = BRAT.db.acc
    acc[spec] = acc[spec] or {}
    for _, src in ipairs(SOURCES) do
        local r = acc[spec][src] or { pos = 0, buf = {}, buckets = {} }
        acc[spec][src] = r
        local p = preds and preds[src]
        local v = (p == nil) and -1 or (p == actual and 1 or 0)
        r.pos = r.pos % WINDOW + 1
        r.buf[r.pos] = v
        local bk = r.buckets[bucket] or { seen = 0, hit = 0 }
        r.buckets[bucket] = bk
        bk.seen = bk.seen + 1
        if v == 1 then bk.hit = bk.hit + 1 end
        if bk.seen > 400 then bk.seen, bk.hit = bk.seen / 2, bk.hit / 2 end -- favor recent play
    end
end

-- n = predictions scored (recent window), match = hits / n,
-- coverage = share where the source had a guess at all, buckets = per enemy count.
function Stats:Accuracy(src, spec)
    local r = BRAT.db.acc[spec or BRAT.GetSpecID()]
    r = r and r[src]
    if not r then return { n = 0, match = 0, coverage = 0, buckets = {} } end
    local n, hit, guessed = 0, 0, 0
    for _, v in pairs(r.buf) do
        n = n + 1
        if v == 1 then hit = hit + 1 end
        if v ~= -1 then guessed = guessed + 1 end
    end
    return {
        n = n,
        match = n > 0 and hit / n or 0,
        coverage = n > 0 and guessed / n or 0,
        buckets = r.buckets,
    }
end

---------------------------------------------------------------------------
-- Fights: one record per combat, stored as a compact string so the
-- tools\fetch_my_parses.py script can read it from SavedVariables.
---------------------------------------------------------------------------
local fight
local encounter = { id = 0, diff = 0 }

local function contextKey(f)
    -- Fights are only compared with similar fights: same boss (or dummy /
    -- other) and similar enemy count (1, 2, 3+).
    local tg = math.min(3, math.max(1, math.floor((f.tg or 1) + 0.5)))
    return f.kind .. ":" .. (f.enc or 0) .. ":" .. tg
end
Stats.ContextKey = contextKey

local REGIONS = { "US", "KR", "EU", "TW", "CN" }

-- char/realm/region let tools\fetch_my_parses.py find your parses by itself.
local function encode(f)
    return ("t=%d;spec=%d;src=%s;dps=%d;dur=%d;tg=%.1f;kind=%s;enc=%d;diff=%d;ab=%d;char=%s;realm=%s;region=%s"):format(
        f.t, f.spec, f.src, f.dps, f.dur, f.tg, f.kind, f.enc, f.diff, f.ab and 1 or 0,
        f.char or "", f.realm or "", f.region or "")
end

local function decode(s)
    local f = {}
    for k, v in s:gmatch("(%w+)=([^;]*)") do f[k] = tonumber(v) or v end
    f.ab = f.ab == 1
    return f
end

function Stats:Fights(spec)
    local out = {}
    for _, s in ipairs(BRAT.db.fights) do
        local f = decode(s)
        if f.spec == spec and (f.dur or 0) >= MIN_FIGHT and (f.dps or 0) > 0 then out[#out + 1] = f end
    end
    return out
end

-- Read your own damage for the fight that just ended from Blizzard's damage
-- meter. Picks whichever session's duration best matches our own timer.
local function readMyDamage(ourDuration)
    if not C_DamageMeter or not C_DamageMeter.GetCombatSessionFromType then return nil end
    if InCombatLockdown() then return nil end
    local ST = Enum.DamageMeterSessionType or {}
    local DT = Enum.DamageMeterType or {}
    local best, bestDiff
    for _, st in ipairs({ ST.Current or 1, ST.Expired or 2 }) do
        local s = BRAT.Safe(C_DamageMeter.GetCombatSessionFromType, st, DT.DamageDone or 0)
        if type(s) == "table" and type(s.combatSources) == "table" then
            for _, src in ipairs(s.combatSources) do
                if src.isLocalPlayer and not BRAT.IsSecret(src.totalAmount) and (src.totalAmount or 0) > 0 then
                    local d = (not BRAT.IsSecret(s.durationSeconds)) and s.durationSeconds or nil
                    local diff = d and math.abs(d - ourDuration) or 9999
                    if not best or diff < bestDiff then best, bestDiff = { total = src.totalAmount, dur = d }, diff end
                end
            end
        end
    end
    if not best then return nil end
    local dur = best.dur
    if not dur or dur <= 0 or math.abs(dur - ourDuration) > ourDuration * 0.4 then dur = ourDuration end
    return best.total / dur
end

-- A/B test: pick the source with fewer fights in this kind of fight.
local function chooseABSource()
    local spec = BRAT.GetSpecID()
    local kind = encounter.id > 0 and "boss" or "other"
    local counts = { logs = 0, blizzard = 0 }
    for _, f in ipairs(Stats:Fights(spec)) do
        if f.ab and f.kind == kind and (f.enc or 0) == encounter.id then counts[f.src] = (counts[f.src] or 0) + 1 end
    end
    if not BRAT.Sources.logs:HasRotation(spec) then return "blizzard" end
    if counts.logs == counts.blizzard then return (math.random(2) == 1) and "logs" or "blizzard" end
    return counts.logs < counts.blizzard and "logs" or "blizzard"
end

function Stats:OnCombatStart()
    if BRAT.db.abTest then Stats.abSource = chooseABSource() end
    fight = {
        start = GetTime(), t = GetServerTime(), spec = BRAT.GetSpecID(),
        src = BRAT.ActiveSource(), tsum = 0, tn = 0,
        kind = encounter.id > 0 and "boss" or "other",
        enc = encounter.id, diff = encounter.diff, ab = BRAT.db.abTest and true or false,
        char = UnitName("player"), realm = (GetRealmName() or ""):gsub("[;=]", ""),
        region = REGIONS[GetCurrentRegion and GetCurrentRegion() or 1] or "US",
    }
end

-- Called each display update while in combat.
function Stats:Sample(realTargets)
    if not fight then return end
    fight.tsum = fight.tsum + (realTargets or 1)
    fight.tn = fight.tn + 1
    if fight.kind == "other" and fight.tn % 20 == 1 then
        local name = BRAT.Safe(UnitName, "target")
        if name and name:find("Dummy") then fight.kind = "dummy" end
    end
end

function Stats:OnCombatEnd()
    local f = fight
    fight = nil
    if not f then return end
    local dur = GetTime() - f.start
    C_Timer.After(1.5, function()
        Stats.abSource = nil -- back to the chosen source between fights
        if dur < MIN_FIGHT then return end
        local dps = readMyDamage(dur)
        if not dps then return end
        f.dps = math.floor(dps + 0.5)
        f.dur = math.floor(dur + 0.5)
        f.tg = f.tn > 0 and (f.tsum / f.tn) or 1
        table.insert(BRAT.db.fights, encode(f))
        while #BRAT.db.fights > MAX_FIGHTS do table.remove(BRAT.db.fights, 1) end
        if BRAT.Options then BRAT.Options:Refresh() end
    end)
end

---------------------------------------------------------------------------
-- DPS comparison: the recommendation (works for every player, in game).
-- Each fight's DPS is divided by the average DPS of fights
-- in the same context (boss / dummy, enemy count), so a dummy and a raid
-- boss can be compared fairly. Only contexts with BOTH sources count.
---------------------------------------------------------------------------
function Stats:Compare(spec)
    local fights = self:Fights(spec)
    local raw = {
        logs = { n = 0, sum = 0, best = 0 },
        blizzard = { n = 0, sum = 0, best = 0 },
    }
    local ctx = {}
    for _, f in ipairs(fights) do
        local r = raw[f.src]
        if r then
            r.n = r.n + 1
            r.sum = r.sum + f.dps
            r.best = math.max(r.best, f.dps)
        end
        local k = contextKey(f)
        ctx[k] = ctx[k] or { n = 0, sum = 0, srcs = {} }
        ctx[k].n = ctx[k].n + 1; ctx[k].sum = ctx[k].sum + f.dps; ctx[k].srcs[f.src] = true
    end
    local norm = { logs = {}, blizzard = {} }
    for _, f in ipairs(fights) do
        local c = ctx[contextKey(f)]
        if c.srcs.logs and c.srcs.blizzard and norm[f.src] then
            table.insert(norm[f.src], f.dps / (c.sum / c.n))
        end
    end
    local function meanSE(t)
        local n = #t
        if n == 0 then return 0, 0, 0 end
        local m = 0; for _, v in ipairs(t) do m = m + v end; m = m / n
        local var = 0; for _, v in ipairs(t) do var = var + (v - m) ^ 2 end
        var = n > 1 and var / (n - 1) or 0
        return m, math.sqrt(var / n), n
    end
    local lm, lse, ln = meanSE(norm.logs)
    local bm, bse, bn = meanSE(norm.blizzard)
    local res = {
        raw = {
            logs = {
                n = raw.logs.n,
                avg = raw.logs.n > 0 and raw.logs.sum / raw.logs.n or 0,
                best = raw.logs.best,
            },
            blizzard = {
                n = raw.blizzard.n,
                avg = raw.blizzard.n > 0 and raw.blizzard.sum / raw.blizzard.n or 0,
                best = raw.blizzard.best,
            },
        },
        matched = { logs = ln, blizzard = bn },
    }
    if ln >= self.MIN_PARSES and bn >= self.MIN_PARSES then
        res.diff = (lm - bm) / ((lm + bm) / 2) -- + means Warcraft Logs did more DPS
        local noise = 2 * math.sqrt(lse ^ 2 + bse ^ 2) / ((lm + bm) / 2)
        res.noise = noise
        if math.abs(res.diff) > noise then
            res.winner = res.diff > 0 and "logs" or "blizzard"
            res.confidence = (ln >= 15 and bn >= 15) and "high" or "medium"
        else
            res.confidence = "too close to call"
        end
    end
    return res
end

-- The recommended source: whichever did clearly more DPS in comparable fights
-- (needs 5+ fights each in matching contexts, and a gap bigger than the noise).
function Stats:Winner(spec)
    local c = self:Compare(spec)
    return c.winner, c
end

---------------------------------------------------------------------------
-- "Does BRAT know the rotation?" (Learn from Blizzard): NEXT has to match
-- Blizzard's assistant closely, overall and at every enemy count.
---------------------------------------------------------------------------
Stats.READY_MATCH = 0.90
Stats.READY_N = 300
Stats.READY_BUCKET = 0.85

function Stats:Readiness(spec)
    spec = spec or BRAT.GetSpecID()
    local a = self:Accuracy("blizzard", spec)
    local out = { acc = a, learned = false, reasons = {} }
    if a.n < self.READY_N then
        table.insert(out.reasons, ("needs %d more of your casts scored (has %d of %d)"):format(
            self.READY_N - a.n, a.n, self.READY_N))
    end
    if a.match < self.READY_MATCH then
        table.insert(out.reasons, ("NEXT matches Blizzard %.0f%% of the time (needs %.0f%%)"):format(
            a.match * 100, self.READY_MATCH * 100))
    end
    local cap = BRAT.GetCap()
    for k = 1, cap do
        local bk = a.buckets[k]
        if bk and bk.seen >= 20 and bk.hit / bk.seen < self.READY_BUCKET then
            table.insert(out.reasons, ("at %s it only matches %.0f%% (needs %.0f%%)"):format(
                k >= cap and (k .. "+ enemies") or (k == 1 and "1 enemy" or k .. " enemies"),
                bk.hit / bk.seen * 100, self.READY_BUCKET * 100))
        end
    end
    out.learned = #out.reasons == 0
    out.verdict = out.learned and "ready" or "learning"
    return out
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_REGEN_DISABLED")
ev:RegisterEvent("PLAYER_REGEN_ENABLED")
ev:RegisterEvent("ENCOUNTER_START")
ev:RegisterEvent("ENCOUNTER_END")
ev:SetScript("OnEvent", function(_, event, a1, _, a3)
    if not BRAT.db then return end
    if event == "PLAYER_REGEN_DISABLED" then
        Stats:OnCombatStart()
    elseif event == "PLAYER_REGEN_ENABLED" then
        Stats:OnCombatEnd()
    elseif event == "ENCOUNTER_START" then
        encounter.id = (not BRAT.IsSecret(a1) and tonumber(a1)) or 0
        encounter.diff = (not BRAT.IsSecret(a3) and tonumber(a3)) or 0
        if fight and fight.kind ~= "boss" then
            fight.kind, fight.enc, fight.diff = "boss", encounter.id, encounter.diff
        end
    elseif event == "ENCOUNTER_END" then
        encounter.id, encounter.diff = 0, 0
    end
end)

function Stats:ResetComparison()
    local spec = BRAT.GetSpecID()
    local keep = {}
    for _, s in ipairs(BRAT.db.fights) do
        if decode(s).spec ~= spec then keep[#keep + 1] = s end
    end
    BRAT.db.fights = keep
    BRAT.db.acc[spec] = nil
    BRAT.db.resetAt[spec] = GetServerTime()
    say("comparison data cleared for this spec (fight DPS records and prediction scores).")
end
