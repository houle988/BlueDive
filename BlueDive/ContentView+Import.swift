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

    func importDiveFile(from url: URL, preloadedData: Data? = nil, formats: ImportFormatOptions?, fileType: ImportFileType) {
        isImporting = true

        Task {
            do {
                let data: Data
                if let preloaded = preloadedData {
                    data = preloaded
                } else {
                    guard url.startAccessingSecurityScopedResource() else {
                        throw ImportError.accessDenied
                    }
                    defer { url.stopAccessingSecurityScopedResource() }
                    data = try Data(contentsOf: url)
                }

                let chosenFormats = formats ?? ImportFormatOptions()
                let parsedDives = try parseImportData(
                    data,
                    fileType: fileType,
                    formats: chosenFormats
                )

                await MainActor.run {
                    isImporting = false
                    routeParsedDives(parsedDives, fileName: url.lastPathComponent)
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

    // MARK: - Parsing

    // Parse and insert are kept separate so duplicate detection can run between them.
    private func parseImportData(
        _ data: Data,
        fileType: ImportFileType,
        formats: ImportFormatOptions
    ) throws -> [BlueDiveGlobalData] {
        switch fileType {
        case .macDive:
            return try parseMacDiveXML(data: data, formats: formats)
        case .blueDive:
            return try parseBlueDiveXML(data: data, importGear: formats.importGear)
        case .uddf:
            return try parseUDDFXML(data: data, importGear: formats.importGear)
        }
    }

    private func parseMacDiveXML(data: Data, formats: ImportFormatOptions) throws -> [BlueDiveGlobalData] {
        let parser = MacDiveXMLParser()
        parser.distanceFormat    = formats.distanceFormat
        parser.temperatureFormat = formats.temperatureFormat
        parser.pressureFormat    = formats.pressureFormat
        parser.volumeFormat      = formats.volumeFormat
        parser.weightFormat      = formats.weightFormat
        parser.importGear        = formats.importGear
        guard let parsedData = parser.parse(data: data), !parsedData.isEmpty else {
            throw ImportError.parsingFailed
        }
        return parsedData
    }

    private func parseBlueDiveXML(data: Data, importGear: Bool) throws -> [BlueDiveGlobalData] {
        let parser = BlueDiveXMLParser()
        parser.importGear = importGear
        guard let parsedData = parser.parse(data: data), !parsedData.isEmpty else {
            throw ImportError.parsingFailed
        }
        return parsedData
    }

    private func parseUDDFXML(data: Data, importGear: Bool) throws -> [BlueDiveGlobalData] {
        let parser = UDDFXMLParser()
        parser.importGear = importGear
        guard let parsedData = parser.parse(data: data), !parsedData.isEmpty else {
            throw ImportError.parsingFailed
        }
        return parsedData
    }

    // MARK: - Duplicate Detection

    @MainActor
    func routeParsedDives(_ parsed: [BlueDiveGlobalData], fileName: String) {
        let duplicates = findDuplicateMatches(in: parsed)
        if duplicates.isEmpty {
            commitParsedDives(parsed, indices: Array(parsed.indices), fileName: fileName)
        } else {
            pendingDuplicateImport = PendingDuplicateImport(
                parsedDives: parsed,
                duplicates: duplicates,
                fileName: fileName
            )
        }
    }

    @MainActor
    func commitParsedDives(_ parsed: [BlueDiveGlobalData], indices: [Int], fileName: String) {
        for index in indices {
            guard parsed.indices.contains(index) else { continue }
            insertDiveFromMacDive(parsed[index], fileName: fileName)
        }
        do {
            try modelContext.save()
            if UserDefaults.standard.bool(forKey: "notificationsEnabled") {
                let totalDives = (try? modelContext.fetchCount(FetchDescriptor<Dive>())) ?? 0
                NotificationManager.shared.notifyMilestoneAchieved(totalDives: totalDives)
            }
        } catch {
            importError = .saveFailed(error)
            showErrorAlert = true
        }
    }

    @MainActor
    func findDuplicateMatches(in parsed: [BlueDiveGlobalData]) -> [DuplicateImportMatch] {
        // Build lookup structures once so per-dive matching is O(1) instead of O(N).
        // One-to-many dict: multiple existing dives can share the same identifier string
        // (e.g. after a prior double-import). All candidates are kept; the best match is
        // chosen by temporal proximity rather than silently discarding collision victims.
        var divesByIdentifier: [String: [Dive]] = [:]
        for d in dives {
            let id = (d.identifier ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { continue }
            divesByIdentifier[id, default: []].append(d)
        }
        // Bucket existing dives by UTC minute; bucket radius is kept in sync with dateTolerance.
        let divesByMinute: [Int: [Dive]] = Dictionary(grouping: dives) {
            Int($0.timestamp.timeIntervalSince1970 / 60)
        }

        var matches: [DuplicateImportMatch] = []
        var consumedExistingIDs = Set<UUID>()
        for (index, dive) in parsed.enumerated() {
            guard let (existing, reason) = findExistingDuplicate(
                for: dive,
                excluding: consumedExistingIDs,
                divesByIdentifier: divesByIdentifier,
                divesByMinute: divesByMinute
            ) else { continue }
            consumedExistingIDs.insert(existing.id)
            matches.append(DuplicateImportMatch(
                parsedIndex: index,
                incomingDate: dive.date,
                incomingSiteName: dive.site?.name ?? "",
                incomingMaxDepth: dive.maxDepth,
                incomingDuration: dive.duration / 60,
                incomingDistanceUnit: dive.distanceFormat,
                existing: existing,
                reason: reason
            ))
        }
        return matches
    }

    @MainActor
    private func findExistingDuplicate(
        for incoming: BlueDiveGlobalData,
        excluding consumed: Set<UUID>,
        divesByIdentifier: [String: [Dive]],
        divesByMinute: [Int: [Dive]]
    ) -> (Dive, DuplicateMatchReason)? {
        // Tracks dives proven to belong to a different computer via identifier path.
        // Prevents the heuristic path from re-matching a dive already ruled out by serial mismatch
        // or a failed profile sanity check. Scoped per call so other incoming dives can still claim them.
        var identifierRejectedIDs = Set<UUID>()

        // Heuristic tolerances — also reused by the identifier path for profile sanity (H1 fix).
        let dateTolerance: TimeInterval = 180
        let durationToleranceMin = 2
        let depthToleranceMeters = 1.0

        // Pre-compute incoming values once; both paths use them.
        // BlueDiveGlobalData.duration is seconds; Dive.duration is stored in minutes (floor).
        let incomingDurationMin = incoming.duration / 60
        let incomingDepthMeters = depthInMeters(incoming.maxDepth, unit: incoming.distanceFormat)
        let incomingSiteName = (incoming.site?.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let incomingSerial = (incoming.serial ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // MARK: Identifier path
        // O(1) lookup — computer UID survives unit changes and edits.
        // Skipped entirely when incoming has no date (nil-date .min is non-deterministic).
        let trimmedID = (incoming.identifier ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedID.isEmpty, let incomingDate = incoming.date {
            // M3: divesByIdentifier keys are exact-case from the caller; collect all candidates
            // whose key case-folds equal to trimmedID so "42A" matches "42a".
            let loweredID = trimmedID.lowercased()
            var idCandidates: [Dive] = []
            for (key, dives) in divesByIdentifier where key.lowercased() == loweredID {
                idCandidates.append(contentsOf: dives)
            }

            // H2: try all candidates in temporal order, not just the nearest one.
            // A later candidate may have a better serial match even if the nearest one is rejected.
            // M5: deterministic tiebreak on UUID string when two candidates are equidistant.
            let sortedCandidates = idCandidates
                .filter { !consumed.contains($0.id) }
                .sorted { lhs, rhs in
                    let dl = abs(lhs.timestamp.timeIntervalSince(incomingDate))
                    let dr = abs(rhs.timestamp.timeIntervalSince(incomingDate))
                    if dl != dr { return dl < dr }
                    return lhs.id.uuidString < rhs.id.uuidString
                }

            for match in sortedCandidates {
                let existingSerial = (match.computerSerialNumber ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let bothSerialsMatch = !incomingSerial.isEmpty && !existingSerial.isEmpty && incomingSerial == existingSerial
                // When both serials are confirmed equal, allow 24 h of clock drift / timezone
                // ambiguity. Otherwise tighten to 2 h to reduce cross-diver false positives
                // (MacDive uses sequential numbers like "42" as identifiers).
                let dateLimit: TimeInterval = bothSerialsMatch ? 86_400 : 7_200
                let deltaT = abs(match.timestamp.timeIntervalSince(incomingDate))

                // Candidates are sorted nearest-first, but dateLimit varies per candidate
                // (a later candidate may have bothSerialsMatch and a larger window), so
                // skip rather than break.
                guard deltaT < dateLimit else { continue }

                let atLeastOneSerial = !incomingSerial.isEmpty || !existingSerial.isEmpty
                let serialsCompatible = incomingSerial.isEmpty || existingSerial.isEmpty || incomingSerial == existingSerial

                if atLeastOneSerial && serialsCompatible {
                    if deltaT <= dateTolerance && bothSerialsMatch {
                        // Both serials confirmed equal and within heuristic date window — maximum
                        // confidence. Trust identifier + serial directly; no profile check needed.
                        return (match, .sameIdentifier)
                    }
                    // Outside the heuristic window, or serials not both confirmed: require depth +
                    // duration sanity before declaring .sameIdentifier. Guards against firmware
                    // resets that recycle dive IDs — even within a short time window.
                    let existingDepthMeters = depthInMeters(match.maxDepth, unit: match.importDistanceUnit)
                    if abs(existingDepthMeters - incomingDepthMeters) <= depthToleranceMeters,
                       abs(match.duration - incomingDurationMin) <= durationToleranceMin {
                        return (match, .sameIdentifier)
                    }
                    // Profile validation failed — proven wrong dive despite matching identifier+serial.
                    // Block the heuristic from re-matching this candidate.
                    identifierRejectedIDs.insert(match.id)
                } else if !serialsCompatible {
                    // Hard serial mismatch — proven different computer.
                    // Block the heuristic and continue to try the next identifier candidate.
                    identifierRejectedIDs.insert(match.id)
                }
                // Both serials empty: fall through; heuristic will validate on profile.
            }
        }

        // MARK: Heuristic path
        // Fallback for files without identifiers (older MacDive exports, manual logs).
        // Depth is normalised to metres so a metric re-import of an imperial dive still matches.
        // 180 s (3 min) tolerates user-edited timestamps / clock-drift corrections while being
        // narrow enough that two genuinely separate dives (minimum surface interval >> 3 min)
        // cannot collide even at the same site with the same computer.
        guard let date = incoming.date else { return nil }

        // Bucket radius must cover the full dateTolerance window; kept in sync automatically.
        let minuteKey = Int(date.timeIntervalSince1970 / 60)
        let bucketRadius = Int(ceil(dateTolerance / 60))
        let candidates = (minuteKey - bucketRadius ... minuteKey + bucketRadius).flatMap { divesByMinute[$0] ?? [] }

        // When both sides have a non-empty site name, require them to match — avoids false
        // positives for back-to-back resort/training dives with similar profiles.
        // M5: deterministic tiebreak on UUID string when two candidates are equidistant.
        let match = candidates
            .filter { existing in
                guard !identifierRejectedIDs.contains(existing.id) else { return false }
                guard !consumed.contains(existing.id) else { return false }
                guard abs(existing.timestamp.timeIntervalSince(date)) <= dateTolerance else { return false }
                guard abs(existing.duration - incomingDurationMin) <= durationToleranceMin else { return false }
                let existingDepthMeters = depthInMeters(existing.maxDepth, unit: existing.importDistanceUnit)
                guard abs(existingDepthMeters - incomingDepthMeters) <= depthToleranceMeters else { return false }
                let existingSiteName = existing.siteName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !incomingSiteName.isEmpty, !existingSiteName.isEmpty,
                   existingSiteName.compare(incomingSiteName,
                                           options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame {
                    return false
                }
                // Serial discriminator: when both sides carry a serial number they must match.
                // Prevents a buddy's simultaneous dive (different computer) from being flagged
                // as a duplicate when profiles overlap and neither side has a site name.
                let existingSerial = (existing.computerSerialNumber ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !incomingSerial.isEmpty, !existingSerial.isEmpty, incomingSerial != existingSerial {
                    return false
                }
                return true
            }
            .min { lhs, rhs in
                let dl = abs(lhs.timestamp.timeIntervalSince(date))
                let dr = abs(rhs.timestamp.timeIntervalSince(date))
                if dl != dr { return dl < dr }
                return lhs.id.uuidString < rhs.id.uuidString
            }

        if let match { return (match, .sameDateAndProfile) }
        return nil
    }

    private func depthInMeters(_ value: Double, unit: String) -> Double {
        unit.lowercased() == "feet" ? value / 3.28084 : value
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
                events: sample.events,
                currentGas: sample.currentGas
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
            siteName: diveData.site?.name ?? NSLocalizedString("Unknown site", bundle: .forAppLanguage(), comment: "Fallback site name when an imported dive has no site name"),
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
        
        // Exit GPS (BlueDive XML round-trip)
        newDive.exitLatitude  = diveData.site?.exitLatitude
        newDive.exitLongitude = diveData.site?.exitLongitude

        // Deco stops (from BlueDive XML round-trip)
        if !diveData.decoStops.isEmpty {
            newDive.decoStops = diveData.decoStops
        }

        // Raw dive computer data (from BlueDive XML round-trip)
        newDive.rawDiveComputerData = diveData.rawDiveComputerData
        newDive.fingerprintData = diveData.fingerprintData

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

            // Fetch all gear once; both caches are updated after each insert so gear
            // created earlier in this loop is visible to subsequent iterations.
            var gearByID: [UUID: Gear] = {
                let all = (try? modelContext.fetch(FetchDescriptor<Gear>())) ?? []
                return Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
            }()
            var gearList: [Gear] = Array(gearByID.values)

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
                // Priority 1: UUID match (BlueDive XML exports carry the canonical gear UUID).
                // Priority 2: name + category + diverName + serial match — catches gear that was
                //   previously imported via a dive XML before UUID round-tripping was added, and
                //   also handles MacDive/UDDF imports that never carry a UUID.
                let existingGear: Gear?
                if let gearID = gearItem.id, let byID = gearByID[gearID] {
                    existingGear = byID
                } else {
                    existingGear = gearList.first {
                        $0.matches(name: gearName, category: category, diverName: gearItem.diverName, serial: gearItem.serial)
                    }
                }

                if let gear = existingGear {
                    equipmentToAdd.append(gear)
                } else {
                    let newGear = Gear(
                        id: gearItem.id ?? UUID(),
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
                        diverName: gearItem.diverName,
                        nextServiceDue: gearItem.nextServiceDue,
                        serviceHistory: gearItem.serviceHistory,
                        gearNotes: gearItem.gearNotes
                    )
                    modelContext.insert(newGear)
                    gearByID[newGear.id] = newGear
                    gearList.append(newGear)
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
        }
    }
    
    // MARK: - Helper Functions
    
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
        // Determine which dive is earlier.
        // Primary signal: timestamp. Tiebreaker: tank start pressure (more gas = start of dive),
        // so that dives with identical timestamps (e.g. date-only precision) are ordered correctly.
        let (earlier, later): (Dive, Dive) = {
            if diveA.timestamp != diveB.timestamp {
                return diveA.timestamp < diveB.timestamp ? (diveA, diveB) : (diveB, diveA)
            }
            let aStart = diveA.tanks.first?.startPressure ?? 0
            let bStart = diveB.tanks.first?.startPressure ?? 0
            return aStart >= bStart ? (diveA, diveB) : (diveB, diveA)
        }()

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
                ppo2: sample.ppo2,
                events: sample.events,
                currentGas: sample.currentGas
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

        // --- CNS: sum both segments, capped at 100% ---
        // Addition is conservative (ignores surface off-gassing) but correct when
        // the dive computer reset its CNS counter between the two dives.
        if let laterCNS = later.cnsPercentage {
            earlier.cnsPercentage = min(100, (earlier.cnsPercentage ?? 0) + laterCNS)
        }

        // --- tempAir: keep from earlier dive (pre-dive measurement) ---
        // Already preserved since we keep the earlier dive's data.

        // --- tempHigh: max of both ---
        if let laterHigh = later.maxTemperature {
            earlier.maxTemperature = max(earlier.maxTemperature ?? laterHigh, laterHigh)
        }

        // --- tempLow: min of both ---
        earlier.minTemperature = min(earlier.minTemperature, later.minTemperature)

        // --- Tank pressures: start from earlier dive, end from later dive ---
        // Tanks are matched by index (tank 0 ↔ tank 0, etc.).
        // Tanks in the earlier dive that have no counterpart in the later dive are unchanged.
        if !earlier.tanks.isEmpty {
            var updatedTanks = earlier.tanks
            let laterTanks = later.tanks
            for i in 0..<updatedTanks.count {
                guard i < laterTanks.count else { break }
                let tank = updatedTanks[i]
                updatedTanks[i] = TankData(
                    id: tank.id,
                    o2: tank.o2,
                    he: tank.he,
                    volume: tank.volume,
                    startPressure: tank.startPressure,
                    endPressure: laterTanks[i].endPressure,
                    workingPressure: tank.workingPressure,
                    tankMaterial: tank.tankMaterial,
                    tankType: tank.tankType
                )
            }
            earlier.tanks = updatedTanks
        }

        // --- Exit GPS: always taken from the later dive (nil if it has none) ---
        // Entry GPS stays from the earlier dive.
        earlier.exitLatitude  = later.exitLatitude
        earlier.exitLongitude = later.exitLongitude

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
