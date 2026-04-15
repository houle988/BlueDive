import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// MARK: - Import File Type

/// Identifies which parser to invoke for a given import file.
enum ImportFileType {
    case macDive
    case blueDive
    case uddf
}

// MARK: - Import Error

enum ImportError: LocalizedError {
    case accessDenied
    case parsingFailed
    case fileSelectionFailed(Error)
    case saveFailed(Error)
    case unsupportedFormat
    
    var errorDescription: String? {
        let bundle = Bundle.forAppLanguage()
        switch self {
        case .accessDenied:
            return NSLocalizedString("Unable to access the selected file.", bundle: bundle, comment: "")
        case .parsingFailed:
            return NSLocalizedString("The file could not be read correctly.", bundle: bundle, comment: "")
        case .fileSelectionFailed(let error):
            let fmt = NSLocalizedString("Selection error: %@", bundle: bundle, comment: "")
            return String(format: fmt, error.localizedDescription)
        case .saveFailed(let error):
            let fmt = NSLocalizedString("Save error: %@", bundle: bundle, comment: "")
            return String(format: fmt, error.localizedDescription)
        case .unsupportedFormat:
            return NSLocalizedString("Unrecognised file format. Supported formats are MacDive XML, BlueDive XML, and UDDF.", bundle: bundle, comment: "")
        }
    }
}

// MARK: - ContentView Import Extension

extension ContentView {

    func handleFileImport(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            // Read the file once: used for format detection and later for import.
            Task {
                guard url.startAccessingSecurityScopedResource() else {
                    await MainActor.run {
                        importError = .accessDenied
                        showErrorAlert = true
                    }
                    return
                }
                let rawData = try? Data(contentsOf: url)
                url.stopAccessingSecurityScopedResource()

                // Scan the first 4 KB — all format signatures appear near the top.
                let snippet = rawData.flatMap { String(data: $0.prefix(4096), encoding: .utf8) } ?? ""

                // ── Format detection ──────────────────────────────────────────────
                // Priority order matters: check the most specific signatures first.

                // 1. BlueDive XML — our own export format.
                //    Signature: <software>BlueDive</software> inside <metadata>.
                let isBlueDive = snippet.contains("<software>BlueDive</software>")

                // 2. UDDF — identified by <uddf root element or .uddf extension.
                //    Checked before MacDive because UDDF files exported by MacDive
                //    may contain "mac-dive.com" in their <generator> section.
                let isUDDF = !isBlueDive && (
                    snippet.contains("<uddf")
                    || url.pathExtension.lowercased() == "uddf"
                )

                // 3. MacDive XML — identified by its DOCTYPE declaration.
                let isMacDive  = !isBlueDive && !isUDDF && (
                    snippet.contains("<!DOCTYPE dives SYSTEM \"http://www.mac-dive.com/macdive_logbook.dtd\">")
                    || snippet.contains("mac-dive.com")
                )

                await MainActor.run {
                    if isBlueDive {
                        // BlueDive XML — units are stored inside the file but we
                        // still show the import sheet so the user can toggle gear import.
                        let options = ImportFormatOptions()
                        importFormatOptions = options
                        if let data = rawData {
                            pendingImport = PendingImport(url: url, data: data, formatOptions: options, fileType: .blueDive)
                        }

                    } else if isUDDF {
                        // UDDF — units are always SI (converted to metric by the parser)
                        // but we still show the import sheet so the user can toggle gear import.
                        let options = ImportFormatOptions()
                        importFormatOptions = options
                        if let data = rawData {
                            pendingImport = PendingImport(url: url, data: data, formatOptions: options, fileType: .uddf)
                        }

                    } else if isMacDive {
                        // MacDive XML — units are ambiguous, show the picker first.
                        let options: ImportFormatOptions
                        if let data = rawData,
                           let detected = DetectedUnitSystem.detect(from: data) {
                            options = detected.formatOptions
                        } else {
                            options = ImportFormatOptions()
                        }
                        importFormatOptions = options
                        if let data = rawData {
                            pendingImport = PendingImport(url: url, data: data, formatOptions: options)
                        }

                    } else {
                        // Unrecognised format — inform the user.
                        importError = .unsupportedFormat
                        showErrorAlert = true
                    }
                }
            }
        case .failure(let error):
            importError = .fileSelectionFailed(error)
            showErrorAlert = true
        }
    }

    func importDiveFile(from url: URL, formats: ImportFormatOptions?, fileType: ImportFileType) {
        // Show loading indicator
        isImporting = true
        
        Task {
            do {
                guard url.startAccessingSecurityScopedResource() else {
                    throw ImportError.accessDenied
                }
                defer { url.stopAccessingSecurityScopedResource() }
                
                let data = try Data(contentsOf: url)
                
                switch fileType {
                case .macDive:
                    let chosenFormats = formats ?? ImportFormatOptions()
                    try await importMacDiveXML(data: data, fileName: url.lastPathComponent, formats: chosenFormats)

                case .blueDive:
                    let chosenFormats = formats ?? ImportFormatOptions()
                    try await importBlueDiveXML(data: data, fileName: url.lastPathComponent, importGear: chosenFormats.importGear)

                case .uddf:
                    let chosenFormats = formats ?? ImportFormatOptions()
                    try await importUDDFXML(data: data, fileName: url.lastPathComponent, importGear: chosenFormats.importGear)
                }
                
                await MainActor.run {
                    isImporting = false
                }
                
            } catch let error as ImportError {
                await MainActor.run {
                    isImporting = false
                    importError = error
                    showErrorAlert = true
                }
            } catch {
                await MainActor.run {
                    isImporting = false
                    importError = .saveFailed(error)
                    showErrorAlert = true
                }
            }
        }
    }

    private func importMacDiveXML(data: Data, fileName: String, formats: ImportFormatOptions) async throws {
        let divesData = try await Task.detached(priority: .userInitiated) {
            let parser = await MacDiveXMLParser()
            // Inject the user-chosen unit formats before parsing
            await MainActor.run {
                parser.distanceFormat    = formats.distanceFormat
                parser.temperatureFormat = formats.temperatureFormat
                parser.pressureFormat    = formats.pressureFormat
                parser.volumeFormat      = formats.volumeFormat
                parser.weightFormat      = formats.weightFormat
                parser.importGear        = formats.importGear
            }
            guard let parsedData = await parser.parse(data: data), !parsedData.isEmpty else {
                throw ImportError.parsingFailed
            }
            return parsedData
        }.value
        
        await MainActor.run {
            for diveData in divesData {
                insertDiveFromMacDive(diveData, fileName: fileName)
            }
        }
    }

    private func importBlueDiveXML(data: Data, fileName: String, importGear: Bool = true) async throws {
        // Instantiate the parser on the main actor (where its init is isolated)
        // before handing off the actual parsing work to a detached task.
        let parser = BlueDiveXMLParser()
        parser.importGear = importGear
        let divesData = try await Task.detached(priority: .userInitiated) {
            // BlueDive XML stores units inside the file, so no format injection needed.
            guard let parsedData = await parser.parse(data: data), !parsedData.isEmpty else {
                throw ImportError.parsingFailed
            }
            return parsedData
        }.value

        await MainActor.run {
            for diveData in divesData {
                // BlueDiveGlobalData is the same type used by MacDive imports,
                // so we can reuse insertDiveFromMacDive directly.
                insertDiveFromMacDive(diveData, fileName: fileName)
            }
        }
    }

    private func importUDDFXML(data: Data, fileName: String, importGear: Bool = true) async throws {
        let parser = UDDFXMLParser()
        parser.importGear = importGear
        let divesData = try await Task.detached(priority: .userInitiated) {
            // UDDF uses SI units; the parser converts to metric display units internally.
            guard let parsedData = await parser.parse(data: data), !parsedData.isEmpty else {
                throw ImportError.parsingFailed
            }
            return parsedData
        }.value

        await MainActor.run {
            for diveData in divesData {
                // BlueDiveGlobalData is the same type used by all imports,
                // so we can reuse insertDiveFromMacDive directly.
                insertDiveFromMacDive(diveData, fileName: fileName)
            }
        }
    }

    // MARK: - MacDive XML Import
    
    @MainActor
    func insertDiveFromMacDive(_ diveData: BlueDiveGlobalData, fileName: String) {
        // Convert MacDive samples to DiveProfilePoints
        let profilePoints = diveData.samples.map { sample in
            DiveProfilePoint(
                time: sample.time / 60.0, // Convert seconds to minutes
                depth: sample.depth,
                temperature: sample.temperature,
                tankPressure: sample.pressure,
                tankPressures: sample.tankPressures,
                ndl: sample.ndt != nil ? Double(sample.ndt!) : nil,
                ppo2: sample.ppo2,
                events: sample.events
            )
        }
        
        // Format buddies
        let buddiesString = diveData.buddies.joined(separator: ", ")
        
        // Convert surface interval from seconds to string
        // MacDive exports surfaceInterval in minutes (not seconds despite the field name)
        let surfaceIntervalString: String
        if let intervalMinutes = diveData.surfaceInterval, intervalMinutes > 0 {
            let totalMinutes = intervalMinutes
            let days    = totalMinutes / 1440  // 1440 minutes in a day
            let hours   = (totalMinutes % 1440) / 60
            let minutes = totalMinutes % 60
            
            if days > 0 {
                surfaceIntervalString = "\(days)d \(hours)h \(String(format: "%02d", minutes))m"
            } else {
                surfaceIntervalString = "\(hours)h \(String(format: "%02d", minutes))m"
            }
        } else {
            surfaceIntervalString = "0h 00m"
        }
        

        
        // Calculate average depth if not provided
        let averageDepth = diveData.averageDepth ?? (profilePoints.isEmpty
            ? diveData.maxDepth * 0.6
            : profilePoints.reduce(0.0) { $0 + $1.depth } / Double(profilePoints.count))
        
        // Create the dive with all MacDive information
        let newDive = Dive(
            diveNumber: diveData.diveNumber,
            identifier: diveData.identifier,
            timestamp: diveData.date ?? Date(),
            location: diveData.site?.location ?? "",
            siteName: diveData.site?.name ?? String(localized: "Unknown site"),
            diveTypes: diveData.types.isEmpty ? nil : diveData.types.joined(separator: ", "),
            tags: diveData.tags,
            computerName: diveData.computer ?? "",
            computerSerialNumber: diveData.serial,
            surfaceInterval: surfaceIntervalString,
            diverName: diveData.diver ?? UserDefaults.standard.string(forKey: "userName") ?? "",
            buddies: buddiesString,
            rating: diveData.rating ?? 0,
            isRepetitiveDive: (diveData.repetitiveDive ?? 0) > 0,
            weights: diveData.weight,
            weather: diveData.weather,
            surfaceConditions: diveData.surfaceConditions,
            current: diveData.current,
            visibility: diveData.visibility,
            entryType: diveData.entryType,
            diveOperator: diveData.diveOperator,
            diveMaster: diveData.diveMaster,
            skipper: diveData.skipper,
            boat: diveData.boat,
            maxDepth: diveData.maxDepth,
            averageDepth: averageDepth,
            duration: diveData.duration / 60, // Convert seconds to minutes
            waterTemperature: diveData.tempLow ?? 20.0,
            minTemperature: diveData.tempLow ?? 18.0,
            airTemperature: diveData.tempAir,
            maxTemperature: diveData.tempHigh,
            decompressionAlgorithm: diveData.decoModel,
            cnsPercentage: diveData.cns,
            isDecompressionDive: diveData.isDecompressionDive,
            notes: diveData.notes ?? "",
            importDistanceUnit: diveData.distanceFormat,
            importTemperatureUnit: diveData.temperatureFormat,
            importPressureUnit: diveData.pressureFormat,
            importVolumeUnit: diveData.volumeFormat,
            importWeightUnit: diveData.weightFormat,
            sourceImport: diveData.sourceImport,
            siteCountry: diveData.site?.country,
            siteBodyOfWater: diveData.site?.bodyOfWater,
            siteDifficulty: diveData.site?.difficulty,
            siteWaterType: diveData.site?.waterType,
            siteAltitude: diveData.site?.altitude,
            siteLatitude: diveData.site?.latitude,
            siteLongitude: diveData.site?.longitude,
            profileSamples: profilePoints
        )
        
        // Deco stops (from BlueDive XML round-trip)
        if !diveData.decoStops.isEmpty {
            newDive.decoStops = diveData.decoStops
        }

        // ── Save tank data and gas mixes ────────────────────────────────────
        // Priority: Use the new multi-tank array (diveData.tanks) if available,
        // otherwise fall back to the legacy single-gas format (diveData.gases).
        // This ensures backward compatibility while supporting the new format.
        
        if !diveData.tanks.isEmpty {
            // Multi-tank format
            var tanks: [TankData] = []
            
            for tank in diveData.tanks {
                let o2Fraction = Double(tank.oxygen ?? 21) / 100.0
                let heFraction = Double(tank.helium ?? 0) / 100.0
                
                let resolvedTankType: String? = tank.tankType ?? (tank.double ? "Twinset" : nil)
                let tankData = TankData(
                    id: UUID(uuidString: tank.id ?? "") ?? UUID(),
                    o2: o2Fraction,
                    he: heFraction,
                    volume: tank.volume,
                    startPressure: tank.startPressure,
                    endPressure: tank.endPressure,
                    workingPressure: tank.workingPressure,
                    tankMaterial: tank.tankMaterial,
                    tankType: resolvedTankType,
                    usageStartTime: tank.usageStartTime,
                    usageEndTime: tank.usageEndTime
                )
                tanks.append(tankData)
            }
            
            newDive.tanks = tanks
        } else if !diveData.gases.isEmpty {
            // Legacy single-gas format
            var tanks: [TankData] = []
            
            for gas in diveData.gases {
                let o2Fraction = Double(gas.oxygen ?? 21) / 100.0
                let heFraction = Double(gas.helium ?? 0) / 100.0
                
                let resolvedGasTankType: String? = gas.tankType ?? (gas.double ? "Twinset" : nil)
                let tankData = TankData(
                    o2: o2Fraction,
                    he: heFraction,
                    volume: gas.tankSize,
                    startPressure: gas.pressureStart,
                    endPressure: gas.pressureEnd,
                    workingPressure: gas.workingPressure,
                    tankMaterial: gas.tankMaterial,
                    tankType: resolvedGasTankType
                )
                tanks.append(tankData)
            }
            
            newDive.tanks = tanks
        }
        
        modelContext.insert(newDive)
        
        // Create gear items from MacDive gear list
        do {
            var equipmentToAdd: [Gear] = []
            
            for gearItem in diveData.gear {
                // Map MacDive gear types to app categories
                let rawType = gearItem.type ?? "other"
                let category = mapMacDiveGearType(rawType)
                
                // BlueDive exports store the full name in <name>; MacDive stores only the model,
                // so the manufacturer must be prepended for MacDive imports.
                let gearName: String
                if diveData.sourceImport == "BlueDive" {
                    gearName = gearItem.name
                } else if let manufacturer = gearItem.manufacturer, !manufacturer.isEmpty {
                    gearName = "\(manufacturer) \(gearItem.name)"
                } else {
                    gearName = gearItem.name
                }
                
                // Check if gear already exists.
                // When a serial number is present it is included in the match so that two
                // pieces of gear with the same name/type but different serials are kept
                // as separate items (e.g. two identical regulators owned by the same diver).
                let gearSerial = gearItem.serial
                var gearDescriptor = FetchDescriptor<Gear>()
                gearDescriptor.predicate = #Predicate<Gear> { gear in
                    gear.name == gearName && gear.category == category
                }
                let candidates = (try? modelContext.fetch(gearDescriptor)) ?? []
                let existingGear: Gear? = candidates.first { candidate in
                    // If either side has a serial, they must match.
                    // If neither has a serial, fall back to name+category match.
                    switch (candidate.serialNumber, gearSerial) {
                    case let (a?, b?): return a == b
                    case (nil, nil):   return true
                    default:           return false
                    }
                }
                
                if let gear = existingGear {
                    equipmentToAdd.append(gear)
                } else {
                    let newGear = Gear(
                        name: gearName,
                        category: category,
                        manufacturer: gearItem.manufacturer,
                        model: gearItem.model,
                        serialNumber: gearItem.serial,
                        datePurchased: gearItem.datePurchased ?? diveData.date ?? Date(),
                        purchasePrice: gearItem.purchasePrice,
                        currency: gearItem.currency,
                        purchasedFrom: gearItem.purchasedFrom,
                        weightContribution: gearItem.weightContribution ?? 0.0,
                        weightContributionUnit: gearItem.weightContributionUnit ?? UserPreferences.shared.weightUnit.symbol,
                        isInactive: gearItem.isInactive,
                        nextServiceDue: gearItem.nextServiceDue,
                        serviceHistory: gearItem.serviceHistory,
                        gearNotes: gearItem.gearNotes
                    )
                    modelContext.insert(newGear)
                    equipmentToAdd.append(newGear)
                }
            }
            
            // Associate gear with dive
            if newDive.usedGear == nil { newDive.usedGear = [] }
            newDive.usedGear!.append(contentsOf: equipmentToAdd)
            
            // Create marine life sightings from imported data
            for marineLifeData in diveData.marineLifeSeen {
                let marineSight = MarineSight(
                    name: marineLifeData.name,
                    count: marineLifeData.count
                )
                marineSight.dive = newDive
                if newDive.seenFish == nil { newDive.seenFish = [] }
                newDive.seenFish!.append(marineSight)
                modelContext.insert(marineSight)
            }
            
            try modelContext.save()
            
            // Check for milestones
            if UserDefaults.standard.bool(forKey: "notificationsEnabled") {
                let totalDives = (try? modelContext.fetchCount(FetchDescriptor<Dive>())) ?? 0
                NotificationManager.shared.notifyMilestoneAchieved(totalDives: totalDives)
            }
            
        } catch {
            importError = .saveFailed(error)
            showErrorAlert = true
        }
    }
    
    // MARK: - Helper Functions
    
    func determineGasName(oxygen: Int, helium: Int) -> String {
        if helium > 0 {
            return "Trimix"
        } else if oxygen > 21 {
            return "Nitrox"
        } else {
            return "Air"
        }
    }
    
    func mapMacDiveGearType(_ type: String) -> String {
        // Resolves both our own English export keys and legacy French rawValues.
        (GearCategory(exportKeyOrRawValue: type) ?? .other).rawValue
    }

    // MARK: - Merge Dives

    /// Merges two dives into one. The earlier dive is kept as the base and
    /// the later dive's samples are appended (offset by dive 1 duration + surface interval).
    /// Recalculated fields: maxDepth, averageDepth, duration, cns, tempAir, tempHigh, tempLow, endPressure.
    /// The later dive is deleted after merge.
    func mergeDives(_ diveA: Dive, with diveB: Dive) {
        // Determine which dive is earlier
        let (earlier, later) = diveA.timestamp <= diveB.timestamp ? (diveA, diveB) : (diveB, diveA)

        // --- Append samples from the later dive ---
        var combinedSamples = earlier.profileSamples
        let laterSamples = later.profileSamples

        // Time offset = last sample time of earlier dive + surface interval of later dive
        let earlierLastTime = combinedSamples.last?.time ?? Double(earlier.duration)

        // Parse surface interval from the later dive (stored as display string like "1h 36m")
        let surfaceMinutes = parseSurfaceIntervalMinutes(from: later.surfaceInterval) ?? 0

        let timeOffset = earlierLastTime + Double(surfaceMinutes)

        for sample in laterSamples {
            combinedSamples.append(DiveProfilePoint(
                time: sample.time + timeOffset,
                depth: sample.depth,
                temperature: sample.temperature,
                tankPressure: sample.tankPressure,
                tankPressures: sample.tankPressures,
                ndl: sample.ndl,
                ppo2: sample.ppo2
            ))
        }
        earlier.profileSamples = combinedSamples

        // --- Recalculate maxDepth ---
        let allDepths = combinedSamples.map(\.depth)
        earlier.maxDepth = allDepths.max() ?? earlier.maxDepth

        // --- Recalculate averageDepth (time-weighted) ---
        if combinedSamples.count >= 2 {
            var weightedSum = 0.0
            for i in 1..<combinedSamples.count {
                let dt = combinedSamples[i].time - combinedSamples[i - 1].time
                let avgDepth = (combinedSamples[i].depth + combinedSamples[i - 1].depth) / 2.0
                weightedSum += avgDepth * dt
            }
            let totalTime = (combinedSamples.last?.time ?? 0) - (combinedSamples.first?.time ?? 0)
            if totalTime > 0 {
                earlier.averageDepth = weightedSum / totalTime
            }
        }

        // --- Recalculate duration ---
        // Use the last sample time (which includes surface interval) converted to minutes
        if let lastTime = combinedSamples.last?.time {
            earlier.duration = Int(lastTime.rounded())
        } else {
            earlier.duration = earlier.duration + surfaceMinutes + later.duration
        }

        // --- CNS: take the higher value ---
        if let laterCNS = later.cnsPercentage {
            earlier.cnsPercentage = max(earlier.cnsPercentage ?? 0, laterCNS)
        }

        // --- tempAir: keep from earlier dive (pre-dive measurement) ---
        // Already preserved since we keep the earlier dive's data.

        // --- tempHigh: max of both ---
        if let laterHigh = later.maxTemperature {
            earlier.maxTemperature = max(earlier.maxTemperature ?? laterHigh, laterHigh)
        }

        // --- tempLow: min of both ---
        earlier.minTemperature = min(earlier.minTemperature, later.minTemperature)

        // --- endPressure: use the later dive's end pressure on the default tank ---
        if !earlier.tanks.isEmpty {
            var updatedTanks = earlier.tanks
            let tank = updatedTanks[0]
            updatedTanks[0] = TankData(
                id: tank.id,
                o2: tank.o2,
                he: tank.he,
                volume: tank.volume,
                startPressure: tank.startPressure,
                endPressure: later.tanks.first?.endPressure,
                workingPressure: tank.workingPressure,
                tankMaterial: tank.tankMaterial,
                tankType: tank.tankType
            )
            earlier.tanks = updatedTanks
        }

        // --- Delete the later dive ---
        modelContext.delete(later)
        try? modelContext.save()
    }

    /// Parses a surface interval display string like "1h 36m" or "2d 1h 30m" into total minutes.
    func parseSurfaceIntervalMinutes(from string: String) -> Int? {
        guard !string.isEmpty, string != "0h 00m" else { return nil }
        let patternWithDays = #/(\d+)d\s*(\d+)h\s*(\d+)m/#
        if let match = string.firstMatch(of: patternWithDays) {
            let days    = Int(match.output.1) ?? 0
            let hours   = Int(match.output.2) ?? 0
            let minutes = Int(match.output.3) ?? 0
            let total = (days * 1440) + (hours * 60) + minutes
            return total > 0 ? total : nil
        }
        let pattern = #/(\d+)h\s*(\d+)m/#
        guard let match = string.firstMatch(of: pattern) else { return nil }
        let hours   = Int(match.output.1) ?? 0
        let minutes = Int(match.output.2) ?? 0
        let total = hours * 60 + minutes
        return total > 0 ? total : nil
    }

    func exportAllDivesToXML() {
        let xml = BlueDiveXMLExporter.generateXML(for: dives)
        guard let data = xml.data(using: .utf8) else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let fileName = "BlueDive_Export_\(formatter.string(from: Date())).xml"
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName
        panel.allowedContentTypes = [.xml]
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? data.write(to: url)
        }
        #else
        exportDocument = ExportableFileDocument(data: data)
        exportFileName = fileName
        exportContentType = .xml
        showFileExporter = true
        #endif
    }

    func exportAllDivesToUDDF() {
        let uddf = BlueDiveUDDFExporter.generateUDDF(for: dives)
        guard let data = uddf.data(using: .utf8) else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let fileName = "BlueDive_Export_\(formatter.string(from: Date())).uddf"
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName
        panel.allowedContentTypes = [.uddf]
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? data.write(to: url)
        }
        #else
        exportDocument = ExportableFileDocument(data: data)
        exportFileName = fileName
        exportContentType = .uddf
        showFileExporter = true
        #endif
    }

}
