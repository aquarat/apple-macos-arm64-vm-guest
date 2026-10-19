#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Draw the benchmark charts in docs/benchmarks/ from docs/benchmarks/data/.

Python 3 standard library only (no matplotlib). Each chart is a static SVG
on a light card, so it reads the same in GitHub's light and dark themes.

    scripts/plot-benchmarks.py            # rewrite docs/benchmarks/*.svg
    scripts/plot-benchmarks.py --check    # validate the CSVs, write nothing
    scripts/plot-benchmarks.py --out DIR  # write the SVGs somewhere else

Data layout (docs/benchmarks/data/, one row per measured run):

- series.csv       series id -> chart label, colour role, description
- metrics.csv      metric id -> panel title, unit, axis label
- unit-test.csv, ui-tests.csv, drain.csv, balloon.csv, copy-path.csv
                   runs: date,series,run,reims,qemu,metric,value,unit,source
                   oop-vs-inprocess.svg takes the unit-test and UI rows of
                   series named inproc-* and oop-*; ui-tests.svg leaves out
                   series named *-ab (that chart's UI A/B)
- ranges.csv       results reported only as a range (or a note):
                   date,series,metric,low,high,unit,note,source
- reliability.csv  date,label,reims,qemu,clean,total,failures,role,criterion,source
- boot.csv         date,panel,label,failures,boots,role,source

Rows of a runs chart follow the order of series.csv (keep it chronological);
reliability and boot rows follow their own files. A new series needs a line
in series.csv; a new metric needs a line in metrics.csv. copy-path.svg is
drawn only when copy-path.csv has rows.
"""

import argparse
import csv
import math
import os
import statistics
import sys
from xml.sax.saxutils import escape

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BENCH = os.path.join(ROOT, "docs", "benchmarks")
DATA = os.path.join(BENCH, "data")

# Light card colours. The card is opaque, so dark page themes do not matter.
SURFACE = "#fcfcfb"
CARD_EDGE = "#dddcd5"
INK = "#0b0b0b"
INK2 = "#52514e"
MUTED = "#6b6a65"
GRID = "#e8e7e1"
AXIS = "#b9b8ae"
BAND = "#ecebe6"
ROLE = {
    "reference": "#8a8883",  # no GPU / no balloon
    "main": "#2a78d6",       # builds along the way
    "highlight": "#eb6834",  # the deployed build
    "next": "#4a3aa7",       # measured, not deployed yet
}
GOOD = "#0ca30c"
BAD = "#d03b3b"
FONT = "system-ui, -apple-system, 'Segoe UI', Helvetica, Arial, sans-serif"

WIDTH = 780
PAD = 22


# ---------------------------------------------------------------- data ----

def read_csv(name, required=True):
    path = os.path.join(DATA, name)
    if not os.path.exists(path):
        if required:
            sys.exit(f"missing {path}")
        return []
    with open(path, newline="", encoding="utf-8") as f:
        rows = [r for r in csv.DictReader(f) if any((v or "").strip() for v in r.values())]
    for i, r in enumerate(rows, 2):
        r["_where"] = f"{name}:{i}"
    return rows


def num(row, key):
    v = (row.get(key) or "").strip()
    if v == "":
        return None
    try:
        return float(v)
    except ValueError:
        sys.exit(f"{row['_where']}: {key}={v!r} is not a number")


class Data:
    def __init__(self):
        self.series = {r["series"]: r for r in read_csv("series.csv")}
        self.metrics = {r["metric"]: r for r in read_csv("metrics.csv")}
        self.ranges = read_csv("ranges.csv")
        for r in self.ranges:
            self.check_series(r)
            num(r, "low"), num(r, "high")

    def check_series(self, r):
        if r["series"] not in self.series:
            sys.exit(f"{r['_where']}: series {r['series']!r} is not in series.csv")
        role = self.series[r["series"]]["role"]
        if role not in ROLE:
            sys.exit(f"series.csv: {r['series']}: role {role!r} not one of {sorted(ROLE)}")

    def runs(self, name, required=True):
        rows = read_csv(name, required)
        for r in rows:
            self.check_series(r)
            if num(r, "value") is None:
                sys.exit(f"{r['_where']}: no value")
        return rows

    def metric_title(self, metric):
        m = self.metrics.get(metric)
        return (m["title"], m["unit"], m["axis"]) if m else (metric, "", metric)

    def rows_for(self, runs, metric, keep=None):
        """Chart rows for one metric: runs and ranges grouped by series.

        keep, if given, is a predicate on the series id: other series are left out.
        """
        order, by = [], {}

        def get(sid):
            if sid not in by:
                s = self.series[sid]
                by[sid] = dict(label=s["label"], role=s["role"], runs=[],
                               range=None, note="", reims=[])
                order.append(sid)
            return by[sid]

        for r in runs:
            if r["metric"] != metric or (keep and not keep(r["series"])):
                continue
            row = get(r["series"])
            row["runs"].append(num(r, "value"))
            c = (r.get("reims") or "-").strip()
            if c not in ("-", "") and c[:10] not in row["reims"]:
                row["reims"].append(c[:10])
        for r in self.ranges:
            if r["metric"] != metric or (keep and not keep(r["series"])):
                continue
            row = get(r["series"])
            lo, hi = num(r, "low"), num(r, "high")
            if lo is not None and hi is not None:
                row["range"] = (lo, hi)
            row["note"] = r.get("note", "").strip()
        rank = {sid: i for i, sid in enumerate(self.series)}
        return [by[s] for s in sorted(order, key=rank.get)]


# ----------------------------------------------------------------- svg ----

def tw(text, size):
    """Rough text width for a proportional sans."""
    return len(text) * size * 0.56


def fmt(v):
    if v == 0:
        return "0"
    if abs(v) >= 100:
        return f"{v:.0f}" if v == int(v) else f"{v:.1f}"
    if abs(v) >= 10:
        return f"{v:.2f}".rstrip("0").rstrip(".")
    if abs(v) >= 1:
        return f"{v:.2f}".rstrip("0").rstrip(".")
    return f"{v:.3f}".rstrip("0").rstrip(".")


def nice_scale(vmax, ticks=5):
    if vmax <= 0:
        return 1.0, 1.0
    raw = vmax / ticks
    mag = 10 ** math.floor(math.log10(raw))
    for m in (1, 2, 2.5, 5, 10):
        step = m * mag
        if step >= raw:
            break
    return step, math.ceil(vmax / step - 1e-9) * step


class Svg:
    def __init__(self):
        self.parts = []

    def add(self, s):
        self.parts.append(s)

    def text(self, x, y, s, size=12.5, fill=INK, anchor="start", weight=None, italic=False):
        w = f' font-weight="{weight}"' if weight else ""
        it = ' font-style="italic"' if italic else ""
        self.add(f'<text x="{x:.1f}" y="{y:.1f}" font-size="{size}" fill="{fill}" '
                 f'text-anchor="{anchor}"{w}{it}>{escape(s)}</text>')

    def line(self, x1, y1, x2, y2, stroke=GRID, width=1):
        self.add(f'<line x1="{x1:.1f}" y1="{y1:.1f}" x2="{x2:.1f}" y2="{y2:.1f}" '
                 f'stroke="{stroke}" stroke-width="{width}"/>')

    def rect(self, x, y, w, h, fill, rx=0, opacity=None):
        o = f' fill-opacity="{opacity}"' if opacity is not None else ""
        self.add(f'<rect x="{x:.1f}" y="{y:.1f}" width="{max(w, 0):.1f}" height="{h:.1f}" '
                 f'rx="{rx}" fill="{fill}"{o}/>')

    def bar(self, x0, x1, cy, h, fill, opacity=None):
        """Horizontal bar, square at the baseline, 4px rounded data end."""
        w = x1 - x0
        if w <= 0:
            return
        r = min(4, w, h / 2)
        top, bot = cy - h / 2, cy + h / 2
        o = f' fill-opacity="{opacity}"' if opacity is not None else ""
        self.add(f'<path d="M{x0:.1f},{top:.1f} H{x1 - r:.1f} Q{x1:.1f},{top:.1f} {x1:.1f},{top + r:.1f} '
                 f'V{bot - r:.1f} Q{x1:.1f},{bot:.1f} {x1 - r:.1f},{bot:.1f} H{x0:.1f} Z" fill="{fill}"{o}/>')

    def dot(self, x, y, fill, r=4.5):
        self.add(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{r}" fill="{fill}" '
                 f'stroke="{SURFACE}" stroke-width="1.5"/>')

    def render(self, height, title, desc):
        head = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{WIDTH}" height="{height:.0f}" '
                f'viewBox="0 0 {WIDTH} {height:.0f}" role="img" font-family="{FONT}">\n'
                f'<title>{escape(title)}</title>\n<desc>{escape(desc)}</desc>\n'
                f'<rect x="0.5" y="0.5" width="{WIDTH - 1}" height="{height - 1:.0f}" rx="10" '
                f'fill="{SURFACE}" stroke="{CARD_EDGE}"/>\n')
        return head + "\n".join(self.parts) + "\n</svg>\n"


def header(svg, title, subtitle):
    y = PAD + 16
    svg.text(PAD, y, title, size=17, weight="600")
    for line in subtitle:
        y += 19
        svg.text(PAD, y, line, size=12.5, fill=INK2)
    return y + 14


def row_value_text(row, unit):
    u = f" {unit}" if unit else ""
    if row["range"] is not None:
        lo, hi = row["range"]
        if lo == hi:
            return row["note"] or f"{fmt(lo)}{u}"
        return f"{fmt(lo)}–{fmt(hi)}{u}"
    runs = row["runs"]
    if not runs:
        return ""
    extra = f" · {row['note']}" if row["note"] else ""  # e.g. a run that crashed
    if len(runs) == 1:
        return f"{fmt(runs[0])}{u}{extra}"
    lo, hi = min(runs), max(runs)
    span = f"{fmt(lo)}{u}" if lo == hi else f"{fmt(lo)}–{fmt(hi)}{u}"
    return f"{span}, {len(runs)} runs{extra}"


def label_width(rows):
    return max([tw(r["label"], 12.5) for r in rows] + [120]) + 14


def panel(svg, y, rows, title, unit, axis, label_w, value_w, ref=None, row_h=34, xmax=None):
    """One horizontal dot/bar panel. Returns the y below it.

    Rows with runs: a pale bar to the mean, one dot per run.
    Rows with a reported range: a capsule from low to high, plus any runs.
    """
    if title:
        svg.text(PAD, y + 4, title, size=13.5, weight="600")
        y += 16
    if ref:
        y += 14
    x0 = PAD + label_w
    x1 = WIDTH - PAD - value_w
    vals = [v for r in rows for v in r["runs"]]
    vals += [v for r in rows if r["range"] for v in r["range"]]
    if ref:
        vals += list(ref[:2])
    step, top = nice_scale(xmax if xmax is not None else max(vals + [0]))
    sx = lambda v: x0 + (x1 - x0) * v / top
    plot_top, plot_bot = y, y + row_h * len(rows)

    # grid and reference band
    if ref:
        lo, hi, rlabel = ref
        svg.rect(sx(lo), plot_top, max(sx(hi) - sx(lo), 2), plot_bot - plot_top, BAND)
        svg.text((sx(lo) + sx(hi)) / 2, plot_top - 5, rlabel, size=11, fill=MUTED, anchor="middle")
    n = int(round(top / step))
    for i in range(n + 1):
        v = step * i
        svg.line(sx(v), plot_top, sx(v), plot_bot, GRID if i else AXIS)
        svg.text(sx(v), plot_bot + 15, fmt(v), size=11, fill=MUTED, anchor="middle")

    for i, r in enumerate(rows):
        cy = plot_top + row_h * i + row_h / 2
        colour = ROLE[r["role"]]
        sub = ("Reims " + ", ".join(c[:8] for c in r["reims"])) if r["reims"] else ""
        if sub:
            svg.text(x0 - 10, cy - 1, r["label"], size=12.5, anchor="end")
            svg.text(x0 - 10, cy + 12, sub, size=10.5, fill=MUTED, anchor="end")
        else:
            svg.text(x0 - 10, cy + 4.5, r["label"], size=12.5, anchor="end")
        right = x0
        if r["range"] is not None:
            lo, hi = r["range"]
            if hi > lo:  # at least 10px wide so a narrow range stays visible
                a, b = sx(lo), sx(hi)
                if b - a < 10:
                    a, b = (a + b) / 2 - 5, (a + b) / 2 + 5
                svg.rect(a, cy - 5, b - a, 10, colour, rx=5, opacity=0.5)
                right = b
            elif hi > 0:
                svg.dot(sx(hi), cy, colour)
                right = sx(hi) + 4
        elif r["runs"]:
            svg.bar(x0, sx(statistics.mean(r["runs"])), cy, 14, colour, opacity=0.28)
            right = sx(statistics.mean(r["runs"]))
        for v in r["runs"]:
            svg.dot(sx(v), cy, colour)
            right = max(right, sx(v) + 4)
        text = row_value_text(r, unit)
        if text:
            svg.text(right + 8, cy + 4.5, text, size=12, fill=INK2)
        elif r["note"]:
            svg.text(x0 + 8, cy + 4.5, r["note"], size=12, fill=INK2, italic=True)
    y = plot_bot + 31
    svg.text((x0 + x1) / 2, y, axis, size=11.5, fill=INK2, anchor="middle")
    return y + 22


def runs_chart(data, runs, metrics, title, subtitle, desc, ref_series=None, xmax=None, keep=None):
    svg = Svg()
    y = header(svg, title, subtitle)
    panels = []
    for m in metrics:
        rows = data.rows_for(runs, m, keep)
        if rows:
            panels.append((m, rows))
    if not panels:
        return None
    label_w = max(label_width(rows) for _, rows in panels)
    for m, rows in panels:
        mtitle, unit, axis = data.metric_title(m)
        value_w = max(tw(row_value_text(r, unit), 12) for r in rows) + 18
        ref = None
        if ref_series:
            vals = [num(r, "value") for r in runs if r["series"] == ref_series and r["metric"] == m]
            if vals:
                ref = (min(vals), max(vals), "shaded: no-GPU runs")
        y = panel(svg, y + 6, rows, mtitle if len(panels) > 1 else "", unit, axis,
                  label_w, value_w, ref=ref,
                  xmax=xmax.get(m) if isinstance(xmax, dict) else xmax)
    return svg.render(y + 4, title, desc)


def count_chart(rows, title, subtitle, desc, panels):
    """Stacked run counts (reliability) or failure rates (boot)."""
    svg = Svg()
    y = header(svg, title, subtitle)
    label_w = max(tw(r["label"], 12.5) for r in rows) + 14
    for ptitle, prow, kind in panels:
        prows = [r for r in rows if prow(r)]
        if not prows:
            continue
        y += 6
        svg.text(PAD, y + 4, ptitle, size=13.5, weight="600")
        y += 16
        x0 = PAD + label_w
        texts = [kind["text"](r) for r in prows]
        value_w = max(tw(t, 12) for t in texts) + 18
        x1 = WIDTH - PAD - value_w
        step, top = nice_scale(max(kind["value"](r) for r in prows) or 1)
        if kind.get("top"):
            step, top = kind["top"]
        sx = lambda v: x0 + (x1 - x0) * v / top
        row_h = 34
        plot_bot = y + row_h * len(prows)
        n = int(round(top / step))
        for i in range(n + 1):
            v = step * i
            svg.line(sx(v), y, sx(v), plot_bot, GRID if i else AXIS)
            svg.text(sx(v), plot_bot + 15, kind["tick"](v), size=11, fill=MUTED, anchor="middle")
        for i, (r, text) in enumerate(zip(prows, texts)):
            cy = y + row_h * i + row_h / 2
            sub = r.get("_sub", "")
            if sub:
                svg.text(x0 - 10, cy - 1, r["label"], size=12.5, anchor="end")
                svg.text(x0 - 10, cy + 12, sub, size=10.5, fill=MUTED, anchor="end")
            else:
                svg.text(x0 - 10, cy + 4.5, r["label"], size=12.5, anchor="end")
            right = kind["draw"](svg, r, sx, cy)
            svg.text(right + 8, cy + 4.5, text, size=12, fill=INK2)
        y = plot_bot + 31
        svg.text((x0 + x1) / 2, y, kind["axis"], size=11.5, fill=INK2, anchor="middle")
        y += 22
    return svg.render(y + 4, title, desc)


def reliability_chart():
    rows = read_csv("reliability.csv")
    for r in rows:
        c, t = num(r, "clean"), num(r, "total")
        if c is None or t is None or c > t:
            sys.exit(f"{r['_where']}: need clean <= total")
        if r["role"] not in ROLE:
            sys.exit(f"{r['_where']}: role {r['role']!r}")
        r["_sub"] = "Reims " + r["reims"][:8] if r["reims"] not in ("", "-") else ""

    def draw(svg, r, sx, cy):
        c, t = num(r, "clean"), num(r, "total")
        h = 14
        if c == t:
            svg.bar(sx(0), sx(t), cy, h, GOOD)
        else:  # 2px surface gap between the clean and failed segments
            if c > 0:
                svg.rect(sx(0), cy - h / 2, sx(c) - sx(0) - 1, h, GOOD)
            svg.bar(sx(c) + 1, sx(t), cy, h, BAD)
        return sx(t)

    def text(r):
        c, t = int(num(r, "clean")), int(num(r, "total"))
        s = f"{c}/{t} clean"
        if r["failures"].strip():
            s += f" · {r['failures'].strip()}"
        return s

    kind = dict(value=lambda r: num(r, "total"), draw=draw, text=text,
                tick=lambda v: fmt(v), axis="Sustained runs (green: clean, red: failed)")
    return count_chart(
        rows, "GPU stability under sustained iOS simulator load",
        ["Each row counts sustained runs on a macOS 26 guest: a UI test, then repeated test reruns.",
         "Clean = no guest panic and no host GPU hang. The three worker rows overlap: the candidate's",
         "runs are part of the round-robin series, which is part of the stamp-fix series."],
        "Clean runs per build: " + "; ".join(f"{r['label']}: {text(r)}" for r in rows),
        [("Clean runs per build, in the order they were measured", lambda r: True, kind)])


def boot_chart():
    rows = read_csv("boot.csv")
    for r in rows:
        f, b = num(r, "failures"), num(r, "boots")
        if f is None or not b or f > b:
            sys.exit(f"{r['_where']}: need failures <= boots > 0")

    def pct(r):
        return 100.0 * num(r, "failures") / num(r, "boots")

    def draw(svg, r, sx, cy):
        p = pct(r)
        colour = ROLE[r["role"]]
        if p > 0:
            svg.bar(sx(0), sx(p), cy, 14, colour)
            return sx(p)
        svg.dot(sx(0) + 5, cy, colour, r=4)
        return sx(0) + 9

    def text(r):
        return f"{int(num(r, 'failures'))}/{int(num(r, 'boots'))} ({pct(r):.1f} %)"

    kind = dict(value=pct, draw=draw, text=text, tick=lambda v: f"{fmt(v)} %",
                axis="Share of boots (%), lower is better", top=(5, 20))
    return count_chart(
        rows, "macOS 26 boot reliability",
        ["Tahoe guests booted repeatedly with retries off. Both faults were one macOS virtio",
         "driver bug: a used ring placed inside the available ring. QEMU now relocates it."],
        "Boot failure rates: " + "; ".join(f"{r['label']} ({r['panel']}): {text(r)}" for r in rows),
        [("Boots that never reached SSH", lambda r: r["panel"] == "boot_stall", kind),
         ("Boots with no sound device (of those that reached SSH)", lambda r: r["panel"] == "sound_missing", kind)])


# ---------------------------------------------------------------- main ----

def build(data):
    charts = {}
    unit = data.runs("unit-test.csv")
    charts["unit-test.svg"] = runs_chart(
        data, unit, ["unit_test_wall"],
        "iOS simulator unit tests: GPU builds against no GPU",
        ["macOS 26 guest, 4 vCPU / 8 GB. Dots are runs, pale bars their mean, capsules a reported range.",
         "Orange: deployed builds. The two production-host rows (M1 Ultra, pre-warmed image) compare only",
         "with each other; every other row ran on the M1 Max test host. Lower is better."],
        "Simulator unit-test wall time per build: " + "; ".join(
            f"{r['series']} {r['value']} s" for r in unit),
        ref_series="none")
    ui = data.runs("ui-tests.csv")
    # Series ending in "-ab" (the in/out-of-process UI A/B on 0001-only Mesa)
    # are drawn only in oop-vs-inprocess.svg.
    charts["ui-tests.svg"] = runs_chart(
        data, ui, ["app_suite_wall", "ci_ui_job_wall", "probe_cold_wall", "probe_warm_wall"],
        "UI tests on a GPU-accelerated macOS 26 guest",
        ["An iOS app's offline XCUITest suite: lab runs (8 vCPU / 12 GB, 12 of 14 pass in every GPU mode),",
         "then production CI on an M1 Ultra host (8 vCPU / 24 GB; 12/14 passed, then 14/14). Last two panels:",
         "a small SwiftUI XCUITest, 8 vCPU / 16 GB. Dots are runs, pale bars their mean, capsules a reported range.",
         "Orange: Reims out of process, deployed 2026-10-19."],
        "UI test wall times: " + "; ".join(
            f"{r['metric']} {r['series']} {r['value']} s" for r in ui if not r["series"].endswith("-ab")),
        keep=lambda s: not s.endswith("-ab"))
    oop = lambda s: s.startswith(("inproc-", "oop-"))
    oop_rows = [r for r in unit + ui if oop(r["series"])]
    charts["oop-vs-inprocess.svg"] = runs_chart(
        data, oop_rows, ["unit_test_wall", "app_suite_wall", "probe_cold_wall"],
        "Reims in process against out of process",
        ["M1 Max test host. Unit tests: 4 vCPU / 8 GB, Mesa 0001+0002, runs interleaved. UI tests: 8 vCPU / 12 GB;",
         "the \"0001-only Mesa\" rows lacked Mesa patch 0002; that Mesa aborted once in process and took",
         "QEMU with it (\"1 more crashed\"). Pacing: guest surfaces held to 60 Hz, opt-in. Orange: deployed 2026-10-19.",
         "Dots are runs, pale bars their mean. Lower is better."],
        "In process against out of process: " + "; ".join(
            f"{r['metric']} {r['series']} {r['value']} s" for r in oop_rows),
        keep=oop)
    drain = data.runs("drain.csv")
    charts["drain.svg"] = runs_chart(
        data, drain, ["tranche_p90", "tranche_max", "vcpu_wait_total", "drain_busy"],
        "Reims drain behaviour over a UI-test session",
        ["How long the device's command drain runs without a break (a tranche), how long vCPUs",
         "wait for the device lock, and total drain busy time. 8 vCPU / 12 GB. Capsules span the",
         "reported runs of a build, dots are individual runs. The copy path is in the 2026-10-11 release."],
        "Drain per build: " + "; ".join(
            f"{r['metric']} {r['series']} {r['low']}-{r['high']} {r['unit']}"
            for r in data.ranges if r["metric"].startswith(("tranche", "vcpu", "drain")))
        + "; runs: " + "; ".join(f"{r['metric']} {r['series']} {r['value']} {r['unit']}" for r in drain))
    charts["reliability.svg"] = reliability_chart()
    charts["boot.svg"] = boot_chart()
    balloon = data.runs("balloon.csv")
    charts["balloon.svg"] = runs_chart(
        data, balloon, ["footprint_avg"],
        "Memory balloon: host memory a macOS 26 guest holds",
        ["Average host footprint of a 10 GiB guest (4 vCPUs, guest RAM on a shared memfd), sampled",
         "every 2 s. Grey: no balloon. Blue: scripts/balloon-governor.py. Lower is better."],
        "Host footprint: " + "; ".join(f"{r['series']} {r['metric']} {r['value']} GB" for r in balloon))
    copy = data.runs("copy-path.csv", required=False)
    if copy:
        metrics = list(dict.fromkeys(r["metric"] for r in copy))
        charts["copy-path.svg"] = runs_chart(
            data, copy, metrics, "Reims copy path: one copy instead of two",
            ["The 2026-10-10 build against the copy-path builds (in the 2026-10-11 release) on the unit-test benchmark,",
             "4 vCPU / 8 GB, runs interleaved. Cycle counts: one perf capture of the drain thread",
             "per build. Dots are runs, pale bars their mean. Lower is better."],
            "Copy-path measurements: " + "; ".join(
                f"{r['series']} {r['metric']} {r['value']} {r['unit']}" for r in copy))
    return {k: v for k, v in charts.items() if v}


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--check", action="store_true", help="validate the data, write nothing")
    ap.add_argument("--out", default=BENCH, help="output directory (default docs/benchmarks)")
    args = ap.parse_args()
    charts = build(Data())
    if args.check:
        print(f"ok: {len(charts)} charts from {DATA}")
        return
    os.makedirs(args.out, exist_ok=True)
    for name, body in charts.items():
        path = os.path.join(args.out, name)
        with open(path, "w", encoding="utf-8") as f:
            f.write(body)
        print(path)


if __name__ == "__main__":
    main()
