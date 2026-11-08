-- BRAT cooldown tracker. In combat Midnight hides spell cooldowns from addons
-- (secret values), so BRAT tracks them itself:
--   * casting a spell starts its cooldown timer (length read from the game out
--     of combat, else the spell's base cooldown);
--   * it LEARNS cooldown reductions: how many seconds each of your casts takes
--     off another spell's cooldown (e.g. Smite / Holy Fire -> Holy Word: Chastise).
-- Learning uses facts Blizzard gives us:
--   * Blizzard recommends X, or you cast X  => X is ready. If BRAT thought it
--     still had time left, the reductions were too small: raise them.
--   * Blizzard recommends a filler (no cooldown, e.g. Smite) => spells it
--     normally prefers weren't ready. If BRAT thought one was, lower them.
local _, BRAT = ...
local CD = {}
BRAT.Cooldowns = CD

local GCD_MAX = 1.5    -- anything this short is just the global cooldown
local RATE_UP = 0.5    -- learning speed when BRAT was too pessimistic
local RATE_DOWN = 0.5  -- learning speed when BRAT was too optimistic (same speed, so bad lessons unlearn fast)
-- Telling a reduction from a reset: reductions are spread over the casts in
-- between (Smite x8 -> Chastise 30s early = 3.75s per cast); a reset is one jump.
local MAX_PER_CAST = 0.15 -- more than this share of the cooldown per cast in between = a reset/proc
local CONFIRMED = 3    -- Blizzard must have picked a spell this often before
                       -- "filler picked" counts as evidence it wasn't ready

-- Spec knowledge (cooldown reductions, lengths, DoTs) lives in Data\SpecRules.lua;
-- these read the current spec's set.
local function rules() return BRAT.Rules() end
local function knownRed(x) return rules().reductions[x] end
local function dotDef(x) return rules().dots[x] end

-- Holy Priest: Apotheosis (200183) greatly increases Holy Word cooldown
-- reduction and grants a Holy Word charge when activated. 20s, +12s with
-- Eternal Sanctity (1215245) (duration confirmed in game, 12.1.5). Tooltip: Holy Word cooldown reduction +200%
-- (= 3x), confirmed in game 12.1.5.
local APOTHEOSIS, ETERNAL_SANCTITY = 200183, 1215245
local APOTHEOSIS_MULT = 3
local HOLY_WORDS = { [88625] = true, [2050] = true, [34861] = true } -- Chastise, Serenity, Sanctify
local apoUntil = 0
function CD:InApotheosis() return GetTime() < apoUntil end

-- DoTs you keep up (rules().dots) are treated like a cooldown that ends when
-- it's time to refresh (30% of the duration left, the pandemic window), so NEXT
-- suggests them exactly when they need refreshing. Reset when you change
-- target. Midnight hides debuff timers on enemies, so this is timed from casts.
local PANDEMIC = 0.3

-- Reduction per cast of `y` on `x`. Spells with known rules use only those
-- (learning on top drifted when charges were unknown). Others use what BRAT learned.
local function redOf(x, y)
    local known = knownRed(x)
    if not known then
        local i = BRAT.db.cds[x]
        return (i and i.red and i.red[y]) or 0
    end
    local k = known[y]
    if type(k) == "table" then
        if k.talent and not BRAT.Knows(k.talent) then return 0 end
        -- Per enemy hit, capped (Evoker Causality: Pyre 0.4s per target, at most 2s).
        if k.perTarget then
            local t = (BRAT.Predict and BRAT.Predict.enemies) or 1
            return math.min(k.max or math.huge, k.perTarget * t)
        end
        return k[1]
    end
    return k or 0
end

-- pending[X] = { q = {readyTime...}, castAt = t, counts = {[Y] = casts since} }
local pending = {}

-- One ID per spell: the spell you actually cast right now. A talent can
-- replace one spell with another (Holy Fire replaces Shadow Word: Pain in
-- Midnight), and the game may report a cast under either ID. So every ID is
-- mapped to its base spell's *current* replacement: SW:P and Holy Fire both
-- become Holy Fire when talented, and stay SW:P when not. (Mapping to the base
-- alone wrongly turned Holy Fire into Shadow Word: Pain.)
local keyCache = {}
local function key(id)
    if not id then return id end
    local k = keyCache[id]
    if k == nil then
        local base = BRAT.Safe(C_Spell.GetBaseSpell, id) or id
        local over = BRAT.Safe(C_Spell.GetOverrideSpell, base)
        k = (type(over) == "number" and over ~= 0) and over or base
        keyCache[id] = k
    end
    return k
end
-- Talents/spells changed: replacements may differ now.
local kf = CreateFrame("Frame")
kf:RegisterEvent("SPELLS_CHANGED")
kf:RegisterEvent("TRAIT_CONFIG_UPDATED")
kf:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
kf:SetScript("OnEvent", function() wipe(keyCache) end)
CD.Key = function(_, id) return key(id) end
function CD:IsDot(id) return dotDef(key(id)) ~= nil end

local function info(id)
    local cds = BRAT.db.cds
    cds[id] = cds[id] or {}
    return cds[id]
end

-- Remember the real cooldown/charges whenever the game lets us read them.
function CD:LearnFromGame(raw)
    local id = key(raw)
    local cd = BRAT.Safe(C_Spell.GetSpellCooldown, raw)
    if cd and not BRAT.IsSecret(cd.duration) and not BRAT.IsSecret(cd.isOnGCD)
        and not cd.isOnGCD and cd.duration and cd.duration > GCD_MAX then
        info(id).len = cd.duration
    end
    local ch = BRAT.Safe(C_Spell.GetSpellCharges, raw)
    if ch and not BRAT.IsSecret(ch.maxCharges) and ch.maxCharges then
        info(id).charges = ch.maxCharges
        if not BRAT.IsSecret(ch.cooldownDuration) and ch.cooldownDuration and ch.cooldownDuration > GCD_MAX then
            info(id).len = ch.cooldownDuration
        end
    end
end

-- Full cooldown length in seconds (nil = no real cooldown, i.e. a filler).
function CD:Length(id)
    id = key(id)
    local i = BRAT.db.cds[id]
    if i and i.len then return i.len end
    local ms = BRAT.Safe(GetSpellBaseCooldown, id)
    if ms and ms > GCD_MAX * 1000 then
        info(id).len = ms / 1000
        return ms / 1000
    end
    local known = rules().lengths[id]
    if known then return known end
    local dot = dotDef(id)
    if dot then return dot[1] * (1 - PANDEMIC) end
    return nil
end

-- Seconds taken off X's current cooldown by casts since it started.
local function reduction(x, p)
    local r = 0
    for y, n in pairs(p.counts) do r = r + redOf(x, y) * n end
    return r
end

-- Model's seconds left on X's front charge (negative = ready already).
local function frontLeft(x, p, now)
    return p.q[1] - now - reduction(x, p)
end

-- Nudge X's reduction rates so the model's time left moves by `delta` seconds
-- (positive = X should come back sooner). Normalized LMS step.
local function adjust(x, p, delta, rate)
    local sumSq = 0
    for _, n in pairs(p.counts) do sumSq = sumSq + n * n end
    if sumSq == 0 then return end
    local i = info(x)
    i.red = i.red or {}
    local len = i.len or 60
    for y, n in pairs(p.counts) do
        local r = redOf(x, y) + rate * delta * n / sumSq
        i.red[y] = math.max(0, math.min(len, r))
    end
end

-- The front charge finished at time `t`: start the next one fresh.
local function popFront(x, p, t)
    table.remove(p.q, 1)
    local len = CD:Length(x) or 0
    for k = 1, #p.q do p.q[k] = t + k * len end
    wipe(p.counts)
    if not p.q[1] then pending[x] = nil end
end

-- X is known to be ready right now (Blizzard picked it, or you cast it).
local function proveReady(x, now)
    local p = pending[x]
    if not p or not p.q[1] then return end
    if p.castAt and now - p.castAt <= GCD_MAX then return end -- stale pick
    local left = frontLeft(x, p, now)
    local len = CD:Length(x) or 0
    -- Resets and procs (Empyreal Blaze, Apotheosis) aren't cooldown reductions:
    -- skip if the spell glows / is a free cast, or the time it came back early
    -- is too much per cast in between to be reductions.
    local proc = BRAT.Procs:IsGlowing(x) or (BRAT.Predict.freeCasts and BRAT.Predict.freeCasts[x])
    local casts = 0
    for _, n in pairs(p.counts) do casts = casts + n end
    local perCast = casts > 0 and left / casts or math.huge
    if left > 0 and not proc and not dotDef(x) and not knownRed(x) and not CD:InApotheosis() and perCast <= len * MAX_PER_CAST then
        adjust(x, p, left, RATE_UP)
    end
    popFront(x, p, now)
end

-- Drop charges whose full cooldown has certainly passed.
local function expire(x, now)
    local p = pending[x]
    while p and p.q[1] and p.q[1] <= now do
        popFront(x, p, p.q[1])
        p = pending[x]
    end
    -- Multi-charge spells: also pop when reductions finished the front charge.
    p = pending[x]
    local charges = (BRAT.db.cds[x] and BRAT.db.cds[x].charges) or 1
    while charges > 1 and p and p.q[1] and frontLeft(x, p, now) <= 0 do
        popFront(x, p, now)
        p = pending[x]
    end
end

function CD:OnCast(raw)
    local now = GetTime()
    self:LearnFromGame(raw)
    local id = key(raw)
    -- Apotheosis: Holy Words get a charge right away, and their cooldown
    -- reduction is multiplied while it lasts.
    if id == APOTHEOSIS then
        apoUntil = now + 20 + (BRAT.Knows(ETERNAL_SANCTITY) and 12 or 0)
        for x in pairs(HOLY_WORDS) do
            local hp = pending[x]
            if hp and hp.q[1] then popFront(x, hp, now) end
        end
    end
    -- This cast reduces every other spell's running cooldown.
    local apo = now < apoUntil
    for x, p in pairs(pending) do
        if x ~= id then
            local mult = (apo and HOLY_WORDS[x]) and APOTHEOSIS_MULT or 1
            p.counts[id] = (p.counts[id] or 0) + mult
        end
    end
    -- Casts that also apply a DoT (Shadow: Tentacle Slam applies Vampiric
    -- Touch, which applies Shadow Word: Pain with Misery) restart its timer.
    for d, def in pairs(rules().dots) do
        if d ~= id and def.refreshedBy then
            for _, by in ipairs(def.refreshedBy) do
                if by == id then
                    pending[d] = { q = { now + def[1] * (1 - PANDEMIC) }, counts = {}, castAt = now }
                end
            end
        end
    end
    local len = self:Length(id)
    if not len then return end
    -- A free cast (e.g. Empyreal Blaze: Holy Fire with no cooldown) doesn't
    -- start or change the spell's own cooldown. (Predict uses it up after this.)
    if BRAT.Predict.FreeLeft and BRAT.Predict:FreeLeft(raw) > 0 then return end
    expire(id, now)
    local charges = info(id).charges or 1
    local p = pending[id]
    -- Casting it proves a charge was ready.
    if p and #p.q >= charges then proveReady(id, now) end
    p = pending[id] or { q = {}, counts = {} }
    pending[id] = p
    local last = p.q[#p.q]
    p.q[#p.q + 1] = math.max(now, last or now) + len
    p.castAt = now
end

-- Called when Blizzard's recommendation changes.
function CD:OnPicked(id)
    if not id then return end
    -- Blizzard recommends a spell with free casts (Empyreal Blaze Holy Fire)
    -- because it's free, not because its cooldown is over: not proof of anything.
    if BRAT.Predict.FreeLeft and BRAT.Predict:FreeLeft(id) > 0 then return end
    id = key(id)
    local now = GetTime()
    if pending[id] then
        info(id).picks = (info(id).picks or 0) + 1
        proveReady(id, now)
    elseif self:Length(id) then
        info(id).picks = (info(id).picks or 0) + 1
    else
        -- A filler was picked: spells Blizzard normally prefers aren't ready.
        for x, p in pairs(pending) do
            local i = BRAT.db.cds[x]
            local single = not (i and i.charges and i.charges > 1)
            if single and not dotDef(x) and not knownRed(x) and i and (i.picks or 0) >= CONFIRMED and p.q[1]
                and not (p.castAt and now - p.castAt <= GCD_MAX) then
                local left = frontLeft(x, p, now)
                if left <= 0 then adjust(x, p, left - 0.25, RATE_DOWN) end
            end
        end
    end
end

-- Seconds until a charge is ready by BRAT's own tracking (0 = ready).
function CD:Remaining(id)
    id = key(id)
    local now = GetTime()
    expire(id, now)
    local p = pending[id]
    if not p then return 0 end
    local charges = (BRAT.db.cds[id] and BRAT.db.cds[id].charges) or 1
    if #p.q < charges then return 0 end
    return math.max(0, frontLeft(id, p, now))
end

-- Seconds left on a spell's cooldown: the game's value when readable, else
-- BRAT's estimate. Returns left, estimated (true = BRAT's own tracking).
function CD:Left(id)
    if self:IsDot(id) then return self:Remaining(id), true end
    local cd = BRAT.Safe(C_Spell.GetSpellCooldown, id)
    if cd and not BRAT.IsSecret(cd.startTime) and not BRAT.IsSecret(cd.duration)
        and not BRAT.IsSecret(cd.isOnGCD) then
        if cd.isOnGCD or not cd.duration or cd.duration == 0 then return 0, false end
        return math.max(0, cd.startTime + cd.duration - GetTime()), false
    end
    return self:Remaining(id), true
end

-- Short text of what BRAT has learned, e.g. "Holy Word: Chastise 60s (Smite -4.0s)".
function CD:Describe(limit)
    local out = {}
    local spells = {}
    for x, i in pairs(BRAT.db.cds) do if i.red and next(i.red) then spells[x] = i end end
    for x in pairs(rules().reductions) do spells[x] = BRAT.db.cds[x] or {} end
    for x, i in pairs(spells) do
        local ys = {}
        for y in pairs(i.red or {}) do ys[y] = true end
        for y in pairs(knownRed(x) or {}) do ys[y] = true end
        if next(ys) then
            local parts = {}
            for y in pairs(ys) do
                local r = redOf(x, y)
                if r >= 0.1 then
                    parts[#parts + 1] = ("%s -%.1fs"):format(C_Spell.GetSpellName(y) or y, r)
                end
            end
            if #parts > 0 then
                out[#out + 1] = ("%s %ds (%s)"):format(C_Spell.GetSpellName(x) or x, self:Length(x) or 0, table.concat(parts, ", "))
            end
        end
        if limit and #out >= limit then break end
    end
    return out
end

-- Every spell BRAT is timing that comes off cooldown within `maxLeft` seconds
-- (rotation spells and anything else with a cooldown you've cast), soonest
-- first: { {id, left}, ... }. DoT refresh timers aren't cooldowns: skipped.
function CD:Upcoming(maxLeft)
    local out = {}
    for x in pairs(pending) do
        if not dotDef(x) then
            local left = self:Remaining(x)
            if left > 0 and left <= maxLeft then out[#out + 1] = { id = x, left = left } end
        end
    end
    table.sort(out, function(a, b) return a.left < b.left end)
    return out
end

-- About to waste charges? True if a multi-charge spell (e.g. a Holy Word with
-- 2 charges) is at full charges, or will be within `window` + 3 seconds.
function CD:AboutToCap(id, window)
    id = key(id)
    local max = BRAT.db.cds[id] and BRAT.db.cds[id].charges
    if not max or max < 2 then return false end
    local now = GetTime()
    expire(id, now)
    local p = pending[id]
    local recharging = p and #p.q or 0
    if recharging == 0 then return true end -- all charges up
    if max - recharging == max - 1 then
        return frontLeft(id, p, now) <= (window or 1.5) + 3
    end
    return false
end

-- Forget running timers (spec change). Learned rates are kept.
function CD:Clear() wipe(pending); apoUntil = 0 end

-- Read every rotation spell's real cooldown length and charges (e.g. 2 Holy
-- Word charges) whenever the game allows it: out of combat.
function CD:LearnRotation()
    local list = BRAT.Safe(C_AssistedCombat and C_AssistedCombat.GetRotationSpells)
    if type(list) == "table" then
        for _, id in ipairs(list) do
            if not BRAT.IsSecret(id) then
                self:LearnFromGame(id)
                local over = BRAT.Safe(C_Spell.GetOverrideSpell, id)
                if over and over ~= id then self:LearnFromGame(over) end
            end
        end
    end
    -- Also the spells with default lengths (big cooldowns, defensives), so real
    -- talented values replace the defaults when the game shows them.
    for id in pairs(rules().lengths) do
        if BRAT.Knows(id) then self:LearnFromGame(id) end
    end
end

local tf = CreateFrame("Frame")
tf:RegisterEvent("PLAYER_TARGET_CHANGED")
tf:RegisterEvent("PLAYER_REGEN_ENABLED")
tf:RegisterEvent("PLAYER_ENTERING_WORLD")
tf:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
tf:RegisterEvent("TRAIT_CONFIG_UPDATED")
tf:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_TARGET_CHANGED" then
        -- New target: your DoTs aren't on it yet.
        for x in pairs(rules().dots) do pending[x] = nil end
        if not UnitAffectingCombat("player") then CD:LearnRotation() end
    else
        C_Timer.After(1, function() if not UnitAffectingCombat("player") then CD:LearnRotation() end end)
    end
end)
