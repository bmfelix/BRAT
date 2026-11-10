# BRAT: Brad's Rotation Assistant Technology

WoW addon (retail, Midnight, interface 120105 / patch 12.1.5). Shows two icons:
NOW (Blizzard's Assisted Combat pick) and NEXT (BRAT's prediction). Lua 5.1.
Load order is in `BRAT.toc`; each file starts with a header comment explaining it.

## The core constraint
In combat, Midnight makes cooldowns, resources (Essence, Insanity), target health and
most combat data **secret** to addons. So BRAT:
- tracks cooldowns itself (`Cooldowns.lua`): a cast starts the timer, the length is
  read from the game out of combat (else `db.cds[id].len`, else the base cooldown);
- applies **known** reductions from `Data/SpecRules.lua`, and learns only what isn't listed;
- treats Blizzard's pick (`C_AssistedCombat.GetNextCastSpell`) as proof the spell is ready.

## Design principles (learned the hard way)
- **Err slow, never fast.** A timer that runs slow gets corrected when Blizzard picks the
  spell (`Cooldowns:OnPicked`). A timer that runs fast never gets corrected and BRAT
  offers spells that aren't ready. Fit models to the conservative side.
- **Stale picks:** for a spell with known reductions, a Blizzard pick within
  `STALE_PICK` (4s) of that spell's own cast is ignored (the pick lags the cast).
- **Spec knowledge goes in `Data/SpecRules.lua`** (the schema is documented at the top of
  that file), with research notes, sources and a "to confirm in game" list in
  `Specs/<Class>-<Spec>.md`. Mark each rule confirmed vs guide-only.
- **Research first:** patch 12.1+ sources only (Icy Veins, Wowhead, Method). Icy Veins and
  Wowhead block automated page reads: use web search with targeted questions.
  Real 12.1 spell IDs come from Warcraft Logs cast data (override IDs differ from base).
- **Tier set bonuses:** never count pieces or trust set IDs (an older season's set would
  match). `BRAT.SetBonus(pieces, spellID)` (Core.lua) reads the tier-slot tooltips and
  is true only when an *active* (green) "(N) Set:" line names that spell. Rules use
  `bonus = { pieces, spellID }` (checked by `BRAT.RuleOn`) or call SetBonus in
  function lengths / reductions. Returns nil when gear isn't readable yet.
- Locale-safe: match spells by `C_Spell.GetSpellName`, never hard-coded English text.

## Testing (no WoW needed)
- LuaJIT: `C:\Users\Brad\AppData\Local\Programs\LuaJIT\bin\luajit.exe`.
- Python 3.15 (`python`, via the python.org Install Manager) for the PC tools and data scripts.
- `sh tests/run.sh` runs every `tests/test_*.lua`. They load the real addon files with
  stubbed WoW APIs (`loadfile(path)("BRAT", BRAT)`). Run after every rule change; add a
  harness or checks per spec you touch.
- Syntax check a file: `luajit -bl <file>`.

## Debugging a wrong recommendation
1. Ask for `/brat why` (rules, facts used, active set bonuses) and `/brat watch`.
2. Read the fight history from SavedVariables:
   `C:\Program Files (x86)\World of Warcraft\_retail_\WTF\Account\BMFELIX\SavedVariables\BRAT.lua`
   Lines `H1;P;t;pick;now;next;kind;real;used;glow;cds` (prediction) and
   `H1;C;t;spell;now;next` (cast); format documented in `History.lua`.
3. Compare BRAT's timer with when Blizzard picked the spell. Blizzard picking a spell
   BRAT thinks is on cooldown = BRAT's timer is too slow (reductions missing).
   `python tools/analyze_history.py` does broader analysis.

## Spec status
| Spec | ID | Status |
|---|---|---|
| Holy Priest | 257 | confirmed in game |
| Shadow Priest | 258 | guides only; S2 2pc/4pc modeled |
| Discipline Priest | 256 | guides only; S2 2pc modeled |
| Devastation Evoker | 1467 | guides + WCL + Brad's fight history; Causality / Mass Disintegrate / S2 4pc modeled |

Open questions per spec are in each `Specs/*.md` "To confirm in game" section.

## Repo notes
- `tools/` holds the PC tools, Python standard library only (no pip installs):
  `brat.py` (shared: spec list `SPECS`, SavedVariables/Lua parsing, WCL client, cache I/O),
  `fetch_warcraftlogs.py` (top-player parses -> `Data/WCLRaw.lua`), `fetch_my_parses.py`
  (your parses -> `Data/MyParses.lua`), `analyze_history.py`, `data_manager.py` (window;
  double-click `BRAT Data Manager.cmd`). Each has `--help`. New spec: add it to `SPECS`.
- The parse cache is JSON in `tools/cache/<Class>-<Spec>/` (converted from the old PowerShell
  XML cache on 2026-11-09; the Python export reproduced `Data/WCLRaw.lua` byte for byte).
- Generated Lua files are written UTF-8, CRLF.
- The repo is **public** (github.com/bmfelix/BRAT, remote name `BRAT`). Never commit secrets:
  `tools/wcl-creds.json` is gitignored (the old secret leaked in history and was rotated
  2026-11-10).
- Commit only when Brad asks.
