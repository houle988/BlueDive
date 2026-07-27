# Dive Gear Icon Processing Guide

This document describes the complete workflow for adding or updating gear manufacturer brand images in the Gear tab's icon system.

---

## Overview

Each gear item in the Gear List shows a 44pt circular icon. When the item's `manufacturer` field matches a known brand, a brand logo image is shown. Otherwise the icon falls back to the category SF Symbol (e.g. a tank cylinder for tanks, a wetsuit figure for suits). Icons are stored as 132×132px universal PNG imagesets in the Xcode asset catalog. A `UIImage(named:)` existence check ensures that placeholder imagesets (no image yet) transparently fall back to the SF Symbol rather than showing a blank circle.

---

## Asset Catalog Location

```
BlueDive/Assets.xcassets/GearIcons/
```

Each brand has its own `.imageset` folder inside `GearIcons/`.

---

## Asset Naming Convention

Asset names follow the pattern `GearIcon_<Brand>` — brand-level only, no model suffixes:

| Brand | Asset name |
|---|---|
| Scubapro | `GearIcon_Scubapro` |
| Aqualung | `GearIcon_Aqualung` |
| Atomic Aquatics | `GearIcon_AtomicAquatics` |
| Heinrichs Weikamp | `GearIcon_HeinrichsWeikamp` |
| Light & Motion | `GearIcon_LightAndMotion` |
| Sea&Sea | `GearIcon_SeaAndSea` |

General rule: remove spaces and special characters, concatenate words in PascalCase.

---

## Icon Display in SwiftUI

```swift
Image(assetName)
    .resizable()
    .aspectRatio(contentMode: .fill)
    .frame(width: 44, height: 44)
    .clipShape(Circle())
```

The image fills a 44×44pt circle. At 3× scale that is 132px — the target PNG size. The circle clips the edges, so the logo should be centred and fill the frame.

---

## Contents.json Templates

### PNG imageset (production)

```json
{
  "images" : [
    {
      "filename" : "BrandName.png",
      "idiom" : "universal"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

### Placeholder imageset (no image yet — falls back to SF Symbol)

```json
{
  "images" : [],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

Placeholder imagesets cause `UIImage(named:)` to return `nil`, which the `imageExists()` guard in `GearIconView` detects, keeping the category SF Symbol active until a real logo is added.

---

## Standard Image Processing Pipeline

All source images — regardless of format or size — must go through this pipeline before installation.

> **Why not flood-fill?** Flood-fill from corners cannot reach enclosed letter counters (e.g. inside B, A, R, P, O). Use the colour-key approach below instead — it removes white everywhere in the image, not just connected to the edges. The RGB of transparent pixels is also zeroed to prevent white bleed on dark backgrounds.

### Step 2 — Remove white background (colour-key, distance from white)

```python
from PIL import Image
import numpy as np

img = Image.open("source.png").convert("RGBA")
data = np.array(img, dtype=np.float32)
r, g, b = data[:,:,0], data[:,:,1], data[:,:,2]

# Euclidean distance from pure white (255,255,255)
dist = np.sqrt((r - 255)**2 + (g - 255)**2 + (b - 255)**2)

# Hard cut: pixels within dist 80 of white → fully transparent.
# Zero out RGB of transparent pixels to prevent white bleed on dark backgrounds.
is_logo = dist >= 80
result = np.zeros((data.shape[0], data.shape[1], 4), dtype=np.uint8)
result[:,:,0] = np.where(is_logo, data[:,:,0], 0).astype(np.uint8)
result[:,:,1] = np.where(is_logo, data[:,:,1], 0).astype(np.uint8)
result[:,:,2] = np.where(is_logo, data[:,:,2], 0).astype(np.uint8)
result[:,:,3] = np.where(is_logo, 255, 0).astype(np.uint8)
img = Image.fromarray(result, "RGBA")
```

The threshold of 80 safely separates white/near-white backgrounds from any coloured logo (typical logo colours are 200–320 units from white). Adjust upward (100–120) if light-coloured logo elements are being clipped.

### Step 3 — Crop to non-transparent bounding box

```python
bbox = img.getbbox()
cropped = img.crop(bbox)
cw, ch = cropped.size
```

This removes all transparent padding around the logo, ensuring it fills the circle rather than appearing small.

### Step 4 — Pad to square

```python
side = max(cw, ch)
padded = Image.new("RGBA", (side, side), (0, 0, 0, 0))
padded.paste(cropped, ((side - cw) // 2, (side - ch) // 2))
```

This preserves the aspect ratio — without this step, wide or tall logos get squished into the square frame.

### Step 5 — Resize to 132×132px

```python
final = padded.resize((132, 132), Image.LANCZOS)
final.save("output.png", "PNG")
```

### Complete single-file script

```python
from PIL import Image
import numpy as np

src = "/path/to/source.webp"   # or .png, .jpg
dst = "/path/to/output.png"

img = Image.open(src).convert("RGBA")
data = np.array(img, dtype=np.float32)
r, g, b = data[:,:,0], data[:,:,1], data[:,:,2]

# Step 2: colour-key white background
dist = np.sqrt((r - 255)**2 + (g - 255)**2 + (b - 255)**2)
is_logo = dist >= 80
result = np.zeros((data.shape[0], data.shape[1], 4), dtype=np.uint8)
result[:,:,0] = np.where(is_logo, data[:,:,0], 0).astype(np.uint8)
result[:,:,1] = np.where(is_logo, data[:,:,1], 0).astype(np.uint8)
result[:,:,2] = np.where(is_logo, data[:,:,2], 0).astype(np.uint8)
result[:,:,3] = np.where(is_logo, 255, 0).astype(np.uint8)
img = Image.fromarray(result, "RGBA")
w, h = img.size

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
   cp output.png "BlueDive/Assets.xcassets/GearIcons/GearIcon_Hollis.imageset/Hollis.png"
   ```
3. Remove any existing SVG placeholder if present:
   ```bash
   rm "BlueDive/Assets.xcassets/GearIcons/GearIcon_Hollis.imageset/*.svg"
   ```
4. Update `Contents.json` to reference the PNG:
   ```json
   {
     "images" : [
       { "filename" : "Hollis.png", "idiom" : "universal" }
     ],
     "info" : { "author" : "xcode", "version" : 1 }
   }
   ```

No code changes are needed — `GearIconView` detects the new image automatically via `UIImage(named:)`.

---

## Adding a Brand New Manufacturer

1. Create the imageset folder:
   ```bash
   mkdir "BlueDive/Assets.xcassets/GearIcons/GearIcon_NewBrand.imageset"
   ```
2. Add a placeholder `Contents.json` (brand shows SF Symbol fallback until image is added):
   ```json
   { "images" : [], "info" : { "author" : "xcode", "version" : 1 } }
   ```
3. Add a matching entry in `GearIconView.assetName(forManufacturer:)` in `GearIconView.swift`:
   ```swift
   if lc.contains("newbrand") { return "GearIcon_NewBrand" }
   ```
4. When the logo image is ready, install it following the steps above.

---

## Common Issues

| Symptom | Cause | Fix |
|---|---|---|
| Logo appears too small in circle | Source image has large transparent padding | Ensure Step 3 (crop bounding box) ran correctly |
| Logo appears squished | Landscape/portrait source scaled to square without padding | Ensure Step 4 (pad to square) ran |
| Light-coloured logo parts clipped | Threshold too aggressive for a pale logo | Increase `dist` threshold from 80 to 100–120 |
| Grey/white rectangle visible on dark backgrounds | Soft-ramp or non-zeroed RGB on transparent pixels | Use hard threshold and zero out RGB of transparent pixels (see script above) |
| Blank circle shown | Placeholder imageset in catalog, image not yet added | Install PNG and update `Contents.json` |
| SF Symbol shown despite image file present | `Contents.json` still has empty `images` array | Update `Contents.json` to reference the filename |
| SF Symbol shown despite correct `Contents.json` | Asset name in code doesn't match folder name | Verify the `lc.contains(...)` entry in `GearIconView.assetName()` returns the exact folder name |

---

## Single-Tier Lookup Logic

Defined in `BlueDive/BlueDive/GearIconView.swift`:

1. **Brand substring match** — `gear.manufacturer` is lowercased and checked for known brand keywords in order. Returns the corresponding `GearIcon_*` asset name, or `nil` if no match.
2. **Image existence check** — `UIImage(named:)` confirms the asset actually contains image data. Placeholder imagesets (empty `images` array) return `nil` here, causing the SF Symbol fallback to activate.
3. **SF Symbol fallback** — the category icon from `GearCategory.icon` (e.g. `cylinder.fill` for tanks), coloured by `GearCategory.color`. Falls back to `wrench.and.screwdriver.fill` if category is unknown.

---

## Complete Brand Inventory

### Brands with logos (19) — image copied from DeviceIcons

| Asset name | Match strings |
|---|---|
| `GearIcon_Shearwater` | `shearwater` |
| `GearIcon_Suunto` | `suunto` |
| `GearIcon_Scubapro` | `scubapro` |
| `GearIcon_Mares` | `mares` |
| `GearIcon_Oceanic` | `oceanic` |
| `GearIcon_Aqualung` | `aqualung` |
| `GearIcon_Sherwood` | `sherwood` |
| `GearIcon_HeinrichsWeikamp` | `heinrichs`, `weikamp`, `ostc` |
| `GearIcon_Cressi` | `cressi` |
| `GearIcon_Divesoft` | `divesoft` |
| `GearIcon_DeepSix` | `deep six` |
| `GearIcon_Deepblu` | `deepblu` |
| `GearIcon_McLean` | `mclean` |
| `GearIcon_Oceans` | `oceans` |
| `GearIcon_Seac` | `seac` |
| `GearIcon_Halcyon` | `halcyon` |
| `GearIcon_Ratio` | `ratio` |
| `GearIcon_DiveSystem` | `divesystem`, `idive` |
| `GearIcon_Apeks` | `apeks` |

### Brands with placeholder imagesets (45) — awaiting logo

#### Wetsuits / Drysuits / Thermal

| Asset name | Match strings |
|---|---|
| `GearIcon_FourthElement` | `fourth element` |
| `GearIcon_Bare` | `bare` |
| `GearIcon_DUI` | `diving unlimited`, ` dui` |
| `GearIcon_Waterproof` | `waterproof` |
| `GearIcon_Santi` | `santi` |
| `GearIcon_OThree` | `o'three`, `o three`, `othree` |
| `GearIcon_Typhoon` | `typhoon` |
| `GearIcon_Henderson` | `henderson` |
| `GearIcon_Whites` | `whites` |
| `GearIcon_Camaro` | `camaro` |
| `GearIcon_Ursuit` | `ursuit` |

#### Regulators / BCDs / Wings

| Asset name | Match strings |
|---|---|
| `GearIcon_Poseidon` | `poseidon` |
| `GearIcon_AtomicAquatics` | `atomic` |
| `GearIcon_Zeagle` | `zeagle` |
| `GearIcon_Hollis` | `hollis` |
| `GearIcon_Xdeep` | `xdeep` |
| `GearIcon_Tecline` | `tecline` |
| `GearIcon_DiveRite` | `dive rite` |

#### Computers / Multi-category

| Asset name | Match strings |
|---|---|
| `GearIcon_Tusa` | `tusa` |
| `GearIcon_Garmin` | `garmin` |

#### Masks / Fins

| Asset name | Match strings |
|---|---|
| `GearIcon_Beuchat` | `beuchat` |
| `GearIcon_ISTSports` | `ist sports`, `ist pro` |

#### Lights / Imaging

| Asset name | Match strings |
|---|---|
| `GearIcon_Bigblue` | `bigblue`, `big blue` |
| `GearIcon_LightAndMotion` | `light & motion`, `light and motion` |
| `GearIcon_LightMonkey` | `light monkey` |
| `GearIcon_Orcatorch` | `orcatorch` |
| `GearIcon_Keldan` | `keldan` |
| `GearIcon_Ikelite` | `ikelite` |
| `GearIcon_SeaAndSea` | `sea & sea`, `sea&sea` |
| `GearIcon_Paralenz` | `paralenz` |
| `GearIcon_Nauticam` | `nauticam` |
| `GearIcon_Sola` | `sola` |
| `GearIcon_UnderwaterKinetics` | `underwater kinetics` |

#### Cylinders

| Asset name | Match strings |
|---|---|
| `GearIcon_Catalina` | `catalina` |
| `GearIcon_Faber` | `faber` |
| `GearIcon_Luxfer` | `luxfer` |
| `GearIcon_Worthington` | `worthington` |
| `GearIcon_Eurocylinder` | `eurocylinder` |

#### Other

| Asset name | Match strings |
|---|---|
| `GearIcon_Highland` | `highland` |
| `GearIcon_YRVA` | `yrva` |
| `GearIcon_Nautec` | `nautec` |
| `GearIcon_SeaDog` | `sea-dog`, `sea dog` |
| `GearIcon_XSScuba` | `xs scuba` |
| `GearIcon_Storm` | `storm` |

---

## Source File Formats Accepted

The Python Pillow pipeline accepts any format Pillow can open: `.webp`, `.png`, `.jpg`, `.jpeg`. The output is always `.png` with an RGBA channel.

Install Pillow if not present:
```bash
pip3 install Pillow
```
