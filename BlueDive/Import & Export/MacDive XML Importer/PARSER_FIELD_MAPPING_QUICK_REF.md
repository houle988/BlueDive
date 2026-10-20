# Parser Field Mapping Quick Reference

## Overview
This document provides a quick reference for developers to understand which fields are imported by each parser.

---

## MacDiveXMLParser vs BlueDiveXMLParser

### 🟢 Both Parsers Import (Shared Fields)

#### Basic Dive Info
- date, identifier, diveNumber, rating, repetitiveDive
- diver, computer, serial
- maxDepth, averageDepth, duration, interval
- cns, decoModel

#### Environmental Data
- tempAir, tempHigh, tempLow
- visibility, weight, weather, current, surfaceConditions

#### Dive Operations
- entryType, diveMaster, diveOperator, skipper, boat
- surfaceInterval

#### Notes & Organization
- notes, tags, types (array), buddies (array)

#### Site Data
- name, location, country, bodyOfWater
- waterType, difficulty, altitude
- latitude (lat), longitude (lon)

#### Gas Data (Basic - 10 fields)
- pressureStart, pressureEnd
- oxygen, helium, double
- tankSize, workingPressure
- supplyType, duration, tankName

#### Gear Data (Basic - 4 fields)
- type, manufacturer, name, serial

#### Profile Samples
- time, depth, pressure, temperature
- ppo2, ndt (ndl in BlueDive)

---

## 🔴 MacDiveXMLParser Does NOT Import

### Marine Life Sightings (0/2 fields)
❌ name  
❌ count

### Gas Extended Data (0/2 fields)
❌ tankMaterial  
❌ tankType

### Gear Extended Data (0/12 fields)
❌ datePurchased  
❌ purchasePrice  
❌ currency  
❌ purchasedFrom  
❌ weightContribution  
❌ nextServiceDue  
❌ serviceHistory  
❌ gearNotes  
❌ tankVolume  
❌ tankMaterial  
❌ tankType  
❌ tankMaxPressure

---

## 🟢 BlueDiveXMLParser Imports EVERYTHING

### All Shared Fields ✅
(Same as MacDiveXMLParser - see above)

### Plus Marine Life Sightings (2/2 fields) ✅
✓ name  
✓ count

### Plus Gas Extended (2/2 fields) ✅
✓ tankMaterial  
✓ tankType

### Plus Gear Extended (12/12 fields) ✅
✓ datePurchased  
✓ purchasePrice  
✓ currency  
✓ purchasedFrom  
✓ weightContribution  
✓ nextServiceDue  
✓ serviceHistory  
✓ gearNotes  
✓ tankVolume  
✓ tankMaterial  
✓ tankType  
✓ tankMaxPressure

### Plus Metadata (Read but not stored in dive model) ✅
✓ software, version, exportedAt  
✓ distanceFormat, temperatureFormat, pressureFormat, volumeFormat, weightFormat

---

## Implementation Notes

### MacDiveXMLParser Strategy
**Conservative Import:** Only imports fields that MacDive XML actually contains
- Excluded fields set to `nil` or empty arrays
- Parsing code for excluded fields is commented out
- Clear documentation on why fields are excluded

### BlueDiveXMLParser Strategy
**Comprehensive Import:** Imports everything including app-specific metadata
- Supports round-trip import/export fidelity
- Handles extended gear management features
- Tracks marine life sightings and tank specifications

---

## Data Structure Compatibility

Both parsers output `BlueDiveGlobalData` structures:
```swift
struct BlueDiveGlobalData {
    // Units
    let distanceFormat: String
    let temperatureFormat: String
    let pressureFormat: String
    let volumeFormat: String
    let weightFormat: String
    
    // Basic info, stats, conditions, etc.
    // ... (shared fields)
    
    // Related data
    let site: BlueDiveSiteData?
    let types: [String]
    let buddies: [String]
    let gases: [BlueDiveGasData]        // May have nil extended fields (MacDive)
    let gear: [BlueDiveGearData]        // May have nil extended fields (MacDive)
    let samples: [BlueDiveSamplesData]
    let marineLifeSeen: [BlueDiveMarineLifeData]    // Empty array for MacDive imports
}
```

---

## Decision Tree: Which Parser to Use?

```
Is the XML from MacDive?
├─ YES → Use MacDiveXMLParser
│         • Basic dive logging fields
│         • No marine life, limited gear/gas metadata
│         • Most common import scenario
│
└─ NO → Is it from DiveBlue app export?
         ├─ YES → Use BlueDiveXMLParser
         │         • Full feature set
         │         • Marine life sightings included
         │         • Complete gear management
         │         • Round-trip fidelity
         │
         └─ NO → Check XML root element
                  ├─ <diveBlueExport> → BlueDiveXMLParser
                  └─ Other → Likely MacDiveXMLParser
```

---

## Testing Checklist

When modifying parsers, verify:

- [ ] MacDive import doesn't populate marine life data
- [ ] MacDive import doesn't populate gas tankMaterial/tankType
- [ ] MacDive import doesn't populate gear extended fields
- [ ] BlueDive import populates ALL fields
- [ ] Both parsers handle their respective formats without errors
- [ ] Invalid/unknown XML elements are gracefully ignored
- [ ] Data structures remain compatible between parsers

---

## File Locations

- **MacDive Parser:** `MacDiveXMLParser.swift`
- **BlueDive Parser:** `BlueDiveXMLParser.swift`
- **Shared Models:** Defined in `MacDiveXMLParser.swift`, used by both
- **CSV Mapping:** See original CSV provided by developer

---

## Questions?

If you're unsure which fields are imported:
1. Check this document's field lists above
2. Review CSV mapping in project documentation  
3. Search parser code for `// NOT imported` comments
4. Run unit tests to verify expected behavior

