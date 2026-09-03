import subprocess, sys, tempfile, os
from PIL import Image

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))
from render_verify import autocrop  # noqa: E402

def test_autocrop_strips_border():
    img = Image.new("RGB", (200, 200), "white")
    for x in range(90, 110):
        for y in range(90, 110):
            img.putpixel((x, y), (255, 0, 0))
    cropped = autocrop(img, margin=5)
    assert cropped.size == (30, 30), cropped.size  # 20px content + 2*5 margin

if __name__ == "__main__":
    test_autocrop_strips_border()
    print("PASS=1 FAIL=0")
