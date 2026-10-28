#!/usr/bin/env python3
"""Compteur de téléchargements de Wispad : relève les téléchargements des releases GitHub, les garde dans un CSV et
dessine le graphique du README, en clair et en sombre. Lancé toutes les heures par .github/workflows/metrics.yml,
sur la branche de données « metrics ».

  scripts/download-stats.py --repo samirmedani/wispad --dir <dossier>

Le dossier garde downloads.csv : un relevé à chaque changement (téléchargements, étoiles, versions), et au moins un
par jour. GitHub ne donne que le total actuel de chaque version : la courbe dans le temps vient de ces relevés.
Jeton facultatif : GITHUB_TOKEN. Bibliothèque standard de Python seulement.
"""
import argparse
import csv
import datetime as dt
import json
import math
import os
import urllib.request
from xml.sax.saxutils import escape

API = "https://api.github.com"
NNBSP = "\u202f"
MONTHS = ["janv.", "févr.", "mars", "avr.", "mai", "juin", "juil.", "août", "sept.", "oct.", "nov.", "déc."]
HEARTBEAT = dt.timedelta(hours=24)
FIELDS = ["releve", "total", "etoiles", "versions"]
MAX_BARS = 20
FONT = "-apple-system, BlinkMacSystemFont, 'Segoe UI', 'Noto Sans', Helvetica, Arial, sans-serif"

THEMES = {
    "light": {"bg": "#ffffff", "panel": "#f6f8fa", "border": "#d1d9e0", "text": "#1f2328", "muted": "#59636e",
              "grid": "#d1d9e0", "brand": "#ff3b36"},
    "dark": {"bg": "#0d1117", "panel": "#151b23", "border": "#3d444d", "text": "#f0f6fc", "muted": "#9198a1",
             "grid": "#3d444d", "brand": "#ff4d48"},
}

try:
    from zoneinfo import ZoneInfo
    PARIS = ZoneInfo("Europe/Paris")
except Exception:  # Pas de base des fuseaux : l'heure reste en UTC.
    PARIS = dt.timezone.utc


def parse(text):
    return dt.datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)


def iso(moment):
    return moment.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def get(url, token):
    request = urllib.request.Request(url, headers={
        "Accept": "application/vnd.github+json", "User-Agent": "wispad-metrics", "X-GitHub-Api-Version": "2022-11-28"})
    if token:
        request.add_header("Authorization", "Bearer " + token)
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def fetch(repo, token):
    """Versions publiées (de la plus ancienne à la plus récente) avec leurs téléchargements, et les étoiles."""
    releases, page = [], 1
    while True:
        batch = get(f"{API}/repos/{repo}/releases?per_page=100&page={page}", token)
        releases += batch
        if len(batch) < 100:
            break
        page += 1
    stars = get(f"{API}/repos/{repo}", token).get("stargazers_count", 0)
    versions = []
    for release in releases:
        if release.get("draft") or not release.get("published_at"):
            continue
        count = sum(asset.get("download_count", 0) for asset in release.get("assets", []))
        versions.append({"tag": release["tag_name"], "published": parse(release["published_at"]), "downloads": count})
    versions.sort(key=lambda version: version["published"])
    return versions, stars


def read_history(path):
    if not os.path.exists(path):
        return []
    rows = []
    with open(path, newline="", encoding="utf-8") as handle:
        for row in csv.DictReader(handle):
            try:
                rows.append({"time": parse(row["releve"]), "total": int(row["total"]), "stars": int(row["etoiles"]),
                             "versions": int(row["versions"])})
            except (KeyError, ValueError):
                continue
    return sorted(rows, key=lambda row: row["time"])


def write_history(path, rows):
    with open(path, "w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle, lineterminator="\n")
        writer.writerow(FIELDS)
        for row in rows:
            writer.writerow([iso(row["time"]), row["total"], row["stars"], row["versions"]])


def record(history, now, total, stars, versions):
    """Ajoute un relevé si un chiffre a changé, ou si le dernier a un jour : rien d'autre ne réécrit les fichiers."""
    if history:
        last = history[-1]
        same = (last["total"], last["stars"], last["versions"]) == (total, stars, versions)
        if same and now - last["time"] < HEARTBEAT:
            return False
    history.append({"time": now, "total": total, "stars": stars, "versions": versions})
    return True


def num(value):
    return f"{value:,}".replace(",", NNBSP)


def local(moment):
    return moment.astimezone(PARIS)


def day_label(moment, year=False):
    moment = local(moment)
    label = f"{moment.day} {MONTHS[moment.month - 1]}"
    return f"{label} {moment.year}" if year else label


def hour_label(moment):
    moment = local(moment)
    return f"{moment.hour} h {moment.minute:02d}" if moment.minute else f"{moment.hour} h"


def ticks(maximum, count=4):
    if maximum <= 0:
        return [0, 1]
    raw = maximum / count
    magnitude = 10 ** math.floor(math.log10(raw))
    step = next(factor * magnitude for factor in (1, 2, 5, 10) if factor * magnitude >= raw)
    step = max(1, int(round(step)))
    top = step * math.ceil(maximum / step)
    return list(range(0, top + 1, step))


def text(x, y, value, size, color, weight=400, anchor="start", halo=None):
    """Texte ; « halo » (couleur du fond) le détache d'une ligne qui passe derrière."""
    outline = f' stroke="{halo}" stroke-width="8" stroke-linejoin="round" paint-order="stroke"' if halo else ""
    return (f'<text x="{x:.1f}" y="{y:.1f}" font-size="{size}" font-weight="{weight}" fill="{color}" '
            f'text-anchor="{anchor}"{outline}>{escape(value)}</text>')


def delta(history, total):
    """Téléchargements des 7 derniers jours ; tant que les relevés ont moins d'une semaine, depuis le premier."""
    if not history:
        return "Depuis le premier relevé", "+0"
    now = history[-1]["time"]
    week = [row for row in history if now - row["time"] >= dt.timedelta(days=7)]
    if week:
        return "7 derniers jours", f"+{num(max(0, total - week[-1]['total']))}"
    first = history[0]
    return f"Depuis le {day_label(first['time'])}", f"+{num(max(0, total - first['total']))}"


def render(theme, versions, history, stars):
    c = THEMES[theme]
    width, height = 960, 640
    total = sum(version["downloads"] for version in versions)
    parts = []
    add = parts.append
    latest = versions[-1] if versions else None
    summary = f"{num(total)} téléchargements de Wispad, {len(versions)} versions, {stars} étoiles."
    add(f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" viewBox="0 0 {width} {height}" '
        f'role="img" aria-labelledby="titre desc" font-family="{FONT}" style="font-variant-numeric: tabular-nums">')
    add(f'<title id="titre">Téléchargements de Wispad</title><desc id="desc">{escape(summary)}</desc>')
    add(f'<defs><linearGradient id="aire" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{c["brand"]}" '
        f'stop-opacity="0.30"/><stop offset="1" stop-color="{c["brand"]}" stop-opacity="0"/></linearGradient></defs>')
    add(f'<rect x="0.5" y="0.5" width="{width - 1}" height="{height - 1}" rx="16" fill="{c["bg"]}" stroke="{c["border"]}"/>')

    # En-tête : total, puis trois chiffres.
    add(text(32, 58, "Téléchargements", 15, c["muted"], 600))
    add(text(30, 114, num(total), 54, c["text"], 700))
    add(text(32, 142, "Wispad.dmg, toutes versions confondues", 13, c["muted"]))
    since_label, since_value = delta(history, total)
    pills = [
        (f"Version {latest['tag']}" if latest else "Dernière version", num(latest["downloads"]) if latest else "0"),
        (since_label, since_value),
        ("Étoiles GitHub", f"★ {num(stars)}"),
    ]
    pill_width, gap, top = 150, 10, 36
    left = width - 32 - len(pills) * pill_width - (len(pills) - 1) * gap
    for index, (label, value) in enumerate(pills):
        x = left + index * (pill_width + gap)
        add(f'<rect x="{x}" y="{top}" width="{pill_width}" height="70" rx="12" fill="{c["panel"]}" stroke="{c["border"]}"/>')
        add(text(x + 16, top + 26, label, 12, c["muted"], 500))
        add(text(x + 16, top + 55, value, 23, c["text"], 700))

    # Au fil du temps : total relevé, courbe et aire.
    chart_left, chart_right, chart_top, chart_bottom = 72, 928, 216, 372
    add(text(32, 196, "Au fil du temps", 15, c["text"], 600))
    points = [(row["time"], row["total"]) for row in history]
    span = (points[-1][0] - points[0][0]).total_seconds() if len(points) >= 2 else 0
    scale = ticks(max([value for _, value in points] + [total]))
    top_value = scale[-1]

    def y_of(value):
        return chart_bottom - value / top_value * (chart_bottom - chart_top)

    for value in scale:
        y = y_of(value)
        dash = "" if value == 0 else ' stroke-dasharray="3 5"'
        add(f'<line x1="{chart_left}" y1="{y:.1f}" x2="{chart_right}" y2="{y:.1f}" stroke="{c["grid"]}"{dash}/>')
        add(text(chart_left - 12, y + 4, num(value), 12, c["muted"], 400, "end"))
    if span > 0:
        start = points[0][0]

        def x_of(moment):
            return chart_left + (moment - start).total_seconds() / span * (chart_right - chart_left)

        coords = [(x_of(moment), y_of(value)) for moment, value in points]
        line = " ".join(f"{'M' if i == 0 else 'L'}{x:.1f},{y:.1f}" for i, (x, y) in enumerate(coords))
        add(f'<path d="{line} L{coords[-1][0]:.1f},{chart_bottom} L{coords[0][0]:.1f},{chart_bottom} Z" fill="url(#aire)"/>')
        add(f'<path d="{line}" fill="none" stroke="{c["brand"]}" stroke-width="2.5" stroke-linejoin="round" stroke-linecap="round"/>')
        last_x, last_y = coords[-1]
        add(f'<circle cx="{last_x:.1f}" cy="{last_y:.1f}" r="5" fill="{c["brand"]}" stroke="{c["bg"]}" stroke-width="2.5"/>')
        add(text(last_x - 10, last_y - 12, num(points[-1][1]), 13, c["text"], 700, "end", c["bg"]))
        labels = 5 if span >= 4 * 86_400 else 4
        for index in range(labels):
            moment = start + dt.timedelta(seconds=span * index / (labels - 1))
            anchor = "start" if index == 0 else "end" if index == labels - 1 else "middle"
            label = day_label(moment) if span >= 2 * 86_400 else f"{day_label(moment)}, {hour_label(moment)}"
            add(text(x_of(moment), chart_bottom + 22, label, 12, c["muted"], 400, anchor))
    else:
        y = y_of(total)
        add(f'<circle cx="{chart_right:.1f}" cy="{y:.1f}" r="5" fill="{c["brand"]}" stroke="{c["bg"]}" stroke-width="2.5"/>')
        add(text(chart_right - 10, y - 12, num(total), 13, c["text"], 700, "end"))
        add(text((chart_left + chart_right) / 2, (chart_top + chart_bottom) / 2,
                 "La courbe se trace au fil des relevés, faits toutes les heures.", 13, c["muted"], 400, "middle", c["bg"]))

    # Par version : les dernières versions, la plus récente en couleur pleine.
    shown = versions[-MAX_BARS:]
    add(text(32, 432, "Par version", 15, c["text"], 600))
    if len(versions) > len(shown):
        add(text(chart_right, 432, f"{len(shown)} dernières versions sur {len(versions)}", 12, c["muted"], 400, "end"))
    bars_top, bars_bottom = 470, 572
    add(f'<line x1="{chart_left}" y1="{bars_bottom}" x2="{chart_right}" y2="{bars_bottom}" stroke="{c["grid"]}"/>')
    if shown:
        slot = (chart_right - chart_left) / len(shown)
        bar = min(30.0, slot * 0.6)
        highest = max(version["downloads"] for version in shown) or 1
        for index, version in enumerate(shown):
            center = chart_left + slot * (index + 0.5)
            value = version["downloads"]
            is_latest = index == len(shown) - 1
            if value > 0:
                h = max(4.0, value / highest * (bars_bottom - bars_top))
                opacity = "1" if is_latest else "0.5"
                add(f'<rect x="{center - bar / 2:.1f}" y="{bars_bottom - h:.1f}" width="{bar:.1f}" height="{h:.1f}" '
                    f'rx="{min(4.0, bar / 4):.1f}" fill="{c["brand"]}" fill-opacity="{opacity}"/>')
                add(text(center, bars_bottom - h - 7, num(value), 12, c["text"], 600, "middle"))
            else:
                add(f'<rect x="{center - bar / 2:.1f}" y="{bars_bottom - 2:.1f}" width="{bar:.1f}" height="2" fill="{c["muted"]}" fill-opacity="0.5"/>')
                add(text(center, bars_bottom - 9, "0", 12, c["muted"], 500, "middle"))
            tag = version["tag"][1:] if version["tag"].startswith("v") else version["tag"]
            add(text(center, bars_bottom + 20, tag, 11.5, c["text"] if is_latest else c["muted"], 600 if is_latest else 400, "middle"))

    when = history[-1]["time"] if history else None
    footer = "Relevé toutes les heures depuis l'API GitHub"
    if when:
        footer += f" · données du {day_label(when, year=True)} à {hour_label(when)} (heure de Paris)"
    add(text(32, 620, footer, 12, c["muted"]))
    add("</svg>")
    return "\n".join(parts) + "\n"


BRANCH_README = """# Métriques de Wispad

Branche de données, mise à jour toutes les heures par le workflow « Métriques » (`.github/workflows/metrics.yml`
sur `main`). Ne pas la modifier à la main.

- `downloads.csv` : un relevé à chaque changement (téléchargements, étoiles, versions), et au moins un par jour.
- `downloads-light.svg`, `downloads-dark.svg` : le graphique affiché dans le README, en clair et en sombre.
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", required=True)
    parser.add_argument("--dir", required=True)
    parser.add_argument("--now", help="horodatage du relevé (ISO, UTC), pour les essais")
    args = parser.parse_args()
    os.makedirs(args.dir, exist_ok=True)
    now = parse(args.now) if args.now else dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
    versions, stars = fetch(args.repo, os.environ.get("GITHUB_TOKEN"))
    total = sum(version["downloads"] for version in versions)
    history_path = os.path.join(args.dir, "downloads.csv")
    history = read_history(history_path)
    added = record(history, now, total, stars, len(versions))
    write_history(history_path, history)
    for theme in THEMES:
        with open(os.path.join(args.dir, f"downloads-{theme}.svg"), "w", encoding="utf-8") as handle:
            handle.write(render(theme, versions, history, stars))
    with open(os.path.join(args.dir, "README.md"), "w", encoding="utf-8") as handle:
        handle.write(BRANCH_README)
    print(f"{num(total)} téléchargements, {len(versions)} versions, {stars} étoiles ; "
          f"{'nouveau relevé' if added else 'aucun changement'} ({len(history)} relevés).")


if __name__ == "__main__":
    main()
