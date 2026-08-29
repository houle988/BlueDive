import SwiftUI
import UIKit

// MARK: - Insurance Icon View

struct InsuranceIconView: View {
    let insurerName: String
    let size: CGFloat
    let fallbackColor: Color
    let fillOpacity: Double
    /// When set, the fallback (no logo) shows this SF Symbol instead of initials.
    let fallbackSymbol: String?
    private let resolvedAsset: String?

    init(
        insurerName: String,
        size: CGFloat = 60,
        fallbackColor: Color,
        fillOpacity: Double = 0.2,
        fallbackSymbol: String? = nil
    ) {
        self.insurerName = insurerName
        self.size = size
        self.fallbackColor = fallbackColor
        self.fillOpacity = fillOpacity
        self.fallbackSymbol = fallbackSymbol
        if let name = Self.assetName(for: insurerName), UIImage(named: name) != nil {
            self.resolvedAsset = name
        } else {
            self.resolvedAsset = nil
        }
    }

    private var cornerRadius: CGFloat { size * 10 / 44 }
    private var padding: CGFloat { size * 6 / 44 }

    private var fallbackText: String {
        let trimmed = insurerName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "?" : String(trimmed.prefix(4))
    }

    var body: some View {
        if let assetName = resolvedAsset {
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
        } else if let symbol = fallbackSymbol {
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(fallbackColor.opacity(fillOpacity))
                Image(systemName: symbol)
                    .font(.system(size: size * 18 / 44))
                    .foregroundStyle(fallbackColor)
            }
            .frame(width: size, height: size)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(fallbackColor.opacity(fillOpacity))
                Text(verbatim: fallbackText)
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundStyle(fallbackColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(4)
            }
            .frame(width: size, height: size)
        }
    }

    // MARK: Asset resolution
    // Order matters: more-specific tokens before shorter ones (e.g. "dan europe" before "dan").

    static func assetName(for insurerName: String) -> String? {
        let lc = insurerName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !lc.isEmpty else { return nil }
        if lc.contains("diveassure") || lc.contains("dive assure")               { return "InsuranceIcon_DiveAssure" }
        if lc.contains("nautilus")                                                { return "InsuranceIcon_Nautilus" }
        // Base DAN: match whole-word to avoid false hits (e.g. "abundant", "sudan").
        if lc.contains("divers alert") || lc == "dan" || lc.hasPrefix("dan ")
            || lc.hasSuffix(" dan") || lc.contains(" dan ") || lc.contains("dan(") { return "InsuranceIcon_DAN" }
        return nil
    }
}
