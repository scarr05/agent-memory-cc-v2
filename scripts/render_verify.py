"""render_verify.py — render a .drawio file to an auto-cropped PNG in one command.

Usage: python render_verify.py diagram.drawio [page-index]
Prints the PNG path on success. Replaces the manual render->crop->inspect loop
(audit: 9 cycles for one diagram).
"""
import subprocess, sys, tempfile
from pathlib import Path
from PIL import Image, ImageChops

DRAWIO = r"C:\Program Files\draw.io\draw.io.exe"

def autocrop(img, margin=10):
    bg = Image.new(img.mode, img.size, (255, 255, 255))
    bbox = ImageChops.difference(img.convert("RGB"), bg.convert("RGB")).getbbox()
    if not bbox:
        return img
    left, top, right, bottom = bbox
    left = max(0, left - margin); top = max(0, top - margin)
    right = min(img.width, right + margin); bottom = min(img.height, bottom + margin)
    return img.crop((left, top, right, bottom))

def main():
    src = Path(sys.argv[1]).resolve()
    page = sys.argv[2] if len(sys.argv) > 2 else "0"
    out = Path(tempfile.gettempdir()) / f"{src.stem}-p{page}.png"
    subprocess.run(
        [DRAWIO, "--export", "--format", "png", "--scale", "2",
         "--page-index", page, "--output", str(out), str(src)],
        check=True, capture_output=True)
    img = Image.open(out)
    autocrop(img).save(out)
    print(out)

if __name__ == "__main__":
    main()
