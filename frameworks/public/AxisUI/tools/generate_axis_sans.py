#!/usr/bin/env python3
"""Author and rasterize Bedrock's original Axis Sans, without external fonts.

Every centerline below was drawn for this project in a 12 by 16 design grid.
The final stroke outlines have round joins and open apertures. The readable
14 by 20 base face and every larger strike are rasterized from those curves.
Eight subpixel scanlines integrate horizontal coverage without bitmap scaling.
Only Python's standard library is used. Assets and manifest share this source.
"""
import json
import math
from pathlib import Path
import re
import struct
import zlib

ROOT = Path(__file__).resolve().parent.parent
WIDTH, HEIGHT, FIRST, LAST = 14, 20, 32, 126
STROKE, SAMPLES = 1.42, 8
MAX_SCALE = 16
# Advance, original paths. Commands: move, line, cubic/quadratic curve, close.
GLYPHS = {
    ' ': (4, ''),
    'A': (9, 'M1 12 L4.5 2 L8 12 M2.3 8.5 L6.7 8.5'),
    'B': (9, 'M1.5 12 L1.5 2 L4.9 2 C8.4 2 8.4 6.6 4.9 6.6 L1.5 6.6 M4.9 6.6 C8.9 6.6 8.8 12 4.8 12 L1.5 12'),
    'C': (9, 'M7.7 3.2 C6.1 1.2 1.4 1.4 1.4 7 C1.4 12.5 6 12.8 7.8 10.9'),
    'D': (9, 'M1.5 2 L1.5 12 L4.4 12 C9.6 12 9.5 2 4.4 2 Z'),
    'E': (8, 'M6.7 2 L1.5 2 L1.5 12 L6.8 12 M1.5 6.7 L5.9 6.7'),
    'F': (8, 'M1.5 12 L1.5 2 L6.8 2 M1.5 6.6 L5.9 6.6'),
    'G': (10, 'M8 3.1 C6 1.1 1.4 1.7 1.4 7 C1.4 12.4 6.2 13.1 8.3 10.5 L8.3 7.5 L5.4 7.5'),
    'H': (9, 'M1.5 2 L1.5 12 M7.5 2 L7.5 12 M1.5 6.8 L7.5 6.8'),
    'I': (4, 'M2 2 L2 12'),
    'J': (7, 'M5.5 2 L5.5 9.3 C5.5 12.8 1.3 13 1 10'),
    'K': (9, 'M1.5 2 L1.5 12 M7.6 2 L1.5 8.1 M3.9 5.8 L7.9 12'),
    'L': (8, 'M1.5 2 L1.5 12 L6.9 12'),
    'M': (11, 'M1.4 12 L1.4 2 L5.5 10 L9.6 2 L9.6 12'),
    'N': (10, 'M1.5 12 L1.5 2 L8.5 12 L8.5 2'),
    'O': (10, 'M5 1.9 C9.9 1.9 9.9 12.1 5 12.1 C.1 12.1 .1 1.9 5 1.9 Z'),
    'P': (9, 'M1.5 12 L1.5 2 L4.9 2 C9.2 2 9.2 7.2 4.9 7.2 L1.5 7.2'),
    'Q': (10, 'M5 1.9 C9.9 1.9 9.9 12.1 5 12.1 C.1 12.1 .1 1.9 5 1.9 Z M5.9 9.4 L9 13.1'),
    'R': (9, 'M1.5 12 L1.5 2 L4.9 2 C9.1 2 9.1 7.1 4.9 7.1 L1.5 7.1 M4.8 7.1 L8.1 12'),
    'S': (9, 'M7.4 3 C5.9 1.3 1.5 1.2 1.5 4.2 C1.5 7.5 7.7 6.1 7.7 9.4 C7.7 12.8 3 13 1.3 11'),
    'T': (8, 'M.8 2 L7.2 2 M4 2 L4 12'),
    'U': (9, 'M1.5 2 L1.5 8.6 C1.5 13.3 7.5 13.3 7.5 8.6 L7.5 2'),
    'V': (9, 'M1 2 L4.5 12 L8 2'),
    'W': (12, 'M.9 2 L3.2 12 L6 3.4 L8.8 12 L11.1 2'),
    'X': (9, 'M1.1 2 L7.9 12 M7.9 2 L1.1 12'),
    'Y': (9, 'M1.1 2 L4.5 7.2 L7.9 2 M4.5 7.2 L4.5 12'),
    'Z': (9, 'M1.3 2 L7.7 2 L1.2 12 L7.8 12'),
    'a': (8, 'M1.6 5.9 C3.6 4.5 6.5 5 6.5 7.3 L6.5 12 M6.5 8.4 C.1 7.1 .1 12.7 4.4 12 C5.4 11.8 6.1 11.1 6.5 10.4'),
    'b': (8, 'M1.5 1.8 L1.5 12 M1.5 7.2 C3.2 3.9 6.7 4.9 6.7 8.6 C6.7 12.5 3.3 13.1 1.5 10.4'),
    'c': (7, 'M5.8 5.8 C3.7 4.2 1.2 5.4 1.2 8.5 C1.2 11.8 3.8 13 5.9 11.3'),
    'd': (8, 'M6.5 1.8 L6.5 12 M6.5 7.1 C4.9 3.9 1.3 4.8 1.3 8.6 C1.3 12.5 4.7 13.1 6.5 10.4'),
    'e': (8, 'M1.3 8.2 L6.6 8.2 C6.6 3.8 1.3 3.9 1.3 8.5 C1.3 12 4.5 13.1 6.6 11.3'),
    'f': (5, 'M2 12 L2 4.2 C2 1.8 3.2 1.2 4.5 1.8 M.7 5.2 L4.1 5.2'),
    'g': (8, 'M6.5 5.2 L6.5 11.7 C6.5 15.2 3.1 15.9 1.4 14 M6.5 7.1 C4.8 3.9 1.3 4.8 1.3 8.3 C1.3 11.9 4.8 12.8 6.5 9.9'),
    'h': (8, 'M1.5 1.8 L1.5 12 M1.5 7.2 C3.4 4.2 6.5 4.5 6.5 7.4 L6.5 12'),
    'i': (4, 'M2 5.2 L2 12 M2 2.4 L2 2.5'),
    'j': (4, 'M2.5 5.2 L2.5 12 C2.5 14.8 1.3 15.2 .4 14.6 M2.5 2.4 L2.5 2.5'),
    'k': (8, 'M1.5 1.8 L1.5 12 M6.5 5.2 L1.5 9.8 M3.8 7.7 L6.8 12'),
    'l': (4, 'M1.7 1.8 L1.7 10.6 C1.7 11.8 2.3 12.2 3 12'),
    'm': (12, 'M1.3 5.2 L1.3 12 M1.3 7 C2.6 4.1 5.8 4.6 5.8 7.3 L5.8 12 M5.8 7.1 C7.1 4.1 10.7 4.6 10.7 7.4 L10.7 12'),
    'n': (8, 'M1.5 5.2 L1.5 12 M1.5 7.2 C3.3 4.2 6.5 4.5 6.5 7.4 L6.5 12'),
    'o': (8, 'M4 5 C7.8 5 7.8 12.2 4 12.2 C.2 12.2 .2 5 4 5 Z'),
    'p': (8, 'M1.5 5.2 L1.5 15 M1.5 7.1 C3.2 4 6.7 4.8 6.7 8.5 C6.7 12.1 3.3 13 1.5 10.3'),
    'q': (8, 'M6.5 5.2 L6.5 15 M6.5 7.1 C4.8 4 1.3 4.8 1.3 8.5 C1.3 12.1 4.7 13 6.5 10.3'),
    'r': (6, 'M1.5 5.2 L1.5 12 M1.5 7.5 C2.5 5.1 4.1 4.7 5.1 5.5'),
    's': (7, 'M5.6 5.8 C4 4.6 1.4 4.5 1.4 6.7 C1.4 8.8 5.8 8 5.8 10.4 C5.8 12.6 2.5 12.7 1.1 11.4'),
    't': (5, 'M2.2 3.1 L2.2 10 C2.2 11.9 3.2 12.4 4.3 11.7 M.7 5.2 L4.3 5.2'),
    'u': (8, 'M1.5 5.2 L1.5 9.8 C1.5 12.8 4.8 13 6.5 10 L6.5 5.2 M6.5 10 L6.5 12'),
    'v': (8, 'M1.1 5.2 L4 12 L6.9 5.2'),
    'w': (11, 'M.9 5.2 L3 12 L5.5 5.5 L8 12 L10.1 5.2'),
    'x': (8, 'M1.3 5.2 L6.7 12 M6.7 5.2 L1.3 12'),
    'y': (8, 'M1 5.2 L4 12 M7 5.2 L3.8 13.3 C3.2 14.9 2.3 15.3 1.2 14.9'),
    'z': (7, 'M1.2 5.2 L5.8 5.2 L1.1 12 L5.9 12'),
    '0': (8, 'M4 2 C7.9 2 7.9 12 4 12 C.1 12 .1 2 4 2 Z M2.7 9.5 L5.3 4.5'),
    '1': (8, 'M2 4 L4.2 2 L4.2 12 M2 12 L6.5 12'),
    '2': (8, 'M1.3 4.1 C1.6 1.1 6.7 1.2 6.7 4.3 C6.7 6.7 2.6 8.4 1.2 12 L6.8 12'),
    '3': (8, 'M1.6 2.8 C3.5 1.2 6.8 1.8 6.6 4.4 C6.4 6.1 4.8 6.6 3.5 6.6 M3.5 6.6 C7.7 6.4 8.2 12 4.1 12 C2.8 12 1.8 11.6 1.2 10.8'),
    '4': (8, 'M5.6 12 L5.6 2 L1 8.8 L7.2 8.8'),
    '5': (8, 'M6.5 2 L1.8 2 L1.5 6.6 C7.8 4.5 8.4 12 4.2 12 C2.8 12 1.9 11.6 1.2 10.8'),
    '6': (8, 'M6.4 2.7 C3.1 .3 .9 4.5 1.3 8.9 C1.7 13.7 7.5 12.8 6.9 8.6 C6.5 5.7 2.8 5.2 1.4 8.1'),
    '7': (8, 'M1.2 2 L6.8 2 L3.4 12'),
    '8': (8, 'M4 2 C.2 2 .4 6.4 4 6.5 C7.6 6.4 7.8 2 4 2 Z M4 6.5 C-.1 6.5 .2 12 4 12 C7.8 12 8.1 6.5 4 6.5 Z'),
    '9': (8, 'M1.6 11.3 C4.9 13.7 7.1 9.5 6.7 5.1 C6.3 .3 .5 1.2 1.1 5.4 C1.5 8.3 5.2 8.8 6.6 5.9'),
    '!': (4, 'M2 2 L2 8.4 M2 11.6 L2 11.7'),
    '"': (6, 'M1.8 2 L1.5 4.5 M4.5 2 L4.2 4.5'),
    '#': (9, 'M3.7 2 L2.1 12 M7 2 L5.4 12 M1.4 5.3 L7.8 5.3 M.9 8.8 L7.3 8.8'),
    '$': (8, 'M6.2 3.3 C4.8 1.5 1.5 2.1 1.5 4.5 C1.5 7.5 6.4 6.1 6.4 9.3 C6.4 11.8 3 12.4 1.4 10.5 M4 1 L4 13.4'),
    '%': (12, 'M2.9 2 C.1 2 .1 6.4 2.9 6.4 C5.7 6.4 5.7 2 2.9 2 Z M9.1 7.6 C6.3 7.6 6.3 12 9.1 12 C11.9 12 11.9 7.6 9.1 7.6 Z M9.8 2 L2.2 12'),
    '&': (10, 'M8.5 7.2 C6.3 14.3 1.2 12.5 1.2 9.2 C1.2 6.6 6.4 5.3 6.4 3.5 C6.4 .9 2.4 1.3 2.4 3.9 C2.4 6.1 7.1 10.7 8.9 12'),
    "'": (3, 'M1.9 2 L1.5 4.5'),
    '(': (5, 'M3.8 1.3 C.7 4.7 .7 10.1 3.8 13.4'),
    ')': (5, 'M1.2 1.3 C4.3 4.7 4.3 10.1 1.2 13.4'),
    '*': (7, 'M3.5 2 L3.5 7 M1.2 3.3 L5.8 5.8 M5.8 3.3 L1.2 5.8'),
    '+': (9, 'M4.5 4 L4.5 11 M1 7.5 L8 7.5'),
    ',': (4, 'M2.3 11.4 C2.3 12.7 1.8 13.5 1.1 14'),
    '-': (6, 'M1.1 8 L4.9 8'),
    '.': (3, 'M1.5 11.6 L1.5 11.7'),
    '/': (6, 'M5 1.6 L1 13.2'),
    ':': (4, 'M2 5.7 L2 5.8 M2 11.6 L2 11.7'),
    ';': (4, 'M2 5.7 L2 5.8 M2.3 11.4 C2.3 12.7 1.8 13.5 1.1 14'),
    '<': (9, 'M7.5 4 L1.5 7.5 L7.5 11'),
    '=': (9, 'M1.5 5.5 L7.5 5.5 M1.5 9.5 L7.5 9.5'),
    '>': (9, 'M1.5 4 L7.5 7.5 L1.5 11'),
    '?': (8, 'M1.4 3.8 C1.7 .9 6.8 1.2 6.7 4 C6.6 6.1 4 6.3 4 8.5 M4 11.6 L4 11.7'),
    '@': (12, 'M8.5 5.2 L8 9.3 C7.7 11.7 11 11 11 6.3 C11 .1 .9 .1 .9 7.4 C.9 13.5 7.3 14.2 9.5 12.5 M8.3 6.6 C6.9 3.7 3.7 4.9 3.5 8.4 C3.3 11.4 6.5 11.5 8 8.7'),
    '[': (5, 'M3.9 1.7 L1.6 1.7 L1.6 13.2 L3.9 13.2'),
    '\\': (6, 'M1 1.6 L5 13.2'),
    ']': (5, 'M1.1 1.7 L3.4 1.7 L3.4 13.2 L1.1 13.2'),
    '^': (9, 'M1.6 6.5 L4.5 2 L7.4 6.5'),
    '_': (8, 'M.9 14 L7.1 14'),
    '`': (4, 'M1 1.6 L2.8 3.2'),
    '{': (6, 'M4.6 1.4 C2.8 1.4 2.5 2.6 2.5 4.6 C2.5 6.4 2.2 7.1 1.1 7.5 C2.2 7.9 2.5 8.6 2.5 10.4 C2.5 12.4 2.8 13.6 4.6 13.6'),
    '|': (4, 'M2 1.2 L2 14'),
    '}': (6, 'M1.4 1.4 C3.2 1.4 3.5 2.6 3.5 4.6 C3.5 6.4 3.8 7.1 4.9 7.5 C3.8 7.9 3.5 8.6 3.5 10.4 C3.5 12.4 3.2 13.6 1.4 13.6'),
    '~': (9, 'M1.2 8.4 C3.1 4.5 5.9 11.5 7.8 7.6'),
}


def segments(path):
    tokens = re.findall(r'[MLCQZ]|-?(?:\d*\.\d+|\d+)', path)
    result, index, here, origin = [], 0, (0., 0.), (0., 0.)
    while index < len(tokens):
        command = tokens[index]; index += 1
        count = {'M': 2, 'L': 2, 'C': 6, 'Q': 4, 'Z': 0}[command]
        values = tuple(float(value) for value in tokens[index:index + count]); index += count
        if command == 'M':
            here = origin = values
        elif command == 'L' or command == 'Z':
            end = values if command == 'L' else origin
            result.append((*here, *end)); here = end
        else:
            start = here
            end = values[-2:]
            for step in range(1, 25):
                t = step / 24; u = 1 - t
                if command == 'C':
                    point = tuple(u**3 * start[c] + 3*u*u*t * values[c] + 3*u*t*t * values[c+2] + t**3 * end[c] for c in (0, 1))
                else:
                    point = tuple(u*u * start[c] + 2*u*t * values[c] + t*t * end[c] for c in (0, 1))
                result.append((*here, *point)); here = point
    return result


def outline(char):
    """Keep original curves, with a larger lowercase reading size."""
    def point(x, y):
        if char.islower():
            if 2 < y < 5:
                y = 2 + (y - 2) * 2.5 / 3
            elif 5 <= y < 12:
                y = 4.5 + (y - 5) * 7.5 / 7
        return x * 7 / 6, y * 1.2 + .6
    return [(*point(x1, y1), *point(x2, y2))
            for x1, y1, x2, y2 in segments(GLYPHS[char][1])]


def rasterize(edges, advance, scale):
    """Integrate the union of round stroked segments at the target size.

    Horizontal span coverage is analytic; only the vertical direction is
    sampled. Intervals are united before integration, so overlaps at joins
    never accumulate darker coverage. No intermediate low-resolution raster
    is enlarged, including at the largest supported size.
    """
    width, height = advance * scale, HEIGHT * scale
    spans = [[] for _ in range(height * SAMPLES)]
    radius = STROKE * scale / 2
    endpoints = set()
    def rows(low, high):
        start = max(0, math.ceil(low * SAMPLES - .5))
        end = min(len(spans), math.ceil(high * SAMPLES - .5))
        return range(start, end)
    for edge in edges:
        x1, y1, x2, y2 = (value * scale for value in edge)
        endpoints.update(((x1, y1), (x2, y2)))
        dx, dy = x2 - x1, y2 - y1
        length = math.hypot(dx, dy)
        if length == 0:
            continue
        nx, ny = -dy * radius / length, dx * radius / length
        corners = ((x1 + nx, y1 + ny), (x2 + nx, y2 + ny),
                   (x2 - nx, y2 - ny), (x1 - nx, y1 - ny))
        sides = tuple(zip(corners, corners[1:] + corners[:1]))
        for row in rows(min(y for _, y in corners), max(y for _, y in corners)):
            y = (row + .5) / SAMPLES
            hits = [ax + (y - ay) * (bx - ax) / (by - ay)
                    for (ax, ay), (bx, by) in sides
                    if min(ay, by) <= y < max(ay, by)]
            if hits:
                spans[row].append((min(hits), max(hits)))
    for x, y in sorted(endpoints):
        for row in rows(y - radius, y + radius):
            half = math.sqrt(max(0., radius * radius - ((row + .5) / SAMPLES - y)**2))
            spans[row].append((x - half, x + half))
    pixels = bytearray(width * height)
    for y in range(height):
        coverage = [0.] * width
        for row in range(y * SAMPLES, (y + 1) * SAMPLES):
            left, right = 0., 0.
            merged = []
            for lo, hi in sorted(spans[row]):
                lo, hi = max(0., lo), min(float(width), hi)
                if lo >= hi:
                    continue
                if lo > right:
                    if right > left:
                        merged.append((left, right))
                    left, right = lo, hi
                else:
                    right = max(right, hi)
            if right > left:
                merged.append((left, right))
            for lo, hi in merged:
                for x in range(math.floor(lo), min(width, math.ceil(hi))):
                    coverage[x] += min(x + 1., hi) - max(float(x), lo)
        for x, value in enumerate(coverage):
            pixels[y * width + x] = min(255, int(value * 255 / SAMPLES + .5))
    return pixels


def specimen(atlas, advances, strikes):
    width, height = 1280, 600
    pixels = bytearray(bytes((24, 27, 35)) * width * height)
    def coverage(code, x, y, scale):
        if scale == 1: return atlas[code*WIDTH*HEIGHT + y*WIDTH + x]
        return strikes[code][y * advances[code] * scale + x]
    def paint(text, x, y, foreground, scale=1):
        for byte in text.encode('ascii'):
            code = byte-FIRST
            for py in range(HEIGHT*scale):
                for px in range(advances[code]*scale):
                    alpha = coverage(code, px, py, scale)
                    if not alpha: continue
                    at = ((y+py)*width + x+px)*3
                    for c in range(3): pixels[at+c] = (foreground[c]*alpha + pixels[at+c]*(255-alpha)+127)//255
            x += advances[code]*scale
    lines = ['Files   Notes   Downloads   Rename   Save   New folder',
             'The quick brown fox jumps over the lazy dog.',
             '0123456789   () [] {} < > & ;  $ @ %',
             'Aa Bb Cc Dd Ee Ff Gg Ii Jj Ll Mm Rr Qq Ww']
    paint('Axis Sans', 32, 24, (232, 229, 220), 2)
    paint('Original curves, rasterized at each size', 32, 80, (153, 164, 179))
    for row, line in enumerate(lines): paint(line, 32, 124+row*32, (232, 229, 220))
    for y in range(280, 576):
        begin = (y*width+24)*3
        pixels[begin:begin+(1256-24)*3] = bytes((240, 242, 244))*(1256-24)
    paint('Axis Sans on a light native surface', 40, 302, (36, 39, 45), 2)
    for row, line in enumerate(lines): paint(line, 40, 370+row*36, (36, 39, 45))
    def chunk(kind, data):
        return struct.pack('>I', len(data))+kind+data+struct.pack('>I', zlib.crc32(kind+data)&0xffffffff)
    scanlines = b''.join(b'\0'+pixels[y*width*3:(y+1)*width*3] for y in range(height))
    png = b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0))
    png += chunk(b'IDAT', zlib.compress(scanlines, 9))+chunk(b'IEND', b'')
    (ROOT / 'axis-sans-specimen.png').write_bytes(png)


def main():
    assert set(GLYPHS) == {chr(code) for code in range(FIRST, LAST + 1)}
    atlas, advances = bytearray(), bytearray()
    outlines = {}
    for code in range(FIRST, LAST + 1):
        char = chr(code)
        advance = (GLYPHS[char][0] * 7 + 3) // 6
        advances.append(advance)
        outlines[char] = edges = outline(char)
        pixels = rasterize(edges, advance, 1)
        for y in range(HEIGHT):
            for x in range(WIDTH):
                atlas.append(pixels[y * advance + x] if x < advance else 0)
    (ROOT / 'src/axis_sans.bin').write_bytes(atlas)
    (ROOT / 'src/axis_sans_advances.bin').write_bytes(advances)
    vectors, offsets, double = bytearray(), [], []
    for code in range(FIRST, LAST + 1):
        offsets.append(len(vectors))
        previous = None
        for edge in outlines[chr(code)]:
            x1, y1, x2, y2 = (round(value * 64) for value in edge)
            if previous != (x1, y1):
                vectors.extend(struct.pack('<BBhh', 128, 0, x1, y1))
            dx, dy = x2 - x1, y2 - y1
            if -127 <= dx <= 127 and -128 <= dy <= 127:
                vectors.extend(struct.pack('<bb', dx, dy))
            else:
                vectors.extend(struct.pack('<BBhh', 128, 1, x2, y2))
            previous = x2, y2
        double.append(rasterize(outlines[chr(code)], advances[code - FIRST], 2))
    offsets.append(len(vectors))
    assert offsets[-1] <= 65535
    (ROOT / 'src/axis_sans_vectors.bin').write_bytes(vectors)
    (ROOT / 'src/axis_sans_vector_offsets.bin').write_bytes(struct.pack('<' + 'H' * len(offsets), *offsets))
    manifest = {'family': 'Axis Sans', 'provenance': 'Original Bedrock vector centerlines and stroke outlines; no external typeface data.',
                'source': 'tools/generate_axis_sans.py', 'coverage_asset': 'src/axis_sans.bin', 'advance_asset': 'src/axis_sans_advances.bin',
                'format': 'gray8 glyph-major, then row-major', 'first_codepoint': FIRST, 'glyph_count': LAST-FIRST+1,
                'glyph_width': WIDTH, 'glyph_height': HEIGHT, 'line_height': HEIGHT, 'baseline': 15,
                'cap_height': 12, 'x_height': 9, 'editor_advance': WIDTH, 'samples_per_axis': SAMPLES,
                'sampling': 'analytic horizontal union coverage, eight vertical subpixel samples',
                'vector_asset': 'src/axis_sans_vectors.bin', 'vector_index_asset': 'src/axis_sans_vector_offsets.bin',
                'vector_format': 'glyph-major paths; i8 dx,dy line deltas; escape 128,kind,i16le x,y (kind0 move,kind1 line); u16le byte offsets; coordinates in 1/64 pixels',
                'vector_stroke_radius': round(STROKE * 32), 'vector_samples_per_axis': 8,
                'max_scale': MAX_SCALE, 'advances': list(advances)}
    (ROOT / 'axis-sans.json').write_text(json.dumps(manifest, indent=2)+'\n', encoding='utf-8')
    specimen(atlas, advances, double)
    print(f'Axis Sans: {len(advances)} original glyphs, {len(atlas)} base bytes, {len(vectors)} vector bytes')


if __name__ == '__main__':
    main()
