-- BRAT priority: Blizzard's spell priority, per spec and enemy count, so NEXT
-- can be decided on the fly from what will actually be ready. Recorded during
-- fights into the Blizzard cache; used once the Blizzard rotation is (re)built.
-- Every time Blizzard's pick changes, the picked spell "beat" every other
-- rotation spell that was ready at that moment. Each spell's score is the share
-- of those match-ups it won: a spell Blizzard casts whenever it's ready (Holy
-- Word: Chastise) scores near 1, the filler (Smite) near 0.
local _, BRAT = ...
local Priority = {}
BRAT.Priority = Priority

local MAX_GAMES = 600   -- per spell; older results fade (halved) so talent changes catch up
local READY_NOW = 0.3   -- "ready" when Blizzard picked: under this much cooldown left

-- Match-ups are recorded into the current fight (Blizzard cache, Learn.lua) and
-- read from the built Blizzard rotation, so they follow cache -> rebuild too.
local function tbl(create, bucket)
    if create then return BRAT.Learn:SessionPrio(bucket) end
    return BRAT.Learn:Prio(bucket)
end

-- Blizzard picked `pick` with `bucket` enemies; `rotation` = set of rotation spell IDs.
function Priority:Learn(pick, bucket, rotation)
    if not pick or not rotation then return end
    local t = tbl(true, bucket)
    if not t then return end -- not in a fight
    local function rec(id)
        local r = t[id]
        if not r then r = { w = 0, g = 0 }; t[id] = r end
        if r.g >= MAX_GAMES then r.w = r.w / 2; r.g = r.g / 2 end
        return r
    end
    local winner = rec(pick)
    for id in pairs(rotation) do
        if id ~= pick and BRAT.IsUsable(id) and BRAT.IsReadySoon(id, READY_NOW) and not BRAT.HasOwnBuff(id) then
            local loser = rec(id)
            winner.w = winner.w + 1
            winner.g = winner.g + 1
            loser.g = loser.g + 1
        end
    end
end

-- Known priority from current guides, per spec (Data\SpecRules.lua: order):
-- fixed scores that learning doesn't change (learning from Blizzard drifted
-- when cooldown estimates were off). Spells not listed are learned as usual.

-- The guide's score for this spell, or nil if the guide doesn't rank it.
function Priority:Known(id, bucket, free)
    local fn = BRAT.Rules().order[BRAT.Cooldowns:Key(id)]
    return fn and fn(bucket, free) or nil
end

-- Starting guess before anything is learned: a spell with a real cooldown
-- (Chastise, Holy Fire) is worth casting when it's ready; a filler without one
-- (Smite, Holy Nova) ranks below. Learned results replace this as they come in.
local PRIOR_WEIGHT = 4 -- the guess counts like this many match-ups
local function prior(id)
    return BRAT.Cooldowns:Length(id) and 0.75 or 0.25
end

-- Score 0..1 (share of match-ups won, blended with the starting guess) and how
-- many match-ups it's based on. Uses the nearest enemy count with data.
-- Returns games = -1 for a score that comes from the guide (KNOWN_ORDER).
-- `free` = a proc makes this cast free (e.g. Empyreal Blaze Holy Fire).
function Priority:Score(id, bucket, free)
    local known = self:Known(id, bucket, free)
    if known then return known, -1 end
    local p = prior(id)
    for r = 0, BRAT.MAX_TARGETS do
        for _, k in ipairs(r == 0 and { bucket } or { bucket - r, bucket + r }) do
            local t = tbl(false, k)
            local s = t and t[id]
            if s and s.g >= 1 then return (s.w + p * PRIOR_WEIGHT) / (s.g + PRIOR_WEIGHT), s.g end
        end
    end
    return p, 0
end

-- Total match-ups learned for this enemy count (how much BRAT knows).
function Priority:Learned(bucket)
    local t, n = tbl(false, bucket), 0
    if t then for _, s in pairs(t) do n = n + s.g end end
    return n / 2
end

-- Ranked list for display: { {id, score, games}, ... }
function Priority:Ranked(bucket)
    local out = {}
    for id in pairs(tbl(false, bucket) or {}) do
        local score, g = self:Score(id, bucket)
        out[#out + 1] = { id = id, score = score, g = g }
    end
    table.sort(out, function(a, b) return a.score > b.score end)
    return out
end
