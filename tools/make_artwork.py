#!/usr/bin/env python3
"""Draw AppleBacon's own icon and banner (no third-party artwork).

Outputs assets/applebacon-icon.png (1024x1024) and assets/applebacon-banner.png (1600x900).
"""
import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parents[1]
YELLOW = (255, 231, 16)
INK = (14, 16, 19)
STEEL = (38, 43, 49)
APPLE = (214, 38, 44)
APPLE_DARK = (150, 20, 28)
LEAF = (92, 184, 64)
STEM = (96, 62, 36)
MEAT = (178, 52, 50)
MEAT_DARK = (122, 30, 34)
FAT = (246, 196, 178)
FONT = 'C:/Windows/Fonts/bahnschrift.ttf'


def font(size, weight=700):
    face = ImageFont.truetype(FONT, size)
    try:
        face.set_variation_by_axes([weight, 100])  # Bahnschrift: weight, width
    except Exception:
        pass
    return face


def hazard(image, box, stripe, colour=YELLOW, ink=INK):
    # Diagonal warning stripes, clipped to the box.
    x0, y0, x1, y1 = box
    w, h = x1 - x0, y1 - y0
    band = Image.new('RGB', (w, h), ink)
    draw = ImageDraw.Draw(band)
    for start in range(-h, w + h, stripe * 2):
        draw.polygon([(start, h), (start + stripe, h), (start + stripe + h, 0), (start + h, 0)], fill=colour)
    image.paste(band, (x0, y0))


def apple(draw, c, s):
    # Two upper lobes and a rounder base make the apple; a dark notch at the top.
    for dx in (-0.13, 0.13):
        draw.ellipse([c + (dx - 0.27) * s, c - 0.25 * s, c + (dx + 0.27) * s, c + 0.27 * s], fill=APPLE)
    draw.ellipse([c - 0.38 * s, c - 0.15 * s, c + 0.38 * s, c + 0.36 * s], fill=APPLE)
    draw.ellipse([c + 0.08 * s, c - 0.17 * s, c + 0.26 * s, c + 0.02 * s], fill=(236, 92, 88))  # highlight
    draw.ellipse([c - 0.06 * s, c - 0.29 * s, c + 0.06 * s, c - 0.19 * s], fill=APPLE_DARK)
    draw.line([(c, c - 0.22 * s), (c + 0.03 * s, c - 0.42 * s)], fill=STEM, width=max(2, int(s * 0.045)))
    leaf = [(c + 0.04 * s, c - 0.33 * s), (c + 0.16 * s, c - 0.46 * s), (c + 0.31 * s, c - 0.43 * s),
            (c + 0.2 * s, c - 0.32 * s)]
    draw.polygon(leaf, fill=LEAF)


def bacon(draw, c, s):
    # A wavy strip across the apple: dark edges, red meat, a pale fat stripe.
    def edge(offset, steps=60):
        points = []
        for i in range(steps + 1):
            t = i / steps
            x = c + (t - 0.5) * 0.96 * s
            y = c + 0.18 * s - (t - 0.5) * 0.5 * s + math.sin(t * math.pi * 3) * 0.05 * s + offset * s
            points.append((x, y))
        return points

    def band(top, bottom, colour):
        draw.polygon(edge(top) + edge(bottom)[::-1], fill=colour)

    band(-0.105, 0.105, INK)
    band(-0.085, 0.085, MEAT_DARK)
    band(-0.065, 0.065, MEAT)
    band(-0.02, 0.02, FAT)
    band(-0.055, -0.04, FAT)


def emblem(size):
    big = size * 2  # drawn at double size, then smoothed down
    image = Image.new('RGBA', (big, big), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    c = big / 2
    draw.ellipse([c - big * 0.47, c - big * 0.47, c + big * 0.47, c + big * 0.47], fill=YELLOW)
    draw.ellipse([c - big * 0.43, c - big * 0.43, c + big * 0.43, c + big * 0.43], fill=INK)
    apple(draw, c, big)
    bacon(draw, c, big)
    return image.resize((size, size), Image.Resampling.LANCZOS)


def fitted(draw, text, width, size):
    while size > 20 and draw.textlength(text, font=font(size)) > width:
        size -= 4
    return font(size)


def icon(path):
    size = 1024
    image = Image.new('RGB', (size, size), INK)
    draw = ImageDraw.Draw(image)
    draw.rectangle([0, 0, size, size], fill=STEEL)
    draw.rectangle([28, 28, size - 28, size - 28], fill=INK)
    hazard(image, (28, size - 150, size - 28, size - 28), 46)
    mark = emblem(620)
    image.paste(mark, ((size - 620) // 2, 72), mark)
    text = 'APPLEBACON'
    title = fitted(draw, text, size - 140, 150)
    width = draw.textlength(text, font=title)
    draw.rectangle([(size - width) / 2 - 24, 716, (size + width) / 2 + 24, 866], fill=INK)
    draw.text(((size - width) / 2, 724), text, font=title, fill=YELLOW)
    image.save(path, optimize=True)


def banner(path):
    w, h = 1600, 900
    image = Image.new('RGB', (w, h), INK)
    draw = ImageDraw.Draw(image)
    for x in range(0, w, 64):
        draw.line([(x, 0), (x, h)], fill=(22, 25, 29), width=1)
    for y in range(0, h, 64):
        draw.line([(0, y), (w, y)], fill=(22, 25, 29), width=1)
    hazard(image, (0, 0, w, 44), 34)
    hazard(image, (0, h - 44, w, h), 34)
    glow = Image.new('RGBA', (w, h), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse([140, 170, 700, 730], fill=(255, 231, 16, 70))
    image.paste(glow.filter(ImageFilter.GaussianBlur(70)), (0, 0), glow.filter(ImageFilter.GaussianBlur(70)))
    mark = emblem(520)
    image.paste(mark, (160, 190), mark)
    draw = ImageDraw.Draw(image)
    draw.text((760, 250), 'APPLEBACON', font=fitted(draw, 'APPLEBACON', 780, 170), fill=YELLOW)
    draw.text((768, 470), 'LOOK  ·  STATS  ·  PASSIVE', font=font(54, 600), fill=(236, 236, 236))
    draw.text((768, 548), 'Build your own armor from what you own.', font=font(40, 400), fill=(170, 176, 182))
    draw.rectangle([768, 640, 1100, 646], fill=YELLOW)
    image.save(path, optimize=True)


if __name__ == '__main__':
    (ROOT / 'assets').mkdir(exist_ok=True)
    icon(ROOT / 'assets/applebacon-icon.png')
    banner(ROOT / 'assets/applebacon-banner.png')
    print('assets/applebacon-icon.png, assets/applebacon-banner.png')
