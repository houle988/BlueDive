# Dive Computer Icon Processing Guide

This document describes the complete workflow for adding or updating dive computer product images in the Bluetooth Scanner's device icon system.

---

## Overview

Each dive computer displayed in the Bluetooth Scanner shows a 44pt circular icon. Icons are stored as 132×132px universal PNG imagesets in the Xcode asset catalog. A two-tier lookup resolves the icon: exact model name first, then brand-level fallback, then a generic SF Symbol.

---

## Asset Catalog Location

```
BlueDive/Assets.xcassets/DeviceIcons/
```

Each device has its own `.imageset` folder inside `DeviceIcons/`.

---

## Asset Naming Convention

Asset names follow the pattern `DeviceIcon_<SanitizedName>`:

| Rule | Example |
|---|---|
| Spaces → underscores | `Perdix 2` → `DeviceIcon_Shearwater_Perdix_2` |
| `Heinrichs Weikamp` → `HeinrichsWeikamp` (no space) | `HeinrichsWeikamp_OSTC_2` |
| Strip non-alphanumeric (except `_`) | `Cosmiq+` → `DeviceIcon_Deepblu_Cosmiq` |
| Brand-level fallback | `DeviceIcon_Shearwater`, `DeviceIcon_Aqualung`, etc. |

The asset name is derived at runtime by `modelLevelAssetName()` in `BluetoothScannerComponents.swift`.

---

## Icon Display in SwiftUI

```swift
Image(assetName)
    .resizable()
    .aspectRatio(contentMode: .fill)
    .frame(width: 44, height: 44)
    .clipShape(Circle())
```

The image fills a 44×44pt circle. At 3× scale that is 132px — the target PNG size. The circle clips the edges, so the device should be centred and fill the frame.

---

## Contents.json Templates

### PNG imageset

```json
{
  "images" : [
    {
      "filename" : "ModelName.png",
      "idiom" : "universal"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

### SVG placeholder (do not use for real product images)

```json
{
  "images" : [{ "filename" : "DeviceIcon_Name.svg", "idiom" : "universal" }],
  "info" : { "author" : "xcode", "version" : 1 },
  "properties" : { "preserves-vector-representation" : true }
}
```

---

## Standard Image Processing Pipeline

All source images — regardless of format or size — must go through this pipeline before installation.

### Step 1 — Check for alpha and white background

```bash
sips -g hasAlpha /path/to/source.png
```

- **hasAlpha: yes, transparent corners** → skip to Step 3
- **hasAlpha: yes, opaque white corners** → run Step 2 (flood-fill)
- **hasAlpha: no** → run Step 2 (flood-fill)

Check corners manually if unsure:
```python
from PIL import Image
img = Image.open("source.png").convert("RGBA")
w, h = img.size
for c in [(0,0),(w-1,0),(0,h-1),(w-1,h-1)]:
    print(c, img.getpixel(c))
```

### Step 2 — Remove white/opaque background (flood-fill from corners)

```python
from PIL import Image

def flood_fill_transparent(img, seed_point, tolerance=30):
    data = img.load()
    sr, sg, sb, sa = data[seed_point]
    visited = set()
    stack = [seed_point]
    w, h = img.size
    while stack:
        x, y = stack.pop()
        if (x, y) in visited or x < 0 or y < 0 or x >= w or y >= h:
            continue
        r, g, b, a = data[x, y]
        if abs(r-sr) <= tolerance and abs(g-sg) <= tolerance and abs(b-sb) <= tolerance:
            data[x, y] = (r, g, b, 0)
            visited.add((x, y))
            stack += [(x+1,y),(x-1,y),(x,y+1),(x,y-1)]

img = Image.open("source.png").convert("RGBA")
w, h = img.size
for corner in [(0,0),(w-1,0),(0,h-1),(w-1,h-1)]:
    flood_fill_transparent(img, corner, tolerance=30)
```

Increase `tolerance` (up to ~50) if edges look ragged. Decrease it if internal white areas are being erased.

### Step 3 — Crop to non-transparent bounding box

```python
bbox = img.getbbox()
cropped = img.crop(bbox)
cw, ch = cropped.size
```

This removes all transparent padding around the device, ensuring the device fills the circle rather than appearing small.

### Step 4 — Pad to square

```python
side = max(cw, ch)
padded = Image.new("RGBA", (side, side), (0, 0, 0, 0))
padded.paste(cropped, ((side - cw) // 2, (side - ch) // 2))
```

This preserves the aspect ratio — without this step, landscape or portrait devices get squished into the square frame.

### Step 5 — Resize to 132×132px

```python
final = padded.resize((132, 132), Image.LANCZOS)
final.save("output.png", "PNG")
```

### Complete single-file script

```python
from PIL import Image

src = "/path/to/source.webp"   # or .png, .jpg
dst = "/path/to/output.png"

img = Image.open(src).convert("RGBA")
w, h = img.size

# Step 2: flood-fill white background (skip if already transparent)
def flood_fill_transparent(img, seed_point, tolerance=30):
    data = img.load()
    sr, sg, sb, sa = data[seed_point]
    visited = set()
    stack = [seed_point]
    iw, ih = img.size
    while stack:
        x, y = stack.pop()
        if (x, y) in visited or x < 0 or y < 0 or x >= iw or y >= ih:
            continue
        r, g, b, a = data[x, y]
        if abs(r-sr) <= tolerance and abs(g-sg) <= tolerance and abs(b-sb) <= tolerance:
            data[x, y] = (r, g, b, 0)
            visited.add((x, y))
            stack += [(x+1,y),(x-1,y),(x,y+1),(x,y-1)]

for corner in [(0,0),(w-1,0),(0,h-1),(w-1,h-1)]:
    flood_fill_transparent(img, corner, tolerance=30)

# Steps 3–5: crop → pad → resize
bbox = img.getbbox()
cropped = img.crop(bbox)
cw, ch = cropped.size
side = max(cw, ch)
padded = Image.new("RGBA", (side, side), (0, 0, 0, 0))
padded.paste(cropped, ((side - cw) // 2, (side - ch) // 2))
final = padded.resize((132, 132), Image.LANCZOS)
final.save(dst, "PNG")
print(f"Done: {w}x{h} source → {cw}x{ch} cropped → {side}x{side} padded → 132x132")
```

---

## Installing a New Image

1. Process the source with the pipeline above.
2. Copy the resulting PNG into the imageset folder:
   ```bash
   cp output.png "BlueDive/Assets.xcassets/DeviceIcons/DeviceIcon_Shearwater_Perdix_2.imageset/Perdix_2.png"
   ```
3. Remove any existing SVG placeholder:
   ```bash
   rm "BlueDive/Assets.xcassets/DeviceIcons/DeviceIcon_Shearwater_Perdix_2.imageset/*.svg"
   ```
4. Update `Contents.json` to reference the PNG (remove the `properties` key used by SVGs):
   ```json
   {
     "images" : [
       { "filename" : "Perdix_2.png", "idiom" : "universal" }
     ],
     "info" : { "author" : "xcode", "version" : 1 }
   }
   ```

---

## Creating a New Imageset (model not yet in catalog)

```bash
ASSETS="BlueDive/Assets.xcassets/DeviceIcons"
mkdir "$ASSETS/DeviceIcon_Shearwater_NewModel.imageset"
```

Then add the PNG and write `Contents.json` as above. No code changes are needed — the lookup in `BluetoothScannerComponents.swift` will find the asset automatically once the library adds support for that model name.

---

## Common Issues

| Symptom | Cause | Fix |
|---|---|---|
| Device appears too small in circle | Source image has large transparent padding | Ensure Step 3 (crop bounding box) ran correctly |
| Device appears squished | Landscape/portrait source scaled to square without padding | Ensure Step 4 (pad to square) ran |
| White halo around device | Flood-fill tolerance too low | Increase tolerance to 40–50 |
| Internal white areas erased | Flood-fill tolerance too high | Decrease tolerance to 20–25 |
| Icon not showing (generic fallback used) | Asset name mismatch | Verify `modelLevelAssetName()` output matches the folder name |

---

## Two-Tier Lookup Logic

Defined in `BlueDive/Bluetooth/BluetoothScannerComponents.swift`:

1. **Exact model match** — if the name matches a known `DeviceConfiguration.supportedModels` entry, `modelLevelAssetName()` builds the asset name and that image is used.
2. **Brand substring match** — if the BLE advertisement name contains a brand keyword (e.g. `"shearwater"`), the brand-level asset (e.g. `DeviceIcon_Shearwater`) is used.
3. **SF Symbol fallback** — `gauge.with.dots.needle.bottom.50percent`, or `applewatch.watchface` for Garmin.

---

## Source File Formats Accepted

The Python Pillow pipeline accepts any format Pillow can open: `.webp`, `.png`, `.jpg`, `.jpeg`. The output is always `.png` with an RGBA channel.

Install Pillow if not present:
```bash
pip3 install Pillow
```
