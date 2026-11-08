-- BRAT prediction: slot 1 comes from Blizzard; slot 2 comes from either
-- Warcraft Logs data or from learning what Blizzard recommends next.
-- All follow-up data is split by how many enemies you're fighting (1..8+).
local _, BRAT = ...
local Predict = {}
BRAT.Predict = Predict

local LEARN_TIMEOUT = 2.0 -- seconds to wait for the next recommendation
local PRIORITY_MIN = 40   -- learned priority match-ups needed (per enemy count) before NEXT uses it
local HABIT_WEIGHT = 0.2  -- how much "what usually comes next" counts in close priority calls
local MIN_BUCKET_TOTAL = 10 -- below this, also borrow from nearby target counts

local pendingFrom, pendingTime, pendingTargets

-- learn[spec][targets][from][to] = count
-- Blizzard's rotation spells for this spec, plus their current overrides
-- (e.g. Mind Flay -> Mind Flay: Insanity). nil if the list isn't available.
-- (Defined first: everything below uses it.)
local function rotationSet()
    local list = BRAT.Safe(C_AssistedCombat and C_AssistedCombat.GetRotationSpells)
    if type(list) ~= "table" or #list == 0 then return nil end
    -- Each spell as you'd actually cast it now: a replaced spell (Shadow Word:
    -- Pain when Holy Fire is talented) becomes its replacement, so it's never
    -- suggested on its own.
    local set = {}
    for _, id in ipairs(list) do
        if not BRAT.IsSecret(id) and not BRAT.Never(id) then set[BRAT.Cooldowns:Key(id)] = true end
    end
    return set
end

-- Learned Blizzard data: recorded into the Blizzard cache during fights and
-- used from the built Blizzard rotation (Learn.lua).

-- Blizzard's current recommendation (slot 1 raw).
function Predict:GetBlizzardPick()
    if not C_AssistedCombat then return nil end
    local id = BRAT.Safe(C_AssistedCombat.GetNextCastSpell, false)
    if not id or id == 0 then return nil end
    -- Spells the spec rules filter out (Evoker: Tail Swipe) are never shown,
    -- even when Blizzard's assistant picks them.
    if BRAT.Never(id) then return nil end
    -- GetActionSpell is the "one button" proxy spell, never a real pick.
    local proxy = BRAT.Safe(C_AssistedCombat.GetActionSpell)
    if proxy and id == proxy then return nil end
    -- As you'd cast it now (Shadow Word: Pain -> Holy Fire when talented).
    return BRAT.Cooldowns:Key(id)
end

local pendingPreds -- each source's NEXT guess at the moment you cast
local pendingGlow  -- spells glowing (procs) at the moment you cast
local REPEAT_AFTER = 0.6 -- same pick this long after the cast = a real repeat (Smite -> Smite)

function Predict:OnPlayerCast(spellID)
    self.lastCastAt = GetTime()
    if not spellID then return end
    self.lastCastSpell = BRAT.Cooldowns:Key(spellID)
    -- The game may report the cast under a talent's override ID; match by base spell.
    local CDs = BRAT.Cooldowns
    if self.lastPick and spellID ~= self.lastPick and CDs:Key(spellID) == CDs:Key(self.lastPick) then
        spellID = self.lastPick
    end
    -- Casting the spell uses up one free cast.
    local free = self.freeCasts
    local usedFree = false
    for id, n in pairs(free) do
        if type(id) == "number" and CDs:Key(id) == CDs:Key(spellID) then
            usedFree = true
            free[id] = (n > 1) and (n - 1) or nil
            if not free[id] then free["why" .. id] = nil; free["exp" .. id] = nil end
        end
    end
    -- Known procs this cast triggers (e.g. Chastise -> Empyreal Blaze: 2 free Holy Fires).
    -- A proc that gives the same spell again (Evoker Strafing Run: Deep Breath ->
    -- a second Deep Breath) comes from the normal cast only, not the free one.
    for _, fp in ipairs(BRAT.Rules().procs) do
        local renews = fp.gives == fp.spell and usedFree
        if CDs:Key(spellID) == fp.spell and BRAT.Knows(fp.talent) and not renews then
            free[fp.gives] = fp.count
            free["why" .. fp.gives] = fp.name
            free["exp" .. fp.gives] = fp.duration and (GetTime() + fp.duration) or nil
        end
    end
    if spellID and spellID == self.lastPick and UnitAffectingCombat("player") then
        -- You cast Blizzard's pick: it beat every other rotation spell ready now.
        BRAT.Priority:Learn(spellID, self.realTargets or 1, rotationSet())
    end
    if spellID and spellID == self.lastPick then
        pendingFrom, pendingTime, pendingTargets = spellID, GetTime(), self.realTargets or 1
        pendingGlow = BRAT.Procs:Snapshot(spellID)
        -- Ask both sources what comes next, to score them against Blizzard.
        local logsId, logsKind = self:GetNext(spellID, "logs")
        local blizzId, blizzKind = self:GetNext(spellID, "blizzard")
        local function real(k) return k == "proc" or k == "priority" end
        pendingPreds = {
            logs = (logsKind == "logs" or real(logsKind)) and logsId or nil,
            blizzard = (blizzKind == "learned" or real(blizzKind)) and blizzId or nil,
        }
    end
end

-- Called every update with Blizzard's current pick; records transitions.
function Predict:Observe(pick)
    self.lastPick = pick
    if not pendingFrom then return end
    if GetTime() - pendingTime > LEARN_TIMEOUT then
        pendingFrom = nil
        return
    end
    -- A different pick is Blizzard's answer. The same pick counts once Blizzard
    -- has had time to update (otherwise it's just the old recommendation).
    if pick and (pick ~= pendingFrom or GetTime() - pendingTime >= REPEAT_AFTER) then
        -- Free casts: Blizzard wants a cooldown spell again right after casting it
        -- (a proc reset it). Stop assuming that once it moves on.
        local free = Predict.freeCasts
        -- (Not for spells with a known proc rule like Empyreal Blaze: those are
        -- counted exactly, and a normal cast after a free one isn't a free cast.)
        if pick == pendingFrom and not Predict:CanRepeat(pick) and not Predict:HasKnownProc(pick) then
            -- At least the one Blizzard is showing now.
            free[pick] = math.max(free[pick] or 0, 1)
        elseif free[pendingFrom] and not free["why" .. pendingFrom] then
            -- A learned free cast (not a known proc): Blizzard moved on, so it's gone.
            free[pendingFrom] = nil
        end
        -- Score before learning, so the learned guess can't "see" the answer.
        if BRAT.Stats then BRAT.Stats:Score(pendingPreds, pick, pendingTargets) end
        pendingPreds = nil
        BRAT.Procs:Learn(pendingGlow, pick)
        pendingGlow = nil
        -- Into this fight's Blizzard cache entry (written when combat ends).
        BRAT.Learn:Record(pendingTargets, pendingFrom, pick)
        pendingFrom = nil
    end
end

-- Can `id` be NEXT after casting `current`? A spell can follow itself only if it
-- has no real cooldown (Smite -> Smite) or has charges; one with a cooldown
-- won't be ready right after you cast it.
local function canRepeat(id)
    if not BRAT.Cooldowns:Length(id) then return true end
    local i = BRAT.db.cds[id]
    return i and i.charges and i.charges > 1
end

-- Spells about to be cast before this prediction (NOW, when predicting THEN):
-- they'll be on cooldown by then unless they can repeat.
local castBefore

-- Spells with "free casts" right now: a proc lets them skip their cooldown
-- (e.g. Empyreal Blaze stacks -> instant Holy Fire, again and again).
-- Learned live: set when Blizzard recommends a spell again right after you cast
-- it, cleared when it stops doing that (stacks used up).
local freeCasts = {}   -- [spellID] = free casts left; ["why"..spellID] = which proc
Predict.freeCasts = freeCasts
function Predict:CanRepeat(id) return canRepeat(id) end

-- Procs don't carry over between fights.
local regen = CreateFrame("Frame")
regen:RegisterEvent("PLAYER_REGEN_ENABLED")
regen:SetScript("OnEvent", function() wipe(freeCasts) end)

-- Known procs that give free casts (Data\SpecRules.lua: procs): casting `spell`
-- with `talent` grants `count` casts of `gives` that skip its cooldown, e.g.
-- Holy: Empyreal Blaze, Chastise -> next two Holy Fires instant, no cooldown.
local function freeProcs() return BRAT.Rules().procs end

-- Does a known proc rule give free casts of this spell (and do you have its talent)?
function Predict:HasKnownProc(id)
    local k = BRAT.Cooldowns:Key(id)
    for _, fp in ipairs(freeProcs()) do
        if fp.gives == k and BRAT.Knows(fp.talent) then return true end
    end
    return false
end

-- How many free casts (proc lets it skip its cooldown) this spell has: known
-- procs or learned (Blizzard repeated it), else 1 if its button glows.
local function freeCount(id)
    local exp = freeCasts["exp" .. id]
    if exp and GetTime() > exp then
        -- The proc ran out (e.g. Empyreal Blaze after 30s).
        freeCasts[id], freeCasts["why" .. id], freeCasts["exp" .. id] = nil, nil, nil
    end
    local n = freeCasts[id]
    if n and n > 0 then return n, freeCasts["why" .. id] or "Blizzard repeated it" end
    -- Spells with a known proc rule (Holy Fire / Empyreal Blaze) are counted
    -- exactly; a lingering glow must not make a normal cast look free.
    if Predict:HasKnownProc(id) then return 0 end
    if BRAT.Procs:IsGlowing(id) then return 1, "glowing" end
    return 0
end

-- Free casts available right now (before any prediction), e.g. Empyreal Blaze.
function Predict:FreeLeft(id)
    local n = freeCount(id)
    if n > 0 then return n end
    -- The cast may be reported under another ID of the same spell (talent override).
    local k = BRAT.Cooldowns:Key(id)
    for other in pairs(freeCasts) do
        if type(other) == "number" and other ~= id and BRAT.Cooldowns:Key(other) == k then
            n = freeCount(other)
            if n > 0 then return n end
        end
    end
    return 0
end

-- Is a free cast left for `id` after `current` (NOW) is cast? If NOW is this
-- same spell, NOW uses one of them, so only the rest count.
function Predict:IsFree(id, current)
    local n, why = freeCount(id)
    local hadFree = n > 0
    if id == current or (castBefore and castBefore[id]) then n = n - 1 end
    -- NOW itself may trigger a known proc (NOW = Chastise -> 2 free Holy Fires next).
    local CDs = BRAT.Cooldowns
    for _, fp in ipairs(freeProcs()) do
        -- Self-renewing procs (Strafing Run): NOW being the free cast gives nothing.
        local renews = fp.gives == fp.spell and hadFree
        if fp.gives == id and BRAT.Knows(fp.talent) and not renews then
            if current and CDs:Key(current) == fp.spell then
                n = math.max(n, fp.count)
                why = fp.name
            elseif castBefore then
                -- Predicting THEN: NOW triggered it and NEXT (this same spell) used one.
                for b in pairs(castBefore) do
                    if CDs:Key(b) == fp.spell then
                        n = math.max(n, fp.count - (id == current and 1 or 0))
                        why = fp.name
                    end
                end
            end
        end
    end
    return n > 0, why
end

-- How long until the predicted spell gets cast: NOW's cast time or your
-- (haste-adjusted) global cooldown, whichever is longer; for THEN, plus the
-- same for NEXT. A spell counts as ready if it's ready by then.
local function readyWindow(current)
    local function one(id) return math.max(BRAT.GCD(), id and BRAT.CastTime(id) or 0) end
    local w = one(current) + 0.1
    if castBefore then for b in pairs(castBefore) do w = w + one(b) end end
    return w
end

-- Warcraft Logs mode, spells the guide doesn't rank: score from how often top
-- players cast it here (share of casts in the Warcraft Logs rotation), kept
-- between the guide's filler (0.2) and its main spells (0.8+).
local function logsScore(share) return 0.15 + 0.6 * (share or 0) end

-- Share of each spell among all casts at `targets` enemies in a Warcraft Logs
-- rotation (used when there's no "after spell X" to look at, e.g. idle NOW).
local function bucketShares(data, targets)
    local b = data and data[math.min(targets, BRAT.GetCap())]
    local totals, sum = {}, 0
    if b then
        for _, tos in pairs(b) do
            for id, n in pairs(tos) do totals[id] = (totals[id] or 0) + n; sum = sum + n end
        end
    end
    local out = {}
    for id, n in pairs(totals) do
        local s = n / math.max(sum, 1)
        out[id] = (out[id] or 0) + s
        -- Also under the ID you cast it as now (logs may hold another ID of the spell).
        local k = BRAT.Cooldowns:Key(id)
        if k ~= id then out[k] = (out[k] or 0) + s end
    end
    return out
end

-- While you're casting (or in the global cooldown right after a cast) the game
-- can report every spell as unusable / locked: Evoker empowers do this the
-- whole time you hold them and a moment after. That's the cast, not the spell,
-- so then "usable" isn't trusted and readiness comes from BRAT's own cooldown
-- timers (fillers with no cooldown are ready).
local castingNow -- defined below
local function locked()
    return castingNow() ~= nil or GetTime() - (Predict.lastCastAt or 0) < BRAT.GCD()
end
local function usable(id) return BRAT.IsUsable(id) or locked() end
local function readySoon(id, window)
    if BRAT.IsReadySoon(id, window) then return true end
    return locked() and BRAT.Cooldowns:Remaining(id) <= window
end

local function candidateOK(id, current)
    if not id or BRAT.Never(id) then return false end
    if Predict:IsFree(id, current) then
        -- A proc: ready even if its cooldown timer says otherwise.
        return usable(id) and not BRAT.HasOwnBuff(id)
    end
    -- A spell can't normally follow itself (casting it starts its cooldown),
    -- unless that cast is free: a free Empyreal Holy Fire leaves the cooldown
    -- alone, so a normal Holy Fire can still come right after it.
    local castFree = (id == current or (castBefore and castBefore[id])) and Predict:FreeLeft(id) > 0
    local repeatOK = canRepeat(id) or castFree
    return (id ~= current or repeatOK) and usable(id) and readySoon(id, readyWindow(current))
        and not BRAT.HasOwnBuff(id)
        and not (castBefore and castBefore[id] and not repeatOK)
end

-- Follow-ups of `current` at `targets` enemies, from any number of
-- [targets][from][to] tables. If that exact count is thin, widen to
-- neighbors (weight halves per step) so 3 targets can borrow from 2 and 4.
local function gather(sources, current, targets)
    local merged, total = {}, 0
    for radius = 0, BRAT.MAX_TARGETS do
        local w = 0.5 ^ radius
        for _, k in ipairs(radius == 0 and { targets } or { targets - radius, targets + radius }) do
            for _, data in ipairs(sources) do
                local src = data[k] and data[k][current]
                if src then
                    for id, n in pairs(src) do
                        merged[id] = (merged[id] or 0) + n * w
                        total = total + n * w
                    end
                end
            end
        end
        if total >= MIN_BUCKET_TOTAL then break end
    end
    return merged
end

-- Returns spellID, source ("logs" | "learned" | "list") for the slot-2 prediction.
-- sourceOverride ("logs" | "blizzard") asks a specific source; default is the active one.
function Predict:GetNext(current, sourceOverride)
    if not current then return nil end
    self.after = current -- spec rules can ask what's cast before this prediction (Predict:Unspent)
    self.window = readyWindow(current) -- ...and how long until it's cast (Evoker: Essence regen)
    local spec = BRAT.GetSpecID()
    local targets = self.targets or 1

    -- 1) Known follow-ups from the chosen source, most frequent first.
    local sources, kind, rotSet = {}, "learned", nil
    -- The rotation for where you are: this boss, this dungeon, Raid or Mythic+ (Context.lua).
    local logs = BRAT.Context:Data()
    if (sourceOverride or BRAT.ActiveSource()) == "logs" and logs and next(logs) then
        sources[1] = logs; kind = "logs"
        rotSet = rotationSet()
    else
        -- Blizzard mode, or Logs mode with no logs data for this spec yet:
        -- the built Blizzard rotation for where you are.
        local learned = BRAT.Learn:Data()
        if learned then sources[#sources + 1] = learned end
    end

    local merged = gather(sources, current, targets)
    local sorted, total = {}, 0
    for id, n in pairs(merged) do
        total = total + n
        if n >= BRAT.db.minSamples then sorted[#sorted + 1] = { id = id, n = n } end
    end
    table.sort(sorted, function(a, b) return a.n > b.n end)

    -- 0) Decide on the fly: of the rotation spells that will be ready when NOW
    -- finishes, the one Blizzard's learned priority ranks highest. The habit
    -- data (what usually comes after NOW) only breaks close calls.
    -- Works from the first cast: before anything is learned, spells with a real
    -- cooldown start above fillers (see Priority.lua).
    do
        rotSet = rotSet or rotationSet()
        local cands = {}
        for id in pairs(rotSet or {}) do cands[id] = true end
        for id in pairs(merged) do if kind ~= "logs" or not rotSet or rotSet[id] then cands[id] = true end end
        -- Warcraft Logs mode: how often top players cast each spell at this enemy
        -- count. A spell the guide doesn't rank and they never cast here (Evoker:
        -- Tail Swipe) isn't suggested at all.
        local overall = kind == "logs" and bucketShares(logs, targets) or nil
        local bestId, bestScore
        local moving = BRAT.IsMoving()
        for id in pairs(cands) do
            local p, games = BRAT.Priority:Score(id, targets, (self:IsFree(id, current)))
            if p and overall and games >= 0 and not overall[id] then p = nil end
            if p and candidateOK(id, current) then
                local share = (merged[id] or 0) / math.max(total, 1)
                local habit = 0
                if games >= 0 then
                    if kind == "logs" then
                        -- Warcraft Logs mode: spells the guide doesn't rank follow
                        -- the Warcraft Logs rotation, not what was learned from Blizzard.
                        p = logsScore(share)
                    else
                        -- Habit only breaks close calls between learned spells.
                        habit = HABIT_WEIGHT * share
                    end
                end
                -- The guide's order (games = -1) stands as is.
                local score = p + habit
                -- Moving: a spell with a cast time can't be cast (unless a proc makes it
                -- instant), nor a channel / empowered spell (spec rules: stationary).
                if moving and BRAT.MustStand(id, (self:IsFree(id, current))) then score = score - 1 end
                -- About to cap charges (e.g. 2 Holy Word charges): use one now so no
                -- cooldown reduction is wasted.
                if BRAT.Cooldowns:AboutToCap(id, readyWindow(current)) then score = score + 0.3 end
                if not bestScore or score > bestScore then bestId, bestScore = id, score end
            end
        end
        if bestId then return bestId, "priority" end
    end
    local pickId, pickShare
    for _, e in ipairs(sorted) do
        local allowed = true -- learned data came from Blizzard's picks already
        if kind == "logs" then
            -- Only suggest spells Blizzard's assistant also uses (skips
            -- defensives, trinkets, talents you don't have).
            if rotSet then allowed = rotSet[e.id] == true else allowed = BRAT.Knows(e.id) end
        end
        if allowed and candidateOK(e.id, current) then
            pickId, pickShare = e.id, e.n / total
            break
        end
    end

    -- A proc is lit up: use it if Blizzard picks it next more often than the
    -- normal follow-up gets picked.
    rotSet = rotSet or rotationSet()
    local procId, procP = BRAT.Procs:Best(function(id)
        return (not rotSet or rotSet[id]) and candidateOK(id, current)
    end)
    if procId and procId ~= pickId and procP >= (pickShare or 0) then return procId, "proc" end
    if pickId then return pickId, kind end

    -- 1b) Nothing known after this exact spell: the spell most cast at this enemy
    -- count in the same data (the filler, e.g. Smite on single target).
    if sources[1] then
        local totals = {}
        for _, data in ipairs(sources) do
            local b = data[math.min(targets, BRAT.GetCap())]
            if b then for _, tos in pairs(b) do for id, n in pairs(tos) do totals[id] = (totals[id] or 0) + n end end end
        end
        local list = {}
        for id, n in pairs(totals) do list[#list + 1] = { id = id, n = n } end
        table.sort(list, function(a, b) return a.n > b.n end)
        for _, e in ipairs(list) do
            local allowed = kind ~= "logs" or not rotSet or rotSet[e.id]
            if allowed and candidateOK(e.id, current) then return e.id, "list" end
        end
    end

    -- 2) Fallback: Blizzard's rotation spell list, in its order.
    local list = BRAT.Safe(C_AssistedCombat and C_AssistedCombat.GetRotationSpells)
    if type(list) == "table" then
        for _, id in ipairs(list) do
            if not BRAT.IsSecret(id) and candidateOK(id, current) then
                return id, "list"
            end
        end
    end
    return nil
end

-- Final two spells to show.
function Predict:GetQueue()
    local pick = self:GetBlizzardPick()
    -- Real enemy count (capped: above the spec's rotation cap nothing changes).
    -- Learning records under this; NEXT uses the user's remapped rotation.
    self.cap = BRAT.GetCap()
    -- Uncapped enemy count, for spec rules that care past the rotation cap
    -- (Evoker: Pyre at 5+, Eternity Surge rank).
    self.enemies = BRAT.EnemyCount(pick)
    self.realTargets = math.min(self.enemies, self.cap)
    self.targets = BRAT.GetRemap(self.realTargets)
    self:Observe(pick)
    -- Each new Blizzard pick teaches the cooldown tracker (see Cooldowns.lua).
    local changed = pick ~= self.prevPick
    if changed then
        self.prevPick = pick
        BRAT.Cooldowns:OnPicked(pick)
        -- Learn Blizzard's priority: this pick beat every other ready rotation spell.
        -- Skipped just after a cast, when the pick may be a stale one.
        if pick and UnitAffectingCombat("player") and GetTime() - (self.lastCastAt or 0) > 0.2 then
            BRAT.Priority:Learn(pick, self.realTargets, rotationSet())
        end
    end

    local first = pick
    -- NOW is Blizzard's pick. Override it only if it's a buff you already have
    -- (e.g. Fortitude is up), or the game itself (not BRAT's in-combat estimate)
    -- says it's on cooldown and no proc makes it free: Blizzard knows about
    -- procs like Empyreal Blaze, BRAT's timer may not.
    if first then
        local left, estimated = BRAT.Cooldowns:Left(first)
        local onRealCooldown = not estimated and left > BRAT.GCD() + 0.1 and not self:IsFree(first)
        if onRealCooldown or BRAT.HasOwnBuff(first) then
            first = self:GetNext(first) or first
        end
    end
    -- Warcraft Logs mode: NOW is BRAT's own decision (guide rules + the Warcraft
    -- Logs rotation for this boss / dungeon / Raid / Mythic+). Learn-from-Blizzard
    -- mode: NOW is Blizzard's pick. (Blizzard's pick is always still read for
    -- learning, and is the fallback when BRAT has no answer.)
    self.nowFrom = "blizzard"
    -- Learn-from-Blizzard mode with a built Blizzard rotation: NOW is BRAT's
    -- decision from that rotation too. Blizzard's own pick is only used when the
    -- chosen source has no rotation for this spec (none built / cleared).
    local useMine
    if BRAT.ActiveSource() == "logs" then
        local logsData = BRAT.Context:Data()
        useMine = logsData and next(logsData) ~= nil
    else
        useMine = BRAT.Learn:HasRotation()
    end
    -- In and out of combat: before a pull BRAT reads the real cooldowns, so its
    -- pick (the opener) is at its most reliable then.
    -- Also when Blizzard's pick was filtered out (spec rules: never): BRAT's own pick.
    if useMine or (not first and UnitAffectingCombat("player")) then
        local mine = self:BestNow()
        if mine then first, self.nowFrom = mine, "brat" end
    end
    self.shownNow = first
    local second, source = self:GetNext(first)
    self.lastKind = source
    -- /brat watch: one chat line whenever NEXT changes, with the reason.
    if self.watch and (second ~= self.watchLast or first ~= self.watchNow) then
        self.watchLast, self.watchNow = second, first
        self:WatchLine(first, second, source)
    end
    if changed then BRAT.History:OnPick(pick, first, second, source)
    else BRAT.History:OnShown(first, second) end

    -- THEN: the spell after NEXT (only when the display shows 2 upcoming spells).
    local third, source3
    if second and (BRAT.db.nextCount or 1) >= 2 then
        castBefore = first and { [first] = true } or nil
        third, source3 = self:GetNext(second)
        castBefore = nil
    end
    return first, second, source, third, source3
end

-- The spell you're casting right now (cast or channel), or nil.
function castingNow() -- the local declared above candidateOK
    for _, fn in ipairs({ UnitCastingInfo, UnitChannelInfo }) do
        local ok, name, _, _, _, _, _, _, a8, a9 = pcall(fn, "player")
        if ok and name and not BRAT.IsSecret(name) then
            -- UnitCastingInfo: spellID is the 9th value; UnitChannelInfo: the 8th.
            local id = (fn == UnitCastingInfo) and a9 or a8
            if type(id) == "number" and not BRAT.IsSecret(id) then return id end
        end
    end
end

-- The spell the current prediction comes after, if you haven't cast it yet
-- (it's NOW on the display, not the spell you're casting or just cast). Its
-- resource cost isn't spent yet: Evoker rules take it off the Essence they read.
function Predict:Unspent()
    local a = self.after
    if not a then return nil end
    local K = BRAT.Cooldowns.Key
    local casting = castingNow()
    if casting and K(nil, casting) == K(nil, a) then return nil end
    if self.lastCastSpell == K(nil, a) and GetTime() - (self.lastCastAt or 0) < BRAT.GCD() then return nil end
    return a
end

-- BRAT's own NOW (setting "NOW from: BRAT").
--   Casting, or still in the global cooldown of your last cast -> the spell to
--   press when that finishes: BRAT's NEXT for it, so NEXT moves into NOW.
--   Idle -> the highest-priority spell ready right now.
-- nil = no opinion (Blizzard's pick is used instead).
function Predict:BestNow()
    local after = castingNow()
    if not after and self.lastCastSpell and GetTime() - (self.lastCastAt or 0) < BRAT.GCD() then
        after = self.lastCastSpell
    end
    if after then return (self:GetNext(after)) end
    self.after, self.window = nil, 0 -- idle: nothing is cast before this pick

    local tg = self.targets or 1
    local moving = BRAT.IsMoving()
    local logsMode = BRAT.ActiveSource() == "logs"
    local shares = logsMode and bucketShares(BRAT.Context:Data(), tg) or {}
    local bestId, bestScore
    for id in pairs(rotationSet() or {}) do
        local free = self:IsFree(id)
        local ready = free or BRAT.IsReadySoon(id, 0.25)
        if ready and BRAT.IsUsable(id) and not BRAT.HasOwnBuff(id) then
            local score, games = BRAT.Priority:Score(id, tg, free)
            -- Spells the guide doesn't rank: Warcraft Logs mode uses the Warcraft
            -- Logs shares; Blizzard mode uses the priority from the Blizzard rotation.
            if games >= 0 and logsMode then
                -- Never cast by top players at this enemy count: not suggested.
                score = shares[id] and logsScore(shares[id]) or nil
            end
            if score then
                if moving and BRAT.MustStand(id, free) then score = score - 1 end
                if BRAT.Cooldowns:AboutToCap(id, 0.25) then score = score + 0.3 end
                if not bestScore or score > bestScore then bestId, bestScore = id, score end
            end
        end
    end
    return bestId
end

-- Heads-up: spells with a cooldown coming back within `lookahead` seconds
-- (Chastise, Holy Fire, Apotheosis, Halo, defensives...), soonest first, at
-- most `max`, leaving out what NOW/NEXT/THEN already show and free casts.
-- Returns { {id, left}, ... }.
function Predict:ComingUp(shown, lookahead, max)
    local out = {}
    if not lookahead or lookahead <= 0 then return out end
    local current = shown[1]
    local skip = {}
    for _, id in pairs(shown) do if id then skip[BRAT.Cooldowns:Key(id)] = true end end
    for _, e in ipairs(BRAT.Cooldowns:Upcoming(readyWindow(current) + lookahead)) do
        if not skip[e.id] and not BRAT.Never(e.id) and BRAT.Knows(e.id) and not self:IsFree(e.id, current) then
            out[#out + 1] = e
            if #out >= (max or 3) then break end
        end
    end
    return out
end

-- One line for /brat watch, e.g.
-- "12:04:31 NOW Smite > NEXT Holy Fire [priority] cd 0.8s est, NOW takes 1.3s"
function Predict:WatchLine(now, nxt, kind)
    local function name(id) return (id and C_Spell.GetSpellName(id)) or "-" end
    local parts = { ("%s NOW %s (%s) > NEXT %s [%s]"):format(date("%H:%M:%S"), name(now),
        self.nowFrom == "brat" and "BRAT" or "Blizzard", name(nxt), tostring(kind)) }
    if nxt then
        local left, est = BRAT.Cooldowns:Left(nxt)
        parts[#parts + 1] = ("cd %.1fs%s, NOW takes %.1fs"):format(left, est and " est" or "", readyWindow(now))
        local free, why = self:IsFree(nxt, now)
        if free then parts[#parts + 1] = "FREE (" .. tostring(why) .. ")" end
        local n = self:FreeLeft(nxt)
        if n > 0 then parts[#parts + 1] = ("free casts left %d"):format(n) end
        if BRAT.Procs:IsGlowing(nxt) then parts[#parts + 1] = "glowing" end
    end
    print("|cff66ccffBRAT|r " .. table.concat(parts, ", "))
end

-- /brat why: how NEXT was chosen right now, step by step.
function Predict:Why(say)
    local function name(id) return (id and C_Spell.GetSpellName(id)) or tostring(id) end
    local now = self.shownNow or self.lastPick
    if not now then say("no NOW spell right now. Target an enemy and try again.") return end
    local spec = BRAT.GetSpecID()
    local src = BRAT.ActiveSource()
    local _, ctxKind, ctxLabel = BRAT.Context:Get()
    local nxt, kind = self:GetNext(now)
    say(("NOW: %s (from %s; Blizzard's pick: %s). NEXT: %s (from: %s)"):format(name(now),
        self.nowFrom == "brat" and "BRAT's rotation" or "Blizzard's assistant", name(self.lastPick),
        name(nxt), tostring(kind)))
    say("Spec rules: " .. (BRAT.Rules().notes or "none for this spec yet (everything is learned)"))
    if nxt then
        local left, est = BRAT.Cooldowns:Left(nxt)
        local free, freeWhy = self:IsFree(nxt, now)
        say(("  Timing: NOW takes about %.1fs; NEXT has %.1fs cooldown left%s%s."):format(
            readyWindow(now), left, est and " (BRAT's estimate)" or "",
            free and (", but is a free cast (" .. tostring(freeWhy) .. ")") or
            (left > 0 and ", so it'll be ready when NOW finishes" or "")))
    end
    say(("Source: %s. Rotation: %s. Enemies: %d seen, using the %d-target bucket (cap %d)."):format(
        src == "logs" and "Warcraft Logs" or "Learn from Blizzard", src == "logs" and tostring(ctxLabel) or "-",
        self.realTargets or 1, self.targets or 1, BRAT.GetCap()))

    -- Live priority (what decides NEXT once enough is learned).
    local tg = self.targets or 1
    local known = math.floor(BRAT.Priority:Learned(tg))
    say(("Priority at %d target(s): %d match-ups learned%s"):format(tg, known,
        known < PRIORITY_MIN and " (still mostly the starting guess: cooldown spells above fillers)" or ""))
    -- Every rotation spell (learned or still on the starting guess), best first.
    local ranked = {}
    for id in pairs(rotationSet() or {}) do
        local score, g = BRAT.Priority:Score(id, tg, (self:IsFree(id, now)))
        ranked[#ranked + 1] = { id = id, score = score, g = g }
    end
    table.sort(ranked, function(a, b) return a.score > b.score end)
    for i, r in ipairs(ranked) do
        if i > 8 then break end
        local ready = BRAT.IsReadySoon(r.id, 1.6)
        local left, est = BRAT.Cooldowns:Left(r.id)
        local how = est and " (BRAT's estimate)" or " (game)"
        local free, why = self:IsFree(r.id, now)
        if free then how = how .. " |cffffe633free cast: " .. why .. "|r" end
        local basis = r.g < 0 and "guide" or ("%d learned"):format(r.g)
        say(("    %d. %s  score %.0f%% (%s)  %s"):format(i, name(r.id), r.score * 100, basis,
            ready and ("|cff33e64dready|r" .. how) or ("|cffff8800cooldown %.1fs|r%s"):format(left, how)))
    end

    local reds = BRAT.Cooldowns:Describe(5)
    say("  Cooldown reductions in use: " .. (#reds > 0 and table.concat(reds, "; ") or "none yet"))
    local ch = BRAT.db.cds[BRAT.Cooldowns:Key(88625)]
    if ch and ch.charges then say(("  Holy Word: Chastise charges: %d"):format(ch.charges)) end
    -- Spec-specific facts (Data\SpecRules.lua: why), e.g. Evoker Essence / Pyre choice.
    if BRAT.Rules().why then BRAT.Rules().why(say) end
    -- Cooldown length BRAT uses for each rotation spell (compare with the tooltips).
    local lens = {}
    for id in pairs(rotationSet() or {}) do
        local len = BRAT.Cooldowns:Length(id)
        if len and not BRAT.Cooldowns:IsDot(id) then
            local i = BRAT.db.cds[BRAT.Cooldowns:Key(id)]
            lens[#lens + 1] = ("%s %.0fs%s"):format(name(id), len,
                (i and i.charges and i.charges > 1) and (" x" .. i.charges) or "")
        end
    end
    say("  Cooldown lengths used: " .. (#lens > 0 and table.concat(lens, ", ") or "none"))

    local data
    if src == "logs" then data = BRAT.Context:Data() else data = BRAT.Learn:Data() end
    if not (data and next(data)) then say("  no data for this source/spec, so NEXT is a fallback guess.") return end
    local merged, total = {}, 0
    for r = 0, BRAT.MAX_TARGETS do
        local w = 0.5 ^ r
        for _, k in ipairs(r == 0 and { self.targets or 1 } or { (self.targets or 1) - r, (self.targets or 1) + r }) do
            local tos = data[k] and data[k][now]
            if tos then for id, n in pairs(tos) do merged[id] = (merged[id] or 0) + n * w; total = total + n * w end end
        end
        if total >= 10 then break end
    end
    if total == 0 then say(("  the data has nothing after %s at this enemy count, so NEXT falls back to the most-cast spell."):format(name(now))) return end
    local list = {}
    for id, n in pairs(merged) do list[#list + 1] = { id = id, n = n } end
    table.sort(list, function(a, b) return a.n > b.n end)
    say(("  After %s, the data says:"):format(name(now)))
    for _, e in ipairs(list) do
        local why = {}
        local free, freeWhy = self:IsFree(e.id, now)
        if e.n < BRAT.db.minSamples then why[#why + 1] = "too few samples" end
        if not free then
            if e.id == now and not canRepeat(e.id) and self:FreeLeft(e.id) == 0 then
                why[#why + 1] = "same spell, has a cooldown"
            end
            if not BRAT.IsReadySoon(e.id, readyWindow(now)) then
                local left, est = BRAT.Cooldowns:Left(e.id)
                why[#why + 1] = ("on cooldown %.1fs%s"):format(left, est and " (BRAT's estimate)" or "")
            end
        end
        if not BRAT.IsUsable(e.id) then why[#why + 1] = "not usable" end
        if BRAT.HasOwnBuff(e.id) then why[#why + 1] = "buff already up" end
        if not BRAT.Knows(e.id) then why[#why + 1] = "not known/talented" end
        say(("    %s: %.0f%% (%.0f)  %s%s"):format(name(e.id), 100 * e.n / total, e.n,
            #why > 0 and ("skipped: " .. table.concat(why, ", ")) or "|cff33e64dOK|r",
            free and (" |cffffe633free cast: " .. tostring(freeWhy) .. "|r") or ""))
    end
    for id in pairs(BRAT.Procs:Snapshot() or {}) do say("  glowing (proc): " .. name(id)) end
end

function Predict:PrintStats(say)
    local spec = BRAT.GetSpecID()
    -- "1:12 2:9 3:5": spells known per target count, in a rotation for here.
    local function buckets(d)
        local parts = {}
        for k = 1, BRAT.MAX_TARGETS do
            local n = BRAT.RotationBuilder.Count(d and d[k])
            if n > 0 then parts[#parts + 1] = ("%s:%d"):format(k == BRAT.MAX_TARGETS and k .. "+" or k, n) end
        end
        return #parts > 0 and table.concat(parts, " ") or "none"
    end
    say(("source: %s, targets now: %s (%s)"):format(
        BRAT.db.source == "logs" and "Warcraft Logs" or "learn from Blizzard",
        tostring(self.targets or "?"), BRAT.db.targets == "auto" and "auto" or "forced"))
    say("spells known per target count (targets:spells), rotation for here")
    for _, key in ipairs({ "logs", "blizzard" }) do
        local src = BRAT.Sources[key]
        local d, label = src:Data()
        say(("  %s: %s (%s)"):format(src.name, buckets(d), label or "no rotation"))
    end
    local info = BRAT.WCLInfo(spec)
    if info then say(("Warcraft Logs data from %s, %d players (%s)."):format(info.date or "?", info.players or 0, info.zone or "?")) end
end
