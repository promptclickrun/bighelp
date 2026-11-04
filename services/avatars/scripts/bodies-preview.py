#!/usr/bin/env python3
"""Draws Bot Studio bodies (sources/bodies/<set>.json) the way the app draws them, as a contact sheet.

Usage:
  python3 scripts/bodies-preview.py sources/bodies/shapes.json [more.json ...] --out sheet.svg [--png sheet.png] [--dark]

Each tile shows a body as saved (its colors, default tilt and classic eyes), then the same body
with wide eyes, a new color and some lean, so a body that only works one way shows it. The math
matches the app's renderer (`BotLookRenderer`): parts in order, then the eyes on top.
"""
import argparse
import json
import math
import pathlib
import shutil
import subprocess
import sys

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
TILE = 132


def tone_fill(tone, main, accent, ink):
    return {"main": main, "accent": accent, "shade": "rgba(0,0,0,0.16)",
            "light": "rgba(255,255,255,0.6)", "ink": ink}[tone]


def capsule(x, y, h, tilt, ink):
    w = h * 0.42
    r = w / 2
    d = f"M{x - r:.2f} {y - h / 2 + r:.2f}a{r:.2f} {r:.2f} 0 0 1 {w:.2f} 0v{h - w:.2f}a{r:.2f} {r:.2f} 0 0 1 {-w:.2f} 0Z"
    return f'<path d="{d}" fill="{ink}" transform="rotate({tilt} {x} {y})"/>'


def oval(x, y, rx, ry, fill):
    return f'<ellipse cx="{x:.2f}" cy="{y:.2f}" rx="{rx:.2f}" ry="{ry:.2f}" fill="{fill}"/>'


def eyes(body, style, ink):
    out = []
    tilt = body.get("eyeTilt", -24)
    for x, y, h in body["eyes"]:
        if style == "wide":
            out.append(oval(x, y, h * 0.3, h * 0.4, ink))
            out.append(oval(x + h * 0.1, y - h * 0.15, h * 0.1, h * 0.1, "#FFFFFF"))
        else:
            out.append(capsule(x, y, h, tilt, ink))
    return "".join(out)


def body_svg(body, main, accent, ink, eye_style="classic", lean=0.0, extra_rot=0.0):
    rot = body.get("rotation", 0) + extra_rot
    parts = []
    for part in body["parts"]:
        color = tone_fill(part.get("tone", "main"), main, accent, ink)
        if "stroke" in part:
            parts.append(f'<path d="{part["d"]}" fill="none" stroke="{color}" stroke-width="{part["stroke"]}" '
                         'stroke-linecap="round" stroke-linejoin="round"/>')
        else:
            rnd = part.get("round", 0)
            stroke = f' stroke="{color}" stroke-width="{rnd}" stroke-linejoin="round"' if rnd else ""
            parts.append(f'<path d="{part["d"]}" fill="{color}"{stroke}/>')
    xf = f"translate(50 50) rotate({rot}) skewX({-lean}) translate(-50 -50)"
    return f'<g transform="{xf}">{"".join(parts)}{eyes(body, eye_style, ink)}</g>'


def sheet(bodies, dark):
    bg, tile_bg, text = ("#000000", "#1C1C1E", "#E5E5EA") if dark else ("#FFFFFF", "#F5F5F7", "#3A3A40")
    columns = 6
    rows = math.ceil(len(bodies) / columns) * 2
    width, height = columns * (TILE + 12) + 12, rows * (TILE + 30) + 12
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
           f'viewBox="0 0 {width} {height}"><rect width="100%" height="100%" fill="{bg}"/>']
    for index, body in enumerate(bodies):
        colors = body.get("colors", {})
        main, accent = colors.get("main", "#E8459A"), colors.get("accent", "#5B4636")
        col, row = index % columns, (index // columns) * 2
        for variant in range(2):
            x, y = 12 + col * (TILE + 12), 12 + (row + variant) * (TILE + 30)
            inner = (body_svg(body, main, accent, "#1C1A19") if variant == 0
                     else body_svg(body, "#3B82F6", accent, "#1C1A19", eye_style="wide", lean=10, extra_rot=8))
            label = body["name"] if variant == 0 else f'{body["name"]} · wide, blue, lean'
            out.append(f'<rect x="{x}" y="{y}" width="{TILE}" height="{TILE}" rx="22" fill="{tile_bg}"/>'
                       f'<svg x="{x + 10}" y="{y + 10}" width="{TILE - 20}" height="{TILE - 20}" viewBox="0 0 100 100">'
                       f'{inner}</svg>'
                       f'<text x="{x + TILE / 2}" y="{y + TILE + 18}" font-family="-apple-system, Helvetica" '
                       f'font-size="12" fill="{text}" text-anchor="middle">{label}</text>')
    out.append("</svg>")
    return "".join(out), width, height


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("files", nargs="+")
    parser.add_argument("--out", required=True)
    parser.add_argument("--png")
    parser.add_argument("--dark", action="store_true")
    args = parser.parse_args()
    bodies = []
    for name in args.files:
        bodies += json.loads(pathlib.Path(name).read_text())["bodies"]
    svg, width, height = sheet(bodies, args.dark)
    pathlib.Path(args.out).write_text(svg)
    if args.png:
        if not pathlib.Path(CHROME).exists():
            sys.exit("Chrome is needed for --png")
        out = pathlib.Path(args.png).resolve()
        subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars",
                        f"--screenshot={out}", f"--window-size={width},{height}",
                        pathlib.Path(args.out).resolve().as_uri()], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print(f"{len(bodies)} bodies -> {args.out}" + (f", {args.png}" if args.png else ""))


if __name__ == "__main__":
    main()
