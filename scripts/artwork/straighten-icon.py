"""Locally remap the approved raster to align the blue stroke with the key.
Uses the original texture; all pixels outside the small repair stay unchanged.
"""
from pathlib import Path
import numpy as np
from PIL import Image

root = Path(__file__).resolve().parents[2]
source = root / 'website/assets/audiojack-keys-waveform-3d-v2.png'
out = root / 'website/assets/audiojack-keys-waveform-3d-v3.png'
im = Image.open(source).convert('RGBA')
a = np.asarray(im)
h, w = a.shape[:2]
# Fit the existing key's two side edges, below its colour transition.
ys = np.arange(575, 711)
left, right = [], []
for y in ys:
    dark = np.all(a[y, :, :3] < 100, axis=1)
    xs = np.where(dark[435:615])[0] + 435
    runs = np.split(xs, np.where(np.diff(xs) > 1)[0] + 1)
    run = max(runs, key=len)
    left.append(run[0] - .5)
    right.append(run[-1] + .5)
lf = np.polyfit(ys, left, 1)
rf = np.polyfit(ys, right, 1)
print('Key edge fits:', lf.tolist(), rf.tolist())
result = a.copy()
for y in range(320, 559):
    rgb = a[y, :, :3].astype(float)
    blue = (rgb[:,2] > 140) & (rgb[:,0] < 90) & (rgb[:,2] > rgb[:,0] * 1.8)
    bx = np.where(blue[480:750])[0] + 480
    if not len(bx):
        continue
    old_l = float(bx[0]) - .5 if y >= 360 else 597.5 + (360-y)*0.50
    new_l = float(np.polyval(lf,y))
    # Retain the horizontal waveform shelf; blend the outer border above it.
    fade = min(1., max(0., (y-320)/37))
    new_l = old_l + (new_l-old_l)*fade
    if y >= 497:
        runs = np.split(bx, np.where(np.diff(bx)>1)[0]+1)
        main = max(runs, key=len)
        if len(main) < 20:
            continue
        old_r = float(main[-1]) + .5
        new_r = float(np.polyval(rf,y))
    else:
        old_r = 630.
        shift = float(np.polyval(rf,497)) - 627.
        new_r = old_r + shift * max(0., (y-460)/37)
    # Move the two edges and white border together. Fixed outer anchors
    # keep the neighbouring keys and large waveform peaks untouched.
    src = np.array([old_l-65, old_l-24, old_l, old_r, old_r+25, old_r+65])
    dst = np.array([old_l-65, old_l-24+new_l-old_l, new_l,
                    new_r, old_r+25+new_r-old_r, old_r+65])
    lo,hi = int(np.floor(src[0])), int(np.ceil(src[-1]))+1
    xx = np.arange(lo,hi)
    mapped = np.interp(xx,dst,src)
    for c in range(4):
        result[y,lo:hi,c] = np.clip(np.interp(mapped, np.arange(w), a[y,:,c].astype(float)),0,255).round().astype('uint8')
Image.fromarray(result).save(out)
Image.fromarray(result).crop((400,310,750,760)).resize((700,900)).save('/tmp/key-after.png')
print(out)
