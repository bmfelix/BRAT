"""BRAT Data Manager (author tool): refresh the Warcraft Logs data that ships inside the
addon, spec by spec. Players never need this.

Start it by double-clicking "BRAT Data Manager.cmd" in this folder.
  Pull new data      download top-player parses into this PC's cache
                     (tools/cache/<Class>-<Spec>/; resumes, waits through the API limit)
  Export to addon    write the cache into Data/WCLRaw.lua (the raw cache BRAT ships)
  Pull & export      both (starts the spec's cache over)
  Clear PC cache     delete the downloaded parses (the shipped data stays)
Then publish the addon update. In game, players rebuild averages and the rotation from
the new data (BRAT settings > Spec data; BRAT tells them). Other specs are never touched.

  python tools/data_manager.py          # window
  python tools/data_manager.py --list   # print status
"""
from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

import brat

FETCHER = brat.TOOLS / "fetch_warcraftlogs.py"
LOCK = brat.CACHE_DIR / ".fetch.lock"


def cache_info(s):
    """This PC's download cache for a spec (parse files per boss / dungeon)."""
    d = brat.spec_dir(s)
    files = list(d.glob("*.json")) if d.exists() else []
    return round(sum(f.stat().st_size for f in files) / 2**20, 1), len(files)


def status():
    shipped = brat.wcl_info()
    rows = []
    for s in brat.SPECS:
        mb, n = cache_info(s)
        w = shipped.get(s["id"])
        rows.append({"spec": s, "name": f"{s['spec']} {s['cls']}", "cache": f"{mb} MB, {n} files",
                     "shipped": f"{w['date']}, {w['players']} parses (ranks {w['ranks']})" if w else "none"})
    return rows


def remove_spec_cache(s):
    d = brat.spec_dir(s)
    if d.exists():
        shutil.rmtree(d)


def pid_alive(pid: int) -> bool:
    if sys.platform != "win32":
        try:
            import os
            os.kill(pid, 0)
            return True
        except OSError:
            return False
    import ctypes
    k = ctypes.windll.kernel32
    h = k.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
    if not h:
        return False
    code = ctypes.c_ulong()
    ok = k.GetExitCodeProcess(h, ctypes.byref(code))
    k.CloseHandle(h)
    return bool(ok) and code.value == 259  # STILL_ACTIVE


def fetch_running() -> bool:
    try:
        return pid_alive(int(LOCK.read_text().strip()))
    except (OSError, ValueError):
        return False


def console_python() -> str:
    """python.exe (with a console) even when this window runs under pythonw.exe."""
    exe = Path(sys.executable)
    con = exe.with_name("python.exe")
    return str(con if con.exists() else exe)


def start_fetch(specs, stage):
    """Run the fetcher for these specs in its own console window (pull can take a while)."""
    cmd = [console_python(), str(FETCHER), "--spec", *[s["spec"] for s in specs], "--stage", stage, "--pause"]
    if stage != "export":
        cmd.append("--wait-for-reset")
    flags = subprocess.CREATE_NEW_CONSOLE if sys.platform == "win32" else 0
    subprocess.Popen(cmd, cwd=str(brat.ROOT), creationflags=flags)


def window():
    import tkinter as tk
    from tkinter import messagebox, ttk

    root = tk.Tk()
    root.title("BRAT Data Manager (author: Warcraft Logs data shipped with the addon)")
    root.geometry("760x400")
    root.option_add("*Font", ("Segoe UI", 10))
    style = ttk.Style(root)
    style.configure("Treeview", rowheight=26, font=("Segoe UI", 10))
    style.configure("Treeview.Heading", font=("Segoe UI", 10))

    ttk.Label(root, text="Tick specs (click a row), then pick an action. Each spec is handled on its own; others are never touched."
              ).pack(anchor="w", padx=12, pady=(10, 4))

    tree = ttk.Treeview(root, columns=("cache", "shipped"), height=6, selectmode="none")
    tree.heading("#0", text="Spec", anchor="w")
    tree.heading("cache", text="Cache on this PC", anchor="w")
    tree.heading("shipped", text="Shipped in the addon (Data/WCLRaw.lua)", anchor="w")
    tree.column("#0", width=190)
    tree.column("cache", width=170)
    tree.column("shipped", width=370)
    tree.pack(fill="x", padx=12)

    checked: set[int] = set()
    specs_by_iid = {}

    def fill():
        tree.delete(*tree.get_children())
        for r in status():
            sid = r["spec"]["id"]
            box = "☑" if sid in checked else "☐"
            iid = tree.insert("", "end", text=f"{box}  {r['name']}", values=(r["cache"], r["shipped"]))
            specs_by_iid[iid] = r["spec"]

    def toggle(event):
        iid = tree.identify_row(event.y)
        if not iid:
            return
        sid = specs_by_iid[iid]["id"]
        checked.symmetric_difference_update({sid})
        fill()

    tree.bind("<Button-1>", toggle)

    def selected():
        return [s for s in brat.SPECS if s["id"] in checked]

    buttons = ttk.Frame(root)
    buttons.pack(fill="x", padx=12, pady=10)

    def action(text, row, col, question, fn):
        def run():
            specs = selected()
            if not specs:
                messagebox.showinfo("BRAT", "Tick at least one spec.")
                return
            if fetch_running():
                messagebox.showinfo("BRAT", "A pull or export is already running. Wait for it to finish.")
                return
            names = ", ".join(f"{s['spec']} {s['cls']}" for s in specs)
            if not messagebox.askokcancel("BRAT", f"{question}\n\nSpecs: {names}"):
                return
            fn(specs)
            fill()
        ttk.Button(buttons, text=text, command=run).grid(row=row, column=col, sticky="ew", padx=4, pady=4, ipady=4)

    buttons.columnconfigure(0, weight=1)
    buttons.columnconfigure(1, weight=1)
    action("Pull new data (download to this PC)", 0, 0,
           "Download ranks 101-115 for every boss and dungeon into this PC's cache? About 10 minutes per spec "
           "(waits through the hourly API limit). Then Export to addon.",
           lambda specs: start_fetch(specs, "pull"))
    action("Export to addon (write Data/WCLRaw.lua)", 0, 1,
           "Write the cached parses into Data/WCLRaw.lua (the raw cache the addon ships)? No download.",
           lambda specs: start_fetch(specs, "export"))
    action("Pull & export", 1, 0,
           "Download fresh parses and write Data/WCLRaw.lua? (This spec's PC cache starts over.)",
           lambda specs: ([remove_spec_cache(s) for s in specs], start_fetch(specs, "all")))
    action("Clear PC cache", 1, 1,
           "Delete this PC's downloaded parses? The data shipped in the addon stays.",
           lambda specs: [remove_spec_cache(s) for s in specs])

    bottom = ttk.Frame(root)
    bottom.pack(fill="x", padx=12)
    ttk.Button(bottom, text="Refresh", command=fill).pack(side="left", padx=4)
    ttk.Label(bottom, foreground="#666", wraplength=600,
              text="After exporting, publish the addon update. Players then rebuild averages and the rotation "
                   "in game (BRAT tells them).").pack(side="left", padx=10)

    fill()
    root.mainloop()


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--list", action="store_true", help="print status instead of opening the window")
    a = p.parse_args()
    if a.list:
        rows = status()
        w1 = max(len(r["name"]) for r in rows)
        w2 = max(len(r["cache"]) for r in rows)
        print(f"{'Name':<{w1}} {'Cache':<{w2}} Shipped")
        print(f"{'----':<{w1}} {'-----':<{w2}} -------")
        for r in rows:
            print(f"{r['name']:<{w1}} {r['cache']:<{w2}} {r['shipped']}")
        return
    window()


if __name__ == "__main__":
    main()
