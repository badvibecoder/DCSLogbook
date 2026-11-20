"""Generate the DCS Logbook application icon.

Run with Pillow available:

    python tools/icon/make_icon.py

Writes assets/dcslogbook.ico (multi-size). The look mirrors the DCS World
icon: near-black rounded square with heavy yellow lettering, but "LOG".
"""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "assets" / "dcslogbook.ico"
PREVIEW = ROOT / "docs" / "icon.png"

MASTER = 256
BG = (24, 24, 24, 255)
EDGE = (52, 52, 52, 255)
YELLOW = (242, 165, 26, 255)
FONT = "C:/Windows/Fonts/ariblk.ttf"
TEXT = "LOG"
SIZES = [(16, 16), (20, 20), (24, 24), (32, 32), (40, 40), (48, 48), (64, 64), (128, 128), (256, 256)]


def render_master() -> Image.Image:
    img = Image.new("RGBA", (MASTER, MASTER), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    radius = int(MASTER * 0.22)
    draw.rounded_rectangle(
        [0, 0, MASTER - 1, MASTER - 1],
        radius=radius,
        fill=BG,
        outline=EDGE,
        width=max(1, MASTER // 128),
    )

    target_w = int(MASTER * 0.70)
    size = MASTER
    font = ImageFont.truetype(FONT, size)
    while size > 8:
        font = ImageFont.truetype(FONT, size)
        box = draw.textbbox((0, 0), TEXT, font=font)
        if box[2] - box[0] <= target_w:
            break
        size -= 2

    tracking = int(size * 0.035)
    widths = [draw.textlength(ch, font=font) for ch in TEXT]
    total = sum(widths) + tracking * (len(TEXT) - 1)
    box = draw.textbbox((0, 0), TEXT, font=font)
    height = box[3] - box[1]

    x = (MASTER - total) / 2
    y = (MASTER - height) / 2 - box[1]
    for ch, width in zip(TEXT, widths):
        draw.text((x, y), ch, font=font, fill=YELLOW)
        x += width + tracking
    return img


def main() -> None:
    master = render_master()
    OUT.parent.mkdir(parents=True, exist_ok=True)
    master.save(OUT, format="ICO", sizes=SIZES)
    master.save(PREVIEW, format="PNG")
    print(f"wrote {OUT} ({OUT.stat().st_size} bytes)")
    print(f"wrote {PREVIEW}")


if __name__ == "__main__":
    main()
