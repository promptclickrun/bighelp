"""The App Store posters, in the lifter brand: Cream and Night pages, Coral, and the app's own screens.

  python3 -I Scripts/AppStorePosters.py --captures <folder> --bricolage <Bricolage Grotesque variable font> \\
      --inter <Inter variable font> --mono <JetBrains Mono font> --output <folder>

Each poster is an HTML page that headless Chrome renders at the display's exact size: a Cream or
Night page (they alternate, Cream first), the lockup (the lifter and "Bighelp", from the app's own
assets), a numbered label in JetBrains Mono, a headline in Bricolage Grotesque 800 tracked -0.03em
with its last period in Coral, a line under it in Inter, and the screen in a plain device frame.
The fonts are the site's (bighelp-site/src/fonts, woff2) or any copies of the same three.

--captures holds the raw screens from Scripts/AppStoreScreenshots.sh: iphone-<shot>.png
(1320×2868, iPhone 6.9"), ipad-<shot>.png (2064×2752, iPad 13") and duo-<shot>.png (1398×2034, the
iPhone Duo's cover screen). The 6.5" posters use the iPhone shots. A display skips a poster whose
screen it has no shot of. Writes <output>/<display type>/NN-name.png and <output>/contact-sheet.png.
"""

import argparse
import base64
import html
import re
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path

from PIL import Image

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
ASSETS = Path(__file__).resolve().parent.parent / "Bighelp/Resources/Assets.xcassets"
CORAL = "#FF5A36"
# The brand kit's pages (bighelp-site/src/css/base.css): Cream by day, Night after dark.
CREAM = dict(page="#FFF6EC", ink="#1A1420", ink2="#4B4551", label="#C63A1B", frame="#1A1420",
             shadow="0 40px 120px rgba(26,20,32,.18)", mark="BighelpMarkColor.svg")
NIGHT = dict(page="#0E0E10", ink="#FFF6EC", ink2="#CFC6CF", label="#FF7A5C", frame="#2A2331",
             shadow="none", mark="BighelpMarkColorDark.svg")

# name, capture, label, headline, the line under it. Pages alternate, Cream first.
PANELS = [
    ("01-chat", "01-spending", "Chat", ("Your bots.", "One simple chat."),
     ("Text your own AI bots like you'd text a friend.", "Answers come back as clear cards.")),
    ("02-today", "13-today", "Today", ("Your day,", "in one look."),
     ("Feed, Ideas and Goals from every bot.", "Open the app and you're caught up.")),
    ("03-bots", "11-bots", "Bots", ("Just your bots.", "A text away."),
     ("A calm home for the bots you talk to most.", "Tap one and chat.")),
    ("04-feed", "03-feed", "Feed", ("A Feed that fills", "when you ask."),
     ("Swipe a post right to say do it.", "Swipe it left to clear it.")),
    ("05-work", "14-work", "Work", ("See the work", "as it happens."),
     ("Chats, coding, tasks and schedules.", "One list of what your bots are doing.")),
    ("06-ideas", "08-ideas", "Ideas", ("Ideas it noticed.", "You decide."),
     ("Your bot offers to take things off your plate.", "Tap Let's do it, or don't.")),
    ("07-automation", "05-automation", "Chat", ("Just ask.", "Consider it done."),
     ("Set up useful work with a conversation.", "Your bots take it from there.")),
    # Goals have no progress number on the host, so the copy promises none.
    ("08-goals", "04-goals", "Goals", ("Your goals,", "in one place."),
     ("Tell your bot what you're working toward.", "It checks in and keeps notes.")),
    ("09-code", "12-code", "Work", ("Code anywhere.", "Just describe it."),
     ("Each message starts its own coding session.", "Check the changes when it's done.")),
    ("10-plan", "02-packing", "Chat", ("A clear plan.", "Less juggling."),
     ("Checklists, budgets and next steps.", "More than a wall of text.")),
]


@dataclass(frozen=True)
class Display:
    size: tuple[int, int]
    capture: str
    # In hundredths of the width: the headline, the line under it, the label, the lockup's height,
    # the device's width, its bezel and its outer corner radius.
    headline: float
    lede: float
    label: float
    lockup: float
    device: float
    bezel: float
    radius: float


DISPLAYS = {
    "APP_IPHONE_67": Display((1320, 2868), "iphone", 11.4, 3.45, 2.5, 8.4, 70, 1.45, 10.4),
    "APP_IPHONE_65": Display((1284, 2778), "iphone", 11.4, 3.45, 2.5, 8.4, 70, 1.45, 10.4),
    "APP_IPAD_PRO_3GEN_129": Display((2064, 2752), "ipad", 8.4, 2.8, 2.0, 6.0, 57, 1.1, 2.8),
    # The cover screen is short and wide, so the device is narrower and the words smaller.
    "APP_IPHONE_DUO": Display((1398, 2034), "duo", 9.2, 3.0, 2.2, 7.0, 60, 1.3, 6.0),
}


def data_url(path: Path) -> str:
    mime = {".png": "image/png", ".woff2": "font/woff2", ".ttf": "font/ttf"}[path.suffix.lower()]
    return f"data:{mime};base64," + base64.b64encode(path.read_bytes()).decode()


def lockup(colors: dict) -> str:
    """The lifter, then "Bighelp" in the kit's outlined letters, in the page's ink."""
    mark = (ASSETS / "BighelpMarkColor.imageset" / colors["mark"]).read_text()
    word = (ASSETS / "BighelpWordmark.imageset/BighelpWordmark.svg").read_text()
    word = re.sub(r'fill="#[0-9A-Fa-f]{6}"', f'fill="{colors["ink"]}"', word)
    mark = mark.replace("<svg ", '<svg class="mark" ', 1)
    word = word.replace("<svg ", '<svg class="word" ', 1)
    return f'<div class="lockup">{mark}{word}</div>'


def page(display: Display, number: int, panel, shot: Path, fonts: dict, dark: bool) -> str:
    _, _, label, headline, lede = panel
    c = NIGHT if dark else CREAM
    width, height = display.size
    u = width / 100
    pad = 7.3 * u
    device_w = display.device * u
    device_h = device_w * Image.open(shot).height / Image.open(shot).width
    device_top = height - device_h - 4.2 * u
    lines = [html.escape(line) for line in headline]
    if lines[-1].endswith("."):
        lines[-1] = lines[-1][:-1] + '<b class="coral">.</b>'
    return f"""<!doctype html><html><head><meta charset="utf-8"><style>
@font-face {{ font-family: Bricolage; src: url({data_url(fonts['bricolage'])}); font-weight: 200 800; }}
@font-face {{ font-family: Inter; src: url({data_url(fonts['inter'])}); font-weight: 100 900; }}
@font-face {{ font-family: Mono; src: url({data_url(fonts['mono'])}); font-weight: 500; }}
html, body {{ margin: 0; width: {width}px; height: {height}px; overflow: hidden; background: {c['page']}; }}
body {{ position: relative; font-family: Inter; color: {c['ink']}; -webkit-font-smoothing: antialiased;
        font-feature-settings: "ss01", "cv11"; }}
.copy {{ position: absolute; left: {pad}px; right: {pad}px; top: {pad * 0.8}px; }}
.lockup {{ display: flex; align-items: center; gap: {0.6 * u}px; height: {display.lockup * u}px; }}
.lockup .mark {{ height: 100%; margin-left: {-0.9 * u}px; }}
.lockup .word {{ height: 58%; }}
.label {{ margin-top: {4.4 * u}px; font: 500 {display.label * u}px/1.4 Mono; letter-spacing: .06em;
          text-transform: uppercase; color: {c['label']}; }}
h1 {{ width: max-content; white-space: nowrap; margin: {1.8 * u}px 0 0; font-family: Bricolage; font-weight: 800;
      font-size: {display.headline * u}px; line-height: .98; letter-spacing: -.03em; }}
.coral {{ color: {CORAL}; font-weight: 800; }}
p {{ margin: {2.6 * u}px 0 0; font-weight: 450; font-size: {display.lede * u}px; line-height: 1.38; color: {c['ink2']}; }}
.device {{ position: absolute; left: {(width - device_w) / 2}px; top: {device_top}px; width: {device_w}px;
           height: {device_h}px; box-sizing: border-box; padding: {display.bezel * u}px;
           border-radius: {display.radius * u}px; background: {c['frame']}; box-shadow: {c['shadow']}; }}
.device img {{ display: block; width: 100%; height: 100%; border-radius: {(display.radius - display.bezel) * u}px; }}
</style></head><body>
<div class="copy">
{lockup(c)}
<div class="label">{number:02d} · {html.escape(label)}</div>
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
        # App Store Connect refuses a screenshot with an alpha channel.
        if image.mode != "RGB":
            image.convert("RGB").save(output)


def contact_sheet(rows: list[list[Path]], output: Path) -> None:
    height = 640
    gap = 24
    scaled = [[Image.open(path).convert("RGB") for path in row] for row in rows if row]
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
    parser.add_argument("--bricolage", type=Path, required=True)
    parser.add_argument("--inter", type=Path, required=True)
    parser.add_argument("--mono", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    fonts = {"bricolage": args.bricolage, "inter": args.inter, "mono": args.mono}
    sheet = []
    for kind, display in DISPLAYS.items():
        folder = args.output / kind
        row = []
        # Numbered as they come out, so a display that skips one still counts 01, 02, 03.
        for panel in PANELS:
            shot = args.captures / f"{display.capture}-{panel[1]}.png"
            if not shot.exists():
                continue
            number = len(row) + 1
            folder.mkdir(parents=True, exist_ok=True)
            path = folder / f"{number:02d}-{panel[0].split('-', 1)[1]}.png"
            render(page(display, number, panel, shot, fonts, dark=number % 2 == 0), display.size, path)
            row.append(path)
            print(path)
        sheet.append(row)
    contact_sheet(sheet, args.output / "contact-sheet.png")
    print(args.output / "contact-sheet.png")


if __name__ == "__main__":
    main()
