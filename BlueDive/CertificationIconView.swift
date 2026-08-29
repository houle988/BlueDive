import SwiftUI
import UIKit

// MARK: - Certification Icon View

struct CertificationIconView: View {
    let organization: String
    let size: CGFloat
    let fillOpacity: Double
    private let resolvedAsset: String?
    private let orgColor: Color
    private let orgText: String

    init(organization: String, size: CGFloat = 60, fillOpacity: Double = 0.2) {
        self.organization = organization
        self.size = size
        self.fillOpacity = fillOpacity
        let org = CertificationOrganization(rawValue: organization)
        self.orgColor = org?.swiftUIColor ?? .gray
        self.orgText = org?.localizedName ?? organization
        if let name = Self.assetName(for: organization), UIImage(named: name) != nil {
            self.resolvedAsset = name
        } else {
            self.resolvedAsset = nil
        }
    }

    private var cornerRadius: CGFloat { size * 10 / 44 }
    private var padding: CGFloat { size * 6 / 44 }

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
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(orgColor.opacity(fillOpacity))
                Text(verbatim: orgText)
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundStyle(orgColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(4)
            }
            .frame(width: size, height: size)
        }
    }

    static func assetName(for organization: String) -> String? {
        switch CertificationOrganization(rawValue: organization) {
        case .padi:  return "CertIcon_PADI"
        case .ssi:   return "CertIcon_SSI"
        case .cmas:  return "CertIcon_CMAS"
        case .naui:  return "CertIcon_NAUI"
        case .sdi:   return "CertIcon_SDI"
        case .tdi:   return "CertIcon_TDI"
        case .bsac:  return "CertIcon_BSAC"
        case .gue:   return "CertIcon_GUE"
        case .other, .none: return nil
        }
    }
}
