"""Author tool: refreshes the Warcraft Logs data that ships inside BRAT (Data/WCLRaw.lua).
Players never run this: they get the data with addon updates.

Two stages, per spec (other specs are always kept as they are):
  pull    download top-player parses from the Warcraft Logs v2 API into this PC's
          cache (tools/cache/<Class>-<Spec>/, one file per boss/dungeon).
  export  turn the cache into Data/WCLRaw.lua: one compact record per parse
          (what followed what, at each enemy count, for its boss or dungeon).
  all     pull, then export (default).
In game, players then Rebuild averages and Build rotation (BRAT settings > Spec data,
or /brat averages, /brat rotation).

Parses: 15 per raid boss and per Mythic+ dungeon, ranks 101-115 (strong players, less
skewed by top-end setups); if a boss has fewer than 101 ranked parses, the lowest-ranked
ones of the top 100 are used. Fetching is resumable, and raising --players later only
fetches the extra parses. The API allows about 300 parses per hour (one spec, ~10
minutes); --wait-for-reset waits through the hourly limit.

Needs a free API client: warcraftlogs.com -> your profile -> API Clients -> Create Client
(any name, redirect URL can be http://localhost). Give it the Client ID and Secret as
--client-id / --client-secret, env vars WCL_CLIENT_ID / WCL_CLIENT_SECRET, or
tools/wcl-creds.json {"clientId": "...", "clientSecret": "..."}.

Examples:
  python tools/fetch_warcraftlogs.py --spec Holy --wait-for-reset
  python tools/fetch_warcraftlogs.py --spec Holy --stage export      # rewrite WCLRaw.lua from the cache
  python tools/fetch_warcraftlogs.py --spec Holy --players 25 --dungeon-players 25
  python tools/fetch_warcraftlogs.py --list-zones
"""
from __future__ import annotations

import argparse
import math
import os
import re
import sys
import time
from datetime import datetime, timezone

import brat

LOCK = brat.CACHE_DIR / ".fetch.lock"  # tells the Data Manager a fetch is running

Q_RANK = """
query($id: Int!, $cls: String!, $spec: String!, $page: Int!) {
  worldData { encounter(id: $id) { characterRankings(className: $cls, specName: $spec, metric: METRIC, page: $page) } }
}
"""
Q_REPORT = """
query($code: String!, $fid: Int!) {
  reportData { report(code: $code) {
    fights(fightIDs: [$fid]) { id startTime endTime }
    masterData { actors(type: "Player") { id name } }
  } }
}
"""
Q_EVENTS = """
query($code: String!, $fid: Int!, $sid: Int!, $start: Float!, $end: Float!) {
  reportData { report(code: $code) {
    events(fightIDs: [$fid], sourceID: $sid, dataType: DATATYPE, startTime: $start, endTime: $end, limit: 10000) {
      data nextPageTimestamp
    }
  } }
}
"""

# Consumables and other things nobody should be told to press as "next".
NOISE_NAMES = re.compile(r"potion|flask|phial|healthstone|augment rune|drums|food|feast", re.I)


def warn(msg):
    print("WARNING: " + msg, flush=True)


def parse_args():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--client-id")
    p.add_argument("--client-secret")
    p.add_argument("--spec", nargs="+", help="e.g. Shadow Holy (also Shadow,Holy). Default: the spec you last played.")
    p.add_argument("--players", type=int, default=15, help="damage parses per raid boss (15 = about 10 minutes per spec)")
    p.add_argument("--dungeon-players", type=int, default=15, help="damage parses per M+ dungeon")
    p.add_argument("--start-rank", type=int, default=101, help="take parses starting at this rank (101 = ranks 101-115 with 15 players)")
    p.add_argument("--wait-for-reset", action="store_true", help="at the hourly API limit, wait for the reset instead of stopping")
    p.add_argument("--zone-id", type=int, default=0, help="raid zone; default: newest raid")
    p.add_argument("--dungeon-zone-id", type=int, default=0, help="M+ zone; default: newest active M+ season")
    p.add_argument("--no-dungeons", action="store_true")
    p.add_argument("--max-targets", type=int, default=8, help='target counts 1..N ("8" means 8 or more)')
    p.add_argument("--points-reserve", type=int, default=150, help="stop fetching when this close to the hourly API limit")
    p.add_argument("--cap-tolerance", type=float, default=0.15, help="how different (0-1) a target count must be to stay its own bucket")
    p.add_argument("--cap-min-samples", type=int, default=150, help='buckets with fewer "A -> B" pairs don\'t vote on the cap')
    p.add_argument("--use-cache", action="store_true", help="only use what's cached, fetch nothing new")
    p.add_argument("--window-before-ms", type=int, default=2500, help="target-count window around each cast")
    p.add_argument("--window-after-ms", type=int, default=750)
    p.add_argument("--max-gap-ms", type=int, default=4000, help='casts further apart than this aren\'t a "next" (downtime)')
    p.add_argument("--list-zones", action="store_true")
    p.add_argument("--stage", choices=["all", "pull", "export"], default="all", type=str.lower)
    p.add_argument("--pause", action="store_true", help="wait for Enter at the end (the Data Manager's console window)")
    return p.parse_args()


def pick_specs(wanted):
    if not wanted:
        last = brat.last_spec()
        if not last:
            sys.exit("Don't know your spec yet: log in with BRAT and /reload once, or pass --spec Holy.")
        s = brat.find_spec(last)
        if not s:
            sys.exit(f"Your last spec ({last}) isn't supported yet. Known: {', '.join(x['spec'] for x in brat.SPECS)}.")
        print(f"Spec: {s['spec']} (the spec you last played; use --spec to choose another).")
        return [s]
    names = {n.strip().lower() for w in wanted for n in w.split(",") if n.strip()}
    specs = [s for s in brat.SPECS if s["spec"].lower() in names]
    if not specs:
        sys.exit(f"No matching specs. Known: {', '.join(x['spec'] for x in brat.SPECS)}.")
    return specs


def target_counts(casts, hits, before, after):
    """For each cast (sorted by time), how many distinct enemies did the player damage
    in [t - before, t + after]? Two-pointer sliding window."""
    counts = [0] * len(casts)
    in_win: dict[str, int] = {}
    lo = hi = 0
    for i, c in enumerate(casts):
        t = c[1]
        while hi < len(hits) and hits[hi][0] <= t + after:
            k = hits[hi][1]
            in_win[k] = in_win.get(k, 0) + 1
            hi += 1
        while lo < hi and hits[lo][0] < t - before:
            k = hits[lo][1]
            in_win[k] -= 1
            if in_win[k] <= 0:
                del in_win[k]
            lo += 1
        counts[i] = len(in_win)
    return counts


def pair_dist(buckets):
    d, total = {}, 0
    for t in buckets:
        if not t:
            continue
        for frm, tos in t.items():
            for to, n in tos.items():
                d[(frm, to)] = d.get((frm, to), 0) + n
                total += n
    return d, total


def distance(a, b):
    (da, ta), (db, tb) = a, b
    if ta == 0 or tb == 0:
        return 0
    return sum(abs(da.get(k, 0) / ta - db.get(k, 0) / tb) for k in set(da) | set(db)) / 2


def rotation_cap(spec_data, max_targets, tolerance, min_samples):
    """The target count where the rotation stops changing. For each candidate cap k,
    compare every bucket j >= k (with enough data) against all the other buckets >= k
    pooled together. If none differ by more than tolerance (total variation distance
    over "A -> B" pairs), everything from k up is one bucket."""
    for k in range(1, max_targets + 1):
        ok = True
        for j in range(k, max_targets + 1):
            one = pair_dist([spec_data.get(j)])
            if one[1] < min_samples:
                continue
            rest = pair_dist([spec_data.get(x) for x in range(k, max_targets + 1) if x != j])
            if rest[1] < min_samples:
                continue
            if distance(one, rest) > tolerance:
                ok = False
                break
        if ok:
            return k
    return max_targets


def merge_above_cap(sd, cap):
    """Merge every bucket above the cap into the cap bucket."""
    dst = sd.setdefault(cap, {})
    for j in [j for j in sd if j > cap]:
        for frm, tos in sd[j].items():
            row = dst.setdefault(frm, {})
            for to, n in tos.items():
                row[to] = row.get(to, 0) + n
        del sd[j]


def lua_pairs(p):
    parts = []
    for tg in sorted(p):
        froms = []
        for a in sorted(p[tg]):
            tos = ",".join(f"[{b}]={p[tg][a][b]}" for b in sorted(p[tg][a]))
            froms.append(f"[{a}]={{{tos}}}")
        parts.append(f"[{tg}]={{{','.join(froms)}}}")
    return "{" + ",".join(parts) + "}"


def main():
    a = parse_args()
    specs = pick_specs(a.spec)
    use_cache = a.use_cache or a.stage == "export"  # export never downloads

    wcl = brat.Wcl(a.client_id, a.client_secret)
    q = wcl.query

    # --- Pick zones -----------------------------------------------------------
    world = q("query { worldData { expansions { id name zones { id name frozen encounters { id name } } } } }")
    newest = max(world["worldData"]["expansions"], key=lambda e: e["id"])
    zones = [z for z in newest["zones"] if z.get("encounters")]
    if a.list_zones:
        print(f"Zones in {newest['name']}:")
        for z in zones:
            print(f"  {z['id']:>5}  {z['name']}  ({len(z['encounters'])} bosses){' [frozen]' if z.get('frozen') else ''}")
        return

    def find_zone(zid, auto, what):
        if zid:
            z = next((z for z in zones if z["id"] == zid), None)
            if not z:
                sys.exit(f"Zone {zid} not found. Run with --list-zones.")
            return z
        cands = sorted((z for z in zones if auto(z)), key=lambda z: z["id"], reverse=True)
        if not cands:
            sys.exit(f"Couldn't pick a {what} zone automatically. Run with --list-zones.")
        return cands[0]

    sources = []
    raid = find_zone(a.zone_id, lambda z: not z.get("frozen") and not re.search(r"Mythic\+|Beta|Complete|Delve|PTR|Dummy", z["name"], re.I), "raid")
    sources.append({"zone": raid, "count": a.players, "kind": "raid"})
    print(f"Raid zone: {raid['name']} ({raid['id']}), {len(raid['encounters'])} bosses, {a.players} parses each from rank {a.start_rank}.")
    if not a.no_dungeons:
        mplus = find_zone(a.dungeon_zone_id, lambda z: not z.get("frozen") and re.search(r"Mythic\+", z["name"], re.I)
                          and not re.search(r"PTR|Beta", z["name"], re.I), "Mythic+")
        sources.append({"zone": mplus, "count": a.dungeon_players, "kind": "mplus"})
        print(f"M+ zone:   {mplus['name']} ({mplus['id']}), {len(mplus['encounters'])} dungeons, {a.dungeon_players} parses each from rank {a.start_rank}.")

    def all_events(code, fid, sid, fight, data_type):
        out, start = [], float(fight["startTime"])
        qe = Q_EVENTS.replace("DATATYPE", data_type)
        while True:
            ev = q(qe, {"code": code, "fid": fid, "sid": sid, "start": start, "end": float(fight["endTime"])})["reportData"]["report"]["events"]
            out.extend(ev.get("data") or [])
            if not ev.get("nextPageTimestamp"):
                return out
            start = float(ev["nextPageTimestamp"])

    def points_left():
        """True = keep fetching. Near the hourly limit: wait for the reset (--wait-for-reset) or stop."""
        try:
            rl = wcl.rate_limit()
            if rl["limitPerHour"] - rl["pointsSpentThisHour"] > a.points_reserve:
                return True
            if not a.wait_for_reset:
                return False
            wait = int(rl["pointsResetIn"]) + 30
            print(f"  API limit nearly used; waiting {round(wait / 60)} min for the hourly reset (Ctrl+C is safe: progress is saved)...", flush=True)
            time.sleep(wait)
            return True
        except Exception:
            return True

    # --- Pull data --------------------------------------------------------------
    # Resumable: every boss/dungeon has its own cache file, tools/cache/<Class>-<Spec>/<kind>-<encounterID>.json,
    # holding the players fetched so far. Re-running only fetches players not in the cache yet,
    # so a big fetch (top 100 everywhere) can be spread over several hours.
    seqs, seq_enc, info, dmg_ids, all_ids = {}, {}, {}, {}, set()
    stop, since_check = False, 0
    names = brat.load_names()

    for s in specs:
        sid_ = s["id"]
        seqs[sid_], seq_enc[sid_], dmg_ids[sid_] = [], [], set()
        info[sid_] = {"players": 0, "casts": [0] * (a.max_targets + 1)}
        sdir = brat.spec_dir(s)
        for src in sources:
            for enc in src["zone"]["encounters"]:
                cf = sdir / f"{src['kind']}-{enc['id']}.json"
                ec = brat.load_cache(cf)
                # A cache built from a different rank range starts over (don't mix ranges).
                if ec and int(ec["startRank"]) != a.start_rank:
                    if use_cache:
                        print(f"  ({enc['name']}: cache is from rank {ec['startRank']}; using it as is)")
                    else:
                        ec = None
                if not ec:
                    ec = {"id": int(enc["id"]), "name": str(enc["name"]), "kind": src["kind"], "startRank": a.start_rank,
                          "tried": set(), "seqs": [], "dmg": set()}
                have = len(ec["seqs"])
                if not use_cache and not stop and have < src["count"]:
                    print(f"[{s['spec']}] {enc['name']}: have {have}, fetching up to {src['count']} from rank {a.start_rank}...", flush=True)
                    # Rankings come 100 per page; start at the page holding start_rank.
                    # Fetch a few spare ranks too, to replace players whose logs fail.
                    want = src["count"] + 15
                    first_page = (a.start_rank - 1) // 100 + 1
                    skip = (a.start_rank - 1) % 100
                    ranks = []

                    def rank_page(pg):
                        r = q(Q_RANK.replace("METRIC", s["metric"]), {"id": int(enc["id"]), "cls": s["cls"], "spec": s["spec"], "page": pg})
                        return r["worldData"]["encounter"]["characterRankings"] or {}

                    try:
                        page = first_page
                        for _ in range(4):
                            if len(ranks) >= skip + want:
                                break
                            cr = rank_page(page)
                            ranks += cr.get("rankings") or []
                            page += 1
                            if not cr.get("hasMorePages"):
                                break
                        if len(ranks) <= skip and first_page > 1:
                            # Fewer parses than the start rank (common for healer specs on
                            # damage): use the lowest-ranked ones of the top 100 instead of none.
                            top = rank_page(1).get("rankings") or []
                            if top:
                                frm = max(0, len(top) - want)
                                print(f"  only {len(top)} ranked players here; using ranks {frm + 1}-{len(top)} instead of {a.start_rank}+.")
                                ranks, skip = top[frm:], 0
                    except Exception as e:
                        warn(f"  rankings failed: {e}")
                    if len(ranks) <= skip:
                        warn("  no ranked players here; skipping.")
                        ranks = []
                    else:
                        ranks = ranks[skip:skip + want]

                    new_here = 0
                    for rk in ranks:
                        if len(ec["seqs"]) >= src["count"]:
                            break
                        key = f"{rk['report']['code']}-{rk['report']['fightID']}-{rk['name']}"
                        if key in ec["tried"]:
                            continue  # fetched (or failed) before
                        since_check += 1
                        if since_check >= 8:
                            since_check = 0
                            if not points_left():
                                warn("Close to the hourly Warcraft Logs API limit; saving and stopping. Run again later to continue (or use --wait-for-reset).")
                                stop = True
                                break
                        ec["tried"].add(key)
                        try:
                            code, fid = rk["report"]["code"], int(rk["report"]["fightID"])
                            rep = q(Q_REPORT, {"code": code, "fid": fid})["reportData"]["report"]
                            fight = (rep.get("fights") or [None])[0]
                            actor = next((x for x in (rep.get("masterData") or {}).get("actors") or [] if x["name"] == rk["name"]), None)
                            if not fight or not actor:
                                continue
                            sid = int(actor["id"])
                            casts = [(int(e["abilityGameID"]), float(e["timestamp"]))
                                     for e in all_events(code, fid, sid, fight, "Casts") if e.get("type") == "cast"]
                            hits = [(float(e["timestamp"]), f"{e['targetID']}.{int(e.get('targetInstance') or 0)}", int(e["abilityGameID"]))
                                    for e in all_events(code, fid, sid, fight, "DamageDone") if e.get("type") == "damage" and e.get("targetID")]
                            ec["dmg"].update(h[2] for h in hits)
                            tc = target_counts(casts, hits, a.window_before_ms, a.window_after_ms)
                            seq, multi = [], 0
                            for (ab, ts), n in zip(casts, tc):
                                k = max(1, min(a.max_targets, n))
                                seq.append([ab, int(ts) if ts.is_integer() else ts, k])
                                multi += k >= 2
                            ec["seqs"].append(seq)
                            new_here += 1
                            pct = round(100 * multi / len(casts)) if casts else 0
                            print(f"    {len(ec['seqs'])}. {rk['name']}: {len(casts)} casts, {pct}% on 2+ targets", flush=True)
                            if new_here % 10 == 0:
                                brat.save_cache(cf, ec)
                        except Exception as e:
                            warn(f"    {rk['name']} skipped: {e}")
                    brat.save_cache(cf, ec)

                # Add this boss/dungeon's cached players to the spec's data.
                for seq in ec["seqs"]:
                    seqs[sid_].append(seq)
                    seq_enc[sid_].append({"id": int(ec["id"]), "name": str(ec["name"]), "kind": ec["kind"]})
                    info[sid_]["players"] += 1
                    for e in seq:
                        all_ids.add(int(e[0]))
                        info[sid_]["casts"][int(e[2])] += 1
                for k in ec["dmg"]:
                    dmg_ids[sid_].add(int(k))
                    all_ids.add(int(k))
        print(f"[{s['spec']}] {info[sid_]['players']} players in total.")

    if a.stage == "pull":
        print("PC cache updated. Next: --stage export (writes Data/WCLRaw.lua for the addon).")
        return

    # --- Spell names, noise filter, and pair counting ------------------------------
    id_list = sorted(i for i in all_ids if i > 0 and not names.get(i))  # WCL uses negative IDs for special events
    for i in range(0, len(id_list), 80):
        parts = " ".join(f"a{x}: ability(id: {x}) {{ id name }}" for x in id_list[i:i + 80])
        try:
            g = q(f"query {{ gameData {{ {parts} }} }}")["gameData"]
            for v in g.values():
                if v:
                    names[int(v["id"])] = v["name"]
        except Exception as e:
            warn(f"Spell name lookup failed: {e}")
    if id_list:
        brat.save_names(names)

    specs = [s for s in specs if info.get(s["id"]) and info[s["id"]]["players"] > 0]
    if not specs:
        sys.exit("No player data cached; leaving Data/WCLRaw.lua unchanged.")

    data = {}     # data[spec][targets][from][to] = count (all pooled; for the rotation cap)
    raw_rec = {}  # raw_rec[spec] = list of per-parse records (Data/WCLRaw.lua)
    for s in specs:
        sp = s["id"]
        raw_rec[sp] = []
        ignore = {int(i) for i in s["ignore"] if i}
        ignore |= {i for i, n in names.items() if n and NOISE_NAMES.search(n)}
        # Damage profile: keep a cast only if a damage event shares its ID or its name
        # (some spells, like Halo, deal damage under a different ID than the cast).
        keep = None
        if s["damage_only"]:
            dmg_names = {names[i] for i in dmg_ids[sp] if names.get(i)}
            keep = lambda i, sp=sp, dn=dmg_names: i in dmg_ids[sp] or (names.get(i) and names[i] in dn)

        data[sp] = {}
        for si, seq in enumerate(seqs[sp]):
            enc = seq_enc[sp][si] if si < len(seq_enc[sp]) else None
            # Pairs go into the pooled data (for the rotation cap) and into this parse's own
            # record, for the raw cache shipped with the addon (Data/WCLRaw.lua): the game
            # rebuilds averages / rotations from it.
            own = {}
            targetsets = [data[sp], own]
            if enc and int(enc["id"]) > 0:
                if enc["kind"] == "mplus":
                    # Dungeons are matched by name in game (lowercase, no apostrophes).
                    raw_rec[sp].append({"kind": "dungeon", "key": brat.dungeon_key(enc["name"]), "label": enc["name"], "pairs": own})
                else:
                    raw_rec[sp].append({"kind": "boss", "key": int(enc["id"]), "label": enc["name"], "pairs": own})
            clean = [e for e in seq if e[0] not in ignore and (keep is None or keep(e[0]))]
            for i in range(1, len(clean)):
                x, y = clean[i - 1], clean[i]
                if y[1] - x[1] > a.max_gap_ms:
                    continue
                bucket, frm, to = int(x[2]), x[0], y[0]
                for d in targetsets:
                    row = d.setdefault(bucket, {}).setdefault(frm, {})
                    row[to] = row.get(to, 0) + 1

    # --- Rotation cap -----------------------------------------------------------------
    caps = {}
    for s in specs:
        sd = data[s["id"]]
        cap = rotation_cap(sd, a.max_targets, a.cap_tolerance, a.cap_min_samples)
        caps[s["id"]] = cap
        merge_above_cap(sd, cap)
        print(f"[{s['spec']}] rotation cap: {cap} target(s). Buckets: {', '.join(f'{x}+' if x == cap else str(x) for x in range(1, cap + 1))}")

    # --- Write Data/WCLRaw.lua: the raw cache that ships inside the addon ----------------
    # One record per parse: what followed what at each enemy count, for its boss or dungeon.
    # The game builds the averages and the rotation from this (in game, Spec data page /
    # /brat averages / /brat rotation). Each spec is its own marked block, so refreshing
    # one spec keeps the others.
    raw_out = brat.ROOT / "Data" / "WCLRaw.lua"
    other = []
    if raw_out.exists():
        keep_it = False
        doing = {s["id"] for s in specs}
        with open(raw_out, encoding="utf-8-sig") as fh:
            for line in fh.read().splitlines():
                m = re.match(r"^-- BEGIN SPEC (\d+)", line)
                if m:
                    keep_it = int(m.group(1)) not in doing
                if keep_it:
                    other.append(line)
                if line.startswith("-- END SPEC"):
                    keep_it = False
    zone_names = " + ".join(src["zone"]["name"].replace('"', "") for src in sources)
    today = datetime.now().strftime("%Y-%m-%d")
    built = int(datetime.now(timezone.utc).timestamp())
    out = ["-- Warcraft Logs raw cache shipped with BRAT: one record per top-player parse (what followed what,",
           "-- at each enemy count, for its raid boss or dungeon). BRAT builds averages and rotations from it in game.",
           "-- GENERATED by tools\\fetch_warcraftlogs.py -- edits here will be overwritten.",
           "local _, BRAT = ...",
           "BRAT.WCLRaw = BRAT.WCLRaw or {}"]
    for s in specs:
        recs = [r for r in raw_rec[s["id"]] if r["pairs"]]
        out.append("")
        out.append(f"-- BEGIN SPEC {s['id']} ({s['spec']} {s['cls']}, {today})")
        out.append(f'BRAT.WCLRaw[{s["id"]}] = {{ info = {{ built = {built}, date = "{today}", players = {len(recs)}, cap = {caps[s["id"]]}, '
                   f'ranks = "{a.start_rank}-{a.start_rank + a.players - 1}", zone = "{zone_names}" }}, fights = {{')
        for r in recs:
            key = str(r["key"]) if r["kind"] == "boss" else '"' + r["key"].replace('"', "") + '"'
            out.append(f'{{kind="{r["kind"]}",key={key},label="{r["label"].replace(chr(34), "")}",pairs={lua_pairs(r["pairs"])}}},')
        out.append("} }")
        out.append(f"-- END SPEC {s['id']}")
    out.extend(other)
    brat.write_lines(raw_out, out)
    print(f"Wrote {raw_out} (shipped raw cache): {', '.join(f'{s['spec']} {len(raw_rec[s['id']])} parses' for s in specs)}.")

    for s in specs:
        i = info[s["id"]]
        dist = " ".join(f"{t}{'+' if t == a.max_targets else ''}:{i['casts'][t]}" for t in range(1, a.max_targets + 1))
        print(f"  {s['spec']}: {i['players']} players. Casts by target count: {dist}")

    try:
        rl = wcl.rate_limit()
        print(f"API points: {int(rl['pointsSpentThisHour'])} / {rl['limitPerHour']} this hour (resets in {round(rl['pointsResetIn'] / 60)} min).")
    except Exception:
        pass


if __name__ == "__main__":
    brat.CACHE_DIR.mkdir(parents=True, exist_ok=True)
    LOCK.write_text(str(os.getpid()))
    code = 0
    try:
        main()
    except brat.WclError as e:
        print(e)
        code = 1
    except KeyboardInterrupt:
        print("Stopped (progress so far is saved).")
        code = 1
    except SystemExit as e:
        if e.code not in (None, 0):
            print(e.code)
            code = 1
    finally:
        try:
            LOCK.unlink()
        except OSError:
            pass
    if "--pause" in sys.argv:
        print()
        input("Done. Press Enter to close this window.")
    sys.exit(code)
