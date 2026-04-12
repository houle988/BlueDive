import SwiftUI
import Charts
import SwiftData
import PhotosUI

// MARK: - Menu Tab (chart + twin tank checkbox + stats + info)

extension DiveDetailView {

    var menuTabContent: some View {
        VStack(spacing: 20) {
            depthProfileSection
            statsGrid
            diveInfoSection
            photosSection
            equipmentSection
            marineSightingsSection
            notesSection
        }
    }

    // MARK: - View Components

    var defaultDepthChart: some View {
        Chart {
            ForEach(Array(defaultProfilePoints.enumerated()), id: \.offset) { _, point in
                AreaMark(
                    x: .value("Time", point.time),
                    y: .value("Depth", point.depth)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.cyan.opacity(0.3), Color.cyan.opacity(0.1)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                LineMark(
                    x: .value("Time", point.time),
                    y: .value("Depth", point.depth)
                )
                .foregroundStyle(Color.cyan)
                .lineStyle(StrokeStyle(lineWidth: 2.5))
            }
        }
        .chartYScale(domain: .automatic(includesZero: true, reversed: true))
        .chartXScale(domain: 0...Double(dive.duration))
        .chartXAxis {
            AxisMarks(values: .automatic) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(.white.opacity(0.2))
                AxisValueLabel {
                    if let time = value.as(Double.self) {
                        Text("\(Int(time)) min")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(.white.opacity(0.2))
                AxisValueLabel {
                    if let depth = value.as(Double.self) {
                        Text("\(Int(depth))m")
                            .font(.caption2)
                            .foregroundStyle(.cyan)
                    }
                }
            }
        }
        .frame(height: 250)
    }

    var depthProfileSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("#\(dive.diveNumber ?? diveNumber)")
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.bold)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.cyan.opacity(0.2))
                    .foregroundStyle(.cyan)
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                Text(dive.siteName)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(dive.shortFormattedDuration)
                            .font(.system(.caption2, design: .monospaced))
                            .fontWeight(.semibold)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.2))
                            .foregroundStyle(.green)
                            .clipShape(RoundedRectangle(cornerRadius: 4))

                        if !dive.surfaceInterval.isEmpty && dive.surfaceInterval != "0h 00m" {
                            Text(dive.displaySurfaceInterval)
                                .font(.system(.caption2, design: .monospaced))
                                .fontWeight(.semibold)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.2))
                                .foregroundStyle(.orange)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }
                    #if os(iOS)
                    locationText
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(dive.timestamp.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    #else
                    (Text(dive.timestamp.formatted(date: .abbreviated, time: .shortened)) + Text(" — ") + locationText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    #endif
                }
                Spacer()
                RatingStarsView(rating: dive.rating)
            }

            // Nouveau graphique unifié interactif
            if !dive.profileSamples.isEmpty {
                UnifiedDiveChartOptimized(dive: dive)
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 20).fill(.ultraThinMaterial))
        .padding(.horizontal)
    }

    // Vérifie si on a des données supplémentaires à afficher
    var hasAdditionalData: Bool {
        dive.profileSamples.contains { $0.temperature != nil || $0.tankPressure != nil || $0.ndl != nil }
    }

    // Légende du graphique
    var chartLegend: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Legend")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)

            // Ascent rate indicators
            HStack(spacing: 16) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.cyan)
                        .frame(width: 8, height: 8)
                    Text("Depth")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.orange.opacity(0.4))
                        .frame(width: 16, height: 8)
                    Text("Fast Ascent (10-18 m/min)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.red.opacity(0.5))
                        .frame(width: 16, height: 8)
                    Text("Dangerous Ascent (≥18 m/min)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.top, 8)
    }

    var depthChart: some View {
        VStack(spacing: 0) {
            // Graphique de profondeur principal
            Chart {
                depthChartContent
            }
            .chartYScale(domain: .automatic(includesZero: true, reversed: true))
            .chartXScale(domain: 0...Double(dive.duration))
            .chartXAxis {
                AxisMarks(values: .automatic) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(.white.opacity(0.2))
                    AxisValueLabel {
                        if let time = value.as(Double.self) {
                            Text("\(Int(time)) min")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(.white.opacity(0.2))
                    AxisValueLabel {
                        if let depth = value.as(Double.self) {
                            Text("\(Int(depth))m")
                                .font(.caption2)
                                .foregroundStyle(.cyan)
                        }
                    }
                }
            }
            .frame(height: 250)

            // Graphiques secondaires (Température, Pression, NDL)
            if hasAdditionalData {
                secondaryChartsView
            }
        }
    }

    // Vue pour les graphiques secondaires
    var secondaryChartsView: some View {
        VStack(spacing: 8) {
            Divider()
                .background(.primary.opacity(0.2))
                .padding(.vertical, 4)

            HStack(spacing: 12) {
                // Température
                if dive.profileSamples.contains(where: { $0.temperature != nil }) {
                    let tempPrefs = UserPreferences.shared.temperatureUnit
                    miniChartView(
                        title: "Temp",
                        values: dive.profileSamples.compactMap { $0.temperature.map { tempPrefs.convert($0, from: dive.storedTemperatureUnit) } },
                        color: .green,
                        unit: tempPrefs.symbol
                    )
                }

                // Pression
                if dive.profileSamples.contains(where: { $0.tankPressure != nil }) {
                    miniChartView(
                        title: "Press",
                        values: dive.profileSamples.compactMap { $0.tankPressure.map { dive.displayProfilePressure($0) } },
                        color: .red,
                        unit: prefs.pressureUnit.symbol
                    )
                }

                // NDL
                if dive.profileSamples.contains(where: { $0.ndl != nil }) {
                    miniChartView(
                        title: "NDL",
                        values: dive.profileSamples.compactMap { $0.ndl },
                        color: .yellow,
                        unit: "min"
                    )
                }
            }
            .frame(height: 60)
        }
    }

    // Mini graphique pour les données secondaires
    func miniChartView(title: String, values: [Double], color: Color, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                Text(title)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 4) {
                if let min = values.min(), let max = values.max() {
                    Text("\(Int(min))-\(Int(max))")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(color)
                    Text(unit)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            // Mini sparkline
            GeometryReader { geometry in
                Path { path in
                    guard !values.isEmpty else { return }
                    let maxValue = values.max() ?? 1
                    let minValue = values.min() ?? 0
                    let range = maxValue - minValue

                    guard range > 0 else { return }

                    let step = geometry.size.width / CGFloat(values.count - 1)

                    for (index, value) in values.enumerated() {
                        let x = CGFloat(index) * step
                        let normalizedValue = (value - minValue) / range
                        let y = geometry.size.height * (1 - normalizedValue)

                        if index == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                }
                .stroke(color, lineWidth: 1.5)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(color.opacity(0.1))
        )
    }

    @ChartContentBuilder
    var depthChartContent: some ChartContent {
        if !dive.profileSamples.isEmpty {
            // AFFICHAGE DU PROFIL RÉEL (UDDF)

            // Indicateurs de vitesse de remontée (en arrière-plan)
            ascentRateIndicators

            // Main depth profile (in foreground)
            ForEach(dive.profileSamples) { sample in
                AreaMark(
                    x: .value("Time", sample.time),
                    y: .value("Depth", sample.depth)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.cyan.opacity(0.4), Color.cyan.opacity(0.1)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                LineMark(
                    x: .value("Time", sample.time),
                    y: .value("Depth", sample.depth)
                )
                .foregroundStyle(Color.cyan)
                .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            }

        } else {
            // DEFAULT CURVE IF NO IMPORT
            ForEach(Array(defaultProfilePoints.enumerated()), id: \.offset) { _, point in
                AreaMark(
                    x: .value("Time", point.time),
                    y: .value("Depth", point.depth)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.cyan.opacity(0.3), Color.cyan.opacity(0.1)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                LineMark(
                    x: .value("Time", point.time),
                    y: .value("Depth", point.depth)
                )
                .foregroundStyle(Color.cyan)
                .lineStyle(StrokeStyle(lineWidth: 2.5))
            }
        }
    }

    // Indicateurs de vitesse de remontée
    @ChartContentBuilder
    var ascentRateIndicators: some ChartContent {
        let samples = dive.profileSamples

        if samples.count >= 2 {
            ForEach(Array(samples.indices.dropFirst()), id: \.self) { i in
                let previous = samples[i - 1]
                let current = samples[i]

                // Calculer la vitesse de remontée (m/min)
                let timeDiff = current.time - previous.time
                let depthDiff = previous.depth - current.depth // Positif si on remonte

                if timeDiff > 0 {
                    let ascentRate = depthDiff / timeDiff // m/min

                    // Seulement si on remonte (ascentRate > 0)
                    if ascentRate > 9 {
                        let color: Color = ascentRate >= 18 ? .red : .orange
                        let opacityValue = ascentRate >= 18 ? 0.5 : 0.3

                        // Afficher une zone colorée pour cette portion
                        RectangleMark(
                            xStart: .value("Start", previous.time),
                            xEnd: .value("End", current.time),
                            yStart: .value("Top", 0),
                            yEnd: .value("Bottom", dive.displayMaxDepth)
                        )
                        .foregroundStyle(color.opacity(opacityValue))
                    }
                }
            }
        }
    }

    var defaultProfilePoints: [(time: Double, depth: Double)] {
        [
            (0, 0),
            (5, dive.displayMaxDepth * 0.7),
            (15, dive.displayMaxDepth),
            (30, dive.displayMaxDepth * 0.9),
            (40, 3),
            (45, 0)
        ]
    }

    var photosSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Photos", systemImage: "photo.fill")
                    .font(.headline)
                    .foregroundStyle(.pink)
                Spacer()
                if !(dive.photosData?.isEmpty ?? true) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isEditingPhotos.toggle()
                        }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.pink)
                    }
                    .buttonStyle(.plain)
                }
                PhotosPicker(selection: $selectedPhotos, maxSelectionCount: 10, matching: .images) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.pink)
                }
            }

            if dive.photosData?.isEmpty ?? true {
                Text("No photo.")
                    .font(.caption)
                    .foregroundStyle(.gray)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(Array((dive.photosData ?? []).enumerated()), id: \.offset) { index, photoData in
                            if let uiImage = PlatformImage(data: photoData) {
                                ZStack(alignment: .topTrailing) {
                                    Image(platformImage: uiImage)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 150, height: 150)
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            if !isEditingPhotos {
                                                selectedPhotoForPreview = IdentifiablePhotoData(data: photoData, index: index)
                                            }
                                        }
                                        .onLongPressGesture {
                                            withAnimation(.easeInOut(duration: 0.2)) {
                                                isEditingPhotos.toggle()
                                            }
                                        }
                                    if isEditingPhotos {
                                        Button {
                                            photoIndexToDelete = index
                                            showDeletePhotoAlert = true
                                        } label: {
                                            Image(systemName: "minus.circle.fill")
                                                .font(.system(size: 18))
                                                .symbolRenderingMode(.palette)
                                                .foregroundStyle(.white, .red)
                                        }
                                        #if os(macOS)
                                        .buttonStyle(.plain)
                                        #endif
                                        .offset(x: 6, y: -6)
                                        .transition(.scale.combined(with: .opacity))
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 15).fill(Color.primary.opacity(0.05)))
        .padding(.horizontal)
        #if os(iOS)
        .onTapGesture {
            if isEditingPhotos {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isEditingPhotos = false
                }
            }
        }
        #endif
        .alert("Remove Photo", isPresented: $showDeletePhotoAlert, presenting: photoIndexToDelete) { index in
            Button("Remove", role: .destructive) {
                withAnimation {
                    deletePhoto(at: index)
                }
                if (dive.photosData?.isEmpty ?? true) {
                    isEditingPhotos = false
                }
            }
            Button("Cancel", role: .cancel) { photoIndexToDelete = nil }
        } message: { _ in
            Text("Remove this photo from the dive?")
        }
        .sheet(item: $selectedPhotoForPreview) { item in
            PhotoPreviewSheet(photoData: item.data, onDelete: {
                deletePhoto(at: item.index)
                selectedPhotoForPreview = nil
                if (dive.photosData?.isEmpty ?? true) {
                    isEditingPhotos = false
                }
            })
        }
        .onChange(of: selectedPhotos) {
            Task {
                await loadPhotos()
            }
        }
    }

    @MainActor
    func loadPhotos() async {
        for item in selectedPhotos {
            if let data = try? await item.loadTransferable(type: Data.self) {
                if dive.photosData == nil {
                    dive.photosData = []
                }
                dive.photosData?.append(data)
            }
        }
        selectedPhotos.removeAll()
        try? modelContext.save()
    }

    @MainActor
    func deletePhoto(at index: Int) {
        dive.photosData?.remove(at: index)
        try? modelContext.save()
    }

    @MainActor
    func removeGearFromDive(_ gear: Gear) {
        dive.usedGear?.removeAll { $0.id == gear.id }
        try? modelContext.save()
        // Exit edit mode if no gear left
        if (dive.usedGear ?? []).isEmpty {
            isEditingEquipment = false
        }
    }

    @MainActor
    func removeFishFromDive(_ fish: MarineSight) {
        modelContext.delete(fish)
        try? modelContext.save()
        // Exit edit mode if no marine life left
        if (dive.seenFish ?? []).isEmpty {
            isEditingMarineLife = false
        }
    }

    @MainActor
    func applyGearGroup(_ group: GearGroup) {
        guard let groupGear = group.gear, !groupGear.isEmpty else { return }
        if dive.usedGear == nil { dive.usedGear = [] }
        let existingIds = Set((dive.usedGear ?? []).map { $0.id })
        var addedCount = 0
        for gear in groupGear {
            if !existingIds.contains(gear.id) {
                dive.usedGear!.append(gear)
                addedCount += 1
            }
        }
        if addedCount > 0 {
            try? modelContext.save()
        }
    }

    var equipmentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Equipment Used", systemImage: "wrench.and.screwdriver.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Spacer()
                if !(dive.usedGear ?? []).isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isEditingEquipment.toggle()
                        }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                }
                if !gearGroups.isEmpty {
                    Menu {
                        ForEach(gearGroups) { group in
                            Button {
                                applyGearGroup(group)
                            } label: {
                                Label("\(group.name) (\(group.gearCount))", systemImage: "tray.2.fill")
                            }
                        }
                    } label: {
                        Image(systemName: "tray.2.fill")
                            .font(.title3)
                            .foregroundStyle(.orange)
                    }
                }
                Button(action: { showAddGear = true }) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.orange)
                }
            }

            if (dive.usedGear ?? []).isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.title2)
                        .foregroundStyle(.secondary)

                    Text("No Equipment Recorded")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            } else {
                // Liste des équipements
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(dive.usedGear ?? []) { gear in
                            ZStack(alignment: .topTrailing) {
                                GearChipView(gear: gear)
                                    .contentShape(Rectangle())
                                    #if os(iOS)
                                    .onTapGesture { }
                                    .onLongPressGesture {
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            isEditingEquipment.toggle()
                                        }
                                    }
                                    #endif
                                if isEditingEquipment {
                                    Button {
                                        gearToDelete = gear
                                        showDeleteGearAlert = true
                                    } label: {
                                        Image(systemName: "minus.circle.fill")
                                            .font(.system(size: 18))
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, .red)
                                    }
                                    #if os(macOS)
                                    .buttonStyle(.plain)
                                    #endif
                                    .offset(x: 6, y: -6)
                                    .transition(.scale.combined(with: .opacity))
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 15).fill(Color.primary.opacity(0.05)))
        .padding(.horizontal)
        #if os(iOS)
        .onTapGesture {
            if isEditingEquipment {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isEditingEquipment = false
                }
            }
        }
        #endif
        .alert("Remove Equipment", isPresented: $showDeleteGearAlert, presenting: gearToDelete) { gear in
            Button("Remove", role: .destructive) {
                removeGearFromDive(gear)
            }
            Button("Cancel", role: .cancel) { }
        } message: { gear in
            Text("Remove \(gear.name) from this dive?")
        }
    }

    var marineSightingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Marine Life Seen", systemImage: "fish.fill")
                    .font(.headline)
                    .foregroundStyle(.cyan)
                Spacer()
                if !(dive.seenFish ?? []).isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isEditingMarineLife.toggle()
                        }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.cyan)
                    }
                    .buttonStyle(.plain)
                }
                Button(action: { showAddFish = true }) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.cyan)
                }
            }

            if (dive.seenFish ?? []).isEmpty {
                Text("No fish saved.")
                    .font(.caption)
                    .foregroundStyle(.gray)
            } else {
                fishScrollView
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 15).fill(Color.primary.opacity(0.05)))
        .padding(.horizontal)
        #if os(iOS)
        .onTapGesture {
            if isEditingMarineLife {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isEditingMarineLife = false
                }
            }
        }
        #endif
        .alert("Remove Marine Life", isPresented: $showDeleteFishAlert, presenting: fishToDelete) { fish in
            Button("Remove", role: .destructive) {
                removeFishFromDive(fish)
            }
            Button("Cancel", role: .cancel) { }
        } message: { fish in
            Text("Remove \(fish.name) from this dive?")
        }
    }

    var fishScrollView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 12) {
                ForEach(dive.seenFish ?? []) { fish in
                    ZStack(alignment: .topTrailing) {
                        FishChipView(fish: fish)
                            .contentShape(Rectangle())
                            #if os(iOS)
                            .onTapGesture { }
                            .onLongPressGesture {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    isEditingMarineLife.toggle()
                                }
                            }
                            #endif
                        if isEditingMarineLife {
                            Button {
                                fishToDelete = fish
                                showDeleteFishAlert = true
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .font(.system(size: 18))
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .red)
                            }
                            #if os(macOS)
                            .buttonStyle(.plain)
                            #endif
                            .offset(x: 6, y: -6)
                            .transition(.scale.combined(with: .opacity))
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    var statsGrid: some View {
        let depthMax     = dive.displayMaxDepth
        let depthAvg     = dive.displayAverageDepth
        let depthSymbol  = prefs.depthUnit.symbol
        let pressSymbol  = prefs.pressureUnit.symbol
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 260))], spacing: 10) {
            DetailCard(
                title: "COMPUTER",
                value: dive.computerName.isEmpty ? "—" : dive.computerName,
                icon: "cpu.fill",
                color: .blue
            )

            DetailCard(
                title: "SERIAL",
                value: dive.computerSerialNumber?.isEmpty == false ? dive.computerSerialNumber!.uppercased() : "—",
                icon: "barcode",
                color: .cyan
            )

            DetailCard(
                title: "MAX",
                value: depthMax,
                specifier: "%.1f",
                unit: depthSymbol,
                icon: "arrow.down.circle.fill",
                color: .blue
            )

            DetailCard(
                title: "AVERAGE",
                value: depthAvg,
                specifier: "%.1f",
                unit: depthSymbol,
                icon: "waveform.path.ecg",
                color: .cyan
            )

            DetailCard(
                title: "DURATION",
                value: dive.formattedDuration,
                icon: "clock.fill",
                color: .green
            )

            DetailCard(
                title: "REPETITIVE",
                localizedValue: dive.isRepetitiveDive ? "Yes" : "No",
                icon: "arrow.triangle.2.circlepath",
                color: dive.isRepetitiveDive ? .orange : .gray
            )

            DetailCard(
                title: "RMV",
                value: dive.formattedRMV,
                icon: "lungs.fill",
                color: .pink
            )

            DetailCard(
                title: "SAC",
                value: dive.formattedSAC,
                icon: "gauge.with.dots.needle.bottom.50percent",
                color: .mint
            )

            DetailCard(
                title: "MIN TEMP",
                value: dive.minTemperature != 0 ? UserPreferences.shared.temperatureUnit.formatted(dive.minTemperature, from: dive.storedTemperatureUnit) : "—",
                icon: "thermometer.low",
                color: .orange
            )

            DetailCard(
                title: "GAS MIX",
                value: dive.formattedGasType,
                icon: "bubbles.and.sparkles.fill",
                color: .purple
            )

            DetailCard(
                title: "START PRESS.",
                value: dive.displayStartPressure.map { String(format: "%.0f \(pressSymbol)", $0) } ?? "—",
                icon: "gauge.with.needle.fill",
                color: .red
            )

            DetailCard(
                title: "END PRESS.",
                value: dive.displayEndPressure.map { String(format: "%.0f \(pressSymbol)", $0) } ?? "—",
                icon: "gauge.with.dots.needle.bottom.50percent",
                color: .red
            )

            DetailCard(
                title: "WEIGHT",
                value: dive.weights.map { UserPreferences.shared.weightUnit.formatted($0, from: dive.storedWeightUnit) } ?? "—",
                icon: "scalemass.fill",
                color: .gray
            )
        }
        .padding(.horizontal)
    }

    // MARK: - Dive Info Section (Diver, Buddies, Type)

    var diveInfoSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Dive Information")
                .font(.headline)
                .foregroundStyle(.primary)

            // Dive Number
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.orange.opacity(0.15))
                        .frame(width: 40, height: 40)
                    Image(systemName: "number")
                        .foregroundStyle(.orange)
                        .font(.system(size: 18))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Dive #")
                        .font(.caption)
                        .foregroundStyle(.gray)
                    if let diveNumber = dive.diveNumber {
                        Text("\(diveNumber)")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.primary)
                    } else {
                        Text("—")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }

            Divider()
                .background(.primary.opacity(0.2))

            // Diver Name
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.cyan.opacity(0.15))
                        .frame(width: 40, height: 40)
                    Image(systemName: "person.fill")
                        .foregroundStyle(.cyan)
                        .font(.system(size: 18))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Diver")
                        .font(.caption)
                        .foregroundStyle(.gray)
                    Text(dive.diverName.isEmpty ? "—" : dive.diverName)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(dive.diverName.isEmpty ? Color.secondary : Color.primary)
                }

                Spacer()
            }

            Divider()
                .background(.primary.opacity(0.2))

            // Buddies
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.15))
                        .frame(width: 40, height: 40)
                    Image(systemName: "person.2.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 16))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Buddy(ies)")
                        .font(.caption)
                        .foregroundStyle(.gray)

                    Text(dive.buddies.isEmpty ? "—" : dive.buddies)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(dive.buddies.isEmpty ? Color.secondary : Color.primary)
                }

                Spacer()
            }

            Divider()
                .background(.primary.opacity(0.2))

            // Dive Type with multiple types support
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.purple.opacity(0.15))
                        .frame(width: 40, height: 40)
                    Image(systemName: diveTypeIcon(for: dive.primaryDiveType))
                        .foregroundStyle(.purple)
                        .font(.system(size: 18))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Dive Type")
                        .font(.caption)
                        .foregroundStyle(.gray)

                    Text(dive.diveTypes?.isEmpty != false ? dive.primaryDiveType : dive.diveTypes!)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                }

                Spacer()
            }

            Divider()
                .background(.primary.opacity(0.2))

            // Dive Operator
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.15))
                        .frame(width: 40, height: 40)
                    Image(systemName: "building.2.fill")
                        .foregroundStyle(.blue)
                        .font(.system(size: 16))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Dive Center")
                        .font(.caption)
                        .foregroundStyle(.gray)
                    Text(dive.diveOperator?.isEmpty == false ? dive.diveOperator! : "—")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(dive.diveOperator?.isEmpty == false ? .primary : .secondary)
                }

                Spacer()
            }

            Divider()
                .background(.primary.opacity(0.2))

            // Dive Master
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.teal.opacity(0.15))
                        .frame(width: 40, height: 40)
                    Image(systemName: "person.badge.shield.checkmark.fill")
                        .foregroundStyle(.teal)
                        .font(.system(size: 16))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Guide/Instructor")
                        .font(.caption)
                        .foregroundStyle(.gray)
                    Text(dive.diveMaster?.isEmpty == false ? dive.diveMaster! : "—")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(dive.diveMaster?.isEmpty == false ? .primary : .secondary)
                }

                Spacer()
            }

            Divider()
                .background(.primary.opacity(0.2))

            // Skipper
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.indigo.opacity(0.15))
                        .frame(width: 40, height: 40)
                    Image(systemName: "person.fill.turn.right")
                        .foregroundStyle(.indigo)
                        .font(.system(size: 16))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Captain")
                        .font(.caption)
                        .foregroundStyle(.gray)
                    Text(dive.skipper?.isEmpty == false ? dive.skipper! : "—")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(dive.skipper?.isEmpty == false ? .primary : .secondary)
                }

                Spacer()
            }

            Divider()
                .background(.primary.opacity(0.2))

            // Boat
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.mint.opacity(0.15))
                        .frame(width: 40, height: 40)
                    Image(systemName: "ferry.fill")
                        .foregroundStyle(.mint)
                        .font(.system(size: 16))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Boat")
                        .font(.caption)
                        .foregroundStyle(.gray)
                    Text(dive.boat?.isEmpty == false ? dive.boat! : "—")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(dive.boat?.isEmpty == false ? .primary : .secondary)
                }

                Spacer()
            }

            Divider()
                .background(.primary.opacity(0.2))

            // Tags
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.pink.opacity(0.15))
                        .frame(width: 40, height: 40)
                    Image(systemName: "tag.fill")
                        .foregroundStyle(.pink)
                        .font(.system(size: 16))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Tags")
                        .font(.caption)
                        .foregroundStyle(.gray)
                    Text(dive.tags?.isEmpty == false ? dive.tags! : "—")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(dive.tags?.isEmpty == false ? .primary : .secondary)
                }

                Spacer()
            }

            Divider()
                .background(.primary.opacity(0.2))

            // Entry Type
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.yellow.opacity(0.15))
                        .frame(width: 40, height: 40)
                    Image(systemName: "arrow.down.to.line.circle.fill")
                        .foregroundStyle(.yellow)
                        .font(.system(size: 16))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Entry Type")
                        .font(.caption)
                        .foregroundStyle(.gray)
                    Text(dive.entryType?.isEmpty == false ? dive.entryType! : "—")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(dive.entryType?.isEmpty == false ? .primary : .secondary)
                }

                Spacer()
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 15).fill(Color.primary.opacity(0.05)))
        .padding(.horizontal)
    }

    // Helper pour obtenir l'icône selon le type de plongée
    func diveTypeIcon(for type: String) -> String {
        switch type.lowercased() {
        case let t where t.contains("récif") || t.contains("reef"):
            return "leaf.fill"
        case let t where t.contains("épave") || t.contains("wreck"):
            return "shippingbox.fill"
        case let t where t.contains("dérive") || t.contains("drift"):
            return "wind"
        case let t where t.contains("mur") || t.contains("wall"):
            return "square.stack.3d.up.fill"
        case let t where t.contains("nuit") || t.contains("night"):
            return "moon.stars.fill"
        case let t where t.contains("caverne") || t.contains("cave") || t.contains("grotte"):
            return "mountain.2.fill"
        case let t where t.contains("photo"):
            return "camera.fill"
        case let t where t.contains("profond") || t.contains("deep"):
            return "arrow.down.circle.fill"
        case let t where t.contains("formation") || t.contains("training"):
            return "graduationcap.fill"
        default:
            return "figure.open.water.swim"
        }
    }

    var notesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Notes", systemImage: "note.text")
                .font(.headline)
                .foregroundStyle(.gray)
            Text(dive.notes.isEmpty ? "—" : dive.notes)
                .font(.body)
                .foregroundStyle(dive.notes.isEmpty ? Color.secondary : Color.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(RoundedRectangle(cornerRadius: 15).fill(Color.primary.opacity(0.05)))
        .padding(.horizontal)
    }
}
