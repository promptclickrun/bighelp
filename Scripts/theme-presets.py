#!/usr/bin/env python3
"""Write the Themes presets' colors (Settings › Appearance) as sRGB hex.

The palettes are ported from T3 Code's packages/shared/src/themePalettes.ts
(github.com/pingdotgg/t3code, MIT License, Copyright 2026 T3 Tools Inc.; see
Bighelp/Resources/ThirdParty-NOTICES.txt). Only the roles bighelp uses are kept,
under names of our own. oklch converts through OKLab to sRGB, and channels
outside sRGB are clipped, so the output is the same on every run.

  Scripts/theme-presets.py           write Bighelp/DesignSystem/BighelpThemePresetPalettes.swift
  Scripts/theme-presets.py --check   fail if that file is out of date
  Scripts/theme-presets.py --report  print each palette's contrast

Python 3 stdlib only.
"""

import math
import pathlib
import re
import sys

OUTPUT = pathlib.Path(__file__).resolve().parent.parent / "Bighelp/DesignSystem/BighelpThemePresetPalettes.swift"

# (preset, mode): role → CSS color, as in T3 Code's palettes.
SOURCE = {
    ("steel", "light"): {
        "canvas": "#fcfcfc",
        "surface": "#ffffff",
        "surfaceRaised": "#fcfcfc",
        "text": "#27272a",
        "textMuted": "#71717b",
        "border": "#e4e4e7",
        "accent": "#1b4ed8",
        "messageSurface": "#f4f4f5",
    },
    ("steel", "dark"): {
        "canvas": "#0a0a0a",
        "surface": "#111111",
        "surfaceRaised": "#111111",
        "text": "#f5f5f5",
        "textMuted": "#818181",
        "border": "#191919",
        "accent": "#346bf1",
        "messageSurface": "#141414",
    },
    ("berry", "light"): {
        "canvas": "oklch(0.982446 0.010114 325.653)",
        "surface": "oklch(0.971835 0.012884 321.894)",
        "surfaceRaised": "oklch(0.988235 0.005049 325.615)",
        "text": "oklch(0.325698 0.116116 325.037)",
        "textMuted": "oklch(0.494754 0.190937 354.544)",
        "border": "oklch(0.923531 0.021247 328.096)",
        "accent": "oklch(0.591646 0.217985 0.584)",
        "messageSurface": "oklch(0.926746 0.037898 332.6)",
    },
    ("berry", "dark"): {
        "canvas": "oklch(0.22813 0.020366 307.469)",
        "surface": "oklch(0.267101 0.02016 311.799)",
        "surfaceRaised": "oklch(0.279864 0.021572 309.532)",
        "text": "oklch(0.980735 0.004092 301.426)",
        "textMuted": "oklch(0.880303 0.03077 342.696)",
        "border": "oklch(0.266943 0.015262 302.425)",
        "accent": "oklch(0.460685 0.185347 4.099)",
        "messageSurface": "oklch(0.273791 0.025541 309.079)",
    },
    ("moss", "light"): {
        "canvas": "oklch(0.972369 0.005497 157.15)",
        "surface": "oklch(0.972369 0.005497 157.15)",
        "surfaceRaised": "oklch(0.949276 0.004496 159.002)",
        "text": "oklch(0.222003 0.03479 328.979)",
        "textMuted": "oklch(0.540472 0.014944 326.176)",
        "border": "oklch(0.864831 0.01312 167.255)",
        "accent": "oklch(0.523295 0.112292 158.089)",
        "messageSurface": "oklch(0.891377 0.026164 164.929)",
    },
    ("moss", "dark"): {
        "canvas": "oklch(0.260865 0.02152 162.75)",
        "surface": "oklch(0.260865 0.02152 162.75)",
        "surfaceRaised": "oklch(0.363192 0.016572 165.32)",
        "text": "oklch(0.990339 0.008411 325.64)",
        "textMuted": "oklch(0.666747 0.004239 187.292)",
        "border": "oklch(0.457475 0.044046 160.971)",
        "accent": "oklch(0.796228 0.133058 157.319)",
        "messageSurface": "oklch(0.470111 0.067221 158.676)",
    },
    ("harbor", "light"): {
        "canvas": "oklch(0.974199 0.002856 241.597)",
        "surface": "oklch(0.974199 0.002856 241.597)",
        "surfaceRaised": "oklch(0.951058 0.002962 258.339)",
        "text": "oklch(0.222003 0.03479 328.979)",
        "textMuted": "oklch(0.541555 0.017468 323.531)",
        "border": "oklch(0.867646 0.013482 252.362)",
        "accent": "oklch(0.536684 0.120219 247.01)",
        "messageSurface": "oklch(0.895373 0.023469 241.913)",
    },
    ("harbor", "dark"): {
        "canvas": "oklch(0.242641 0.024125 250.573)",
        "surface": "oklch(0.242641 0.024125 250.573)",
        "surfaceRaised": "oklch(0.348439 0.019942 253.696)",
        "text": "oklch(0.990339 0.008411 325.64)",
        "textMuted": "oklch(0.652227 0.01149 273.31)",
        "border": "oklch(0.438653 0.039496 245.44)",
        "accent": "oklch(0.758933 0.105833 241.548)",
        "messageSurface": "oklch(0.445224 0.056936 243.413)",
    },
    ("clay", "light"): {
        "canvas": "oklch(0.976527 0.002685 60.725)",
        "surface": "oklch(0.976527 0.002685 60.725)",
        "surfaceRaised": "oklch(0.953321 0.002701 42.266)",
        "text": "oklch(0.222003 0.03479 328.979)",
        "textMuted": "oklch(0.543023 0.017316 331.964)",
        "border": "oklch(0.870631 0.013204 39.431)",
        "accent": "oklch(0.552831 0.129438 44.656)",
        "messageSurface": "oklch(0.899296 0.022939 49.163)",
    },
    ("clay", "dark"): {
        "canvas": "oklch(0.245899 0.019144 42.044)",
        "surface": "oklch(0.245899 0.019144 42.044)",
        "surfaceRaised": "oklch(0.351262 0.01565 37.592)",
        "text": "oklch(0.990339 0.008411 325.64)",
        "textMuted": "oklch(0.654017 0.009505 13.287)",
        "border": "oklch(0.44099 0.040202 48.807)",
        "accent": "oklch(0.762174 0.124117 52.082)",
        "messageSurface": "oklch(0.447961 0.061874 50.849)",
    },
    ("violet", "light"): {
        "canvas": "oklch(0.976531 0.003855 303.226)",
        "surface": "oklch(0.976531 0.003855 303.226)",
        "surfaceRaised": "oklch(0.953326 0.004536 307.676)",
        "text": "oklch(0.222003 0.03479 328.979)",
        "textMuted": "oklch(0.543042 0.018894 325.652)",
        "border": "oklch(0.869608 0.018226 303.859)",
        "accent": "oklch(0.525348 0.15373 294.176)",
        "messageSurface": "oklch(0.897143 0.028558 299.758)",
    },
    ("violet", "dark"): {
        "canvas": "oklch(0.225975 0.031062 293.741)",
        "surface": "oklch(0.225975 0.031062 293.741)",
        "surfaceRaised": "oklch(0.335291 0.026008 296.394)",
        "text": "oklch(0.990339 0.008411 325.64)",
        "textMuted": "oklch(0.640465 0.016197 304.171)",
        "border": "oklch(0.40874 0.058536 295.893)",
        "accent": "oklch(0.671712 0.169136 293.929)",
        "messageSurface": "oklch(0.399975 0.086965 294.177)",
    },
}

ROLES = ["canvas", "surface", "surfaceRaised", "text", "textMuted", "border", "accent", "messageSurface"]


def oklch_to_srgb(lightness, chroma, hue):
    a = chroma * math.cos(math.radians(hue))
    b = chroma * math.sin(math.radians(hue))
    l_ = (lightness + 0.3963377774 * a + 0.2158037573 * b) ** 3
    m_ = (lightness - 0.1055613458 * a - 0.0638541728 * b) ** 3
    s_ = (lightness - 0.0894841775 * a - 1.2914855480 * b) ** 3
    linear = [
        4.0767416621 * l_ - 3.3077115913 * m_ + 0.2309699292 * s_,
        -1.2684380046 * l_ + 2.6097574011 * m_ - 0.3413193965 * s_,
        -0.0041960863 * l_ - 0.7034186147 * m_ + 1.7076147010 * s_,
    ]

    def encode(channel):
        channel = min(max(channel, 0.0), 1.0)
        return 12.92 * channel if channel <= 0.0031308 else 1.055 * channel ** (1 / 2.4) - 0.055

    return [encode(channel) for channel in linear]


def to_hex(css):
    css = css.strip()
    if css.startswith("#"):
        return css[1:].upper()
    match = re.fullmatch(r"oklch\(([\d.]+) ([\d.]+) ([\d.]+)\)", css)
    if not match:
        raise ValueError(f"unsupported color {css}")
    channels = oklch_to_srgb(*(float(part) for part in match.groups()))
    return "".join(f"{round(channel * 255):02X}" for channel in channels)


def luminance(hex_value):
    def linear(channel):
        channel /= 255
        return channel / 12.92 if channel <= 0.04045 else ((channel + 0.055) / 1.055) ** 2.4

    red, green, blue = (int(hex_value[index:index + 2], 16) for index in (0, 2, 4))
    return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)


def contrast(first, second):
    high, low = sorted([luminance(first), luminance(second)], reverse=True)
    return (high + 0.05) / (low + 0.05)


def palettes():
    return {key: {role: to_hex(colors[role]) for role in ROLES} for key, colors in SOURCE.items()}


def swift_source():
    lines = [
        "// Generated by Scripts/theme-presets.py. Don't edit; run the script.",
        "// Palettes ported from T3 Code (github.com/pingdotgg/t3code), MIT License,",
        "// Copyright 2026 T3 Tools Inc. See Bighelp/Resources/ThirdParty-NOTICES.txt.",
        "",
        "extension BighelpPresetPalette {",
    ]
    for (preset, mode), colors in palettes().items():
        arguments = ", ".join(f'{role}: "{colors[role]}"' for role in ROLES)
        lines.append(f"    static let {preset}{mode.capitalize()} = BighelpPresetPalette({arguments})")
    lines.append("}")
    return "\n".join(lines) + "\n"


def main(arguments):
    if "--report" in arguments:
        for (preset, mode), colors in palettes().items():
            print(f"{preset:7} {mode:5} text/canvas {contrast(colors['text'], colors['canvas']):5.2f}"
                  f"  muted/canvas {contrast(colors['textMuted'], colors['canvas']):5.2f}"
                  f"  text/message {contrast(colors['text'], colors['messageSurface']):5.2f}"
                  f"  accent/canvas {contrast(colors['accent'], colors['canvas']):5.2f}")
        return 0
    source = swift_source()
    if "--check" in arguments:
        if not OUTPUT.exists() or OUTPUT.read_text() != source:
            print(f"{OUTPUT} is out of date; run Scripts/theme-presets.py", file=sys.stderr)
            return 1
        return 0
    OUTPUT.write_text(source)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
