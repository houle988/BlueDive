import SwiftUI

// MARK: - Dive Row View

struct DiveRowView: View {
    let summary: DiveSummary
    let diveNumber: Int   // fallback when diveNumber is nil
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
    
    private var diveIcon: some View {
        let resolved = resolvedFlag
        return VStack(spacing: 4) {
            Text(verbatim: "#\(summary.diveNumber ?? diveNumber)")
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

            HStack(spacing: 4) {
                if summary.hasFish {
                    Image(systemName: "fish.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.teal)
                }
                if summary.hasPhotos {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                }
            }
        }
    }
    
    /// Returns the emoji flag and accent colour for the dive's country
    private var resolvedFlag: (flag: String, color: Color) {
        CountryLookup.resolve(summary.siteCountry)
    }

    private var diveTitle: some View {
        Text(summary.siteName)
            .font(.headline)
            .foregroundStyle(.primary)
            .lineLimit(2)
    }

    private var diveDetails: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Duration + surface interval badges
            HStack(spacing: 6) {
                Text(summary.shortFormattedDuration)
                    .font(.system(.caption2, design: .monospaced))
                    .fontWeight(.semibold)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.2))
                    .foregroundStyle(.green)
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                if !summary.surfaceInterval.isEmpty && summary.surfaceInterval != "0h 00m" {
                    Text(summary.displaySurfaceInterval)
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
                if summary.hasGPSCoordinates {
                    Image(systemName: "location.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                
                locationText
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Text(summary.timestamp, format: .dateTime.day().month().year().hour().minute().locale(locale))
                .font(.caption)
                .foregroundStyle(.gray)
        }
    }
    
    private var locationText: Text {
        if let country = summary.siteCountry, !country.isEmpty {
            // If both location and country exist, combine them
            if !summary.location.isEmpty && summary.location != "Inconnu" && summary.location != NSLocalizedString("Unknown", bundle: Bundle.forAppLanguage(), comment: "") {
                return Text(verbatim: "\(summary.location), \(country)")
            }
            // If only country exists
            return Text(verbatim: country)
        }
        // If only location exists
        if !summary.location.isEmpty && summary.location != "Inconnu" && summary.location != NSLocalizedString("Unknown", bundle: Bundle.forAppLanguage(), comment: "") {
            return Text(verbatim: summary.location)
        }
        // Fallback
        return Text("Unknown location")
    }
    
    private var depthInfo: some View {
        let depthValue = summary.displayMaxDepth
        let depthSymbol = prefs.depthUnit.symbol
        return Text(verbatim: depthValue.localizedString(decimals: 1) + depthSymbol)
            .fontWeight(.bold)
            .foregroundStyle(.primary)
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

