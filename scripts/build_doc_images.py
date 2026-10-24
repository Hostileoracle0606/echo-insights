"""Builds the composite images in docs/assets/readme/ from preview captures.

Run after `flutter test test/preview_capture_test.dart`:

    python3 scripts/build_doc_images.py

Needs Pillow (`pip install Pillow`).
"""
import os
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
A = ROOT + "/docs/assets/"
OUT = A + "readme/"
PAPER = (241, 234, 220)

def rounded(im, r):
    m = Image.new("L", im.size, 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, im.size[0]-1, im.size[1]-1], r, fill=255)
    out = Image.new("RGBA", im.size); out.paste(im, (0, 0), m); return out

def phone(path, w, crop_h=None):
    im = Image.open(A + path).convert("RGB")
    if crop_h: im = im.crop((0, 0, im.width, min(im.height, int(im.width*crop_h))))
    im = im.resize((w, int(im.height * w / im.width)), Image.LANCZOS)
    return rounded(im, int(w*0.09))

def sheet(paths, w, gap, pad, name, crop_h=None, offsets=None):
    ims = [phone(p, w, crop_h) for p in paths]
    H = max(i.height for i in ims) + max(offsets or [0])
    W = len(ims)*w + (len(ims)-1)*gap + 2*pad
    canvas = Image.new("RGBA", (W, H + 2*pad), PAPER + (255,))
    for k, im in enumerate(ims):
        x = pad + k*(w+gap); y = pad + (offsets[k] if offsets else 0)
        sh = Image.new("RGBA", canvas.size, (0,0,0,0))
        ImageDraw.Draw(sh).rounded_rectangle([x+6, y+14, x+im.width+6, y+im.height+14], int(w*0.09), fill=(60,40,20,70))
        canvas = Image.alpha_composite(canvas, sh.filter(ImageFilter.GaussianBlur(14)))
        canvas.paste(im, (x, y), im)
    canvas.convert("RGB").save(OUT + name, optimize=True)
    print(name, canvas.size)

def strip(paths, w, gap, pad, name):
    ims = [rounded(Image.open(A+p).convert("RGB").resize((w, int(Image.open(A+p).height*w/Image.open(A+p).width)), Image.LANCZOS), 28) for p in paths]
    H = sum(i.height for i in ims) + gap*(len(ims)-1) + 2*pad
    c = Image.new("RGB", (w+2*pad, H), PAPER); y = pad
    for im in ims: c.paste(im, (pad, y), im); y += im.height + gap
    c.save(OUT + name, optimize=True); print(name, c.size)

os.makedirs(OUT, exist_ok=True)
sheet(["preview-dashboard.png", "preview-journal-screen.png", "preview-split-screen.png", "preview-card-just-talk.png"], 360, 40, 60, "hero.png", offsets=[0, 40, 0, 40])
sheet(["preview-card-just-talk-full.png", "preview-card-debrief-full.png"], 360, 40, 50, "closing-cards.png", crop_h=2.0)
strip(["preview-voice-dock-idle.png", "preview-voice-dock-listening.png", "preview-voice-dock-speaking.png", "preview-voice-dock-thinking.png"], 600, 24, 30, "voice-dock-states.png")

root = ROOT
font = lambda s: ImageFont.truetype(root + "/assets/fonts/Inter.ttf", s)
serif = lambda s: ImageFont.truetype(root + "/assets/fonts/Fraunces.ttf", s)
core = [("paper","#F9F5EC"),("card","#FEFBF6"),("ink","#17100C"),("amber","#EB881F"),("amberSoft","#F2D1AD"),("sage","#527D65"),("secondary","#EAE4DA"),("border","#D5CCC1"),("mutedFg","#564B42"),("destructive","#CC272E")]
ent = [("person","#C97B3A"),("place","#5B8A72"),("organization","#7A6DC4"),("project","#C0A040"),("event","#CF6A52"),("activity","#4AA39E"),("concept","#4A7AB8"),("emotion","#B85A8A"),("other","#8A8A8A")]
W, pad, sw, gap = 1500, 60, 120, 24
H = 640
im = Image.new("RGB", (W, H), "#F9F5EC"); d = ImageDraw.Draw(im)
def row(title, items, y, circle=False):
    d.text((pad, y), title, font=font(20), fill="#564B42")
    y += 44
    for i, (n, c) in enumerate(items):
        x = pad + i * (sw + gap)
        if circle: d.ellipse([x+20, y, x+100, y+80], fill=c, outline="#D5CCC1")
        else: d.rounded_rectangle([x, y, x+sw, y+90], 18, fill=c, outline="#D5CCC1", width=2)
        d.text((x, y+104), n, font=font(19), fill="#17100C")
        d.text((x, y+130), c, font=font(16), fill="#564B42")
    return y + 190
d.text((pad, 40), "Lumen palette", font=serif(52), fill="#17100C")
tw = d.textlength("Lumen palette", font=serif(52)); d.text((pad+tw+2, 40), ".", font=serif(52), fill="#EB881F")
y = row("CORE TOKENS · lib/theme/lumen_colors.dart", core, 140)
y = row("ENTITY TYPES · LumenColors.entityColors", ent, y + 20, circle=True)
im.save(root + "/docs/assets/readme/palette.png", optimize=True); print(im.size)
