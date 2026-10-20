# Tank Properties Quick Reference

## At a Glance

### ✅ Use These (New Computed Properties)
```swift
dive.primaryTankVolume              // Double - tank volume
dive.primaryStartPressure           // Double - start pressure
dive.primaryEndPressure             // Double - end pressure
dive.primaryWorkingPressure         // Double? - working pressure
dive.primaryTankMaterial            // String? - material (Steel, Aluminum)
dive.primaryTankType                // String? - type (Single, Double, Sidemount)
dive.primaryOxygenPercentage        // Int - O₂%
dive.primaryHeliumPercentage        // Int? - He%
dive.primaryTank                    // TankData - full tank object
```

### ⚠️ Avoid These (Legacy Direct Properties)
```swift
dive.cylinderSize                   // Use primaryTankVolume instead
dive.startPressure                  // Use primaryStartPressure instead
dive.endPressure                    // Use primaryEndPressure instead
dive.tankMaterial                   // Use primaryTankMaterial instead
dive.tankType                       // Use primaryTankType instead
dive.oxygenPercentage               // Use primaryOxygenPercentage instead
dive.heliumPercentage               // Use primaryHeliumPercentage instead
```

## Common Patterns

### Reading Values
```swift
// ✅ Display volume
let volume = dive.primaryTankVolume
Text("\(volume, specifier: "%.1f") L")

// ✅ Display start pressure
let start = dive.primaryStartPressure
Text("\(start, specifier: "%.0f") bar")

// ✅ Handle optional working pressure
if let wp = dive.primaryWorkingPressure {
    Text("WP: \(wp, specifier: "%.0f") bar")
}

// ✅ Display gas mix
Text("O₂: \(dive.primaryOxygenPercentage)%")
if let he = dive.primaryHeliumPercentage, he > 0 {
    Text("He: \(he)%")
}
```

### Writing Values
```swift
// ✅ Update volume
dive.primaryTankVolume = 15.0

// ✅ Update pressures
dive.primaryStartPressure = 232.0
dive.primaryEndPressure = 50.0

// ✅ Update working pressure
dive.primaryWorkingPressure = 232.0

// ✅ Update material and type
dive.primaryTankMaterial = "Aluminum"
dive.primaryTankType = "Single"

// ✅ Update gas mix
dive.primaryOxygenPercentage = 32
dive.primaryHeliumPercentage = 10
```

### Edit Forms
```swift
struct EditGasView: View {
    let dive: Dive
    @State private var volume: Double
    @State private var startPressure: Double
    @State private var o2: Int
    
    init(dive: Dive) {
        self.dive = dive
        // ✅ Initialize from computed properties
        _volume = State(initialValue: dive.primaryTankVolume)
        _startPressure = State(initialValue: dive.primaryStartPressure)
        _o2 = State(initialValue: dive.primaryOxygenPercentage)
    }
    
    var body: some View {
        Form {
            TextField("Volume", value: $volume, format: .number)
            TextField("Start", value: $startPressure, format: .number)
            Stepper("O₂: \(o2)%", value: $o2, in: 21...100)
        }
    }
    
    func save() {
        // ✅ Save via computed properties
        dive.primaryTankVolume = volume
        dive.primaryStartPressure = startPressure
        dive.primaryOxygenPercentage = o2
    }
}
```

### Working with Full Tank Object
```swift
// ✅ Get and modify
var tank = dive.primaryTank
tank = TankData(
    id: tank.id,
    gasMixID: tank.gasMixID,

    volume: 15.0,
    startPressure: 200.0,
    endPressure: 50.0,
    workingPressure: 232.0,
    tankMaterial: "Steel",
    tankType: "Double"
)
dive.primaryTank = tank  // Syncs to both TankData and direct properties
```

## Type Differences

| Property | Old Type | New Type | Notes |
|----------|----------|----------|-------|
| Volume | `Double` | `Double` | ✅ Same |
| Start Pressure | `Int` | `Double` | ⚠️ More precision |
| End Pressure | `Int` | `Double` | ⚠️ More precision |
| Working Pressure | N/A | `Double?` | ✅ New field |
| O₂% | `Int` | `Int` | ✅ Same |
| He% | `Int?` | `Int?` | ✅ Same |

## Storage Model

```
Reading Priority:
┌─────────────────────────────────────┐
│ 1. dive.tanks[0] (TankData)        │ ← Primary
│    - High precision (Double)        │
│    - Working pressure included      │
│    - Linked to gas mix              │
└─────────────────────────────────────┘
              ↓ Falls back to
┌─────────────────────────────────────┐
│ 2. dive.cylinderSize, etc.         │ ← Fallback
│    - Legacy fields                  │
│    - Integer precision for pressure │
│    - Always present                 │
└─────────────────────────────────────┘

Writing Behavior:
┌─────────────────────────────────────┐
│ dive.primaryTankVolume = 15.0      │
└─────────────────────────────────────┘
              ↓ Updates both
┌──────────────────┬──────────────────┐
│ tanks[0].volume  │  cylinderSize    │
│     = 15.0       │    = 15.0        │
└──────────────────┴──────────────────┘
```

## Migration Checklist

When updating existing code:

```swift
// Before
let vol = dive.cylinderSize
let start = dive.startPressure  // Int
let end = dive.endPressure      // Int
dive.cylinderSize = 12.0
dive.startPressure = 200

// After
let vol = dive.primaryTankVolume
let start = dive.primaryStartPressure  // Double
let end = dive.primaryEndPressure      // Double
dive.primaryTankVolume = 12.0
dive.primaryStartPressure = 200.0
```

## Common Mistakes

### ❌ Don't Do This
```swift
// Trying to mutate struct directly
dive.primaryTank.volume = 15.0  // Won't persist!

// Mixing old and new APIs inconsistently
dive.cylinderSize = 12.0                    // Direct write
let display = dive.primaryTankVolume        // Computed read
// Works but confusing
```

### ✅ Do This Instead
```swift
// Reassign entire struct
var tank = dive.primaryTank
tank = TankData(..., volume: 15.0, ...)
dive.primaryTank = tank  // Persists

// Consistent API usage
dive.primaryTankVolume = 12.0               // Computed write
let display = dive.primaryTankVolume        // Computed read
```

## Property Mapping Table

| Old Property | New Property | Notes |
|-------------|--------------|-------|
| `cylinderSize` | `primaryTankVolume` | Same type (Double) |
| `startPressure` | `primaryStartPressure` | Int → Double |
| `endPressure` | `primaryEndPressure` | Int → Double |
| `tankMaterial` | `primaryTankMaterial` | Same type (String?) |
| `tankType` | `primaryTankType` | Same type (String?) |
| `oxygenPercentage` | `primaryOxygenPercentage` | Same type (Int) |
| `heliumPercentage` | `primaryHeliumPercentage` | Same type (Int?) |
| N/A | `primaryWorkingPressure` | New (Double?) |
| N/A | `primaryTank` | New (TankData) |

## Benefits Summary

✅ **Type Safety**: No more Int ↔ Double conversions  
✅ **Single Source**: TankData is authoritative  
✅ **Backward Compatible**: Old code still works  
✅ **Future-Proof**: Ready for multi-tank support  
✅ **Precision**: Double values for accurate calculations  
✅ **Working Pressure**: Properly stored and accessible  

## When to Use What

| Scenario | Use |
|----------|-----|
| New code | ✅ `primary*` properties |
| Display views | ✅ `primary*` properties |
| Edit forms | ✅ `primary*` properties |
| XML export | ✅ `primary*` properties |
| Legacy code | ⚠️ Can keep direct properties (but migrate when touching) |
| Internal calculations | ✅ `primary*` properties (already used by RMV/SAC) |

## Key Takeaway

> **Always use `primary*` properties in new code.** They provide better type safety, accuracy, and future compatibility while maintaining full backward compatibility with existing data.
