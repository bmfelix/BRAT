-- BRAT spec rules: what BRAT knows for sure about each spec's damage rotation,
-- from current guides (patch 12.1+ only: Icy Veins / Wowhead) and in-game checks.
-- Research notes and sources: Specs\<class>-<spec>.md.
-- Anything not covered here, BRAT learns while you play.
--
-- Per spec (by specID):
--   order      [spellID] = function(targets, free) -> score 0..1. Higher = cast first
--              when ready. Spells not listed get a learned score.
--   reductions [spellID] = { [castSpellID] = seconds, or { seconds, talent = id } }
--              Seconds a cast takes off that spell's cooldown. A listed spell
--              uses only these (no learning on top). {} = nothing reduces it.
--   lengths    [spellID] = seconds. Cooldown length if the game won't say.
--   procs      { spell, talent, gives, count, duration, name }: casting `spell`
--              (with `talent`) makes the next `count` casts of `gives` free.
--   dots       [spellID] = { duration, refreshedBy = { spellIDs } }: kept up; BRAT
--              suggests them when due for a refresh (30% left, the pandemic window).
--   notes      text shown in /brat why for this spec.
--   stationary [spellID] = true: can't be cast while moving although the game
--              reports no cast time (channels, empowered spells).
--   moveBuff   spellID of a buff that lets you cast while moving (Evoker: Hover).
--   empower    [spellID] = function(targets) -> empower level to release at,
--              shown on the icon as "R1".."R4".
-- Order functions may return nil: "no opinion right now" (e.g. Essence is
-- hidden), and that spell's score is learned from Blizzard instead.
-- A reduction may be { perTarget = s, max = s, talent = id }: s per enemy hit.
-- Spell IDs are the ones the game uses in 12.1 (from Warcraft Logs data).
local _, BRAT = ...

BRAT.SpecRules = {
    -------------------------------------------------------------------------
    -- HOLY PRIEST (257). Confirmed: guide (Method 12.1.5) + Brad in game.
    -------------------------------------------------------------------------
    [257] = {
        notes = "Holy (12.1.5): free Empyreal Holy Fire > Chastise > Holy Fire > Holy Nova (4+ targets) > Smite.",
        order = {
            [88625] = function() return 0.95 end,                         -- Holy Word: Chastise
            [14914] = function(_, free) return free and 0.97 or 0.85 end, -- Holy Fire (free Empyreal first)
            [132157] = function(t) return t >= 4 and 0.50 or 0.15 end,    -- Holy Nova
            [585] = function() return 0.20 end,                           -- Smite
        },
        reductions = {
            -- Chastise: Smite and Holy Nova 4s; Holy Fire 4s with Voice of Harmony.
            [88625] = { [585] = 4, [132157] = 4, [14914] = { 4, talent = 390994 } },
            [14914] = {}, -- Holy Fire: nothing shortens it
        },
        lengths = {
            [14914] = 10,   -- Holy Fire (confirmed in game)
            [88625] = 60,   -- Holy Word: Chastise (talented 40s is read from the game)
            [2050] = 60, [34861] = 60,               -- Holy Word: Serenity / Sanctify
            [200183] = 120, [120517] = 60,           -- Apotheosis, Halo
            [19236] = 90, [586] = 30, [8122] = 45,   -- Desperate Prayer, Fade, Psychic Scream
            [10060] = 120, [47788] = 180, [64843] = 180, [73325] = 90, -- PI, Guardian Spirit, Divine Hymn, Leap of Faith
        },
        procs = {
            -- Empyreal Blaze: Chastise -> next two Holy Fires instant, no cooldown, 30s.
            { spell = 88625, talent = 372616, gives = 14914, count = 2, duration = 30, name = "Empyreal Blaze" },
        },
        dots = {}, -- Holy has no Shadow Word: Pain (Holy Fire replaces it)
    },

    -------------------------------------------------------------------------
    -- SHADOW PRIEST (258). Source: Icy Veins 12.1.5 (rotation page, Oct 2026).
    -- Not yet confirmed in game. Insanity and target health are hidden from
    -- addons, so Shadow Word: Madness and Shadow Word: Death are learned from
    -- Blizzard's picks, not ranked here.
    -------------------------------------------------------------------------
    [258] = {
        notes = "Shadow (12.1.5): keep Vampiric Touch / SW:Pain up > Void Volley > Void Blast > Mind Blast > "
            .. "Tentacle Slam > Halo / Void Torrent > Mind Flay. Madness and SW:Death are learned.",
        order = {
            [34914] = function() return 0.98 end,   -- Vampiric Touch (only "ready" when due: see dots)
            [589] = function() return 0.97 end,     -- Shadow Word: Pain (same)
            [1242173] = function() return 0.93 end, -- Void Volley (Voidform / tier set)
            [8092] = function() return 0.85 end,    -- Mind Blast (charge cap boost applies)
            [1227280] = function() return 0.80 end, -- Tentacle Slam (refreshes VT on up to 6 targets)
            [120644] = function() return 0.70 end,  -- Halo
            [15407] = function() return 0.10 end,   -- Mind Flay (filler)
        },
        reductions = {},
        lengths = {
            [1227280] = 20,  -- Tentacle Slam: 20s fixed (Icy Veins)
            [228260] = 120,  -- Voidform: 2 min
            [1242173] = 15,  -- Void Volley: 15s (hasted) during Voidform
            [10060] = 120,   -- Power Infusion
        },
        procs = {},
        dots = {
            -- With Misery both last 21s (pandemic 6.3s); Vampiric Touch applies
            -- Shadow Word: Pain, and Tentacle Slam applies Vampiric Touch.
            [34914] = { 21, refreshedBy = { 1227280 } },          -- Vampiric Touch
            [589] = { 21, refreshedBy = { 34914, 1227280 } },     -- Shadow Word: Pain (via Misery)
        },
    },

    -------------------------------------------------------------------------
    -- DISCIPLINE PRIEST (256), damage side. Source: Icy Veins 12.1.5 (healing
    -- rotation page). Not yet confirmed in game.
    -------------------------------------------------------------------------
    [256] = {
        notes = "Discipline (12.1.5): SW:Pain if missing > Mind Blast > Penance / Void Shield > "
            .. "Void Blast (in Entropic Rift) > SW:Death > Smite.",
        order = {
            [589] = function() return 0.97 end,     -- Shadow Word: Pain (only "ready" when due)
            [8092] = function() return 0.92 end,    -- Mind Blast (procs Void Shield; opens Entropic Rift)
            [47540] = function() return 0.90 end,   -- Penance (procs Void Shield)
            [1253593] = function() return 0.88 end, -- Void Shield
            [450215] = function() return 0.60 end,  -- Void Blast (replaces Smite in Entropic Rift)
            [32379] = function() return 0.40 end,   -- Shadow Word: Death
            [585] = function() return 0.20 end,     -- Smite (filler)
        },
        reductions = {}, -- tier 2pc (Penance -> Mind Blast -2s) is learned, since set bonuses vary
        lengths = {},
        procs = {},
        dots = {
            [589] = { 16 }, -- Shadow Word: Pain, 16s (pandemic 4.8s)
        },
    },
}

-----------------------------------------------------------------------------
-- DEVASTATION EVOKER (1467). Source: Icy Veins 12.1.5 rotation / spell list /
-- Mythic+ pages, Wowhead 12.1 patch notes; spell IDs from Warcraft Logs
-- (top players, 12.1.5). Not yet confirmed in game. Notes: Specs\Evoker-Devastation.md.
-----------------------------------------------------------------------------
do
    local DISINTEGRATE, PYRE = 356995, 357211
    local FIRE_BREATH, FIRE_BREATH_FOM = 357208, 382266          -- 382266 = Font of Magic version (4 ranks)
    local ETERNITY_SURGE, ETERNITY_SURGE_FOM = 359073, 382411
    local DEEP_BREATH, DEEP_BREATH_SC = 357210, 433874            -- 433874 = Scalecommander's Deep Breath
    local LIVING_FLAME, AZURE_STRIKE, AZURE_SWEEP = 361469, 362969, 1265872
    local UNBOUND_FLAME = 1292321                                 -- Rising Fury: Dragonrage becomes this after it ends
    local CAUSALITY, STRAFING_RUN, MASS_DISINTEGRATE = 375777, 1266151, 436335
    local HOVER = 358267

    -- Scalecommander? (Mass Disintegrate hits up to 4 targets, so Pyre only
    -- takes over at 5+; Flameshaper uses Pyre from 3.)
    local function scalecommander()
        return BRAT.Safe(IsPlayerSpell, DEEP_BREATH_SC) == true
            or BRAT.Safe(IsPlayerSpell, MASS_DISINTEGRATE) == true
    end
    local function pyreAt() return scalecommander() and 5 or 3 end

    -- Essence spender score: a free one (Essence Burst glowing) always goes,
    -- capped Essence goes before anything but the empowers, enough Essence is a
    -- normal spend. nil = Essence is hidden (learned from Blizzard instead).
    local SPENDERS = { [DISINTEGRATE] = true, [PYRE] = true }
    local function spend(id, free, main)
        if free then return main and 0.86 or 0.40 end
        local e, max = BRAT.Essence()
        if not e then return nil end
        -- NOW is a spender you haven't cast yet: its Essence is about to go
        -- (unless Essence Burst pays for it).
        local before = BRAT.Predict:Unspent()
        if before and SPENDERS[before] and BRAT.Predict:FreeLeft(before) == 0 then
            e = e - BRAT.EssenceCost(before, 3)
        end
        if e < BRAT.EssenceCost(id, 3) then return 0.05 end
        if e >= max - 1 then return main and 0.84 or 0.38 end
        return main and 0.60 or 0.30
    end

    BRAT.SpecRules[1467] = {
        notes = "Devastation (12.1.5): Deep Breath (Scalecommander, recast within 18s with Strafing Run) > "
            .. "Fire Breath (rank 1) > Eternity Surge (rank 1 on 1-2 targets, +1 per 2 targets) > "
            .. "Disintegrate (Pyre at 5+ targets as Scalecommander, 3+ as Flameshaper; Essence Burst first) > "
            .. "Azure Sweep > Living Flame (Burnout = instant) > Azure Strike (moving). "
            .. "Dragonrage, Tip the Scales and Twin Flame are learned.",
        order = {
            [DEEP_BREATH_SC] = function() return 0.96 end,
            [DEEP_BREATH] = function() return 0.96 end,
            [FIRE_BREATH_FOM] = function() return 0.92 end,
            [FIRE_BREATH] = function() return 0.92 end,
            [ETERNITY_SURGE_FOM] = function() return 0.90 end,
            [ETERNITY_SURGE] = function() return 0.90 end,
            [DISINTEGRATE] = function(t, free) return spend(DISINTEGRATE, free, t < pyreAt()) end,
            [PYRE] = function(t, free) return spend(PYRE, free, t >= pyreAt()) end,
            -- Rising Fury: spend a charge when under 4 Essence with no Essence Burst.
            [UNBOUND_FLAME] = function()
                local e = BRAT.Essence()
                if not e then return nil end
                local burst = BRAT.Procs:IsGlowing(DISINTEGRATE) or BRAT.Procs:IsGlowing(PYRE)
                return (e < 4 and not burst) and 0.70 or 0.25
            end,
            [AZURE_SWEEP] = function() return 0.55 end,
            -- Azure Strike: Azure Sweep when Eternity Surge upgraded it (glows);
            -- the AoE filler at 3+; else only while moving (Living Flame can't be cast).
            [AZURE_STRIKE] = function(t, free) return free and 0.55 or (t >= 3 and 0.22 or 0.12) end,
            -- Living Flame: filler; instant with Burnout (glows).
            [LIVING_FLAME] = function(t, free) return free and 0.50 or (t >= 3 and 0.15 or 0.20) end,
        },
        reductions = {
            -- Causality: each Disintegrate damage tick takes 0.5s off the empowers
            -- (4 ticks per full channel = 2s); Pyre 0.4s per enemy hit, at most 2s.
            [FIRE_BREATH_FOM] = { [DISINTEGRATE] = { 2, talent = CAUSALITY }, [PYRE] = { perTarget = 0.4, max = 2, talent = CAUSALITY } },
            [FIRE_BREATH] = { [DISINTEGRATE] = { 2, talent = CAUSALITY }, [PYRE] = { perTarget = 0.4, max = 2, talent = CAUSALITY } },
            [ETERNITY_SURGE_FOM] = { [DISINTEGRATE] = { 2, talent = CAUSALITY }, [PYRE] = { perTarget = 0.4, max = 2, talent = CAUSALITY } },
            [ETERNITY_SURGE] = { [DISINTEGRATE] = { 2, talent = CAUSALITY }, [PYRE] = { perTarget = 0.4, max = 2, talent = CAUSALITY } },
            -- Deep Breath (Mass Disintegrate: 1s per target hit) is learned: how
            -- many Disintegrates are "Mass" depends on the empowers in between.
        },
        lengths = {
            [FIRE_BREATH] = 30, [FIRE_BREATH_FOM] = 30,
            [ETERNITY_SURGE] = 30, [ETERNITY_SURGE_FOM] = 30,  -- 27s with Event Horizon (read from the game)
            [DEEP_BREATH] = 120, [DEEP_BREATH_SC] = 120,
            [375087] = 120,  -- Dragonrage
            [370553] = 120,  -- Tip the Scales
            [363916] = 90, [374348] = 90,      -- Obsidian Scales, Renewing Blaze
            [358267] = 35, [370665] = 60,      -- Hover, Rescue
            [374968] = 120, [374227] = 120,    -- Time Spiral, Zephyr
            [351338] = 20,                     -- Quell
        },
        procs = {
            -- Strafing Run: Deep Breath can be cast again within 18s (once).
            { spell = DEEP_BREATH_SC, talent = STRAFING_RUN, gives = DEEP_BREATH_SC, count = 1, duration = 18, name = "Strafing Run" },
            { spell = DEEP_BREATH, talent = STRAFING_RUN, gives = DEEP_BREATH, count = 1, duration = 18, name = "Strafing Run" },
        },
        dots = {},
        -- Evokers can't move while channeling or empowering (Hover lifts it).
        stationary = {
            [DISINTEGRATE] = true,
            [FIRE_BREATH] = true, [FIRE_BREATH_FOM] = true,
            [ETERNITY_SURGE] = true, [ETERNITY_SURGE_FOM] = true,
        },
        moveBuff = HOVER,
        empower = {
            -- Fire Breath: always rank 1 (both hero trees, Icy Veins 12.1.5).
            [FIRE_BREATH] = function() return 1 end,
            [FIRE_BREATH_FOM] = function() return 1 end,
            -- Eternity Surge hits 2 targets per rank: lowest rank that covers them.
            [ETERNITY_SURGE] = function(t) return math.min(3, math.ceil(t / 2)) end,
            [ETERNITY_SURGE_FOM] = function(t) return math.min(4, math.ceil(t / 2)) end,
        },
    }
end

-- Rules for your current spec (or an empty set).
local EMPTY = { order = {}, reductions = {}, lengths = {}, procs = {}, dots = {} }
function BRAT.Rules()
    return BRAT.SpecRules[BRAT.GetSpecID()] or EMPTY
end
