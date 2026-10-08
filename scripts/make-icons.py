#!/usr/bin/env python3
"""Writes every icon of the project from one glyph.

    python3 scripts/make-icons.py

Produces the SVG masters in assets/icon, the macOS icon set, the Android
adaptive icon and the icons of the web interface. PNGs are rendered with
headless Chrome and scaled with sips, so this runs on a Mac with Chrome.
"""
import json
import math
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
TOP, BOTTOM = "#4f8fff", "#2456d6"
GRADIENT = (
    f'<linearGradient id="g" x1="0" y1="0" x2="0" y2="1">'
    f'<stop offset="0" stop-color="{TOP}"/><stop offset="1" stop-color="{BOTTOM}"/></linearGradient>'
)
# The glyph lives in a 108-unit square, centred on (54, 54): a checked row and
# two open ones. (cy, bar width, checked)
ROWS = [(39, 29, True), (54, 29, False), (69, 20, False)]
CX, BAR_X, BAR_H = 36.5, 48, 5.2
ANDROID_SCALE = 1.1


def glyph(scale):
    offset = round(54 - 54 * scale, 3)
    parts = [f'<g transform="translate({offset} {offset}) scale({scale})">']
    for cy, width, checked in ROWS:
        if checked:
            parts.append(f'<circle cx="{CX}" cy="{cy}" r="6.2" fill="#fff"/>')
            parts.append(
                f'<path d="M{CX - 3.1} {cy + 0.2}l2.2 2.2 4.1-4.4" fill="none" stroke="#2f6fed" '
                'stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"/>'
            )
        else:
            parts.append(f'<circle cx="{CX}" cy="{cy}" r="5.1" fill="none" stroke="#fff" stroke-width="2.2" opacity=".9"/>')
        opacity = "" if checked else ' opacity=".9"'
        parts.append(f'<rect x="{BAR_X}" y="{cy - BAR_H / 2}" width="{width}" height="{BAR_H}" rx="{BAR_H / 2}" fill="#fff"{opacity}/>')
    parts.append("</g>")
    return "\n  ".join(parts)


def svg(view, body):
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {view} {view}">\n  {body}\n</svg>\n'


def masters():
    square = svg(108, f'<defs>{GRADIENT}</defs>\n  <rect width="108" height="108" fill="url(#g)"/>\n  {glyph(1.3)}')
    rounded = svg(108, f'<defs>{GRADIENT}</defs>\n  <rect width="108" height="108" rx="24" fill="url(#g)"/>\n  {glyph(1.45)}')
    # macOS draws no mask of its own: the rounded square of the system grid
    # (824 of 1024) and its shadow are part of the picture.
    inner = glyph(1.45).replace("<g transform=", '<g transform="translate(100 100) scale(7.6296)"><g transform=', 1) + "</g>"
    shadow = '<filter id="s" x="-10%" y="-10%" width="120%" height="125%"><feDropShadow dx="0" dy="10" stdDeviation="12" flood-opacity=".28"/></filter>'
    macos = svg(1024, f'<defs>{GRADIENT}{shadow}</defs>\n  <rect x="100" y="100" width="824" height="824" rx="186" fill="url(#g)" filter="url(#s)"/>\n  {inner}')
    out = ROOT / "assets/icon"
    out.mkdir(parents=True, exist_ok=True)
    (out / "icon-square.svg").write_text(square)
    (out / "icon-macos.svg").write_text(macos)
    (ROOT / "web/src/icon.svg").write_text(rounded)
    return out / "icon-square.svg", out / "icon-macos.svg"


def render(source, target):
    subprocess.run(
        [CHROME, "--headless", "--disable-gpu", "--hide-scrollbars", "--default-background-color=00000000",
         "--window-size=1024,1024", f"--screenshot={target}", source.as_uri()],
        check=True, timeout=60, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def scaled(source, size, target):
    subprocess.run(["sips", "-z", str(size), str(size), str(source), "--out", str(target)], check=True, stdout=subprocess.DEVNULL)


def macos(big):
    out = ROOT / "apple/App/Assets.xcassets/AppIcon.appiconset"
    out.mkdir(parents=True, exist_ok=True)
    (out.parent / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    images = []
    for points in (16, 32, 128, 256, 512):
        for factor in (1, 2):
            name = f"icon-{points * factor}.png"
            scaled(big, points * factor, out / name)
            images.append({"idiom": "mac", "size": f"{points}x{points}", "scale": f"{factor}x", "filename": name})
    (out / "Contents.json").write_text(json.dumps({"images": images, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")


def web(big, rounded_big):
    out = ROOT / "web/src"
    scaled(rounded_big, 32, out / "icon-32.png")
    for size in (180, 192, 512):
        scaled(big, size, out / f"icon-{size}.png")


def check_outline(cy):
    """The check mark as a closed outline, to cut it out of the disc."""
    half = 0.95
    a, b, c = (CX - 3.1, cy + 0.2), (CX - 0.9, cy + 2.4), (CX + 3.2, cy - 2.0)

    def unit(p, q):
        length = math.hypot(q[0] - p[0], q[1] - p[1])
        return (q[0] - p[0]) / length, (q[1] - p[1]) / length

    def side(sign):
        (ux, uy), (vx, vy) = unit(a, b), unit(b, c)
        # Offset both segments to one side and join them where the offsets meet.
        p = (a[0] - ux * half - uy * half * sign, a[1] - uy * half + ux * half * sign)
        q = (c[0] + vx * half - vy * half * sign, c[1] + vy * half + vx * half * sign)
        t = ((q[0] - p[0]) * vy - (q[1] - p[1]) * vx) / (ux * vy - uy * vx)
        return [p, (p[0] + ux * t, p[1] + uy * t), q]

    points = side(1) + side(-1)[::-1]
    return "M" + "L".join(f"{x:.2f},{y:.2f}" for x, y in points) + "z"


def android_paths(monochrome):
    paths = []
    for cy, width, checked in ROWS:
        if checked:
            r = 6.2
            disc = f"M{CX - r},{cy}a{r},{r} 0,1 0,{2 * r},0a{r},{r} 0,1 0,-{2 * r},0z"
            if monochrome:
                paths.append(f'        <path android:fillColor="#FFFFFFFF" android:fillType="evenOdd" android:pathData="{disc}{check_outline(cy)}" />')
            else:
                paths.append(f'        <path android:fillColor="#FFFFFFFF" android:pathData="{disc}" />')
                paths.append(f'        <path android:strokeColor="#FF2F6FED" android:strokeWidth="1.9" android:strokeLineCap="round" android:strokeLineJoin="round" android:pathData="M{CX - 3.1},{cy + 0.2}l2.2,2.2 4.1,-4.4" />')
        else:
            r = 5.1
            paths.append(f'        <path android:strokeColor="#FFFFFFFF" android:strokeWidth="2.2" android:strokeAlpha="0.9" android:pathData="M{CX - r},{cy}a{r},{r} 0,1 0,{2 * r},0a{r},{r} 0,1 0,-{2 * r},0z" />')
        h, y = BAR_H, cy - BAR_H / 2
        alpha = "" if checked else ' android:fillAlpha="0.9"'
        paths.append(f'        <path android:fillColor="#FFFFFFFF"{alpha} android:pathData="M{BAR_X + h / 2},{y}h{width - h}a{h / 2},{h / 2} 0,0 1,0,{h}h-{width - h}a{h / 2},{h / 2} 0,0 1,0,-{h}z" />')
    return "\n".join(paths)


def android():
    res = ROOT / "android/app/src/main/res"
    # A launcher may cut everything outside a circle of radius 33 around the
    # centre. The corners of the glyph are 29.25 units away, so 1.1 keeps them
    # inside; AdaptiveIconTest checks the result.
    for name, monochrome in (("ic_launcher_foreground", False), ("ic_launcher_monochrome", True)):
        (res / f"drawable/{name}.xml").write_text(f'''<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="108"
    android:viewportHeight="108">
    <group
        android:pivotX="54"
        android:pivotY="54"
        android:scaleX="{ANDROID_SCALE}"
        android:scaleY="{ANDROID_SCALE}">
{android_paths(monochrome)}
    </group>
</vector>
''')
    (res / "drawable/ic_launcher_background.xml").write_text(f'''<?xml version="1.0" encoding="utf-8"?>
<shape xmlns:android="http://schemas.android.com/apk/res/android">
    <gradient
        android:angle="270"
        android:startColor="{TOP}"
        android:endColor="{BOTTOM}" />
</shape>
''')
    (res / "mipmap-anydpi-v26/ic_launcher.xml").write_text('''<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@drawable/ic_launcher_background" />
    <foreground android:drawable="@drawable/ic_launcher_foreground" />
    <monochrome android:drawable="@drawable/ic_launcher_monochrome" />
</adaptive-icon>
''')


def main():
    square, mac = masters()
    with tempfile.TemporaryDirectory() as tmp:
        tmp = pathlib.Path(tmp)
        render(mac, tmp / "macos.png")
        render(square, tmp / "square.png")
        render(ROOT / "web/src/icon.svg", tmp / "rounded.png")
        macos(tmp / "macos.png")
        web(tmp / "square.png", tmp / "rounded.png")
    android()


if __name__ == "__main__":
    main()
