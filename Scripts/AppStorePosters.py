"""The App Store posters, in bighelp.app's style with the app's Ink look.

  python3 -I Scripts/AppStorePosters.py --captures <folder> --inter <Inter variable font> \\
      --nunito <Nunito variable font> --output <folder>

Each poster is an HTML page that headless Chrome renders at the display's exact size: Paper white
or Black (the app's Ink pages), the wordmark (the Ember Noodle and "ighelp" in Nunito 900), a
numbered pill, a headline in Inter 800 tracked -0.035em with its last period in Ember, a line under
it, and the screen in a plain device frame. The fonts are the site's (bighelp-site/src/fonts, woff2)
or any variable Inter and Nunito.

--captures holds the raw screens from Scripts/AppStoreScreenshots.sh: iphone-<shot>.png
(1320×2868, iPhone 6.9") and ipad-<shot>.png (2064×2752, iPad 13"). The 6.5" posters use the iPhone
shots. Writes <output>/<display type>/NN-name.png and <output>/contact-sheet.png.
"""

import argparse
import base64
import html
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path

from PIL import Image

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
EMBER = "#FF8A7A"
# The wordmark's b (bighelp-site's noodle-d), drawn as a stroke in Ember.
NOODLE = ("M28 12 L28 60 C28 73.807 39.193 85 53 85 C66.807 85 78 73.807 78 60 C78 46.193 66.807 35 53 35 "
          "C39.193 35 28 46.193 28 60 C28 80 22 90 8 94")
PAPER = dict(page="#FFFFFF", ink="#111111", ink2="rgba(17,17,17,.6)", pill="#F2F2F2", frame="#111111",
             shadow="0 40px 120px rgba(0,0,0,.16)")
BLACK = dict(page="#000000", ink="#FFFFFF", ink2="rgba(255,255,255,.62)", pill="#1C1C1E", frame="#2C2C2E",
             shadow="none")

# name, capture, pill, headline, the line under it, on Black. Pages alternate, Paper first.
PANELS = [
    ("01-chat", "01-spending", "Chat", ("Your bots.", "One simple chat."),
     ("Text your own AI agents like you'd text a friend.", "Answers come back as clear cards.")),
    ("02-bots", "11-bots", "Bots mode", ("Just your bots.", "A text away."),
     ("A calm home for the bots you talk to most.", "Tap one and chat.")),
    ("03-feed", "03-feed", "Feed", ("A Feed that fills", "when you ask."),
     ("Your bots post what you asked for.", "Nothing runs until you say so.")),
    ("04-code", "12-code", "Code mode", ("Code anywhere.", "Just describe it."),
     ("Each message starts its own coding session.", "Check the changes when it's done.")),
    ("05-ideas", "08-ideas", "Ideas", ("Ideas it noticed.", "You decide."),
     ("Your bot offers to take things off your plate.", "Tap Let's do it, or don't.")),
    ("06-automation", "05-automation", "Chat", ("Just ask.", "Consider it done."),
     ("Set up useful work with a conversation.", "Your bots take it from there.")),
    # Goals have no progress number on the host, so the copy promises none.
    ("07-goals", "04-goals", "Goals", ("Your goals,", "in one place."),
     ("Tell your bot what you're working toward.", "It checks in and keeps notes.")),
    ("08-plan", "02-packing", "Chat", ("A clear plan.", "Less juggling."),
     ("Checklists, budgets and next steps.", "More than a wall of text.")),
    ("09-work", "07-kanban", "Kanban", ("Keep the work", "in view."),
     ("Plans become tasks you can track.", "From the first idea to done.")),
]


@dataclass(frozen=True)
class Display:
    size: tuple[int, int]
    capture: str
    # In hundredths of the width: the headline, the line under it, the pill's text, the wordmark,
    # the device's width, its bezel and its outer corner radius.
    headline: float
    lede: float
    pill: float
    wordmark: float
    device: float
    bezel: float
    radius: float


DISPLAYS = {
    "APP_IPHONE_67": Display((1320, 2868), "iphone", 10.6, 3.45, 3.2, 4.4, 64, 1.45, 10.4),
    "APP_IPHONE_65": Display((1284, 2778), "iphone", 10.6, 3.45, 3.2, 4.4, 64, 1.45, 10.4),
    "APP_IPAD_PRO_3GEN_129": Display((2064, 2752), "ipad", 8.0, 2.8, 2.5, 3.6, 57, 1.1, 2.8),
}


def data_url(path: Path) -> str:
    mime = {".png": "image/png", ".woff2": "font/woff2", ".ttf": "font/ttf"}[path.suffix.lower()]
    return f"data:{mime};base64," + base64.b64encode(path.read_bytes()).decode()


def page(display: Display, number: int, panel, shot: Path, fonts: dict, dark: bool) -> str:
    _, _, pill, headline, lede = panel
    c = BLACK if dark else PAPER
    width, height = display.size
    u = width / 100
    pad = 7.3 * u
    device_w = display.device * u
    device_h = device_w * Image.open(shot).height / Image.open(shot).width
    device_top = height - device_h - 4.2 * u
    lines = [html.escape(line) for line in headline]
    if lines[-1].endswith("."):
        lines[-1] = lines[-1][:-1] + '<b class="ember">.</b>'
    return f"""<!doctype html><html><head><meta charset="utf-8"><style>
@font-face {{ font-family: Inter; src: url({data_url(fonts['inter'])}); font-weight: 100 900; }}
@font-face {{ font-family: Nunito; src: url({data_url(fonts['nunito'])}); font-weight: 200 1000; }}
html, body {{ margin: 0; width: {width}px; height: {height}px; overflow: hidden; background: {c['page']}; }}
body {{ position: relative; font-family: Inter; color: {c['ink']}; -webkit-font-smoothing: antialiased;
        font-feature-settings: "ss01", "cv11"; }}
.copy {{ position: absolute; left: {pad}px; right: {pad}px; top: {pad * 0.85}px; }}
.wordmark {{ display: flex; align-items: center; gap: {0.15 * u}px; font: 900 {display.wordmark * u}px/1 Nunito;
             letter-spacing: -.02em; }}
.wordmark svg {{ height: {display.wordmark * 1.05 * u}px; overflow: visible; }}
.pill {{ display: flex; width: max-content; align-items: center; gap: {1.1 * u}px; margin-top: {5.2 * u}px;
         padding: {1.05 * u}px {2.2 * u}px; border-radius: 999px; background: {c['pill']}; color: {c['ink2']};
         font-weight: 650; font-size: {display.pill * u}px; }}
.pill i {{ width: {display.pill * 0.375 * u}px; height: {display.pill * 0.375 * u}px; border-radius: 50%;
           background: {EMBER}; }}
h1 {{ width: max-content; white-space: nowrap; margin: {2.6 * u}px 0 0; font-weight: 800;
      font-size: {display.headline * u}px; line-height: 1.02; letter-spacing: -.035em; }}
.ember {{ color: {EMBER}; font-weight: 800; }}
p {{ margin: {2.4 * u}px 0 0; font-weight: 450; font-size: {display.lede * u}px; line-height: 1.38; color: {c['ink2']}; }}
.device {{ position: absolute; left: {(width - device_w) / 2}px; top: {device_top}px; width: {device_w}px;
           height: {device_h}px; box-sizing: border-box; padding: {display.bezel * u}px;
           border-radius: {display.radius * u}px; background: {c['frame']}; box-shadow: {c['shadow']}; }}
.device img {{ display: block; width: 100%; height: 100%; border-radius: {(display.radius - display.bezel) * u}px; }}
</style></head><body>
<div class="copy">
<div class="wordmark"><svg viewBox="0 4 86 98"><path d="{NOODLE}" fill="none" stroke="{EMBER}" stroke-width="16"
  stroke-linecap="round" stroke-linejoin="round"/></svg>ighelp</div>
<div class="pill"><i></i>{number:02d} · {html.escape(pill)}</div>
<h1>{'<br>'.join(lines)}</h1>
<p>{'<br>'.join(html.escape(line) for line in lede)}</p>
</div>
<div class="device"><img src="{data_url(shot)}"></div>
<script>
// A long line shrinks the headline until it fits inside the margins.
document.fonts.ready.then(() => {{
  const h1 = document.querySelector("h1"), room = document.querySelector(".copy").clientWidth;
  let size = parseFloat(getComputedStyle(h1).fontSize);
  while (h1.offsetWidth > room && size > 10) h1.style.fontSize = (size -= 1) + "px";
}});
</script>
</body></html>"""


def render(document: str, size: tuple[int, int], output: Path) -> None:
    with tempfile.TemporaryDirectory() as folder:
        source = Path(folder) / "poster.html"
        source.write_text(document)
        subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars",
                        f"--user-data-dir={folder}/profile", "--force-device-scale-factor=1",
                        f"--window-size={size[0]},{size[1]}", "--virtual-time-budget=2000",
                        f"--screenshot={output}", source.as_uri()], check=True, capture_output=True, timeout=120)
    with Image.open(output) as image:
        if image.size != size:
            raise SystemExit(f"{output} came out {image.size}, not {size}")


def contact_sheet(rows: list[list[Path]], output: Path) -> None:
    height = 640
    gap = 24
    scaled = [[Image.open(path).convert("RGB") for path in row] for row in rows]
    scaled = [[image.resize((round(image.width * height / image.height), height), Image.Resampling.LANCZOS)
               for image in row] for row in scaled]
    width = max(sum(image.width for image in row) + gap * (len(row) + 1) for row in scaled)
    sheet = Image.new("RGB", (width, (height + gap) * len(scaled) + gap), (200, 196, 192))
    for index, row in enumerate(scaled):
        x = gap
        for image in row:
            sheet.paste(image, (x, gap + index * (height + gap)))
            x += image.width + gap
    sheet.save(output)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--captures", type=Path, required=True)
    parser.add_argument("--inter", type=Path, required=True)
    parser.add_argument("--nunito", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    fonts = {"inter": args.inter, "nunito": args.nunito}
    sheet = []
    for kind, display in DISPLAYS.items():
        folder = args.output / kind
        folder.mkdir(parents=True, exist_ok=True)
        row = []
        for number, panel in enumerate(PANELS, 1):
            shot = args.captures / f"{display.capture}-{panel[1]}.png"
            path = folder / f"{panel[0]}.png"
            render(page(display, number, panel, shot, fonts, dark=number % 2 == 0), display.size, path)
            row.append(path)
            print(path)
        sheet.append(row)
    contact_sheet(sheet, args.output / "contact-sheet.png")
    print(args.output / "contact-sheet.png")


if __name__ == "__main__":
    main()
