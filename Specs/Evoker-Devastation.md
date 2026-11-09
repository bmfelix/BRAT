# Devastation Evoker (1467) — damage rotation, patch 12.1.5

Status: **from guides + Warcraft Logs, not yet confirmed in game.** Rules: `Data/SpecRules.lua` [1467].
Sources: Icy Veins Devastation 12.1.5 pages (rotation, spell list, Mythic+ tips, talents), Wowhead
12.1 official patch notes / 12.1 PTR datamine / spell pages, Blizzard hotfixes (Oct 14 2026), read
through search results (Icy Veins and Wowhead block automated page reads). Spell IDs and the
"what top players actually press" checks come from Warcraft Logs (ranks 101-115, The Venomous Abyss
+ Mythic+ Season 2, pulled 2026-11-08).

12.1.5 itself made only tuning changes (Pyre, Unbound Flame, Fire Breath, Azure Strike, Azure Sweep,
Shattering Star damage up; Oct 14 hotfix: Unbound Flame +25%, Azure Sweep +50%). The current design
dates from 12.0 Midnight + the 12.1 Scalecommander rework.

## Hero talents
- **Scalecommander** is the pick everywhere in Season 2 (Icy Veins); Flameshaper only catches up at
  8-9 targets in Mythic+ / roughly even in pure single target. Every logged top player (sample of
  ~270 parses) casts the Scalecommander Deep Breath (433874); none cast the base one (357210).
- BRAT tells them apart by whether you know spell 433874 (or Mass Disintegrate, 436335).

## Single-target priority (Icy Veins 12.1.5, Scalecommander)
1. **Deep Breath** on cooldown; with **Strafing Run** recast it within 18s (after spending at least
   two Imminent Destruction charges — BRAT can't see those, so it just offers the recast).
2. **Fire Breath** — always empower **rank 1**.
3. **Eternity Surge** — rank 1 on single target (fires Shattering Star, now a passive).
4. **Disintegrate** to spend Essence; spend **Essence Burst** first (max 2 stacks, don't cap).
   After an empower, Disintegrate is a **Mass Disintegrate** (hits up to 3 extra targets).
5. **Azure Sweep** when available (Eternity Surge upgrades your next Azure Strike).
6. **Living Flame** filler (instant with **Burnout**, from Fire Breath ticks).
7. **Azure Strike** only while moving without Hover.

Flameshaper differs: no Deep Breath in the priority; Consume Flame (Disintegrate/Pyre eat Fire
Breath duration) replaced Engulf; cast Living Flame at least once between Fire Breaths (Leaping Flames).

## AoE / Mythic+
- **Eternity Surge rank = targets / 2, rounded up** (2/4/6/8 targets per rank 1/2/3/4; rank 4 needs
  Font of Magic). BRAT shows the rank on the icon ("R2").
- **Pyre vs Disintegrate:** Icy Veins pages disagree (3+ in one place, 5+ in another). The logs
  settle it for Scalecommander: at **3-4 targets Disintegrate** (74-86% of spends); at **5+ targets
  Disintegrate when Mass Disintegrate is ready** (an empower since the last Disintegrate: 67%
  Disintegrate) and **Pyre when it isn't** (72% Pyre). BRAT counts Mass Disintegrate charges from
  your casts. Flameshaper (no logs data): Pyre at **3+** per the guide.
- **Filler in AoE:** the guide says Azure Strike replaces Living Flame at 3+, but top players keep
  Living Flame (13-19% of casts at 3-8 targets vs 4-7% Azure Strike). BRAT follows the logs.

### Warcraft Logs: share of casts by enemy count (264 parses)
| Targets | Disintegrate | Pyre | Living Flame | Azure Strike | Deep Breath | Fire Breath | Eternity Surge |
|---|---|---|---|---|---|---|---|
| 1 | 43% | 0% | 24% | 3% | 6% | 9% | 10% |
| 3 | 39% | 7% | 19% | 6% | 6% | 9% | 10% |
| 5 | 29% | 18% | 15% | 7% | 7% | 10% | 10% |
| 8+ | 23% | 24% | 13% | 4% | 8% | 10% | 10% |
Rotation cap from the logs: 4 targets (buckets 1, 2, 3, 4+).
- Fire Breath stays rank 1 (Icy Veins 12.1.5); the leveling guide's "max rank Fire Breath on packs"
  is older advice.
- Pulls much beyond 5 targets favour other specs; Scalecommander stays ahead up to ~8.

## Cooldowns (learned, not ranked)
- **Dragonrage** (2 min): fillers always proc Essence Burst; fires up to 3 Pyres; Animosity: each
  empower +4s (no cap, diminishing). → *learned* (it's your burst window: Blizzard's timing).
- **Rising Fury** (apex): +4% haste per 6s in Dragonrage (5 stacks, then +15% damage); afterwards
  lasts 4s per stack and gives Essence Burst every 4s, and Dragonrage becomes **Unbound Flame**
  (4 charges before Dragonrage is back). Spend Unbound Flame under 4 Essence with no Essence Burst,
  ideally all 4 at the end of Dragonrage at full Rising Fury. → ranked when Essence is readable.
- **Tip the Scales** (2 min): next empower instant at max rank. → *learned*.
- **Twin Flame** (talent, pressed ~2x a fight by some top players). → *learned*.

## Mechanics
| Rule | Value | Confidence |
|---|---|---|
| Causality | Disintegrate: 0.5s off Fire Breath / Eternity Surge each time it deals damage (≈2s per full channel); Pyre: 0.4s per enemy hit, max 2s | guide (spell list), Warcraft Wiki, 12.0.1 tooltip |
| Causality + Mass Disintegrate | More than a plain Disintegrate (it deals damage to more targets). Brad's 12.1.5 fights (20 AoE cooldowns vs Blizzard's picks, 4pc worn): Disintegrate × (1 + 1/12 per extra target), 3.0s at 4+ with 4pc, 2.5s without. Kept on the low side; Blizzard's pick of an empower (4s+ after you cast it) corrects the timer | Brad's logs, 2026-11-09 |
| Tier 2pc (S2) | Shattering Star +50% damage, always at max empower level (Seramate's PTR article said 150%; later sources 50%) | Icy Veins / Maxroll 12.1.5 — **no rotation change**: Eternity Surge stays rank 1 single target and still ranks up with targets in AoE (Icy Veins M+, Maxroll). Shown in `/brat why` |
| Tier 4pc (S2) | Causality +0.1s per trigger (0.6s per Disintegrate tick, 0.5s per Pyre target, Pyre cap left at 2s); Eternity Surge +10% | guide; modeled — detected from the set bonus itself: an active (green) "(4)" tooltip line on a tier-slot item that names Causality (no spell/set ID published; an older set or 3 pieces doesn't count). Brad's single-target logs fit 0.6s/tick |
| Mass Disintegrate → Deep Breath | 1s off Deep Breath per target hit (12.1, was 0.5s) | official 12.1 notes → *learned* |
| Strafing Run | Deep Breath recast within 18s (+20% damage) | guide + 12.0 beta tooltip |
| Fire Breath / Eternity Surge | 30s; Eternity Surge 27s with Event Horizon | from memory of the tooltip; real value read from the game |
| Essence | 1 per 5s; Disintegrate / Pyre cost 3 (−1 per Imminent Destruction stack) | guide |
| Essence Burst | Living Flame 20%, Azure Strike 15%; 100% in Dragonrage; max 2 stacks | guide |
| Azure Sweep | Eternity Surge → next Azure Strike hits all enemies, +75% | guide |
| Shattering Star | passive: Eternity Surge launches it | guide |

## How BRAT models it
- **Essence** is read with `UnitPower` when the game allows it. If NOW is an Essence spender you
  haven't cast yet, its cost is taken off before deciding NEXT. If the game hides Essence in combat,
  Disintegrate / Pyre / Unbound Flame are learned from Blizzard's picks instead (like Shadow's Madness).
- **Essence Burst / Burnout / Azure Sweep** come in as glowing buttons (BRAT's proc tracking): a
  glowing Disintegrate is a free spend and goes first.
- **Can't move while casting**: Disintegrate and the empowers are marked stationary (the game reports
  no cast time for them). Hover lifts it. While moving: Pyre (instant) / Azure Strike.
- **Fire Breath / Eternity Surge timers**: BRAT times them from your casts minus Causality
  (a Disintegrate cast with a Mass Disintegrate charge counts as Mass Disintegrate). If Blizzard's
  assistant picks one 4s+ after you cast it, that's taken as proof it's ready. Before 2026-11-09 the
  timer ignored that and ran up to 11s slow in AoE, so BRAT showed Disintegrate / Pyre instead.
- **Strafing Run** is a "free cast" proc: the first Deep Breath gives one free recast for 18s; the
  free one doesn't give another.

## To confirm in game (tooltips)
- Tier 4-piece detection: `/brat why` should say "Causality 4-piece bonus active" with the Season 2
  set on, "not active" with an older set or 3 pieces. (Relies on the bonus line starting "(4)" and
  being green when active.)
- Fire Breath / Eternity Surge cooldowns (30s? 27s with Event Horizon?).
- Disintegrate: how many damage ticks (Causality = 0.5s each — is a full channel 2s?). With the 4pc, 0.6s.
- Is Essence readable in combat? (`/brat why` shows "Essence: x / y" or "hidden".)
- Talent IDs: Causality 375777, Strafing Run 1266151, Mass Disintegrate 436335 (does BRAT detect them?).
- Does Azure Strike's button glow when Azure Sweep is ready? Does Living Flame glow with Burnout?
- Strafing Run window: 18s? (one PTR page showed a different buff duration).
- Deep Breath base cooldown (2 min?) and how much Mass Disintegrate takes off in practice.
- Is Unbound Flame reported as a replacement of Dragonrage (same button)?
- Mass Disintegrate: does each empower give one charge, and do they stack (BRAT keeps at most 2)?
  Does Disintegrate's button glow / change while one is ready?
