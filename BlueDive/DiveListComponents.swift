import SwiftUI

// MARK: - Dive Row View

struct DiveRowView: View {
    let dive: Dive
    let diveNumber: Int
    private let prefs = UserPreferences.shared
    @Environment(\.locale) private var locale
    
    var body: some View {
        HStack(alignment: .top, spacing: 15) {
            diveIcon
            VStack(alignment: .leading, spacing: 4) {
                diveTitle
                HStack(alignment: .top, spacing: 8) {
                    diveDetails
                    Spacer()
                    depthInfo
                }
            }
        }
    }
    
    private var formattedTimestamp: String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: dive.timestamp)
    }

    private var diveIcon: some View {
        let resolved = resolvedFlag
        return VStack(spacing: 4) {
            Text("#\(dive.diveNumber ?? diveNumber)")
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.bold)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.cyan.opacity(0.2))
                .foregroundStyle(.cyan)
                .clipShape(RoundedRectangle(cornerRadius: 4))

            ZStack {
                Circle()
                    .fill(resolved.color.opacity(0.15))
                    .frame(width: 44, height: 44)
                
                Text(resolved.flag)
                    .font(.system(size: 24))
            }
        }
    }
    
    /// Returns the emoji flag and accent colour for the dive's country
    private var resolvedFlag: (flag: String, color: Color) {
        CountryLookup.resolve(dive.siteCountry)
    }
    
    private var diveTitle: some View {
        Text(dive.siteName)
            .font(.headline)
            .foregroundStyle(.primary)
            .lineLimit(2)
    }

    private var diveDetails: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Duration + surface interval badges
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
            
            // Location and Country
            HStack(spacing: 4) {
                if dive.siteLatitude != nil && dive.siteLongitude != nil {
                    Image(systemName: "location.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                
                locationText
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Text(formattedTimestamp)
                .font(.caption)
                .foregroundStyle(.gray)
        }
    }
    
    private var locationText: Text {
        if let country = dive.siteCountry, !country.isEmpty {
            // If both location and country exist, combine them
            if !dive.location.isEmpty && dive.location != "Inconnu" && dive.location != String(localized: "Unknown") {
                return Text(verbatim: "\(dive.location), \(country)")
            }
            // If only country exists
            return Text(verbatim: country)
        }
        // If only location exists
        if !dive.location.isEmpty && dive.location != "Inconnu" && dive.location != String(localized: "Unknown") {
            return Text(verbatim: dive.location)
        }
        // Fallback
        return Text("Unknown location")
    }
    
    private var depthInfo: some View {
        let depthValue = dive.displayMaxDepth
        let depthSymbol = prefs.depthUnit.symbol
        return Text(String(format: "%.1f\(depthSymbol)", depthValue))
            .fontWeight(.bold)
            .foregroundStyle(.primary)
    }
}

// MARK: - Stats Header View

struct StatsHeaderView: View {
    let dives: [Dive]
    private let prefs = UserPreferences.shared
    
    private var totalTimeHMS: String {
        // Sum seconds with the same preference order used for per-dive duration
        let totalSeconds = dives.reduce(0) { acc, dive in
            // Prefer precise seconds from profile if available
            let samples = dive.profileSamples
            if let last = samples.last?.time, last > 0 {
                return acc + Int(round(last * 60))
            }
            // Heuristic: if stored duration seems already in seconds (>= 3600), use as-is
            if dive.duration >= 3600 {
                return acc + dive.duration
            }
            // Fallback: treat stored `duration` as minutes
            return acc + (dive.duration * 60)
        }
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        if h > 0 {
            return String(format: "%dh %02dm %02ds", h, m, s)
        } else if m > 0 {
            return String(format: "%dm %02ds", m, s)
        } else {
            return String(format: "%ds", s)
        }
    }
    
    private var maxDepthEver: Double {
        dives.map { $0.displayMaxDepth }.max() ?? 0.0
    }
    
    var body: some View {
        // maxDepthEver is already in display units (via displayMaxDepth), so
        // no further conversion is needed — just use the unit symbol.
        let depthValue = maxDepthEver
        let depthSymbol = prefs.depthUnit.symbol
        return HStack(spacing: 12) {
            StatMiniBox(
                title: "DIVES",
                value: "\(dives.count)",
                icon: "figure.open.water.swim",
                color: .blue
            )
            
            StatMiniBox(
                title: "MAX",
                value: String(format: "%.1f\(depthSymbol)", depthValue),
                icon: "arrow.down.circle.fill",
                color: .cyan
            )
            
            StatMiniBox(
                title: "TOTAL TIME",
                value: totalTimeHMS,
                icon: "clock.fill",
                color: .green
            )
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 20).fill(Color.primary.opacity(0.05)))
    }
}

// MARK: - Stat Mini Box

struct StatMiniBox: View {
    let title: LocalizedStringKey
    let value: String
    let icon: String
    let color: Color
    
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: icon)
                .font(.system(size: 8))
                .fontWeight(.bold)
                .foregroundStyle(color)
            
            Text(value)
                .font(.subheadline)
                .fontWeight(.bold)
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

