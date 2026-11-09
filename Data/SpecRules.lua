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
--              Or function() -> seconds: computed live (e.g. a tier set bonus
--              shortens it), used over what the game reports.
--   procs      { spell, talent, gives, count, duration, name }: casting `spell`
--              (with `talent`) makes the next `count` casts of `gives` free.
--   dots       [spellID] = { duration, refreshedBy = { spellIDs } }: kept up; BRAT
--              suggests them when due for a refresh (30% left, the pandemic window).
--   notes      text shown in /brat why for this spec.
--   stationary [spellID] = true: can't be cast while moving although the game
--              reports no cast time (channels, empowered spells).
--   moveBuff   spellID of a buff that lets you cast while moving (Evoker: Hover).
--   available  [spellID] = function() -> false when it can't be cast right now
--              (Evoker: Unbound Flame with no uses left); then it's never offered.
--   noCooldown [spellID] = true: has no cooldown, whatever the game reports.
--   why        function(say): extra lines for /brat why (the facts a rule uses).
--   ignoreCasts [spellID] = true: automatic "casts" that aren't button presses
--              (Evoker: Charged Blast); BRAT doesn't treat them as your cast.
--   empower    [spellID] = function(targets) -> empower level to release at,
--              shown on the icon as "R1".."R4".
-- Order functions may return nil: "no opinion right now" (e.g. Essence is
-- hidden), and that spell's score is learned from Blizzard instead.
-- A reduction may be { perTarget = s, max = s, talent = id }: s per enemy hit,
-- or { fn = function(enemies) -> seconds, talent = id }.
--   castAs     function(spellID) -> spellID: what a cast counts as for cooldown
--              reductions (Evoker: Disintegrate with a Mass Disintegrate charge
--              counts as Mass Disintegrate, 436335).
-- Reductions and procs may carry conditions: talent = id (you know it) and/or
-- bonus = { pieces, spellID } (that set bonus is active; see BRAT.RuleOn).
-- Tier set bonuses: rules call BRAT.SetBonus(2 or 4, spellID) (Core.lua): true
-- when that active set bonus names the spell (read from your gear's tooltips;
-- 2- and 4-piece lines are kept apart), false, or nil = gear not readable yet.
--   onCast     function(spellID): called on each of your casts, after BRAT's
--              cooldown tracker has counted it (spec state like Mass Disintegrate).
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
            -- Tentacle Slam: 20s fixed (Icy Veins); 17s with the Season 2 2-piece
            -- ("Tentacle Slam cooldown reduced by 3 sec", all sources agree).
            [1227280] = function() return BRAT.SetBonus(2, 1227280) == true and 17 or 20 end,
            [228260] = 120,  -- Voidform: 2 min
            [1242173] = 15,  -- Void Volley: 15s (hasted) during Voidform
            [10060] = 120,   -- Power Infusion
        },
        procs = {
            -- Season 2 4-piece (Icy Veins 12.1.5): Tentacle Slam grants a free Void
            -- Volley, castable outside Voidform too. An earlier preview listed a
            -- different 4-piece (instant Vampiric Touch): requiring the active
            -- 4-piece line to name Void Volley means only the version modeled here
            -- counts. No duration published: BRAT still only offers it while the
            -- game says Void Volley is usable.
            { spell = 1227280, bonus = { 4, 1242173 }, gives = 1242173, count = 1, name = "Tier 4-piece" },
        },
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
        reductions = {
            -- Season 2 2-piece: each Penance takes 2s off Mind Blast (Method,
            -- Conquest Capped 12.1.5). Only while that 2-piece is active.
            -- (Listing Mind Blast here means nothing else is learned for it; if
            -- something else shortens it, Blizzard's pick corrects the timer.)
            [8092] = { [47540] = { 2, bonus = { 2, 47540 } } },
        },
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

    -- Mass Disintegrate (Scalecommander): each empower makes the next
    -- Disintegrate hit up to 4 targets. Top players at 5+ targets (Warcraft Logs,
    -- 264 parses): Disintegrate 67% of spends when one is ready, Pyre 72% when not.
    -- Counted from your casts (at most 2 kept); cleared when combat ends.
    local EMPOWERS = { [FIRE_BREATH] = true, [FIRE_BREATH_FOM] = true,
        [ETERNITY_SURGE] = true, [ETERNITY_SURGE_FOM] = true }
    local massReady = 0
    -- Rising Fury: after Dragonrage, Unbound Flame can be cast 4 times (then the
    -- button waits for Dragonrage's cooldown). Counted from your casts.
    local DRAGONRAGE, UNBOUND_USES = 375087, 4
    local unboundLeft = 0
    -- Season 2 tier set, 4 pieces: Causality takes 0.1s more each time it
    -- triggers (Icy Veins 12.1.5). Read from the active 4-piece bonus naming
    -- Causality (BRAT.SetBonus, Core.lua), so an older set doesn't count; until
    -- gear can be read, no bonus (the safe side).
    -- (The 2-piece, Shattering Star always at max empower, changes no decision:
    -- Eternity Surge still ranks up with targets in AoE, Icy Veins / Maxroll 12.1.5.)
    local function tierBonus() return BRAT.SetBonus(4, CAUSALITY) end
    -- Seconds Causality takes off the empowers each time it triggers.
    local function causalityHit() return tierBonus() == true and 0.6 or 0.5 end

    local mf = CreateFrame("Frame")
    mf:RegisterEvent("PLAYER_REGEN_ENABLED")
    mf:SetScript("OnEvent", function() massReady = 0 end)
    -- Your casts (rules.onCast, called by Core after the cooldown tracker has
    -- counted the cast, so castAs below still sees the state before it).
    local function onCast(id)
        if EMPOWERS[id] then massReady = math.min(2, massReady + 1)
        elseif id == DISINTEGRATE then massReady = math.max(0, massReady - 1)
        elseif id == DRAGONRAGE then unboundLeft = UNBOUND_USES
        elseif id == UNBOUND_FLAME then unboundLeft = math.max(0, unboundLeft - 1) end
    end
    -- A Disintegrate cast with a Mass Disintegrate charge ready counts as Mass
    -- Disintegrate for cooldown reductions (it hits more targets: more Causality).
    local function castAs(id)
        if id == DISINTEGRATE and massReady > 0 and scalecommander() then return MASS_DISINTEGRATE end
        return id
    end
    -- Unbound Flame uses left: the game's count when it shows it, else ours.
    local function unboundCharges()
        local ch = BRAT.Safe(C_Spell.GetSpellCharges, UNBOUND_FLAME)
        if type(ch) == "table" and type(ch.currentCharges) == "number" and not BRAT.IsSecret(ch.currentCharges) then
            return ch.currentCharges
        end
        return unboundLeft
    end
    -- Ready when the next spend happens: NOW (not cast yet) may add or use one.
    local function massDisintegrate()
        if not scalecommander() then return false end
        local n, before = massReady, BRAT.Predict:Unspent()
        if before and EMPOWERS[before] then n = n + 1 elseif before == DISINTEGRATE then n = n - 1 end
        return n > 0
    end
    -- Disintegrate is the main spender below the Pyre threshold, and above it
    -- too while Mass Disintegrate is ready.
    -- Uses the real enemy count: the rotation's target buckets stop at its cap (4).
    local function disintegrateMain()
        return (BRAT.Predict.enemies or 1) < pyreAt() or massDisintegrate()
    end

    -- Essence spender score: a free one (Essence Burst glowing) always goes,
    -- capped Essence goes before anything but the empowers, enough Essence is a
    -- normal spend. nil = Essence is hidden (learned from Blizzard instead).
    local SPENDERS = { [DISINTEGRATE] = true, [PYRE] = true }
    local function spend(id, free, main)
        if free then return main and 0.86 or 0.40 end
        -- Essence by the time this would be cast (regen while NOW is cast).
        local e, max = BRAT.EssenceIn(BRAT.Predict.window or 0)
        -- Essence hidden: when to spend is learned, but which spender stays
        -- decided here (the wrong one for the enemy count sits below the fillers).
        if not e then return (not main) and 0.10 or nil end
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

    -- Causality reductions, the same for both empowers (see reductions below).
    -- h = seconds per trigger: 0.5, or 0.6 with the tier 4-piece.
    local DISINTEGRATE_TICKS = 4
    local causality = {
        -- Each damage tick triggers it: 4 ticks per full channel (2s, 2.4s with 4pc).
        [DISINTEGRATE] = { fn = function() return DISINTEGRATE_TICKS * causalityHit() end, talent = CAUSALITY },
        -- Mass Disintegrate: + 1/12 per extra target hit (up to 3), fitted from
        -- Brad's fights: 3.0s at 4+ targets with the 4-piece (2.5s without).
        [MASS_DISINTEGRATE] = { fn = function(n)
            local extra = math.min(3, math.max(0, n - 1))
            return DISINTEGRATE_TICKS * causalityHit() * (1 + extra / 12)
        end, talent = CAUSALITY },
        -- Pyre: per enemy hit (0.4s, 0.5s with 4pc), at most 2s (the 4pc's effect
        -- on the cap isn't documented: left at 2s, the safe side).
        [PYRE] = { fn = function(n) return math.min(2, (causalityHit() - 0.1) * n) end, talent = CAUSALITY },
    }

    BRAT.SpecRules[1467] = {
        notes = "Devastation (12.1.5): Deep Breath (Scalecommander, recast within 18s with Strafing Run) > "
            .. "Fire Breath (rank 1) > Eternity Surge (rank 1 on 1-2 targets, +1 per 2 targets) > "
            .. "Disintegrate (5+ targets: Disintegrate when Mass Disintegrate is ready, else Pyre; "
            .. "Flameshaper: Pyre at 3+; Essence Burst first) > "
            .. "Azure Sweep > Living Flame (Burnout = instant) > Azure Strike (moving). "
            .. "Dragonrage on cooldown. Tip the Scales and Twin Flame follow the Warcraft Logs rotation.",
        -- /brat why: the facts behind the Disintegrate / Pyre choice.
        why = function(say)
            local e, max = BRAT.Essence()
            local n = BRAT.Predict.enemies or 1
            say(("  Essence: %s. Enemies counted: %d (Pyre from %d, %s). Mass Disintegrate charges: %d -> %s."):format(
                e and ("%d / %d"):format(e, max) or "hidden by the game (when to spend is learned)",
                n, pyreAt(), scalecommander() and "Scalecommander" or "Flameshaper",
                massReady, disintegrateMain() and "Disintegrate" or "Pyre"))
            local tb = tierBonus()
            say(("  Tier set: Causality 4-piece bonus %s -> %.1fs per trigger."):format(
                tb == true and "active" or (tb == false and "not active" or "not readable yet"), causalityHit()))
        end,
        -- No cooldown, whatever the game reports while you wait for Essence
        -- (BRAT had learned a 13s "cooldown" on both).
        noCooldown = { [DISINTEGRATE] = true, [PYRE] = true, [LIVING_FLAME] = true, [AZURE_STRIKE] = true },
        -- Never recommended, even when Blizzard's assistant picks them: Tail Swipe,
        -- Wing Buffet (knockbacks, not damage buttons).
        -- Azure Strike: Brad doesn't use it (not on his bars), 2026-11-08. Its
        -- Azure Sweep upgrade (a different spell ID while active) still shows.
        never = { [368970] = true, [357214] = true, [362969] = true },
        -- Castable right now? (false = never offered at the moment.)
        available = {
            [UNBOUND_FLAME] = function() return unboundCharges() > 0 end,
        },
        -- Charged Blast (370454): automatic, four casts per Disintegrate tick. Not a button.
        ignoreCasts = { [370454] = true },
        onCast = onCast,
        castAs = castAs,
        order = {
            -- Dragonrage: on cooldown (Icy Veins 12.1.5: the spec's one major cooldown, 2 min).
            [375087] = function() return 0.95 end,
            [DEEP_BREATH_SC] = function() return 0.96 end,
            [DEEP_BREATH] = function() return 0.96 end,
            [FIRE_BREATH_FOM] = function() return 0.92 end,
            [FIRE_BREATH] = function() return 0.92 end,
            [ETERNITY_SURGE_FOM] = function() return 0.90 end,
            [ETERNITY_SURGE] = function() return 0.90 end,
            [DISINTEGRATE] = function(t, free) return spend(DISINTEGRATE, free, disintegrateMain(t)) end,
            [PYRE] = function(t, free) return spend(PYRE, free, not disintegrateMain(t)) end,
            -- Rising Fury: spend a charge when under 4 Essence with no Essence Burst.
            [UNBOUND_FLAME] = function()
                local e = BRAT.Essence()
                if not e then return nil end
                local burst = BRAT.Procs:IsGlowing(DISINTEGRATE) or BRAT.Procs:IsGlowing(PYRE)
                return (e < 4 and not burst) and 0.70 or 0.25
            end,
            [AZURE_SWEEP] = function() return 0.55 end,
            -- Azure Strike: Azure Sweep when Eternity Surge upgraded it (glows);
            -- else only while moving (Living Flame can't be cast). Top players keep
            -- Living Flame as the filler in AoE too (2-3x Azure Strike at 3-8 targets).
            [AZURE_STRIKE] = function(_, free) return free and 0.55 or 0.12 end,
            -- Living Flame: filler; instant with Burnout (glows).
            [LIVING_FLAME] = function(_, free) return free and 0.50 or 0.20 end,
        },
        reductions = {
            -- Causality: each time Disintegrate deals damage, 0.5s off the empowers
            -- (4 ticks per full channel = 2s); Pyre 0.4s per enemy hit, at most 2s.
            -- Tier 4-piece: 0.6s per trigger. Mass Disintegrate hits up to 3 more
            -- targets, so it takes off more: fitted from Brad's 12.1.5 fights (20 AoE
            -- cooldowns vs Blizzard's picks, 4-piece worn). Deliberately on the low side:
            -- when Blizzard picks the empower first, BRAT's timer is corrected
            -- (Cooldowns.lua OnPicked), but nothing corrects a timer that runs fast.
            [FIRE_BREATH_FOM] = causality,
            [FIRE_BREATH] = causality,
            [ETERNITY_SURGE_FOM] = causality,
            [ETERNITY_SURGE] = causality,
            -- Deep Breath (Mass Disintegrate: 1s per target hit) is learned: how
            -- many Disintegrates are "Mass" depends on the empowers in between.
        },
        lengths = {
            [FIRE_BREATH] = 30, [FIRE_BREATH_FOM] = 30,
            [ETERNITY_SURGE] = 30, [ETERNITY_SURGE_FOM] = 30,  -- 27s with Event Horizon (read from the game)
            [DEEP_BREATH] = 60, [DEEP_BREATH_SC] = 60,  -- 60s read from the game (Brad's Evoker, 12.1.5)
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
