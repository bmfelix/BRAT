"""Pulls YOUR Warcraft Logs parses and matches each one to the NEXT source BRAT was
using in that fight. Writes Data/MyParses.lua for the "Compare sources" settings page.

  1. Upload your logs to warcraftlogs.com as usual.
  2. /reload in game so BRAT's fight list is saved to disk.
  3. Run this script, then /reload again.
Only raid boss kills are matched (Warcraft Logs ranks Mythic+ by whole run).
Uses the same credentials as fetch_warcraftlogs.py (tools/wcl-creds.json).

Your character, realm and region are recorded by BRAT with every fight, so normally
you don't pass anything. --character/--realm/--region override them.

Examples:
  python tools/fetch_my_parses.py
  python tools/fetch_my_parses.py --character Bradpriest --realm "Area 52"
"""
from __future__ import annotations

import argparse
import re
import sys
from datetime import datetime

import brat

QUERY = """
query($n: String!, $s: String!, $r: String!, $e: Int!, $d: Int, $spec: String) {
  characterData { character(name: $n, serverSlug: $s, serverRegion: $r) {
    encounterRankings(encounterID: $e, difficulty: $d, specName: $spec, metric: METRIC)
  } }
}
"""
# Blizzard difficulty IDs (from ENCOUNTER_START) -> Warcraft Logs raid difficulty IDs.
WCL_DIFF = {17: 1, 14: 3, 15: 4, 16: 5}


def slug(realm: str) -> str:
    return re.sub(r"\s+", "-", realm.lower().replace("'", ""))


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--character")
    p.add_argument("--realm")
    p.add_argument("--region")
    p.add_argument("--wow-path", default=brat.WOW_PATH)
    p.add_argument("--match-window-sec", type=int, default=180, help="how close a parse's start must be to BRAT's recorded pull time")
    p.add_argument("--client-id")
    p.add_argument("--client-secret")
    a = p.parse_args()

    # The specs BRAT supports come from the one list in tools/brat.py.
    # (BRAT's healer profiles are damage profiles, so their metric is dps too.)
    spec_names = {s["id"]: s["spec"] for s in brat.SPECS}
    metric = {s["id"]: s["metric"] for s in brat.SPECS}
    wcl = brat.Wcl(a.client_id, a.client_secret)

    # --- Read BRAT's fight list from SavedVariables ---------------------------------
    files = brat.all_saved_variables(a.wow_path)
    if not files:
        sys.exit("No BRAT SavedVariables found. Play, then /reload in game first.")
    fights = []
    for file in files:
        for line in brat.read_text(file).splitlines():
            m = re.match(r'^\s*"(t=[^"]+)"', line)
            if not m:
                continue
            f = dict(kv.split("=", 1) for kv in m.group(1).split(";") if "=" in kv)
            if f.get("kind") == "boss" and brat.num(f.get("enc")) > 0:
                char = a.character or f.get("char")
                realm = a.realm or f.get("realm")
                region = a.region or f.get("region") or "US"
                if not char or not realm:
                    continue  # fights recorded before BRAT saved character info
                fights.append({"t": float(brat.num(f.get("t"))), "spec": int(brat.num(f.get("spec"))), "src": f.get("src"),
                               "enc": int(brat.num(f.get("enc"))), "diff": int(brat.num(f.get("diff"))),
                               "char": char, "realm": realm, "region": region})
    print(f"BRAT recorded {len(fights)} raid boss fights.")
    if not fights:
        sys.exit("No boss fights recorded yet. Raid with BRAT on, then /reload.")

    # --- Query your rankings per character/boss/difficulty/spec, match by time ------
    groups: dict[tuple, list] = {}
    for f in fights:
        groups.setdefault((f["char"], f["realm"], f["region"], f["spec"], f["enc"], f["diff"]), []).append(f)

    results: dict[int, list] = {}  # results[spec] = list of {t, src, pct, enc, diff}
    who = {}
    for group in groups.values():
        first = group[0]
        spec_name = spec_names.get(first["spec"])
        if not spec_name:
            continue
        label = f"{first['char']}-{first['realm']} ({first['region']})"
        variables = {"n": first["char"], "s": slug(first["realm"]), "r": first["region"], "e": first["enc"], "spec": spec_name}
        if first["diff"] in WCL_DIFF:
            variables["d"] = WCL_DIFF[first["diff"]]
        try:
            d = wcl.query(QUERY.replace("METRIC", metric[first["spec"]]), variables)
        except Exception as e:
            print(f"WARNING: {label} encounter {first['enc']}: {e}")
            continue
        char = (d.get("characterData") or {}).get("character")
        if not char:
            print(f"WARNING: {label} not found on Warcraft Logs (have you uploaded logs?).")
            continue
        who[label] = True
        ranks = (char.get("encounterRankings") or {}).get("ranks") or []
        matched = 0
        for rk in ranks:
            start = float(rk["startTime"]) / 1000
            f = next((x for x in group if abs(x["t"] - start) <= a.match_window_sec), None)
            if not f:
                continue
            results.setdefault(f["spec"], []).append({"t": int(f["t"]), "src": f["src"], "pct": float(rk["rankPercent"]),
                                                      "enc": f["enc"], "diff": f["diff"]})
            matched += 1
        print(f"  {label} encounter {first['enc']} ({spec_name}, difficulty {first['diff']}): {len(ranks)} parses, {matched} matched to BRAT fights")

    # --- Write Data/MyParses.lua ------------------------------------------------------
    now = datetime.now().strftime("%Y-%m-%d")
    out = ["-- Your own Warcraft Logs parses, matched to the NEXT source BRAT was using.",
           f"-- GENERATED by tools\\fetch_my_parses.py on {now} -- edits here will be overwritten.",
           "-- Format: [specID] = { { t = pull time, src = source BRAT used, pct = parse percentile, enc, diff }, ... }",
           "-- BRAT averages these per source in game (and skips ones from before a comparison reset).",
           "local _, BRAT = ...",
           "",
           "BRAT.MyParses = {"]
    for spec in sorted(results):
        out.append(f"    [{spec}] = {{ -- {spec_names[spec]}")
        for r in sorted(results[spec], key=lambda r: r["t"]):
            out.append(f'        {{ t = {r["t"]}, src = "{r["src"]}", pct = {brat.fmt(r["pct"])}, enc = {r["enc"]}, diff = {r["diff"]} }},')
        out.append("    },")
        for src in ("logs", "blizzard"):
            pcts = [r["pct"] for r in results[spec] if r["src"] == src]
            if pcts:
                print(f"{spec_names[spec]} / {src}: {len(pcts)} parses, average {brat.fmt(sum(pcts) / len(pcts))}")
    out.append("}")
    names = ", ".join(who).replace('"', "")
    out.append(f'BRAT.MyParsesInfo = {{ date = "{now}", character = "{names}" }}')

    path = brat.ROOT / "Data" / "MyParses.lua"
    brat.write_lines(path, out)
    print(f"Wrote {path}. /reload in game to see it under BRAT > Compare sources.")


if __name__ == "__main__":
    try:
        main()
    except brat.WclError as e:
        sys.exit(str(e))
