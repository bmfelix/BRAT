# Shadow Priest (258) — damage rotation, patch 12.1.5

Status: **from guides, not yet confirmed in game.** Rules: `Data/SpecRules.lua` [258].
Sources: Icy Veins Shadow Priest 12.1.5 pages (rotation page updated 12 Oct 2026), read
through search results (Icy Veins and Wowhead block automated page reads).
12.1.5 itself made no Shadow changes; the current design dates from the 12.1 rework.

## Single-target priority (Icy Veins 12.1.5)
1. Keep Vampiric Touch and Shadow Word: Pain up (refresh in the pandemic window).
   With Misery, Vampiric Touch also applies Shadow Word: Pain; both last 21s (pandemic 6.3s).
   Without Misery, Shadow Word: Pain's pandemic is 4.8s. Tentacle Slam refreshes Vampiric Touch.
2. Shadow Word: Madness (renamed Devouring Plague): when not active, about to expire, or
   about to cap Insanity (also on Mind Devourer). → *learned* (Insanity is hidden from addons)
3. Void Blast (Voidweaver) while Shadow Word: Madness is active or Entropic Rift is about to expire.
4. Mind Blast, Void Volley.
5. Mind Flay (filler; interrupt it for anything else).
Opener: Vampiric Touch, Mind Blast, Tentacle Slam (pre-cast), Halo, Void Volley, Voidform,
trinkets/potion/Power Infusion, Shadow Word: Madness, Void Torrent.

## AoE
- DoTs on up to ~12 targets; Tentacle Slam covers 6 stacked targets; skip targets that live < 18s.
- Mythic+: funnel Shadow Word: Madness into the main / highest-health target.
- Then Void Volley and Mind Blast; Void Blast while Madness is up or Entropic Rift is ending.

## Mechanics
| Rule | Value | Confidence |
|---|---|---|
| Mind Blast | 2 charges with Thought Harvester; only one recharges at a time | guide |
| Shadowy Insight | grants a temporary extra Mind Blast charge | guide |
| Shadow Word: Death | execute < 20% (35% with Deathspeaker); resets if it doesn't kill | guide → *learned* (target health hidden) |
| Voidform | 2 min; pairs with Power Infusion; gives Void Volley (15s, hasted) | guide (one source says 3 uses) |
| Tentacle Slam | 20s fixed; applies Vampiric Touch to up to 6 | guide (one source says 2 charges) |
| Halo | used ~2× per Voidform | guide |
| Season 2 tier 2pc | Tentacle Slam cd −3s (20 → 17s), +100% damage | all sources agree → **modeled** (length 17s while the active 2-piece names Tentacle Slam) |
| Season 2 tier 4pc | Tentacle Slam grants a free Void Volley (castable outside Voidform) | Icy Veins 12.1.5 → **modeled** as a free-cast proc, only if the active 4-piece line names Void Volley. An earlier preview (MMO-Champion, Conquest Capped) listed "next Vampiric Touch instant + Shadowy Apparitions" instead: that version isn't modeled and won't match. Proc duration unknown: offered only while the game says Void Volley is usable |

## To confirm in game (tooltips)
- Tentacle Slam: cooldown and charges.
- Void Volley: cooldown / uses during Voidform.
- Void Torrent cooldown; Halo cooldown.
- Do you take Misery? (Vampiric Touch applying Shadow Word: Pain)
