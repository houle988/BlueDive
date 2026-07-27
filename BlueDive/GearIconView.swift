import SwiftUI
import UIKit

// MARK: - Gear Icon View

struct GearIconView: View {
    let manufacturer: String?
    let category: GearCategory?
    var size: CGFloat = 44

    private var cornerRadius: CGFloat { size * 10 / 44 }
    private var padding: CGFloat { size * 6 / 44 }
    private var symbolSize: CGFloat { size * 18 / 44 }

    var body: some View {
        if let assetName = Self.assetName(forManufacturer: manufacturer), imageExists(assetName) {
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
                    .fill(iconColor.opacity(0.15))
                Image(systemName: iconName)
                    .font(.system(size: symbolSize))
                    .foregroundStyle(iconColor)
            }
            .frame(width: size, height: size)
        }
    }

    // Returns true only when the named asset catalog entry actually contains image data.
    // Imagesets created as placeholders (no PNG/SVG yet) return false, keeping the SF Symbol fallback active.
    private func imageExists(_ name: String) -> Bool {
        UIImage(named: name) != nil
    }

    // MARK: Asset resolution

    private static func assetName(forManufacturer manufacturer: String?) -> String? {
        guard let manufacturer, !manufacturer.isEmpty else { return nil }
        // Order matters: longer/more-specific strings must precede shorter prefixes
        // that could accidentally match (e.g. "oceanic" before "oceans").
        let lc = manufacturer.lowercased()
        if lc.contains("shearwater")                                          { return "GearIcon_Shearwater" }
        if lc.contains("suunto")                                              { return "GearIcon_Suunto" }
        if lc.contains("scubapro")                                            { return "GearIcon_Scubapro" }
        if lc.contains("mares")                                               { return "GearIcon_Mares" }
        if lc.contains("oceanic")                                             { return "GearIcon_Oceanic" }
        if lc.contains("aqualung")                                            { return "GearIcon_Aqualung" }
        if lc.contains("sherwood")                                            { return "GearIcon_Sherwood" }
        if lc.contains("heinrichs") || lc.contains("weikamp") || lc.contains("ostc") {
            return "GearIcon_HeinrichsWeikamp"
        }
        if lc.contains("cressi")                                              { return "GearIcon_Cressi" }
        if lc.contains("divesoft")                                            { return "GearIcon_Divesoft" }
        if lc.contains("deep six")                                            { return "GearIcon_DeepSix" }
        if lc.contains("deepblu")                                             { return "GearIcon_Deepblu" }
        if lc.contains("mclean")                                              { return "GearIcon_McLean" }
        if lc.contains("oceans")                                              { return "GearIcon_Oceans" }
        if lc.contains("seac")                                                { return "GearIcon_Seac" }
        if lc.contains("halcyon")                                             { return "GearIcon_Halcyon" }
        if lc.contains("ratio")                                               { return "GearIcon_Ratio" }
        if lc.contains("divesystem") || lc.contains("idive")                 { return "GearIcon_DiveSystem" }
        if lc.contains("apeks")                                               { return "GearIcon_Apeks" }
        if lc.contains("fourth element")                                      { return "GearIcon_FourthElement" }
        if lc.contains("underwater kinetics")                                 { return "GearIcon_UnderwaterKinetics" }
        if lc.contains("light monkey")                                        { return "GearIcon_LightMonkey" }
        if lc.contains("orcatorch")                                           { return "GearIcon_Orcatorch" }
        if lc.contains("dive rite")                                           { return "GearIcon_DiveRite" }
        if lc.contains("sea-dog") || lc.contains("sea dog")                  { return "GearIcon_SeaDog" }
        if lc.contains("xs scuba")                                            { return "GearIcon_XSScuba" }
        if lc.contains("highland")                                            { return "GearIcon_Highland" }
        if lc.contains("nautec")                                              { return "GearIcon_Nautec" }
        if lc.contains("catalina")                                            { return "GearIcon_Catalina" }
        if lc.contains("faber")                                               { return "GearIcon_Faber" }
        if lc.contains("storm")                                               { return "GearIcon_Storm" }
        if lc.contains("yrva")                                                { return "GearIcon_YRVA" }
        if lc.contains("bare")                                                { return "GearIcon_Bare" }
        // Wetsuits / Drysuits / Thermal
        if lc.contains("diving unlimited") || lc.contains(" dui")            { return "GearIcon_DUI" }
        if lc.contains("waterproof")                                          { return "GearIcon_Waterproof" }
        if lc.contains("santi")                                               { return "GearIcon_Santi" }
        if lc.contains("o'three") || lc.contains("o three") || lc.contains("othree") { return "GearIcon_OThree" }
        if lc.contains("typhoon")                                             { return "GearIcon_Typhoon" }
        if lc.contains("henderson")                                           { return "GearIcon_Henderson" }
        if lc.contains("whites")                                              { return "GearIcon_Whites" }
        if lc.contains("camaro")                                              { return "GearIcon_Camaro" }
        if lc.contains("ursuit")                                              { return "GearIcon_Ursuit" }
        // Regulators / BCDs / Wings
        if lc.contains("poseidon")                                            { return "GearIcon_Poseidon" }
        if lc.contains("atomic")                                              { return "GearIcon_AtomicAquatics" }
        if lc.contains("zeagle")                                              { return "GearIcon_Zeagle" }
        if lc.contains("hollis")                                              { return "GearIcon_Hollis" }
        if lc.contains("xdeep")                                               { return "GearIcon_Xdeep" }
        if lc.contains("kubi")                                                { return "GearIcon_Kubi" }
        if lc.contains("eezycut")                                             { return "GearIcon_Eezycut" }
        if lc.contains("tecline")                                             { return "GearIcon_Tecline" }
        // Computers / Multi-category
        if lc.contains("tusa")                                                { return "GearIcon_Tusa" }
        if lc.contains("garmin")                                              { return "GearIcon_Garmin" }
        // Masks / Fins
        if lc.contains("beuchat")                                             { return "GearIcon_Beuchat" }
        if lc.contains("ist sports") || lc.contains("ist pro")               { return "GearIcon_ISTSports" }
        // Lights / Imaging
        if lc.contains("bigblue") || lc.contains("big blue")                 { return "GearIcon_Bigblue" }
        if lc.contains("light & motion") || lc.contains("light and motion")  { return "GearIcon_LightAndMotion" }
        if lc.contains("keldan")                                              { return "GearIcon_Keldan" }
        if lc.contains("ikelite")                                             { return "GearIcon_Ikelite" }
        if lc.contains("sea & sea") || lc.contains("sea&sea")                { return "GearIcon_SeaAndSea" }
        if lc.contains("paralenz")                                            { return "GearIcon_Paralenz" }
        if lc.contains("nauticam")                                            { return "GearIcon_Nauticam" }
        if lc.contains("sola")                                                { return "GearIcon_Sola" }
        // Cylinders
        if lc.contains("luxfer")                                              { return "GearIcon_Luxfer" }
        if lc.contains("worthington")                                         { return "GearIcon_Worthington" }
        if lc.contains("eurocylinder")                                        { return "GearIcon_Eurocylinder" }
        return nil
    }

    // MARK: SF Symbol fallback

    private var iconName: String {
        category?.icon ?? "wrench.and.screwdriver.fill"
    }

    private var iconColor: Color {
        guard let colorName = category?.color else { return .cyan }
        switch colorName {
        case "purple":  return .purple
        case "blue":    return .blue
        case "green":   return .green
        case "orange":  return .orange
        case "gray":    return .gray
        case "cyan":    return .cyan
        case "pink":    return .pink
        case "indigo":  return .indigo
        default:        return .brown
        }
    }
}
