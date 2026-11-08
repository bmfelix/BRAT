-- BRAT procs: when a proc lights up a spell (the glowing action button),
-- Blizzard usually wants it soon. BRAT watches which spells are glowing and
-- learns, per spec, how often Blizzard's very next pick is the glowing spell.
-- Predict.lua then puts a glowing spell in NEXT when that's more likely than
-- the normal follow-up.
local _, BRAT = ...
local Procs = {}
BRAT.Procs = Procs

local glowing = {} -- [spellID] = true while its button glows

local function mark(id, on)
    if not id or BRAT.IsSecret(id) then return end
    glowing[id] = on or nil
    -- The button may hold the base spell while Blizzard picks the override.
    local over = BRAT.Safe(C_Spell.GetOverrideSpell, id)
    if over and over ~= id then glowing[over] = on or nil end
end

local f = CreateFrame("Frame")
for _, ev in ipairs({ "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW", "SPELL_ACTIVATION_OVERLAY_GLOW_HIDE",
    "PLAYER_SPECIALIZATION_CHANGED", "PLAYER_REGEN_ENABLED" }) do
    pcall(f.RegisterEvent, f, ev) -- an event missing in this client must not break loading
end
f:SetScript("OnEvent", function(_, event, id)
    if event == "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW" then mark(id, true)
    elseif event == "SPELL_ACTIVATION_OVERLAY_GLOW_HIDE" then mark(id, false)
    else
        -- Re-sync from the game where it allows it (drops stale glows).
        for id in pairs(glowing) do
            local on = BRAT.Safe(C_SpellActivationOverlay and C_SpellActivationOverlay.IsSpellOverlayed, id)
            if on == false then glowing[id] = nil end
        end
    end
end)

function Procs:IsGlowing(id) return glowing[id] == true end

-- Copy of the glowing set, taken when you cast (what was lit up then).
function Procs:Snapshot(exclude)
    local s
    for id in pairs(glowing) do
        if id ~= exclude then s = s or {}; s[id] = true end
    end
    return s
end

local function stats(create)
    local spec = BRAT.GetSpecID()
    local all = BRAT.db.procs
    if create and not all[spec] then all[spec] = {} end
    return all[spec]
end

-- After a cast: `snap` = spells glowing at the cast, `pick` = Blizzard's next pick.
function Procs:Learn(snap, pick)
    if not snap then return end
    local t = stats(true)
    for id in pairs(snap) do
        local s = t[id] or { seen = 0, used = 0 }
        t[id] = s
        s.seen = s.seen + 1
        if pick == id then s.used = s.used + 1 end
        if s.seen > 200 then s.seen = s.seen / 2; s.used = s.used / 2 end -- adapt to talent changes
    end
end

-- Chance Blizzard's next pick is this glowing spell. Unknown procs start at 50%.
function Procs:Chance(id)
    local t = stats(false)
    local s = t and t[id]
    if not s then return 0.5 end
    return (s.used + 1) / (s.seen + 2)
end

-- Best glowing spell that passes `ok(id)`; returns id, chance.
function Procs:Best(ok)
    local best, bestP
    for id in pairs(glowing) do
        if ok(id) then
            local p = self:Chance(id)
            if not bestP or p > bestP then best, bestP = id, p end
        end
    end
    return best, bestP
end
