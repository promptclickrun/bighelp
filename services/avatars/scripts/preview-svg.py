#!/usr/bin/env python3
"""Static idle SVG previews of an authored AvatarKit pack, with the backdrop disc off.

Usage: python3 scripts/preview-svg.py <set-id> [--pack <file>] [--check]
Reads sources/packs/<pack>.json (the set ID by default) and writes sources/<set-id>/<character-id>.svg.
--check compares instead of writing and fails on any difference.

Draws each character's idle frame: palette tokens (@p, @ink...) become the character's own colors,
animations are left at rest, the `bg` disc is skipped, and any subtree whose idle opacity is 0 (state-only
art such as sleeping Zs, the waiting badge and happy sparkles) is left out. Numbers keep the pack's own
spelling, so a preview changes only when its art does.
"""
import json
import pathlib
import sys

service = pathlib.Path(__file__).resolve().parent.parent
ATTRIBUTES = {
    'path': [('d', 'd')],
    'rect': [('x', 'x'), ('y', 'y'), ('w', 'width'), ('h', 'height'), ('rx', 'rx')],
    'ellipse': [('cx', 'cx'), ('cy', 'cy'), ('rx', 'rx'), ('ry', 'ry')],
}
# Style keys in the order they're written, after any transform.
STYLES = [('f', 'fill'), ('fo', 'fill-opacity'), ('s', 'stroke'), ('sw', 'stroke-width'), ('so', 'stroke-opacity'),
          ('cap', 'stroke-linecap'), ('join', 'stroke-linejoin')]
# Idle-style keys that only animate or move a node away from its rest pose.
AT_REST = {'an', 'org', 'tl', 'tf'}


def number(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f'Not a number: {value!r}')
    return repr(value)


def escape(text):
    return str(text).replace('&', '&amp;').replace('"', '&quot;').replace('<', '&lt;').replace('>', '&gt;')


def preview(character):
    colors = character['colors']

    def paint(value):
        if value.startswith('@'):
            if value[1:] not in colors:
                raise ValueError(f"{character['id']} uses {value}, which its colors don't define")
            return colors[value[1:]]
        return value

    def node(n, root=False):
        idle = n.get('st', {}).get('idle', {})
        unknown = set(idle) - AT_REST - {key for key, _ in STYLES} - {'o', 'fs'}
        if unknown:
            raise ValueError(f"{character['id']}: unsupported idle style {sorted(unknown)}")
        if n.get('bg') or idle.get('o') == 0:
            return ''
        tag = n['t']
        attributes = []
        if tag == 'circle':
            if n['rx'] != n['ry']:
                raise ValueError(f"{character['id']}: circle with unequal radii")
            attributes += [('cx', number(n['cx'])), ('cy', number(n['cy'])), ('r', number(n['rx']))]
        elif tag in ATTRIBUTES:
            attributes += [(name, n[key] if key == 'd' else number(n[key])) for key, name in ATTRIBUTES[tag] if key in n]
        elif tag not in ('g', 'svg'):
            # Text is only state art (sleeping Zs), and the catalog's SVG validation refuses it.
            raise ValueError(f"{character['id']}: unsupported node {tag}")
        if 'm' in n:
            attributes.append(('transform', f"matrix({' '.join(number(v) for v in n['m'])})"))
        if 'o' in idle:
            attributes.append(('opacity', number(idle['o'])))
        for key, name in STYLES:
            if key in idle:
                attributes.append((name, paint(idle[key]) if key in ('f', 's') else idle[key] if key in ('cap', 'join') else number(idle[key])))
        if tag == 'svg' or root:
            tag = 'g'
        text = ''.join(f' {name}="{escape(value)}"' for name, value in attributes)
        children = ''.join(node(child) for child in n.get('k', []))
        if tag == 'g':
            return f'<{tag}{text}>{children}</{tag}>' if children else f'<{tag}{text} />'
        return f'<{tag}{text} />'

    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200">{node(character["tree"], root=True)}</svg>\n'


def main():
    args = sys.argv[1:]
    check = '--check' in args
    args = [a for a in args if a != '--check']
    if not args:
        sys.exit(__doc__)
    set_id = args[0]
    pack_name = args[args.index('--pack') + 1] if '--pack' in args else set_id
    pack = json.loads((service / f'sources/packs/{pack_name}.json').read_text())
    folder = service / 'sources' / set_id
    folder.mkdir(exist_ok=True)
    different = []
    for character in pack['characters']:
        target = folder / f"{character['id']}.svg"
        svg = preview(character)
        if check:
            if not target.exists() or target.read_text() != svg:
                different.append(target.name)
        else:
            target.write_text(svg)
    if different:
        sys.exit(f'{len(different)} previews differ from the pack: {", ".join(different)}')
    print(f"{'Checked' if check else 'Wrote'} {len(pack['characters'])} previews for {set_id}")


if __name__ == '__main__':
    main()
