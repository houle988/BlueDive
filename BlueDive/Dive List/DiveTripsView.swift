import SwiftUI
import SwiftData
import ImageIO

// MARK: - Dive Trip Model

/// A trip is a lightweight value type derived from dives — no extra SwiftData model needed.
struct DiveTrip: Identifiable {
    let id: UUID = UUID()
    let name: String
    let location: String
    let dives: [Dive]

    var startDate: Date { dives.map(\.timestamp).min() ?? .now }
    var endDate: Date   { dives.map(\.timestamp).max() ?? .now }

    var totalDives: Int        { dives.count }
    var totalMinutes: Int      { dives.map(\.duration).reduce(0, +) }
    /// Compared in the display unit: each dive keeps its depth in the unit it was imported
    /// in, so raw `maxDepth` values of metric and imperial dives are not comparable.
    var deepestDive: Dive?     { dives.max(by: { $0.displayMaxDepth < $1.displayMaxDepth }) }
    var longestDive: Dive?     { dives.max(by: Dive.isShorterDuration) }
    var bestRatedDive: Dive?   { dives.max(by: { $0.rating < $1.rating }) }
    var averageRating: Double  {
        let rated = dives.filter { $0.rating > 0 }
        guard !rated.isEmpty else { return 0 }
        return Double(rated.map(\.rating).reduce(0, +)) / Double(rated.count)
    }
    /// Average maximum depth in the user's display unit (each dive converted from its own
    /// stored unit before averaging).
    var averageMaxDepth: Double {
        guard !dives.isEmpty else { return 0 }
        return dives.map(\.displayMaxDepth).reduce(0, +) / Double(dives.count)
    }
    /// The trip's average RMV (0 when no dive has one) and whether any RMV in it was not
    /// natively available in bar and litres (the value then carries the " *" footnote marker,
    /// as on the Statistics dashboard). One pass: `calculatedRMV` decodes each dive's profile
    /// and tanks, so read this once per render.
    var rmvSummary: (average: Double, isEstimated: Bool) {
        // The shared rule (`rmvAggregate`, also the Statistics dashboard's). It skips dives
        // deleted on another device; the trip's other figures still read every dive, as before.
        let rmv = rmvAggregate(dives)
        return (rmv.average, rmv.isEstimated)
    }
    var formattedTotalTime: String { formattedMinutes(totalMinutes) }
    var durationDays: Int {
        Calendar.current.dateComponents([.day], from: startDate, to: endDate).day.map { $0 + 1 } ?? 1
    }
    var uniqueSites: Int {
        uniqueSiteCount(dives.map(\.siteName))
    }
    /// Where the cover comes from: the earliest photo record (with a thumbnail) of the first
    /// dive that has one, else that dive's first legacy photo. Found from the links only — no
    /// image is read — so it can key the card's decode task.
    enum CoverSource {
        case photo(DivePhoto)
        case legacy(Dive)

        /// Changes when the cover changes (a photo added, removed, or a thumbnail arriving
        /// from iCloud), so the card decodes the new one.
        var key: String {
            switch self {
            case .photo(let photo): return "p:\(photo.id.uuidString)"
            case .legacy(let dive): return "l:\(dive.id.uuidString)"
            }
        }
    }

    var coverSource: CoverSource? {
        for dive in dives {
            // Photos whose thumbnail has arrived (`thumbnail != nil` reads the link only).
            let withThumbnail = (dive.photos ?? []).filter { $0.thumbnail != nil }
            if let photo = withThumbnail.min(by: { ($0.captureDate ?? $0.createdAt) < ($1.captureDate ?? $1.createdAt) }) {
                return .photo(photo)
            }
            if !(dive.photosData?.isEmpty ?? true) { return .legacy(dive) }
        }
        return nil
    }

    /// Cover image for the trip card: the source's thumbnail (CLAUDE.md, "Image Data in
    /// SwiftData": grids read thumbnails, never originals; 512 px is enough for the 140 pt
    /// header), or the legacy photo. Only that one image is loaded; `TripCard` decodes it once,
    /// off the main thread.
    func coverPhotoData(from source: CoverSource) -> Data? {
        switch source {
        case .photo(let photo): return photo.thumbnailBytes
        case .legacy(let dive): return dive.photosData?.first
        }
    }
}

// MARK: - Trip Builder

struct TripBuilder {
    /// Groups dives into trips by date only: a dive within 7 days of the previous one joins
    /// its trip, wherever it took place. Location is used only to name the trip.
    static func buildTrips(from dives: [Dive]) -> [DiveTrip] {
        guard !dives.isEmpty else { return [] }

        let sorted = dives.sorted { $0.timestamp < $1.timestamp }
        var trips: [DiveTrip] = []
        var currentGroup: [Dive] = []

        for dive in sorted {
            guard let lastDive = currentGroup.last else {
                currentGroup.append(dive)
                continue
            }
            let daysBetween = Calendar.current.dateComponents(
                    [.day],
                    from: lastDive.timestamp,
                    to: dive.timestamp
            ).day ?? 999

            if daysBetween <= 7 {
                currentGroup.append(dive)
            } else {
                trips.append(makeTrip(from: currentGroup))
                currentGroup = [dive]
            }
        }
        if !currentGroup.isEmpty {
            trips.append(makeTrip(from: currentGroup))
        }

        return trips.sorted { $0.startDate > $1.startDate } // most recent first
    }

    private static func makeTrip(from dives: [Dive]) -> DiveTrip {
        // Use the most common location as trip name
        let locationCounts = Dictionary(grouping: dives, by: \.location)
            .mapValues(\.count)
        let topLocation = locationCounts.max(by: { $0.value < $1.value })?.key ?? dives.first?.location ?? "Unknown"
        let siteCounts = Dictionary(grouping: dives, by: \.siteName)
            .mapValues(\.count)
        let topSite = siteCounts.max(by: { $0.value < $1.value })?.key ?? topLocation

        let name: String
        if let firstTimestamp = dives.first?.timestamp,
           let year = Calendar.current.dateComponents([.year], from: firstTimestamp).year {
            name = "\(topLocation) \(year)"
        } else {
            name = topLocation
        }

        return DiveTrip(name: name, location: topSite, dives: dives)
    }
}

// MARK: - Dive Trips View

struct DiveTripsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(DiveStore.self) private var store
    @State private var selectedTrip: DiveTrip? = nil
    @State private var prefs = UserPreferences.shared
    @State private var tripsAppeared = false
    @State private var cachedTrips: [DiveTrip] = []
    @State private var tripsReady = false
    @State private var tripsVersion: Int = 0
    /// The inputs the shown trips were built for: back from a trip pushed inside this sheet
    /// (macOS) re-runs the task, which then has nothing to rebuild.
    @State private var builtTripsKey = ""
    @AppStorage(DiverFilter.storageKey) private var selectedDiver: String = ""

    private var filteredDives: [Dive] { DiverFilter.apply(selectedDiver, to: store.dives) }

    private var tripsKey: String {
        "\(store.dives.count):\(selectedDiver):\(tripsVersion):\(store.dives.reduce(into: 0) { $0 += Int($1.timestamp.timeIntervalSinceReferenceDate) })"
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.dives.isEmpty {
                    ContentUnavailableView(
                        "No Trips",
                        systemImage: "airplane.departure",
                        description: Text("Your dives will automatically organize into trips here.")
                    )
                } else if filteredDives.isEmpty {
                    NoEntriesForDiverView(
                        title: Text(verbatim: String(format: NSLocalizedString("No Trips for %@", bundle: Bundle.forAppLanguage(), value: "No Trips for %@", comment: "Empty-state title when the selected diver has no trips; %@ is the diver's name"), selectedDiver)),
                        description: Text(verbatim: String(format: NSLocalizedString("No trips were found for %@.", bundle: Bundle.forAppLanguage(), value: "No trips were found for %@.", comment: "Empty-state description when the selected diver has no trips; %@ is the diver's name"), selectedDiver))
                    )
                } else if !tripsReady {
                    ProgressView("Organizing trips…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if cachedTrips.isEmpty {
                    ContentUnavailableView(
                        "No Trips",
                        systemImage: "airplane.departure",
                        description: Text("Your dives will automatically organize into trips here.")
                    )
                } else {
                    ScrollView {
                        VStack(spacing: 16) {
                            // Summary banner
                            TripsSummaryBanner(trips: cachedTrips, dives: filteredDives)
                                .padding(.horizontal)
                                .opacity(tripsAppeared ? 1.0 : 0.0)
                                .offset(y: tripsAppeared ? 0 : 20)

                            #if os(macOS)
                            // The Mac sheet is wide: trip cards in a grid, as many per row as
                            // fit at a readable width: two on the page-sized sheet (~700 pt).
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16, alignment: .top)], spacing: 16) {
                                ForEach(cachedTrips) { trip in
                                    tripCard(trip)
                                }
                            }
                            .padding(.horizontal)
                            #else
                            ForEach(Array(cachedTrips.enumerated()), id: \.element.id) { index, trip in
                                tripCard(trip)
                            }
                            #endif

                            Spacer(minLength: 30)
                        }
                        .padding(.vertical)
                    }
                }
            }
            .navigationTitle("✈️ My Trips")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            #endif
            .background(AppBackground().ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    closeToolbarButton { dismiss() }
                }
                DiverFilterToolbar(uniqueDivers: store.cachedUniqueDivers, selectedDiver: $selectedDiver)
            }
            #if os(macOS)
            // Pushed inside this sheet (with Back), not a sheet on the sheet: macOS has no
            // swipe-down, and a second sheet would have no way back to the list.
            .navigationDestination(item: $selectedTrip) { trip in
                TripDetailSheet(trip: trip, prefs: prefs)
                    .closeSheetButtonOnMac { dismiss() }
            }
            #else
            .sheet(item: $selectedTrip) { trip in
                TripDetailSheet(trip: trip, prefs: prefs)
                    .standardSheetPresentation()
            }
            #endif
            .task(id: tripsKey) {
                let key = tripsKey
                guard key != builtTripsKey else { return }
                builtTripsKey = key
                tripsAppeared = false
                cachedTrips = TripBuilder.buildTrips(from: Array(filteredDives))
                tripsReady = true
                withAnimation(.easeOut(duration: 0.5)) {
                    tripsAppeared = true
                }
            }
            .onChange(of: store.cachedSummaries) { _, _ in
                tripsVersion += 1
            }
            .diverFilterReset(uniqueDivers: store.cachedUniqueDivers, selectedDiver: $selectedDiver)
        }
    }

    /// A tappable trip card (opens the trip's detail sheet), with its VoiceOver action
    /// and appear animation.
    private func tripCard(_ trip: DiveTrip) -> some View {
        tripCardContent(trip)
            .onTapGesture { selectedTrip = trip }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            // onTapGesture isn't reliably fired by VoiceOver's activate
            // gesture; this makes double-tap open the trip.
            .accessibilityAction { selectedTrip = trip }
            .opacity(tripsAppeared ? 1.0 : 0.0)
            .offset(y: tripsAppeared ? 0 : 20)
    }

    /// macOS: cards of a grid row share the tallest card's height (the grid adds the side
    /// margins); iOS: the card with its side margins, as before, so the tap and VoiceOver
    /// modifiers wrap the padded card exactly as they did.
    @ViewBuilder
    private func tripCardContent(_ trip: DiveTrip) -> some View {
        #if os(macOS)
        TripCard(trip: trip, prefs: prefs, fillsRowHeight: true)
        #else
        TripCard(trip: trip, prefs: prefs)
            .padding(.horizontal)
        #endif
    }
}

// MARK: - Trips Summary Banner

struct TripsSummaryBanner: View {
    let trips: [DiveTrip]
    let dives: [Dive]

    private var totalCountries: Int {
        Set(dives.compactMap { $0.siteCountry }).count
    }
    private var totalLocations: Int {
        Set(dives.map { $0.location.lowercased() }).count
    }

    var body: some View {
        HStack(spacing: 0) {
            TripSummaryStat(value: Double(trips.count).localizedString(decimals: 0), label: "Trips", icon: "airplane", color: .cyan)
            Divider().frame(height: 40).background(Color.primary.opacity(0.15))
            TripSummaryStat(value: Double(totalLocations).localizedString(decimals: 0), label: "Destinations", icon: "mappin.circle.fill", color: .orange)
            Divider().frame(height: 40).background(Color.primary.opacity(0.15))
            TripSummaryStat(value: Double(dives.count).localizedString(decimals: 0), label: "Dives", icon: "bubbles.and.sparkles", color: .blue)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.platformSecondaryBackground)
        )
    }
}

struct TripSummaryStat: View {
    let value: String
    let label: LocalizedStringKey
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon).foregroundStyle(color).font(.title3).accessibilityHidden(true)
            Text(value).font(.title2.weight(.black)).foregroundStyle(.primary)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Trip Card

struct TripCard: View {
    let trip: DiveTrip
    let prefs: UserPreferences
    #if os(macOS)
    /// macOS trips grid: stretch to the tallest card of the row (a trip without a rating
    /// has no star line), extending the card's bottom background.
    var fillsRowHeight = false
    #endif
    @Environment(\.locale) private var locale
    /// The cover, decoded once per trip off the main thread at card size — not the full
    /// original on every render (CLAUDE.md, "Image Data in SwiftData").
    @State private var coverPhoto: PlatformImage?

    /// Longest side of the decoded cover: sharp at the card's width on a Retina display.
    private static let coverPixelSize = 900

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Cover photo or gradient header
            ZStack(alignment: .bottomLeading) {
                Group {
                    if let img = coverPhoto {
                        Image(platformImage: img)
                            .resizable()
                            .scaledToFill()
                    } else {
                        LinearGradient(
                            colors: tripGradient(for: trip.location),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    }
                }
                .frame(height: 140)
                .clipped()
                // Keyed on the cover's source, not `trip.id` (a new UUID on every trips rebuild):
                // a list refresh does not decode the covers again, and a new cover does.
                .task(id: trip.coverSource?.key) {
                    guard let source = trip.coverSource, let data = trip.coverPhotoData(from: source) else {
                        coverPhoto = nil
                        return
                    }
                    let size = Self.coverPixelSize
                    let image = await Task.detached(priority: .utility) { () -> PlatformImage? in
                        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
                        let options: [CFString: Any] = [
                            kCGImageSourceThumbnailMaxPixelSize: size,
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true
                        ]
                        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
                        #if os(iOS)
                        return UIImage(cgImage: cgImage)
                        #else
                        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                        #endif
                    }.value
                    guard !Task.isCancelled else { return }
                    coverPhoto = image
                }

                // Overlay gradient for text readability
                LinearGradient(
                    colors: [.clear, .black.opacity(0.7)],
                    startPoint: .top,
                    endPoint: .bottom
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(trip.name)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)

                    HStack(spacing: 8) {
                        Image(systemName: "calendar")
                            .font(.caption)
                            .accessibilityHidden(true)
                        Text(tripDateRange(trip))
                            .font(.caption)
                    }
                    .foregroundStyle(.white.opacity(0.8))
                }
                .padding(12)
            }
            #if os(macOS)
            // In the row-height grid the header's overlay gradient would otherwise grow
            // with the extra height; keep the header at its 140 pt so the extra space goes
            // to the card's bottom background.
            .frame(height: fillsRowHeight ? 140 : nil)
            #endif
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16))

            // Stats row
            HStack(spacing: 0) {
                TripStatMini(icon: "bubbles.and.sparkles", value: Double(trip.totalDives).localizedString(decimals: 0), label: "Dives")
                Divider().frame(height: 30)
                TripStatMini(icon: "timer", value: trip.formattedTotalTime, label: "Total")
                Divider().frame(height: 30)
                TripStatMini(icon: "arrow.down", value: (trip.deepestDive?.displayMaxDepth ?? 0).localizedString(decimals: 0) + " " + prefs.depthUnit.symbol, label: "Max")
                Divider().frame(height: 30)
                TripStatMini(icon: "mappin", value: Double(trip.uniqueSites).localizedString(decimals: 0), label: "Sites")
            }
            .padding(.vertical, 10)
            .background(Color.platformSecondaryBackground)

            // Star rating row
            if trip.averageRating > 0 {
                HStack(spacing: 6) {
                    ForEach(1...5, id: \.self) { star in
                        Image(systemName: Double(star) <= trip.averageRating ? "star.fill" : "star")
                            .font(.caption)
                            .foregroundStyle(Double(star) <= trip.averageRating ? .yellow : .secondary)
                            .accessibilityHidden(true)
                    }
                    Text(verbatim: trip.averageRating.localizedString(decimals: 1) + " / 5")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.platformSecondaryBackground)
                .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 16, bottomTrailingRadius: 16))
            } else {
                Color.platformSecondaryBackground
                    .frame(height: 2)
                    .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 16, bottomTrailingRadius: 16))
            }
        }
        #if os(macOS)
        .frame(maxHeight: fillsRowHeight ? .infinity : nil, alignment: .top)
        .background(fillsRowHeight ? Color.platformSecondaryBackground : Color.clear)
        #endif
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
    }

    private func tripGradient(for location: String) -> [Color] {
        let gradients: [[Color]] = [
            [.blue, .cyan],
            [.indigo, .blue],
            [.teal, .green],
            [.purple, .indigo],
            [.cyan, .teal],
        ]
        // Stable hash across launches (String.hashValue is randomized per process).
        let stable = location.unicodeScalars.reduce(5381) { ($0 &* 33) &+ Int($1.value) }
        let index = abs(stable) % gradients.count
        return gradients[index]
    }

    private func tripDateRange(_ trip: DiveTrip) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateFormat = DateFormatter.dateFormat(fromTemplate: "dMMM", options: 0, locale: locale)
        if Calendar.current.isDate(trip.startDate, equalTo: trip.endDate, toGranularity: .day) {
            formatter.dateFormat = DateFormatter.dateFormat(fromTemplate: "dMMMyyyy", options: 0, locale: locale)
            return formatter.string(from: trip.startDate)
        }
        let start = formatter.string(from: trip.startDate)
        formatter.dateFormat = DateFormatter.dateFormat(fromTemplate: "dMMMyyyy", options: 0, locale: locale)
        let end = formatter.string(from: trip.endDate)
        return "\(start) – \(end)"
    }
}

struct TripStatMini: View {
    let icon: String
    let value: String
    let label: LocalizedStringKey

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: icon).font(.caption2).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(value).font(.subheadline.weight(.bold)).monospacedDigit()
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

#if os(macOS)
/// Pushed by value inside the Trips sheet (`navigationDestination(item:)`): a trip is
/// identified by its id.
extension DiveTrip: Hashable {
    static func == (lhs: DiveTrip, rhs: DiveTrip) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
#endif

// MARK: - Trip Detail Sheet

/// One trip: its statistics, highlights and dives. On iOS a sheet of its own; on macOS a page
/// pushed inside the Trips sheet.
struct TripDetailSheet: View {
    let trip: DiveTrip
    let prefs: UserPreferences
    @Environment(\.dismiss) private var dismiss
    #if os(macOS)
    /// On macOS this page is pushed inside the Trips sheet (its destination has
    /// `closeSheetButtonOnMac`): that sheet's close action. Nil: presented as its own sheet.
    @Environment(\.sheetDismiss) private var sheetDismiss
    #endif
    @Environment(\.locale) private var locale
    @Environment(DiveStore.self) private var store
    @AppStorage(DiverFilter.storageKey) private var selectedDiver: String = ""

    private var numberMap: [PersistentIdentifier: Int] {
        let numbering = selectedDiver.isEmpty
            ? store.dives
            : store.dives.filter { $0.diverName == selectedDiver }
        let total = numbering.count
        return Dictionary(uniqueKeysWithValues: numbering.enumerated().map {
            ($0.element.persistentModelID, total - $0.offset)
        })
    }

    var body: some View {
        #if os(macOS)
        if let sheetDismiss {
            page(closeSheet: { sheetDismiss() })
        } else {
            sheetPage
        }
        #else
        sheetPage
        #endif
    }

    /// The trip as its own sheet: a navigation stack (the dives are pushed in it) and Close.
    private var sheetPage: some View {
        NavigationStack {
            page(closeSheet: { dismiss() })
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        closeToolbarButton { dismiss() }
                    }
                }
        }
    }

    /// The trip's content; `closeSheet` closes the sheet it is shown in (from a dive's page
    /// on macOS, see `closeSheetButtonOnMac`).
    private func page(closeSheet: @escaping () -> Void) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                #if os(macOS)
                // The Mac sheet is wide: hero stats beside Highlights (hero alone keeps
                // the full width); fixedSize gives both the height of the taller one.
                HStack(alignment: .top, spacing: 20) {
                    heroSection
                        .frame(maxWidth: .infinity)
                    if hasHighlights {
                        highlightsSection
                            .frame(maxWidth: .infinity)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                #else
                // Hero stats
                heroSection

                // Highlights
                if hasHighlights {
                    highlightsSection
                }
                #endif

                // All dives list
                divesListSection(closeSheet: closeSheet)
            }
            .padding()
        }
        .navigationTitle(trip.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .background(AppBackground().ignoresSafeArea())
    }

    private var hasHighlights: Bool {
        trip.deepestDive != nil || trip.longestDive != nil || trip.bestRatedDive != nil
    }

    private var heroSection: some View {
        // Once per render (not memoized): RMV depends on tank pressures, volumes, usage times
        // and the profile, which no store signal reports, so a cache could show a stale value
        // after a tank edit. Each dive caches its decoded profile and tanks, so this is cheap.
        let rmv = trip.rmvSummary
        let averageRMV = rmv.average
        // `isEstimated` is only set by a dive with an RMV, so it implies averageRMV > 0.
        let showsEstimatedRMV = rmv.isEstimated
        return VStack(spacing: 12) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                TripHeroStat(value: Double(trip.totalDives).localizedString(decimals: 0), label: "Dives", icon: "bubbles.and.sparkles.fill", color: .cyan)
                TripHeroStat(value: trip.formattedTotalTime, label: "Underwater", icon: "timer", color: .green)
                TripHeroStat(value: Double(trip.durationDays).localizedString(decimals: 0) + "d", label: "Trip Duration", icon: "calendar", color: .orange)
                TripHeroStat(value: trip.averageMaxDepth.localizedString(decimals: 1) + " " + prefs.depthUnit.symbol, label: "Avg. Depth", icon: "arrow.down.circle", color: .blue)
                TripHeroStat(value: Double(trip.uniqueSites).localizedString(decimals: 0), label: "Sites", icon: "mappin.and.ellipse", color: .purple)
                if averageRMV > 0 {
                    TripHeroStat(value: formatRMV(averageRMV, pressureUnit: prefs.pressureUnit, isEstimated: showsEstimatedRMV), label: "Avg. RMV", icon: "wind", color: .teal)
                } else {
                    // No rated dive: a dash, not a misleading "0.0★".
                    TripHeroStat(value: trip.averageRating > 0 ? trip.averageRating.localizedString(decimals: 1) + "★" : "—", label: "Avg. Rating", icon: "star.fill", color: .yellow)
                }
            }
            // Explains the " *" on Avg. RMV, as the Gas tab's footnote does for one dive.
            if showsEstimatedRMV {
                EstimatedRMVFootnote()
            }
        }
        .fillsAvailableHeightOnMac()
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.platformSecondaryBackground))
    }

    private var highlightsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("🏆 Highlights")
                .font(.headline)

            VStack(spacing: 10) {
                if let d = trip.deepestDive {
                    HighlightRow(icon: "arrow.down.circle.fill", color: .indigo,
                                 title: "Deepest Dive",
                                 subtitle: "\(d.siteName) — \(d.displayMaxDepth.localizedString(decimals: 1)) \(prefs.depthUnit.symbol)")
                }
                if let d = trip.longestDive {
                    HighlightRow(icon: "timer", color: .green,
                                 title: "Longest Dive",
                                 subtitle: "\(d.siteName) — \(d.formattedDuration)")
                }
                if let d = trip.bestRatedDive, d.rating > 0 {
                    HighlightRow(icon: "star.fill", color: .yellow,
                                 title: "Best Dive",
                                 subtitle: "\(d.siteName) — \(d.rating)★")
                }
            }
        }
        .fillsAvailableHeightOnMac()
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.platformSecondaryBackground))
    }

    private func divesListSection(closeSheet: @escaping () -> Void) -> some View {
        let sortedDives = trip.dives.sorted { $0.timestamp < $1.timestamp }
        return VStack(alignment: .leading, spacing: 8) {
            Text("🤿 All Dives (\(trip.totalDives))")
                .font(.headline)
                .padding(.bottom, 4)

            ForEach(sortedDives) { dive in
                NavigationLink(destination: DiveDetailView(dive: dive, sortedDives: sortedDives, diveNumber: numberMap[dive.persistentModelID] ?? 0).closeSheetButtonOnMac { closeSheet() }) {
                    DiveRowView(
                        summary: DiveSummary(from: dive, hasFish: !(dive.seenFish?.isEmpty ?? true), hasPhotos: store.cachedDivesWithPhotos.contains(dive.id)),
                        diveNumber: numberMap[dive.persistentModelID] ?? 0
                    )
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(Color.primary.opacity(0.07))
                    // The whole card opens the dive, including its padding and the gaps between
                    // columns (a plain link only responds where something is drawn).
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.platformSecondaryBackground))
    }
}

// MARK: - Supporting Views

struct TripHeroStat: View {
    let value: String
    let label: LocalizedStringKey
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.title2).foregroundStyle(color).accessibilityHidden(true)
            // One line, shrinking to fit: a value like "0,453 cu ft/min *" is wider than the
            // third of the grid it gets on iPhone.
            Text(value).font(.title3.weight(.black)).monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(label).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(color.opacity(0.08)))
    }
}

struct HighlightRow: View {
    let icon: String
    let color: Color
    let title: LocalizedStringKey
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(color.opacity(0.15)).frame(width: 36, height: 36)
                Image(systemName: icon).foregroundStyle(color).font(.system(size: 15)).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.platformTertiaryBackground))
    }
}
