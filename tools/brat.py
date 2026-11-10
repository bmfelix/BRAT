"""BRAT shared module: what every PC tool needs, in one place.

  SPECS                 the specs BRAT supports (the one list)
  find_spec(name|id)    one entry of SPECS
  saved_variables()     path of the newest BRAT SavedVariables file
  all_saved_variables() every account's BRAT SavedVariables file
  last_spec()           the spec you last played
  parse_lua_table()     parse a Lua table literal (SavedVariables format)
  read_db_table(name)   one top-level table of BRATDB (e.g. "rot") as dicts
  wcl_info()            info about the Warcraft Logs data shipped in Data/WCLRaw.lua
  dungeon_key(name)     dungeon name -> the key the addon uses (lowercase, no apostrophes)
  select_rotation()     the served rotation for a fight (mirrors RotationBuilder.Select)
  Wcl                   Warcraft Logs v2 API client (credentials, token, queries)
  load_cache / save_cache   the per-boss parse cache in tools/cache (JSON)
  write_lines()         write a text file the way the game and git expect (UTF-8, CRLF)
"""
from __future__ import annotations

import base64
import glob
import json
import os
import re
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

TOOLS = Path(__file__).resolve().parent
ROOT = TOOLS.parent
CACHE_DIR = TOOLS / "cache"
NAMES_FILE = CACHE_DIR / "spell-names.json"
WOW_PATH = r"C:\Program Files (x86)\World of Warcraft\_retail_"

# The specs BRAT supports, for every PC tool (the one list to extend).
#   ignore      = spell IDs that show up as casts but aren't buttons (auto-procs).
#   damage_only = keep only casts of spells that dealt damage (a healer's damage
#                 profile: heals between damage casts aren't counted as "next").
SPECS = [
    {"id": 256, "cls": "Priest", "spec": "Discipline", "metric": "dps", "ignore": [], "damage_only": True},
    {"id": 257, "cls": "Priest", "spec": "Holy", "metric": "dps", "ignore": [], "damage_only": True},
    {"id": 258, "cls": "Priest", "spec": "Shadow", "metric": "dps", "ignore": [341263], "damage_only": False},  # Shadowy Apparition
    # Devastation: movement, defensives, utility and potions sit between rotation casts
    # (Hover alone ~20x a fight). Not damage_only: Dragonrage and Tip the Scales deal no damage themselves.
    {"id": 1467, "cls": "Evoker", "spec": "Devastation", "metric": "dps", "damage_only": False,
     "ignore": [358267, 358733, 363916, 374348, 374968, 374227, 370665, 360995, 361195, 361509, 355913,  # Hover, Glide, Obsidian Scales, Renewing Blaze, Time Spiral, Zephyr, Rescue, Verdant Embrace x2, Living Flame (heal), Emerald Blossom
                365585, 374251, 351338, 364342, 406732, 357214, 358385, 390386, 1236616, 1236998, 370454]},  # Charged Blast (auto), Expunge, Cauterizing Flame, Quell, Blessing of the Bronze, Spatial Paradox, Wing Buffet, Landslide, Fury of the Aspects, Light's Potential, Draught of Rampant Abandon
]


def find_spec(key):
    """A SPECS entry by spec ID or spec name (case-insensitive), or None."""
    for s in SPECS:
        if s["id"] == key or (isinstance(key, str) and s["spec"].lower() == key.lower()):
            return s
    return None


def spec_dir(s) -> Path:
    return CACHE_DIR / f"{s['cls']}-{s['spec']}"


# --- SavedVariables -----------------------------------------------------------
def all_saved_variables(wow_path: str = WOW_PATH) -> list[Path]:
    return [Path(p) for p in glob.glob(os.path.join(wow_path, "WTF", "Account", "*", "SavedVariables", "BRAT.lua"))]


def saved_variables(wow_path: str = WOW_PATH) -> Path | None:
    files = all_saved_variables(wow_path)
    return max(files, key=lambda p: p.stat().st_mtime) if files else None


def read_text(path) -> str:
    return Path(path).read_text(encoding="utf-8-sig", errors="replace")


def last_spec(wow_path: str = WOW_PATH) -> int | None:
    """The spec you last played (BRAT saves it on login and spec change), or None."""
    sv = saved_variables(wow_path)
    if not sv:
        return None
    m = re.search(r'\["lastSpec"\]\s*=\s*(\d+)', read_text(sv))
    return int(m.group(1)) if m else None


# --- Lua table literals -------------------------------------------------------
_TOKEN = re.compile(r'"(?:[^"\\]|\\.)*"|--[^\n]*|-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?|[{}\[\]=,;]|true|false|nil|[A-Za-z_]\w*')
_ESC = {"n": "\n", "t": "\t", "r": "\r", "\\": "\\", '"': '"', "'": "'", "a": "\a", "b": "\b", "f": "\f", "v": "\v", "\n": "\n"}


def _lua_unescape(s: str) -> str:
    out, i = [], 0
    while i < len(s):
        c = s[i]
        if c == "\\" and i + 1 < len(s):
            n = s[i + 1]
            if n.isdigit():
                m = re.match(r"\d{1,3}", s[i + 1:])
                out.append(chr(int(m.group(0))))
                i += 1 + len(m.group(0))
                continue
            out.append(_ESC.get(n, n))
            i += 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


def parse_lua_table(text: str):
    """Lua table literal -> nested dicts. Keys are int or str; values int/float/str/bool/None
    or dicts. Handles the SavedVariables format (["key"] = value, [1] = value, list values, comments)."""
    tokens = [t for t in _TOKEN.findall(text) if not t.startswith("--")]
    pos = 0

    def value():
        nonlocal pos
        t = tokens[pos]
        pos += 1
        if t == "{":
            return body()
        if t.startswith('"'):
            return _lua_unescape(t[1:-1])
        if t == "true":
            return True
        if t == "false":
            return False
        if t == "nil":
            return None
        if re.fullmatch(r"-?\d+", t):
            return int(t)
        return float(t)

    def body():
        nonlocal pos
        tbl, n = {}, 0
        while tokens[pos] != "}":
            t = tokens[pos]
            if t in (",", ";"):
                pos += 1
                continue
            if t == "[":
                pos += 1
                k = value()
                pos += 2  # ']' '='
                tbl[k] = value()
            elif tokens[pos + 1] == "=" and re.fullmatch(r"[A-Za-z_]\w*", t):
                pos += 2  # name '='
                tbl[t] = value()
            else:
                n += 1
                tbl[n] = value()
        pos += 1  # '}'
        return tbl

    return value()


def read_db_table(name: str, wow_path: str = WOW_PATH):
    """One top-level table of BRATDB, e.g. read_db_table("rot") -> rot[source][spec]...
    Only that table is parsed (the save file also holds a long fight log)."""
    sv = saved_variables(wow_path)
    if not sv:
        return None
    text = read_text(sv)
    m = re.search(r'^\s*\["' + re.escape(name) + r'"\]\s*=\s*\{', text, re.M)
    if not m:
        return None
    start = m.end() - 1
    depth, in_str, i = 0, False, start
    while i < len(text):  # matching closing brace, skipping braces inside strings
        ch = text[i]
        if in_str:
            if ch == "\\":
                i += 1
            elif ch == '"':
                in_str = False
        elif ch == '"':
            in_str = True
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                break
        i += 1
    return parse_lua_table(text[start:i + 1])


# --- Shipped Warcraft Logs data -----------------------------------------------
def wcl_info() -> dict:
    """Info lines from Data/WCLRaw.lua: {specID: {built, date, players, cap, ranks}}."""
    f = ROOT / "Data" / "WCLRaw.lua"
    info = {}
    if not f.exists():
        return info
    pat = re.compile(r'^BRAT\.WCLRaw\[(\d+)\] = \{ info = \{ built = (\d+), date = "([^"]*)", players = (\d+), cap = (\d+), ranks = "([^"]*)"')
    with open(f, encoding="utf-8-sig", errors="replace") as fh:
        for line in fh:
            m = pat.match(line)
            if m:
                info[int(m.group(1))] = {"built": int(m.group(2)), "date": m.group(3), "players": int(m.group(4)),
                                         "cap": int(m.group(5)), "ranks": m.group(6)}
    return info


def dungeon_key(name):
    """Same normalization as Context.Lower in the addon."""
    return re.sub("[\u2019']", "", name.lower()) if name else name


def select_rotation(rot, kind, key):
    """The served rotation for a place (mirrors RotationBuilder.Select in the addon):
      boss -> that boss, else generic single target; raid -> generic single target
      dungeon -> that dungeon, else generic dungeon;  mplus -> generic dungeon
    Returns {"data", "label"} or None."""
    if not rot:
        return None
    raid = rot.get("raid") or {}
    dung = rot.get("dungeon") or {}
    labels = rot.get("labels") or {}

    def pick(d, label):
        return {"data": d, "label": label} if d else None

    if kind == "boss" and (raid.get("bosses") or {}).get(key):
        return pick(raid["bosses"][key], labels.get(key))
    if kind == "dungeon" and (dung.get("dungeons") or {}).get(key):
        return pick(dung["dungeons"][key], labels.get(key))
    if kind in ("boss", "raid"):
        if raid.get("generic"):
            return pick(raid["generic"], "generic single target")
        return pick(dung.get("generic"), "generic dungeon")
    if dung.get("generic"):
        return pick(dung["generic"], "generic dungeon")
    return pick(raid.get("generic"), "generic single target")


# --- Warcraft Logs API --------------------------------------------------------
class WclError(Exception):
    pass


class Wcl:
    """Warcraft Logs v2 client. Credentials: arguments, env vars WCL_CLIENT_ID /
    WCL_CLIENT_SECRET, or tools/wcl-creds.json {"clientId": "...", "clientSecret": "..."}."""
    API = "https://www.warcraftlogs.com/api/v2/client"
    TOKEN = "https://www.warcraftlogs.com/oauth/token"

    def __init__(self, client_id=None, client_secret=None):
        client_id = client_id or os.environ.get("WCL_CLIENT_ID")
        client_secret = client_secret or os.environ.get("WCL_CLIENT_SECRET")
        if not (client_id and client_secret):
            for name in ("wcl-creds.json", "wcl-credentials.json"):
                f = TOOLS / name
                if f.exists():
                    c = json.loads(read_text(f))
                    client_id, client_secret = c.get("clientId"), c.get("clientSecret")
                    break
        if not (client_id and client_secret):
            raise WclError("No Warcraft Logs credentials. See: python tools/fetch_warcraftlogs.py --help")
        basic = base64.b64encode(f"{client_id}:{client_secret}".encode("ascii")).decode("ascii")
        r = self._post(self.TOKEN, urllib.parse.urlencode({"grant_type": "client_credentials"}).encode(),
                       {"Authorization": "Basic " + basic, "Content-Type": "application/x-www-form-urlencoded"})
        self.token = r["access_token"]

    @staticmethod
    def _post(url, data: bytes, headers: dict):
        headers = {"User-Agent": "BRAT-tools", "Accept": "application/json", **headers}
        req = urllib.request.Request(url, data=data, headers=headers, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            raise WclError(f"HTTP {e.code} from {url}: {e.read()[:300].decode('utf-8', 'replace')}") from None

    def query(self, query: str, variables: dict | None = None):
        body = json.dumps({"query": query, "variables": variables or {}}, separators=(",", ":")).encode()
        r = self._post(self.API, body, {"Authorization": "Bearer " + self.token, "Content-Type": "application/json"})
        if r.get("errors"):
            raise WclError("Warcraft Logs error: " + json.dumps(r["errors"], separators=(",", ":")))
        return r["data"]

    def rate_limit(self):
        return self.query("query { rateLimitData { limitPerHour pointsSpentThisHour pointsResetIn } }")["rateLimitData"]


# --- Parse cache (tools/cache/<Class>-<Spec>/<kind>-<encounterID>.json) -------
# { id, name, kind, startRank, tried: [key...], seqs: [[[spellID, timestamp, targets], ...], ...], dmg: [abilityID...] }
def load_cache(path: Path):
    if not path.exists():
        return None
    with open(path, encoding="utf-8") as fh:
        ec = json.load(fh)
    ec["tried"] = set(ec.get("tried", []))
    ec["dmg"] = set(ec.get("dmg", []))
    return ec


def save_cache(path: Path, ec) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    out = dict(ec, tried=sorted(ec["tried"]), dmg=sorted(ec["dmg"]))
    tmp = path.with_suffix(".tmp")
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(out, fh, separators=(",", ":"), ensure_ascii=False)
    os.replace(tmp, path)  # never leave a half-written cache file


def load_names() -> dict[int, str]:
    if not NAMES_FILE.exists():
        return {}
    with open(NAMES_FILE, encoding="utf-8") as fh:
        return {int(k): v for k, v in json.load(fh).items()}


def save_names(names: dict[int, str]) -> None:
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    with open(NAMES_FILE, "w", encoding="utf-8") as fh:
        json.dump({str(k): names[k] for k in sorted(names)}, fh, ensure_ascii=False, indent=0)


def write_lines(path, lines) -> None:
    """UTF-8 without BOM, CRLF line endings (what the PowerShell tools wrote)."""
    with open(path, "w", encoding="utf-8", newline="\r\n") as fh:
        for line in lines:
            fh.write(line + "\n")


def fmt(x, places=1, grouping=False) -> str:
    """Format like .NET ("{0:N1}" / "{0:0.0}"): halves round away from zero (87.25 -> 87.3)."""
    from decimal import ROUND_HALF_UP, Decimal
    d = Decimal(repr(float(x))).quantize(Decimal(1).scaleb(-places), rounding=ROUND_HALF_UP)
    return f"{d:,}" if grouping else f"{d}"


def num(s, default=0):
    """PowerShell-style number cast: '' / None / missing -> 0; '12' -> 12; '1.5' -> 1.5."""
    if s is None or s == "":
        return default
    try:
        return int(s)
    except ValueError:
        try:
            return float(s)
        except ValueError:
            return default
