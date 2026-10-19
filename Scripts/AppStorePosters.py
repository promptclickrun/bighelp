"""The App Store posters: fresh captures in the live set's frame.

  python3 -I Scripts/AppStorePosters.py --reference <live set> --captures <folder> \\
      --nunito <Nunito variable TTF> --inter <Inter variable TTF> --output <folder>

--reference is the live App Store set (`asc screenshots download`), one folder per
display type: APP_IPHONE_67, APP_IPHONE_65 and APP_IPAD_PRO_3GEN_129. Its first cream
poster and its first dark one are the templates. Their logo, device frame, the frame's
shadow and the circle stay pixel for pixel; the headline, the subtitle and the screen
are replaced. The type was measured from that set: Nunito Black (900, tracked -0.025 em)
for the headline and Inter Medium (500) for the subtitle, each line placed by the top of
its ink, the way the live posters are.

--captures holds the raw screens: iphone-<shot>.png (1320×2868, iPhone 6.9") and
ipad-<shot>.png (2064×2752, iPad 13"). The 6.5" posters use the iPhone shots. Writes
<output>/<display type>/NN-name.png and <output>/contact-sheet.png.
"""

import argparse
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

CREAM, DARK = (255, 249, 245), (18, 17, 16)
# Headline and subtitle colors on each background.
INK = {CREAM: ((28, 26, 25), (81, 75, 71)), DARK: ((255, 249, 245), (198, 189, 182))}

# The live set's copy, by poster name; the templates' old text is cleared with it.
LIVE = {
    "01-one-simple-chat": (("Your agents.", "One simple chat."),
                           ("Turn a question into a useful answer.", "With the agents you choose.")),
    "02-ask-and-done": (("Ask once.", "Make it happen."),
                        ("Set up useful work with a conversation.", "Your agents take it from there.")),
    "03-made-for-you": (("A feed that", "gets you."),
                        ("Updates you actually asked for.", "Not another endless scroll.")),
    "04-clear-plan": (("A clear plan.", "Less juggling."),
                      ("Checklists, budgets and next steps.", "More than just a wall of text.")),
    "05-move-forward": (("Small steps.", "Real progress."),
                        ("Give your goals a place to live.", "Let your agents help you move forward.")),
    "06-next-good-idea": (("Your next", "good idea."),
                          ("Useful suggestions, ready when you are.", "You decide what happens next.")),
    "07-work-in-view": (("Keep the work", "in view."),
                        ("Plans become tasks you can track.", "From the first idea to done.")),
}

# name, capture, background, headline and subtitle. Backgrounds alternate.
PANELS = [
    ("01-one-simple-chat", "01-spending", CREAM, *LIVE["01-one-simple-chat"]),
    ("02-just-your-bots", "11-bots", DARK, ("Just your bots.", "A text away."),
     ("A calm home for the agents you talk to most.", "Tap one and chat, like texting a friend.")),
    ("03-ask-and-done", "05-automation", CREAM, *LIVE["02-ask-and-done"]),
    ("04-code-anywhere", "12-code", DARK, ("Code anywhere.", "Just describe it."),
     ("Each message starts its own coding session.", "Check the changes when it's done.")),
    ("05-made-for-you", "03-feed", CREAM, *LIVE["03-made-for-you"]),
    ("06-clear-plan", "02-packing", DARK, *LIVE["04-clear-plan"]),
    ("07-move-forward", "04-goals", CREAM, *LIVE["05-move-forward"]),
    ("08-next-good-idea", "08-ideas", DARK, *LIVE["06-next-good-idea"]),
    ("09-work-in-view", "07-kanban", CREAM, *LIVE["07-work-in-view"]),
]


@dataclass(frozen=True)
class Style:
    size: float
    weight: float
    tracking: float  # em
    x: float  # pen origin
    tops: tuple[int, int]  # the ink top of each line


@dataclass(frozen=True)
class Display:
    size: tuple[int, int]
    capture: str
    headline: Style
    subtitle: Style
    frames: dict  # background: the device frame's outer box, inclusive
    radius: int
    bezel: int
    clear: dict  # background: rows that hold only background and text
    # background: a box under the subtitle's last line that also holds the frame's shadow
    shadowed: dict


DISPLAYS = {
    "APP_IPHONE_67": Display(
        (1320, 2868), "iphone",
        Style(147, 900, -0.025, 96.375, (384, 534)), Style(46, 500, 0, 96.4375, (741, 801)),
        {CREAM: (257, 995, 1061, 2715), DARK: (99, 995, 903, 2715)}, 101, 12,
        {CREAM: (230, 900), DARK: (230, 970)}, {}),
    "APP_IPHONE_65": Display(
        (1284, 2778), "iphone",
        Style(143, 900, -0.025, 93.875, (372, 518)), Style(45, 500, 0, 93.875, (719, 777)),
        {CREAM: (252, 964, 1031, 2630), DARK: (96, 964, 875, 2630)}, 98, 12,
        {CREAM: (225, 875), DARK: (225, 940)}, {}),
    "APP_IPAD_PRO_3GEN_129": Display(
        (2064, 2752), "ipad",
        Style(194, 900, -0.025, 150.8125, (322, 520)), Style(66, 500, 0, 150.75, (773, 852)),
        {CREAM: (423, 985, 1640, 2598), DARK: (423, 985, 1640, 2598)}, 67, 15,
        {CREAM: (270, 852), DARK: (270, 950)}, {CREAM: (140, 852, 1290, 950)}),
}


class Fonts:
    def __init__(self, nunito: Path, inter: Path):
        self.paths = {"headline": nunito, "subtitle": inter}
        self.cache = {}

    def get(self, role: str, style: Style) -> ImageFont.FreeTypeFont:
        key = (role, style.size, style.weight)
        if key not in self.cache:
            font = ImageFont.truetype(str(self.paths[role]), style.size)
            font.set_variation_by_axes([style.weight])
            self.cache[key] = font
        return self.cache[key]


def line_mask(size: tuple[int, int], text: str, font: ImageFont.FreeTypeFont, style: Style, top: int) -> Image.Image:
    """The line's coverage on a canvas, its pen at style.x and its ink's top at `top`."""
    def draw(baseline: int) -> Image.Image:
        mask = Image.new("L", size, 0)
        canvas = ImageDraw.Draw(mask)
        for index, character in enumerate(text):
            # Where the shaped line puts this letter (kerning included), plus the tracking so far.
            pen = style.x + font.getlength(text[:index + 1]) - font.getlength(character)
            canvas.text((pen + index * style.tracking * style.size, baseline), character, font=font, fill=255,
                        anchor="ls")
        return mask
    probe = draw(size[1] // 2)
    box = probe.getbbox()
    return draw(size[1] // 2 + top - box[1])


def text_masks(display: Display, fonts: Fonts, headline, subtitle) -> list[tuple[str, Image.Image]]:
    masks = []
    for role, style, lines in (("headline", display.headline, headline), ("subtitle", display.subtitle, subtitle)):
        for line, top in zip(lines, style.tops):
            masks.append((role, line_mask(display.size, line, fonts.get(role, style), style, top)))
    return masks


def background_of(path: Path) -> tuple:
    return Image.open(path).convert("RGB").getpixel((5, 5))


def template(folder: Path, display: Display, background: tuple, fonts: Fonts) -> Image.Image:
    """The live poster with this background, without its headline, subtitle or screen."""
    posters = [path for path in sorted(folder.glob("*.png")) if background_of(path) == background]
    if not posters:
        raise SystemExit(f"{folder}: no poster on {background}")
    base = np.asarray(Image.open(posters[0]).convert("RGB")).copy()
    top, bottom = display.clear[background]
    base[top:bottom, :] = background
    box = display.shadowed.get(background)
    if box:
        # Under the last line the frame's shadow starts. Every poster has the same shadow and
        # different words, so the lightest (or darkest) pixel of all of them is the shadow; where
        # every poster has a letter, fill in from the clean pixels above and below.
        left, upper, right, lower = box
        stack = np.stack([np.asarray(Image.open(path).convert("RGB"))[upper:lower, left:right] for path in posters])
        clean = (stack.max(axis=0) if background == CREAM else stack.min(axis=0)).astype(float)
        inked = np.ones(clean.shape[:2], bool)
        for path in posters:
            name = next((key for key in LIVE if path.stem.endswith(key)), None)
            if name is None:
                raise SystemExit(f"{path.name}: unknown live poster, add its copy to LIVE")
            covered = np.zeros(clean.shape[:2], bool)
            for _, mask in text_masks(display, fonts, *LIVE[name]):
                covered |= np.asarray(mask)[upper:lower, left:right] > 0
            inked &= covered
        inked = np.asarray(Image.fromarray(inked.astype(np.uint8) * 255).filter(ImageFilter.MaxFilter(5))) > 0
        above = base[upper - 1, left:right].astype(float)
        for column in np.where(inked.any(axis=0))[0]:
            rows = np.where(inked[:, column])[0]
            for start, end in runs(rows):
                first = clean[start - 1, column] if start > 0 else above[column]
                last = clean[end + 1, column]
                for row in range(start, end + 1):
                    share = (row - start + 1) / (end - start + 2)
                    clean[row, column] = first + (last - first) * share
        base[upper:lower, left:right] = np.round(clean).astype(np.uint8)
    return Image.fromarray(base)


def runs(rows: np.ndarray):
    start = previous = rows[0]
    for row in rows[1:]:
        if row != previous + 1:
            yield start, previous
            start = row
        previous = row
    yield start, previous


def poster(base: Image.Image, display: Display, background: tuple, capture: Image.Image, fonts: Fonts,
           headline, subtitle) -> Image.Image:
    canvas = base.copy()
    left, top, right, bottom = display.frames[background]
    screen = (left + display.bezel, top + display.bezel, right - display.bezel, bottom - display.bezel)
    width, height = screen[2] - screen[0] + 1, screen[3] - screen[1] + 1
    expected = display.size if display.capture == "ipad" else (1320, 2868)
    if capture.size != expected:
        raise SystemExit(f"capture is {capture.size}, expected {expected}")
    shot = capture.convert("RGB").resize((width, height), Image.Resampling.LANCZOS)
    mask = Image.new("L", (width, height), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, width - 1, height - 1), display.radius - display.bezel, fill=255)
    canvas.paste(shot, screen[:2], mask)
    colors = dict(zip(("headline", "subtitle"), INK[background]))
    for role, mask in text_masks(display, fonts, headline, subtitle):
        canvas = Image.composite(Image.new("RGB", display.size, colors[role]), canvas, mask)
    return canvas


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
    parser.add_argument("--reference", type=Path, required=True)
    parser.add_argument("--captures", type=Path, required=True)
    parser.add_argument("--nunito", type=Path, required=True)
    parser.add_argument("--inter", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    fonts = Fonts(args.nunito, args.inter)
    sheet = []
    for kind, display in DISPLAYS.items():
        folder = args.output / kind
        folder.mkdir(parents=True, exist_ok=True)
        bases = {background: template(args.reference / kind, display, background, fonts) for background in (CREAM, DARK)}
        row = []
        for name, shot, background, headline, subtitle in PANELS:
            capture = Image.open(args.captures / f"{display.capture}-{shot}.png")
            path = folder / f"{name}.png"
            poster(bases[background], display, background, capture, fonts, headline, subtitle).save(path, optimize=True)
            row.append(path)
            print(path)
        sheet.append(row)
    contact_sheet(sheet, args.output / "contact-sheet.png")
    print(args.output / "contact-sheet.png")


if __name__ == "__main__":
    main()
