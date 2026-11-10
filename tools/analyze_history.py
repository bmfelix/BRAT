"""Analyzes BRAT's fight history (every pick, prediction and cast) to show how close
BRAT is to Blizzard's rotation and what it should learn next.

Reads WTF/Account/*/SavedVariables/BRAT.lua (do /reload or log out first so WoW writes
it) and prints, per spec:
  1. Fights recorded.
  2. NEXT accuracy: how often the NEXT icon matched what Blizzard picked after you
     cast NOW, split by source (logs / learned / proc / list) and enemy count.
  3. Learned priority: Blizzard's rotation as a ranked list per enemy count, worked
     out from every pick ("it chose A while B was also ready").
  4. Procs: how often Blizzard picks a glowing spell straight away.
  5. Cooldown tracker: picks where BRAT's in-combat estimate wrongly thought a spell
     was still on cooldown (that blocks it from NEXT).
  6. You: how often you pressed the NOW spell.
  7. Compared with Warcraft Logs: success % for BRAT's NEXT, Blizzard's picks and your
     own casts, against the Warcraft Logs rotation BRAT served in game (built from the
     data shipped in Data/WCLRaw.lua; saved in the save file).
  8. Trend of those numbers across earlier runs.
Each run is saved as tools/logs/BRAT-WCL-<place>-<date>_<time>.log.

Examples:
  python tools/analyze_history.py
  python tools/analyze_history.py --spec 257 --last-fights 10
  python tools/analyze_history.py --boss Vexis
"""
from __future__ import annotations

import argparse
import re
import sys
from datetime import datetime

import brat

DIFF_NAMES = {1: "Normal", 2: "Heroic", 8: "Mythic+", 14: "Normal", 15: "Heroic", 16: "Mythic", 17: "LFR", 23: "Mythic"}
num = brat.num


def at(f, i):
    return f[i] if i < len(f) else None


class Fight:
    def __init__(self, **kw):
        self.__dict__.update(kw)


def read_fights(files, spec):
    names, fights = {}, []
    for file in files:
        text = brat.read_text(file)
        if not spec:
            m = re.search(r'\["lastSpec"\]\s*=\s*(\d+)', text)
            if m:
                spec = int(m.group(1))
        for m in re.finditer(r'^\s*\[(\d+)\]\s*=\s*"((?:[^"\\]|\\.)*)",\s*$', text, re.M):
            names[int(m.group(1))] = m.group(2)
        cur = None
        for m in re.finditer(r'"H1;([^"]*)"', text):
            f = m.group(1).split(";")
            kind = f[0]
            if kind == "F":
                # Where: instance name unless it's the open world (type "none").
                real_place = len(f) > 5 and f[4] and f[5] != "none"
                where = f[4] if real_place else "Open world / target dummy"
                inst = f[4] if real_place else None
                inst_type = f[5] if len(f) > 5 and f[5] else "none"
                level = int(num(f[8])) if len(f) > 8 and f[8] else 0
                section = {"party": "Mythic+ / dungeons (whole dungeon)", "raid": "Raid (per boss)"}.get(inst_type, "Other")
                if inst_type == "raid":
                    where = f"{inst} (trash)"
                cur = Fight(time=int(num(at(f, 1))), spec=int(num(at(f, 2))), char=at(f, 3), enc=0, diff=0, inst=inst,
                            inst_type=inst_type, level=level, section=section, ctx_kind=None, label=where, events=[], length=0.0)
                fights.append(cur)
            elif kind == "N":
                if cur:
                    cur.enc, cur.diff = int(num(at(f, 2))), int(num(at(f, 3)))
                    bn = f[4] if len(f) > 4 and f[4] else f"boss {at(f, 2)}"
                    dn = DIFF_NAMES.get(cur.diff)
                    # Dungeons stay one place (the whole run); raids split per boss.
                    if cur.inst_type != "party":
                        cur.label = f"{bn} ({dn})" if dn else bn
            elif kind == "X":
                if cur and not cur.ctx_kind:
                    cur.ctx_kind = at(f, 2)
            elif kind == "E":
                if cur:
                    cur.length = float(num(at(f, 1)))
                cur = None
            elif kind == "P":
                if cur:
                    cds = {}
                    if at(f, 9):
                        for c in f[9].split("/"):
                            kv = c.split(":")
                            left = at(kv, 1) or ""
                            cds[int(num(kv[0]))] = (float(num(left.lstrip("~"))), left.startswith("~"))  # (left, estimated)
                    glow = [int(num(x)) for x in f[8].split("/")] if at(f, 8) else []
                    cur.events.append({"type": "P", "t": float(num(at(f, 1))), "pick": int(num(at(f, 2))), "now": int(num(at(f, 3))),
                                       "next": int(num(at(f, 4))), "kind": at(f, 5) or "", "real": int(num(at(f, 6))),
                                       "used": int(num(at(f, 7))), "glow": glow, "cds": cds})
            elif kind == "C":
                if cur:
                    cur.events.append({"type": "C", "t": float(num(at(f, 1))), "spell": int(num(at(f, 2))),
                                       "now": int(num(at(f, 3))), "next": int(num(at(f, 4)))})
    return names, fights, spec


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--wow-path", default=brat.WOW_PATH)
    p.add_argument("--spec", type=int, default=0, help="spec ID to analyze (0 = the spec you last played)")
    p.add_argument("--last-fights", type=int, default=0, help="only the most recent N fights per spec (0 = all)")
    p.add_argument("--boss", default="", help='only fights whose boss/place contains this text, e.g. --boss "Vexis"')
    p.add_argument("--ready-window", type=float, default=1.5, help="a spell counts as ready if its cooldown has this little left")
    a = p.parse_args()

    files = sorted(brat.all_saved_variables(a.wow_path))
    if not files:
        sys.exit(f"No BRAT SavedVariables found under {a.wow_path}\\WTF. Play a fight, /reload, then run this again.")
    spec_names = {s["id"]: f"{s['spec']} {s['cls']}" for s in brat.SPECS}
    names, fights, spec = read_fights(files, a.spec)

    # ---- Warcraft Logs rotation: exactly what BRAT served in game ----------------
    # BRAT builds its Warcraft Logs rotation in game from the data shipped in
    # Data/WCLRaw.lua, and keeps it in the save file (rot.logs[spec]). Fights are
    # judged against that, chosen the same way the game chooses it.
    rot_all = brat.read_db_table("rot", a.wow_path)
    wcl_rot = rot_all.get("logs") if rot_all else None
    wcl_info = brat.wcl_info()

    def boss_data_for(sp, fight):
        """Which served rotation this fight used: the dungeon (whole run), else generic dungeon;
        the raid boss, else generic single target; elsewhere the kind BRAT logged at the
        start of the fight. None = no Warcraft Logs rotation."""
        rot = wcl_rot.get(sp) if wcl_rot else None
        if not rot:
            return None
        if fight.inst_type == "party":
            kind, key = "dungeon", brat.dungeon_key(fight.inst)
        elif fight.enc:
            kind, key = "boss", fight.enc
        elif fight.inst_type == "raid":
            kind, key = "raid", None
        else:
            kind, key = ("mplus" if fight.ctx_kind == "mplus" else "raid"), None
        sel = brat.select_rotation(rot, kind, key)
        return sel["data"] if sel else None

    def wcl_eval(sp, tg, frm, to, d):
        """How does "after frm, cast to" compare with top players? None = no data for frm."""
        if not d:
            return None
        cap = wcl_info[sp]["cap"] if sp in wcl_info else 8
        tg = min(max(tg, 1), cap)
        tos = None
        for r in range(9):  # nearest bucket that knows frm
            for k in (tg - r, tg + r):
                if tos is None and isinstance(d.get(k), dict) and d[k].get(frm) is not None:
                    tos = d[k][frm]
            if tos is not None:
                break
        if tos is None:
            return None
        total = sum(tos.values())
        best = max(tos, key=tos.get) if tos else None
        return {"top": to == best, "known": to in tos, "share": tos[to] / total if to in tos and total else 0}

    def n(i):
        return names.get(i) or f"spell {i}"

    def pct(x, y):
        return f"{brat.fmt(100.0 * (x or 0) / y, grouping=True):>5}%" if y and y > 0 else "    -"

    out = []

    def say(s=""):
        out.append(s)
        print(s)

    if not fights:
        say("No fights recorded yet. Fight something in game (history recording is on by default), /reload, then run this again.")
        return
    if a.boss:
        fights = [f for f in fights if a.boss.lower() in f.label.lower()]
    if spec:
        fights = [f for f in fights if f.spec == spec]
    if not fights:
        say(f"No fights match --boss '{a.boss}' / --spec {spec}.")
        return

    # Log name tag: the boss filter, the one boss/place if all fights share it, else "All".
    places = list(dict.fromkeys(f.label for f in fights))
    tag = a.boss if a.boss else (places[0] if len(places) == 1 else "All")
    tag = re.sub(r"[^\w\-]+", "-", tag).strip("-")
    log_dir = brat.TOOLS / "logs"

    by_spec: dict[int, list] = {}
    for f in fights:
        by_spec.setdefault(f.spec, []).append(f)
    for spec_id, group in by_spec.items():
        if spec and spec_id != spec:
            continue
        lst = sorted(group, key=lambda f: f.time)
        if a.last_fights > 0 and len(lst) > a.last_fights:
            lst = lst[-a.last_fights:]
        sn = spec_names.get(spec_id) or f"spec {spec_id}"

        say("=" * 78)
        say(f"{sn} ({spec_id})")
        say("=" * 78)
        secs = sum(f.length for f in lst)
        bosses = sum(1 for f in lst if f.enc > 0)
        say(f"1. Fights: {len(lst)} ({bosses} boss pulls), {brat.fmt(secs / 60, grouping=True)} minutes in combat")
        say()

        # ---- 2. NEXT accuracy / 3. priority -------------------------------------------
        acc: dict[str, list] = {}     # "kind|targets" -> [hits, total]
        misses: dict[str, int] = {}   # "from|predicted|actual" -> count
        casts = followed = 0
        universe: dict[int, set] = {}  # targets -> spells Blizzard ever picked
        for fight in lst:
            for e in fight.events:
                if e["type"] == "P" and e["pick"]:
                    universe.setdefault(e["used"], set()).add(e["pick"])
        wins: dict[int, dict] = {}
        games: dict[int, dict] = {}
        glow_seen, glow_used, late, late_sum, picks = {}, {}, {}, {}, {}
        # ---- 7. vs Warcraft Logs: [n compared, #1 matches, known follow-ups, share sum]
        vs = {"next": [0, 0, 0, 0.0], "blizz": [0, 0, 0, 0.0], "you": [0, 0, 0, 0.0]}

        def tally(key, r):
            if not r:
                return
            v = vs[key]
            v[0] += 1
            v[1] += r["top"]
            v[2] += r["known"]
            v[3] += r["share"]

        def inc(d, k, by=1):
            d[k] = d.get(k, 0) + by

        by_boss: dict[str, dict] = {}
        boss_matched = 0
        for fight in lst:
            bb = by_boss.setdefault(fight.label, {"section": fight.section, "fights": 0, "pred": 0, "hit": 0,
                                                  "next_n": 0, "next_ok": 0, "you_n": 0, "you_ok": 0})
            bb["fights"] += 1
            bd = boss_data_for(spec_id, fight)
            if bd:
                boss_matched += 1
            ev = fight.events
            last_p = prev_c = None
            for i, e in enumerate(ev):
                if e["type"] == "P":
                    last_p = e
                    if not e["pick"]:
                        continue
                    tg = e["used"]
                    # Priority: the pick beat every other spell that was ready.
                    w, g = wins.setdefault(tg, {}), games.setdefault(tg, {})
                    for o in universe.get(tg, ()):
                        if o == e["pick"]:
                            continue
                        c = e["cds"].get(o)
                        if c and c[0] > a.ready_window:
                            continue
                        inc(w, e["pick"])
                        inc(g, e["pick"])
                        inc(g, o)
                    for gl in e["glow"]:
                        inc(glow_seen, gl)
                        if gl == e["pick"]:
                            inc(glow_used, gl)
                    inc(picks, e["pick"])
                    c = e["cds"].get(e["pick"])
                    if c and c[1] and c[0] > a.ready_window:
                        inc(late, e["pick"])
                        inc(late_sum, e["pick"], c[0])
                elif e["type"] == "C":
                    casts += 1
                    tg_now = last_p["used"] if last_p else 1
                    # Your own sequence vs top players: consecutive casts within this
                    # fight (combat start to combat end), however far apart.
                    if prev_c:
                        r = wcl_eval(spec_id, tg_now, prev_c["spell"], e["spell"], bd)
                        tally("you", r)
                        if r:
                            bb["you_n"] += 1
                            bb["you_ok"] += r["known"]
                    prev_c = e
                    if e["spell"] != e["now"]:
                        continue
                    followed += 1
                    if not e["next"]:
                        continue
                    # What did Blizzard pick after this cast? The last pick before your
                    # next cast; none at all means it repeated the same spell.
                    actual = e["spell"]
                    for x in ev[i + 1:]:
                        if x["type"] == "C":
                            break
                        if x["type"] == "P" and x["pick"]:
                            actual = x["pick"]
                    kind = (last_p["kind"] if last_p else "") or "?"
                    tg = last_p["used"] if last_p else 1
                    r = wcl_eval(spec_id, tg, e["spell"], e["next"], bd)
                    tally("next", r)
                    if r:
                        bb["next_n"] += 1
                        bb["next_ok"] += r["known"]
                    tally("blizz", wcl_eval(spec_id, tg, e["spell"], actual, bd))
                    bb["pred"] += 1
                    bb["hit"] += actual == e["next"]
                    for key in (f"{kind}|all", f"all|{tg}", "all|all"):
                        av = acc.setdefault(key, [0, 0])
                        av[1] += 1
                        av[0] += actual == e["next"]
                    if actual != e["next"]:
                        inc(misses, f"{e['spell']}|{e['next']}|{actual}")

        say("2. NEXT accuracy (did NEXT match Blizzard's pick after you cast NOW?)")
        al = acc.get("all|all")
        if al:
            say(f"   overall: {pct(al[0], al[1])}  ({al[0]} of {al[1]})")
            for k in ("logs", "learned", "proc", "list"):
                v = acc.get(f"{k}|all")
                if v:
                    say(f"   {k:<8} {pct(v[0], v[1])}  ({v[1]} predictions)")
            for k in sorted((k for k in acc if k.startswith("all|") and k != "all|all"), key=lambda k: int(k.split("|")[1])):
                v = acc[k]
                say(f"   {k.split('|')[1]} target(s): {pct(v[0], v[1])}  ({v[1]} predictions)")
            say("   most common misses (after X, NEXT said Y, Blizzard picked Z):")
            for key, cnt in sorted(misses.items(), key=lambda kv: -kv[1])[:8]:
                x, y, z = (int(v) for v in key.split("|"))
                say(f"     {cnt:>4}x  after {n(x)}: NEXT {n(y)}, Blizzard {n(z)}")
        else:
            say("   no predictions recorded yet")
        say()

        say("3. Blizzard's priority, learned from every pick (top = chosen first when ready)")
        for tg in sorted(wins):
            rows = [(s, wins[tg].get(s, 0) / gm, gm) for s, gm in games[tg].items() if gm >= 5]
            rows.sort(key=lambda r: -r[1])
            if not rows:
                continue
            say(f"   {tg} target(s):")
            for rank, (s, score, gm) in enumerate(rows, 1):
                say(f"     {rank:>2}. {n(s):<32} wins {pct(score * 100, 100)}  ({gm} comparisons)")
        say()

        say("4. Procs (glowing spells): how often Blizzard picked it while it glowed")
        if not glow_seen:
            say("   no glowing spells recorded (none procced, or the game hides glows from addons)")
        for gl in sorted(glow_seen, key=lambda k: -glow_seen[k]):
            say(f"   {n(gl):<32} {pct(glow_used.get(gl, 0), glow_seen[gl])}  ({glow_seen[gl]} picks while glowing)")
        say()

        say("5. Cooldown tracker: Blizzard picked a spell BRAT estimated was still on cooldown")
        for s in sorted(late, key=lambda k: -late[k]):
            say(f"   {n(s):<32} {late[s]} of {picks[s]} picks, BRAT was {brat.fmt(late_sum[s] / late[s], grouping=True)}s too slow on average")
        if not late:
            say("   none: the estimates never blocked a spell Blizzard wanted")
        say()

        say(f"6. You: pressed the NOW spell {pct(followed, casts)} of the time ({casts} casts)")
        say()

        for section in ("Raid (per boss)", "Mythic+ / dungeons (whole dungeon)", "Other"):
            rows = sorted(((lbl, b) for lbl, b in by_boss.items() if b["section"] == section), key=lambda kv: -kv[1]["fights"])
            if not rows:
                continue
            say(section)
            say(f"   {'':<40} {'fights':>6} {'NEXT=Bliz':>10} {'NEXT=WCL':>10} {'You=WCL':>9}")
            for lbl, b in rows:
                say(f"   {lbl[:40]:<40} {b['fights']:>6} {pct(b['hit'], b['pred']):>10} {pct(b['next_ok'], b['next_n']):>10} {pct(b['you_ok'], b['you_n']):>9}")
            say()

        info = wcl_info.get(spec_id)
        if info and wcl_rot and wcl_rot.get(spec_id):
            say(f"7. Compared with Warcraft Logs ({info['players']} parses, ranks {info['ranks']}, data from {info['date']}; the rotation BRAT built in game)")
            say("   success = the step is something top players do after that spell; #1 = their most common choice")
            say(f"   {boss_matched} of {len(lst)} fights compared with the matching rotation (that boss / dungeon, else the generic one)")
            for k, label in (("next", "BRAT's NEXT"), ("blizz", "Blizzard's pick"), ("you", "Your casts")):
                v = vs[k]
                if v[0] == 0:
                    say(f"   {label:<16} no steps to compare yet")
                    continue
                say(f"   {label:<16} success {pct(v[2], v[0])}   #1 match {pct(v[1], v[0])}   ({v[0]} steps)")
        else:
            say("7. Compared with Warcraft Logs: no Warcraft Logs rotation saved for this spec. In game: BRAT settings > "
                "Spec data > Build rotation (Warcraft Logs), then /reload so the save file has it.")
        say()

        # Machine-readable line, used for the trend below on future runs.
        def p1(v):
            return brat.fmt(100.0 * v[2] / v[0], grouping=True) if v[0] else "-"
        next_acc = brat.fmt(100.0 * al[0] / al[1], grouping=True) if al else "-"
        summary = (f"SUMMARY spec={spec_id} tag={tag} fights={len(lst)} nextVsBlizzard={next_acc} nextVsWcl={p1(vs['next'])} "
                   f"blizzardVsWcl={p1(vs['blizz'])} youVsWcl={p1(vs['you'])}")

        say(f"8. Trend for '{tag}' (success %, oldest to newest run)")
        pat = re.compile(rf"^SUMMARY spec={spec_id} tag={re.escape(tag)} ")
        prev = []
        for f in sorted(log_dir.glob("BRAT-WCL-*.log"), key=lambda f: f.stat().st_mtime):
            lines = [ln for ln in brat.read_text(f).splitlines() if pat.match(ln)]
            if lines:
                prev.append((f, lines[-1]))
        say(f"   {'run':<20} {'NEXT=Bliz':>10} {'NEXT=WCL':>10} {'Blizz=WCL':>12} {'You=WCL':>8}")
        for f, line in prev[-5:]:
            kv = dict(re.findall(r"(\w+)=(\S+)", line))
            run = re.sub(r"^BRAT-WCL-.*?(\d{4}-)", r"\1", f.stem)
            say(f"   {run:<20} {kv.get('nextVsBlizzard', ''):>10} {kv.get('nextVsWcl', ''):>10} {kv.get('blizzardVsWcl', ''):>12} {kv.get('youVsWcl', ''):>8}")
        say(f"   {'this run':<20} {next_acc:>10} {p1(vs['next']):>10} {p1(vs['blizz']):>12} {p1(vs['you']):>8}")
        say()
        say(summary)
        say()

    log_dir.mkdir(parents=True, exist_ok=True)
    report = log_dir / f"BRAT-WCL-{tag}-{datetime.now().strftime('%Y-%m-%d_%H-%M-%S')}.log"
    brat.write_lines(report, out)
    print(f"Saved to {report}")


if __name__ == "__main__":
    main()
