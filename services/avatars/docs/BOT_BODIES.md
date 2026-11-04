# Bot Studio bodies

Bot Studio (the app's avatar editor) builds every avatar from one recipe: a **body** from this catalog, plus eyes,
colors, tilt, lean, taller or wider, size, mirror and an idle move that the person picks. All packs use the same
recipe, so every avatar can change in the same ways. This page is the format and the style for the bodies.

## Style

Every body follows the same style, so that the packs look like one family:

- One flat main color. No outlines, gradients, textures or text.
- At most one or two small parts in a second color (`accent`), for example a stem, a handle, steam or a ribbon. The
  main color must stay most of the body, because the person changes it.
- Shading is optional and rare: a `shade` part (black at 16%) or a `light` part (white at 60%) for one fold or one
  panel. These go on top of the main color, so they change with it.
- The body is tilted by default (`rotation`, usually from -30 to 20 degrees), so it feels alive. Upright objects that
  read wrong when tilted can use a small tilt.
- Two small eyes, up and to the right of the body's middle. The app draws them: you give their places. They are
  slanted capsules by default (`eyeTilt` -24). The person can pick other eyes, so leave room around them.
- The body must read at 32 points: a clear silhouette, no thin details.
- Draw from the character's idea (its name and role), not from another app's art. Only first-party art ships.

## Format

One file per set: `sources/bodies/<set>.json`.

```json
{
  "set": { "id": "bitty-bots", "name": "Bitty Bots", "category": "bighelp", "startsAt": null, "expiresAt": null },
  "bodies": [
    {
      "id": "bitty-bots.brew",
      "name": "Brew",
      "role": "Starts the morning",
      "parts": [
        { "d": "M66 42C82 42 82 66 66 66", "tone": "main", "stroke": 8 },
        { "d": "M26 32H66V70A10 10 0 0 1 56 80H36A10 10 0 0 1 26 70Z", "tone": "main", "round": 6 },
        { "d": "M40 24C36 18 44 14 40 8M54 24C50 18 58 14 54 8", "tone": "accent", "stroke": 3 }
      ],
      "eyes": [[42, 50, 11], [53, 52, 11]],
      "eyeTilt": -24,
      "rotation": -6,
      "colors": { "main": "#8B6440", "accent": "#C9C3BD" }
    }
  ]
}
```

- `set.category` is `shapes`, `hermes`, `bighelp` or `seasonal`. A seasonal set has `expiresAt` (ISO 8601 with offset);
  the app hides its bodies after that time, but avatars that use them keep drawing.
- `id` is `<set id>.<slug>`: lowercase letters, digits and `-`. `name` is one or two words. `role` is optional.
- `parts` are drawn in order, back to front, in a 100 × 100 box. Each part is one of:
  - a filled shape: `d`, `tone`, and an optional `round` (a stroke in the same color with round joins, which rounds
    the corners and makes the shape a little bigger);
  - a line: `d`, `tone` and `stroke` (its width), with round caps and joins.
- `d` uses only `M L H V C Q A Z` (upper or lower case). No `S` or `T`. Plain numbers only.
- Each part is filled on its own. Put shapes that overlap each other in separate parts, because subpaths that wind in
  opposite directions leave holes.
- `tone` is `main`, `accent`, `shade`, `light` or `ink` (the eye color).
- `eyes` is `[[x, y, height], [x, y, height]]`: the left eye, then the right eye, before `rotation`. Height is from 9
  to 13. The right eye is usually 10 to 12 to the right of the left eye and 2 lower. Both eyes must sit on the main
  color, at least 3 from any edge or accent part.
- `rotation` turns the whole body (degrees) around (50, 50). Keep every point inside 8…92 after rotation.
- `colors.main` and `colors.accent` are `#RRGGBB`. Eyes are dark (`#1C1A19`), so pick a main color that is not too dark.
  Do not use the brand's Ember coral (`#FF8A7A`) as a main color.
- Up to 12 parts per body, and up to 4,000 characters in each `d`.

## Previews

`python3 scripts/bodies-preview.py sources/bodies/<set>.json --out sheet.svg --png sheet.png [--dark]` draws a contact
sheet the way the app draws the bodies: each body as saved, then with wide eyes, a new color and some lean. Check both
light and dark before you send a set.
