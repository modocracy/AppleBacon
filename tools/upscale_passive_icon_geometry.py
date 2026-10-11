#!/usr/bin/env python3
"""Derive smoothed 64px passive icon geometry from the 32px sampled original art.

The 32px rectangles (src/passive_icon_geometry.lua) are the only icon source
in the public tree. Large picker tiles draw them 1:1 at 64px from this file:
each icon is rasterised, upscaled with bicubic filtering and a light blur,
then re-quantised to four grey levels and merged back into rectangles. This
smooths curves and diagonals; it cannot add detail the 32px sample lacks.
"""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import re

from PIL import Image, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
LEVELS = [1, 96, 170, 254]


def parse_lua_table(text):
    """Parse the generated geometry file (a literal Lua table) as JSON."""
    body = text[text.index('return ') + 7:].strip()
    body = re.sub(r'\["([^"]+)"\]=', r'"\1":', body)
    out, stack = [], []
    for index, char in enumerate(body):
        if char == '{':
            keyed = re.match(r'\s*"[^"]*":', body[index + 1:]) is not None
            stack.append(keyed)
            out.append('{' if keyed else '[')
        elif char == '}':
            out.append('}' if stack.pop() else ']')
        else:
            out.append(char)
    return json.loads(''.join(out))


def raster(icon):
    size = icon['sample']
    image = Image.new('RGBA', (size, size))
    pixels = image.load()
    for x, y, w, h, colour in icon['rectangles']:
        rgba = tuple(icon['palette'][colour - 1])
        for yy in range(y, y + h):
            for xx in range(x, x + w):
                pixels[xx, yy] = rgba
    return image


def merged_rectangles(pixels, width, height):
    """Exact non-overlapping cover: merge identical horizontal runs vertically."""
    active, result = {}, []
    for y in range(height):
        row, x = [], 0
        while x < width:
            colour, end = pixels[y * width + x], x + 1
            while end < width and pixels[y * width + end] == colour:
                end += 1
            row.append((x, end - x, colour))
            x = end
        following = {}
        for key in row:
            rect = active.pop(key, None)
            if rect is None:
                rect = [key[0], y, key[1], 1, key[2] + 1]
            else:
                rect[3] += 1
            following[key] = rect
        result.extend(active.values())
        active = following
    result.extend(active.values())
    return sorted(result, key=lambda r: (r[1], r[0], r[4]))


def upscale(icon, sample=64, blur=1.2):
    if icon['sample'] != 32:
        raise ValueError('32px source icons required')
    grey = raster(icon).convert('L')
    big = grey.resize((sample * 4, sample * 4), Image.Resampling.BICUBIC).filter(ImageFilter.GaussianBlur(blur))
    small = big.resize((sample, sample), Image.Resampling.BOX)
    levels = [min(range(len(LEVELS)), key=lambda i: abs(LEVELS[i] - value)) for value in small.getdata()]
    used = sorted(set(levels))
    remap = {value: index for index, value in enumerate(used)}
    rectangles = merged_rectangles([remap[value] for value in levels], sample, sample)
    if len(rectangles) > 1024:
        raise ValueError('icon rectangle budget exceeded')
    return {'sample': sample, 'palette': [[LEVELS[value]] * 3 + [255] for value in used], 'rectangles': rectangles}


def lua(value):
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=True)
    if isinstance(value, (int, float)):
        return repr(value)
    if isinstance(value, list):
        return '{' + ','.join(lua(v) for v in value) + '}'
    return '{' + ','.join('[' + lua(k) + ']=' + lua(v) for k, v in value.items()) + '}'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=ROOT / 'src/passive_icon_geometry.lua')
    parser.add_argument('--output', type=Path, default=ROOT / 'src/passive_icon_geometry_hd.lua')
    args = parser.parse_args()
    data = parse_lua_table(args.source.read_text(encoding='utf-8'))
    icons = {key: upscale(icon) for key, icon in sorted(data['icons'].items())}
    args.output.write_text('-- Smoothed 64px derivative of passive_icon_geometry.lua (tools/upscale_passive_icon_geometry.py).\n'
                           'return ' + lua({'schema_version': 1, 'sample': 64, 'icons': icons}) + '\n', encoding='utf-8', newline='\n')
    counts = [len(icon['rectangles']) for icon in icons.values()]
    print(f'Derived {len(icons)} icons: {sum(counts)} rectangles, max {max(counts)}, {args.output.stat().st_size} Lua bytes')


if __name__ == '__main__':
    main()
