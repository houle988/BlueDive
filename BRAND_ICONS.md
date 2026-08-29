# Brand Icon Processing Guide

This document describes the complete workflow for adding or updating brand logo images across all three icon systems: Gear, Certifications, and Insurance.

---

## Overview

| Context | Size | Shape |
|---|---|---|
| Gear list row | 44 pt | Rounded-square tile |
| Manufacturer autocomplete suggestion | 28 pt | Rounded-square tile |
| Add / Edit Gear header | 80 pt | Rounded-square tile |
| Gear detail hero | 100 pt | Rounded-square tile |
| Certification card | 60 pt | Rounded-square tile |
| Certification detail | 64 pt | Rounded-square tile |
| Insurance card | 60 pt | Rounded-square tile |
| Insurance detail | 64 pt | Rounded-square tile |

When a matching brand asset exists, a brand logo is shown on a white tile with a subtle border. Otherwise the icon falls back to a category SF Symbol (gear) or tinted text/symbol tile (cert/insurance). Icons are stored as 132×132 px universal PNG imagesets in the Xcode asset catalog. A `UIImage(named:)` existence check ensures that placeholder imagesets (no image yet) transparently fall back to the SF Symbol / text rather than showing a blank tile.

---

## Asset Catalog Locations

```
BlueDive/Assets.xcassets/GearIcons/        ← gear manufacturer logos
BlueDive/Assets.xcassets/CertIcons/        ← certification organization logos
BlueDive/Assets.xcassets/InsuranceIcons/   ← dive insurance provider logos
```

Each brand has its own `.imageset` folder inside the appropriate subfolder.

---

## Asset Naming Convention

| System | Pattern | Example |
|---|---|---|
| Gear | `GearIcon_<Brand>` | `GearIcon_Scubapro` |
| Certifications | `CertIcon_<Org>` | `CertIcon_PADI` |
| Insurance | `InsuranceIcon_<Provider>` | `InsuranceIcon_DAN` |

General rule: remove spaces and special characters, concatenate words in PascalCase.

---

## Icon Display in SwiftUI

`GearIconView`, `CertificationIconView`, and `InsuranceIconView` all share the same rendering pattern:

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

// SF Symbol fallback (GearIconView only)
ZStack {
    RoundedRectangle(cornerRadius: cornerRadius)
        .fill(iconColor.opacity(0.15))
    Image(systemName: categoryIcon)
        .font(.system(size: symbolSize))
        .foregroundStyle(iconColor)
}
.frame(width: size, height: size)

// Symbol fallback (InsuranceIconView with fallbackSymbol:)
ZStack {
    RoundedRectangle(cornerRadius: cornerRadius)
        .fill(fallbackColor.opacity(fillOpacity))
    Image(systemName: symbol)
        .font(.system(size: size * 18 / 44))
        .foregroundStyle(fallbackColor)
}
.frame(width: size, height: size)

// Text fallback (CertificationIconView / InsuranceIconView with no symbol)
ZStack {
    RoundedRectangle(cornerRadius: cornerRadius)
        .fill(color.opacity(fillOpacity))
    Text(verbatim: label)
        .font(.caption).fontWeight(.bold).foregroundStyle(color)
        .lineLimit(1).minimumScaleFactor(0.6).padding(4)
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

### Placeholder imageset (no image yet — falls back to SF Symbol / text)

```json
{
  "images" : [],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

Placeholder imagesets cause `UIImage(named:)` to return `nil`, which the `UIImage(named:) != nil` check in each view's `init` detects, keeping the fallback active until a real logo is added.

---

## Standard Image Processing Pipeline

All source images — regardless of format or size — must go through this pipeline before installation.

> **Why not flood-fill?** Flood-fill from corners cannot reach enclosed letter counters (e.g. inside B, A, R, P, O). Use the colour-key approach below instead — it removes white everywhere in the image, not just connected to the edges. The RGB of transparent pixels is also zeroed to prevent white bleed on dark backgrounds.

> **SVG-derived PNGs:** An SVG exported to PNG often already has a transparent background (alpha = 0) with black RGB values underneath. The pipeline must check the source alpha channel first — otherwise those transparent-black pixels are treated as opaque logo content and produce a black background artifact. The script below handles this correctly.

### Step 2 — Remove white background (colour-key, distance from white)

```python
from PIL import Image
import numpy as np

img = Image.open("source.png").convert("RGBA")
data = np.array(img, dtype=np.float32)
r, g, b, a = data[:,:,0], data[:,:,1], data[:,:,2], data[:,:,3]

# Euclidean distance from pure white (255,255,255)
dist = np.sqrt((r - 255)**2 + (g - 255)**2 + (b - 255)**2)

# A pixel is logo content only if it was opaque in the source AND not white.
# The source-alpha guard is critical for SVG-derived PNGs: transparent-black
# pixels (RGBA 0,0,0,0) score far from white and would otherwise be promoted
# to solid black, creating a black background artifact.
is_logo = (a > 0) & (dist >= 80)

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

src = "/path/to/source.webp"   # or .png, .jpg, .svg-exported .png
dst = "/path/to/output.png"

img = Image.open(src).convert("RGBA")
data = np.array(img, dtype=np.float32)
r, g, b, a = data[:,:,0], data[:,:,1], data[:,:,2], data[:,:,3]

# Step 2: colour-key white background (respecting source alpha)
dist = np.sqrt((r - 255)**2 + (g - 255)**2 + (b - 255)**2)
is_logo = (a > 0) & (dist >= 80)
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

### Gear

1. Process the source with the pipeline above.
2. Copy the resulting PNG into the imageset folder:
   ```bash
   cp output.png "BlueDive/Assets.xcassets/GearIcons/GearIcon_Hollis.imageset/Hollis.png"
   ```
3. Update `Contents.json` to reference the PNG.

No code changes are needed — `GearIconView` detects the new image automatically via `UIImage(named:)`.

### Certifications

1. Process the source with the pipeline above.
2. Copy the resulting PNG into the imageset folder:
   ```bash
   cp output.png "BlueDive/Assets.xcassets/CertIcons/CertIcon_PADI.imageset/PADI.png"
   ```
3. Update `Contents.json` to reference the PNG.

No code changes needed — `CertificationIconView` detects it automatically.

### Insurance

1. Process the source with the pipeline above.
2. Copy the resulting PNG into the imageset folder:
   ```bash
   cp output.png "BlueDive/Assets.xcassets/InsuranceIcons/InsuranceIcon_DAN.imageset/DAN.png"
   ```
3. Update `Contents.json` to reference the PNG.

No code changes needed — `InsuranceIconView` detects it automatically.

---

## Adding a Brand New Entry

### Gear

1. Create the imageset folder and placeholder `Contents.json`.
2. Add one entry to `GearIconView.brandTable` in `GearIconView.swift`:
   ```swift
   Brand(name: "New Brand", tokens: ["newbrand"], asset: "GearIcon_NewBrand"),
   ```
   Tokens must be **complete lowercase strings** the user might store as manufacturer. `knownManufacturers` and `assetName(forManufacturer:)` are both automatically derived from `brandTable` — no other Swift code changes needed.
3. Add a row to the inventory table below.
4. Install the logo image when ready.

### Certifications

Certifications use a **finite `CertificationOrganization` enum** (PADI, SSI, CMAS, NAUI, SDI, TDI, BSAC, GUE, Other). To add logo support for an existing organization:
1. Add the imageset folder under `CertIcons/`.
2. Add a `case` in `CertificationIconView.assetName(for:)` returning the asset name.
3. Add a row to the inventory table below.

To add a brand-new organization requires a data model change — coordinate with the project owner.

### Insurance

Insurance uses free-form `insurerName` text resolved via keyword matching in `InsuranceIconView.assetName(for:)`. To add a new provider:
1. Add the imageset folder under `InsuranceIcons/`.
2. Add a keyword match line in `InsuranceIconView.assetName(for:)` — more specific tokens must appear **before** shorter ones (e.g. `"diveassure"` before a hypothetical `"dive"` match).
3. Add a row to the inventory table below.
4. Install the logo image when ready.

---

## Common Issues

| Symptom | Cause | Fix |
|---|---|---|
| Logo appears too small in tile | Source image has large transparent padding | Ensure Step 3 (crop bounding box) ran correctly |
| Logo appears squished | Landscape/portrait source scaled to square without padding | Ensure Step 4 (pad to square) ran |
| Light-coloured logo parts clipped | Threshold too aggressive for a pale logo | Increase `dist` threshold from 80 to 100–120 |
| Grey/white rectangle visible on dark backgrounds | Soft-ramp or non-zeroed RGB on transparent pixels | Use hard threshold and zero out RGB of transparent pixels (see script above) |
| Black background on SVG-derived PNG | Source alpha ignored — transparent-black pixels promoted to opaque | Add `(a > 0) &` guard to `is_logo` condition (already in script above) |
| Blank tile shown | Placeholder imageset in catalog, image not yet added | Install PNG and update `Contents.json` |
| SF Symbol / text shown despite image file present | `Contents.json` still has empty `images` array | Update `Contents.json` to reference the filename |
| SF Symbol / text shown despite correct `Contents.json` | Asset name doesn't match folder name | Verify the asset name in Swift code matches the exact imageset folder name |

---

## Lookup Architecture

### Gear — `GearIconView.swift`

All brand data lives in a single `private static let brandTable: [Brand]`. Both the autocomplete list and the asset resolver are derived from it automatically.

```
brandTable  ──►  knownManufacturers   (static let, drives manufacturer autocomplete)
            ──►  assetName(for:)      (static func, drives logo resolution)
```

Resolution: `gear.manufacturer` is trimmed, lowercased, and apostrophe-normalised, then looked up in two precomputed dictionaries (canonical name and tokens). First hit returns the asset name.

### Certifications — `CertificationIconView.swift`

Asset resolution uses `CertificationOrganization(rawValue:)` via a `switch` in `assetName(for:)`. Finite enum — no ambiguity.

### Insurance — `InsuranceIconView.swift`

Asset resolution uses ordered keyword `contains` matching on the lowercased `insurerName`. More-specific tokens appear first to prevent partial matches (e.g. `"diveassure"` before a hypothetical `"dive"` match).

---

## Source File Formats Accepted

The Python Pillow pipeline accepts any format Pillow can open: `.webp`, `.png`, `.jpg`, `.jpeg`. The output is always `.png` with an RGBA channel.

Install Pillow if not present:
```bash
pip3 install Pillow
```

---

## Complete Brand Inventory

### Gear — Dive Computers / Multi-category

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

### Gear — Accessories / Knives / Safety

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

### Gear — Tanks / Cylinders

| Asset name | Display name | Match tokens |
|---|---|---|
| `GearIcon_Catalina` | Catalina | `catalina` |
| `GearIcon_Faber` | Faber | `faber` |
| `GearIcon_Luxfer` | Luxfer | `luxfer` |
| `GearIcon_Worthington` | Worthington | `worthington` |
| `GearIcon_Eurocylinder` | Eurocylinder | `eurocylinder` |

### Gear — Wetsuits / Drysuits / Thermal

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

### Gear — Regulators / BCDs / Wings

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

### Gear — Masks / Fins

| Asset name | Display name | Match tokens |
|---|---|---|
| `GearIcon_Beuchat` | Beuchat | `beuchat` |
| `GearIcon_ISTSports` | IST Sports | `ist sports`, `ist pro`, `ists` |

### Gear — Lights / Imaging

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

### Certifications

Resolution: `CertificationOrganization(rawValue: organization)` enum switch in `CertificationIconView.assetName(for:)`.

| Asset name | Organization | Status |
|---|---|---|
| `CertIcon_PADI` | PADI | ✅ logo installed |
| `CertIcon_SSI` | SSI | ✅ logo installed |
| `CertIcon_CMAS` | CMAS | ✅ logo installed |
| `CertIcon_NAUI` | NAUI | ✅ logo installed |
| `CertIcon_SDI` | SDI | ✅ logo installed |
| `CertIcon_TDI` | TDI | ✅ logo installed |
| `CertIcon_BSAC` | BSAC | ✅ logo installed |
| `CertIcon_GUE` | GUE | ✅ logo installed |

---

### Insurance

Resolution: ordered keyword `contains` matching in `InsuranceIconView.assetName(for:)`. More-specific tokens must remain above shorter ones.

| Asset name | Provider | Match keywords | Status |
|---|---|---|---|
| `InsuranceIcon_DAN` | DAN / DAN Europe | `divers alert`, `dan europe`, exact `dan`, `dan `, ` dan`, ` dan `, `dan(` | ✅ logo installed |
| `InsuranceIcon_DiveAssure` | DiveAssure | `diveassure`, `dive assure` | ✅ logo installed |
| `InsuranceIcon_Nautilus` | Nautilus | `nautilus` | ✅ logo installed |
