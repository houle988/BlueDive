# Dive Gear Icon Processing Guide

This document describes the complete workflow for adding or updating gear manufacturer brand images in the Gear tab's icon system.

---

## Overview

Each gear item shows a brand logo tile at multiple sizes throughout the app:

| Context | Size | Shape |
|---|---|---|
| Gear list row | 44 pt | Rounded-square tile |
| Manufacturer autocomplete suggestion | 28 pt | Rounded-square tile |
| Add / Edit Gear header | 80 pt | Rounded-square tile |
| Gear detail hero | 100 pt | Rounded-square tile |

When the item's `manufacturer` field matches a known brand, a brand logo image is shown on a white tile with a subtle border. Otherwise the icon falls back to the category SF Symbol (e.g. a cylinder for tanks, a wetsuit figure for suits) on a tinted background. Icons are stored as 132×132 px universal PNG imagesets in the Xcode asset catalog. A `UIImage(named:)` existence check ensures that placeholder imagesets (no image yet) transparently fall back to the SF Symbol rather than showing a blank tile.

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
| Sea & Sea | `GearIcon_SeaAndSea` |

General rule: remove spaces and special characters, concatenate words in PascalCase.

---

## Icon Display in SwiftUI

`GearIconView` renders a logo tile when the manufacturer matches a known brand, or a tinted SF Symbol tile otherwise:

```swift
// Logo tile (brand asset found)
ZStack {
    RoundedRectangle(cornerRadius: cornerRadius)
        .fill(.white)
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(.quaternary, lineWidth: 0.5)
        )
    Image(assetName)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .padding(padding)
}
.frame(width: size, height: size)
.clipShape(RoundedRectangle(cornerRadius: cornerRadius))

// SF Symbol fallback (no brand match, or placeholder imageset)
ZStack {
    RoundedRectangle(cornerRadius: cornerRadius)
        .fill(iconColor.opacity(0.15))
    Image(systemName: categoryIcon)
        .font(.system(size: symbolSize))
        .foregroundStyle(iconColor)
}
.frame(width: size, height: size)
```

The image fits inside the tile with proportional padding. At 3× scale a 44 pt tile is 132 px — the target PNG size. Logos should have a transparent background and fill most of the square frame.

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

Placeholder imagesets cause `UIImage(named:)` to return `nil`, which the `UIImage(named:) != nil` check in `GearIconView.init` detects, keeping the category SF Symbol active until a real logo is added.

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

This removes all transparent padding around the logo, ensuring it fills the tile rather than appearing small.

### Step 4 — Pad to square

```python
side = max(cw, ch)
padded = Image.new("RGBA", (side, side), (0, 0, 0, 0))
padded.paste(cropped, ((side - cw) // 2, (side - ch) // 2))
```

This preserves the aspect ratio — without this step, wide or tall logos get squished into the square frame.

### Step 5 — Resize to 132×132 px

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
3. Add one entry to `GearIconView.brandTable` in `GearIconView.swift`:
   ```swift
   Brand(name: "New Brand", tokens: ["newbrand"], asset: "GearIcon_NewBrand"),
   ```
   Tokens must be **complete lowercase strings** the user might store as manufacturer (e.g. abbreviations or alternate spellings). Entry order does not affect resolution — each lookup is an exact equality check.
   `knownManufacturers` (autocomplete list) and `assetName(forManufacturer:)` (resolver) are both automatically derived from `brandTable` — no other Swift code changes needed.
4. Add a row for the brand to the inventory table in `DIVE_GEAR_ICONS.md` under the appropriate category heading.
5. When the logo image is ready, install it following the steps above.

---

## Common Issues

| Symptom | Cause | Fix |
|---|---|---|
| Logo appears too small in tile | Source image has large transparent padding | Ensure Step 3 (crop bounding box) ran correctly |
| Logo appears squished | Landscape/portrait source scaled to square without padding | Ensure Step 4 (pad to square) ran |
| Light-coloured logo parts clipped | Threshold too aggressive for a pale logo | Increase `dist` threshold from 80 to 100–120 |
| Grey/white rectangle visible on dark backgrounds | Soft-ramp or non-zeroed RGB on transparent pixels | Use hard threshold and zero out RGB of transparent pixels (see script above) |
| Blank tile shown | Placeholder imageset in catalog, image not yet added | Install PNG and update `Contents.json` |
| SF Symbol shown despite image file present | `Contents.json` still has empty `images` array | Update `Contents.json` to reference the filename |
| SF Symbol shown despite correct `Contents.json` | Asset name in `brandTable` doesn't match folder name | Verify the `asset:` field in the `brandTable` entry matches the exact imageset folder name |

---

## Lookup Architecture

Defined in `BlueDive/BlueDive/GearIconView.swift`. All brand data lives in a single `private static let brandTable: [Brand]`. Both the autocomplete list and the asset resolver are derived from it automatically.

```
brandTable  ──►  knownManufacturers   (static let, drives manufacturer autocomplete)
            ──►  assetName(for:)      (static func, drives logo resolution)
```

### Resolution steps at runtime

1. **Exact brand match** — `gear.manufacturer` is trimmed, lowercased, and apostrophe-normalised (typographic apostrophes → ASCII `'`), then looked up in two precomputed dictionaries: one keyed by canonical name (lowercased) and one keyed by token. The first dictionary hit returns the `asset` name. For example `"DUI"` matches via the token `"dui"`; `"Diving Unlimited International"` matches via its canonical name. A string like `"Bare asdasd"` matches neither and falls back to the SF Symbol.
2. **Image existence check** — `UIImage(named:)` confirms the asset actually contains image data. Placeholder imagesets (empty `images` array in `Contents.json`) return `nil` here, activating the SF Symbol fallback.
3. **SF Symbol fallback** — the category icon from `GearCategory.icon` (e.g. `cylinder.fill` for tanks) on a tinted background. Falls back to `building.2` for autocomplete suggestion rows (where no category context is available) or `wrench.and.screwdriver.fill` for real gear items with an unresolvable category.

### Autocomplete casing

The `name:` field in each `brandTable` entry is the canonical spelling shown in the manufacturer autocomplete dropdown (e.g. `"ScubaPro"`, `"O'Three"`). A user-entered manufacturer that lowercases to the same value as a canonical name is silently shadowed by the canonical spelling in the suggestion list. No stored data is altered — only the suggestion display is affected. If you need to change how a brand appears in autocomplete, update the `name:` field.

---

## Complete Brand Inventory

### Dive Computers / Multi-category

| Asset name | Display name | Match tokens |
|---|---|---|
| `GearIcon_Shearwater` | Shearwater | `shearwater`, `shearwater research` |
| `GearIcon_Suunto` | Suunto | `suunto` |
| `GearIcon_Scubapro` | ScubaPro | `scubapro` |
| `GearIcon_Mares` | Mares | `mares` |
| `GearIcon_Oceanic` | Oceanic | `oceanic` |
| `GearIcon_Aqualung` | Aqualung | `aqualung` |
| `GearIcon_Sherwood` | Sherwood | `sherwood` |
| `GearIcon_HeinrichsWeikamp` | Heinrichs Weikamp | `heinrichs`, `weikamp`, `ostc` |
| `GearIcon_Cressi` | Cressi | `cressi` |
| `GearIcon_Divesoft` | Divesoft | `divesoft` |
| `GearIcon_Tusa` | Tusa | `tusa` |
| `GearIcon_Garmin` | Garmin | `garmin` |

### Accessories / Knives / Safety

| Asset name | Display name | Match tokens |
|---|---|---|
| `GearIcon_DeepSix` | Deep Six | `deep six` |
| `GearIcon_Deepblu` | Deepblu | `deepblu` |
| `GearIcon_McLean` | McLean | `mclean` |
| `GearIcon_Oceans` | Oceans | `oceans` |
| `GearIcon_Seac` | Seac | `seac` |
| `GearIcon_Halcyon` | Halcyon | `halcyon` |
| `GearIcon_Ratio` | Ratio | `ratio` |
| `GearIcon_DiveSystem` | DiveSystem | `divesystem`, `idive` |
| `GearIcon_Apeks` | Apeks | `apeks` |
| `GearIcon_Orcatorch` | Orcatorch | `orcatorch` |
| `GearIcon_DiveRite` | Dive Rite | `dive rite` |
| `GearIcon_SeaDog` | Sea-Dog | `sea-dog`, `sea dog` |
| `GearIcon_XSScuba` | XS Scuba | `xs scuba` |
| `GearIcon_Highland` | Highland | `highland` |
| `GearIcon_Nautec` | Nautec | `nautec` |
| `GearIcon_Storm` | Storm | `storm` |
| `GearIcon_YRVA` | YRVA | `yrva` |

### Tanks / Cylinders

| Asset name | Display name | Match tokens |
|---|---|---|
| `GearIcon_Catalina` | Catalina | `catalina` |
| `GearIcon_Faber` | Faber | `faber` |
| `GearIcon_Luxfer` | Luxfer | `luxfer` |
| `GearIcon_Worthington` | Worthington | `worthington` |
| `GearIcon_Eurocylinder` | Eurocylinder | `eurocylinder` |

### Wetsuits / Drysuits / Thermal

| Asset name | Display name | Match tokens |
|---|---|---|
| `GearIcon_FourthElement` | Fourth Element | `fourth element` |
| `GearIcon_Bare` | Bare | `bare` |
| `GearIcon_DUI` | Diving Unlimited International | `diving unlimited`, `dui` |
| `GearIcon_Waterproof` | Waterproof | `waterproof` |
| `GearIcon_Santi` | Santi | `santi` |
| `GearIcon_OThree` | O'Three | `o'three`, `o three`, `othree` |
| `GearIcon_Typhoon` | Typhoon | `typhoon` |
| `GearIcon_Henderson` | Henderson | `henderson` |
| `GearIcon_Whites` | Whites | `whites` |
| `GearIcon_Camaro` | Camaro | `camaro` |
| `GearIcon_Ursuit` | Ursuit | `ursuit` |

### Regulators / BCDs / Wings

| Asset name | Display name | Match tokens |
|---|---|---|
| `GearIcon_Poseidon` | Poseidon | `poseidon` |
| `GearIcon_AtomicAquatics` | Atomic Aquatics | `atomic` |
| `GearIcon_Zeagle` | Zeagle | `zeagle` |
| `GearIcon_Hollis` | Hollis | `hollis` |
| `GearIcon_Xdeep` | xDeep | `xdeep`, `x-deep` |
| `GearIcon_Kubi` | Kubi | `kubi` |
| `GearIcon_Eezycut` | Eezycut | `eezycut` |
| `GearIcon_Tecline` | Tecline | `tecline` |

### Masks / Fins

| Asset name | Display name | Match tokens |
|---|---|---|
| `GearIcon_Beuchat` | Beuchat | `beuchat` |
| `GearIcon_ISTSports` | IST Sports | `ist sports`, `ist pro`, `ists` |

### Lights / Imaging

| Asset name | Display name | Match tokens |
|---|---|---|
| `GearIcon_Bigblue` | Bigblue | `bigblue`, `big blue` |
| `GearIcon_LightAndMotion` | Light & Motion | `light & motion`, `light and motion` |
| `GearIcon_LightMonkey` | Light Monkey | `light monkey` |
| `GearIcon_UnderwaterKinetics` | Underwater Kinetics | `underwater kinetics`, `uk` |
| `GearIcon_Keldan` | Keldan | `keldan` |
| `GearIcon_Ikelite` | Ikelite | `ikelite` |
| `GearIcon_SeaAndSea` | Sea & Sea | `sea & sea`, `sea&sea`, `sea and sea` |
| `GearIcon_Paralenz` | Paralenz | `paralenz` |
| `GearIcon_Nauticam` | Nauticam | `nauticam` |
| `GearIcon_Sola` | Sola | `sola` |

---

## Source File Formats Accepted

The Python Pillow pipeline accepts any format Pillow can open: `.webp`, `.png`, `.jpg`, `.jpeg`. The output is always `.png` with an RGBA channel.

Install Pillow if not present:
```bash
pip3 install Pillow
```
