import Foundation
import SwiftUI
import CoreText
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - PDF Logbook

struct PDFDiveLogbook {

    // MARK: - Colours

    private static let bgDark       = CGColor(red: 1.0,  green: 1.0,  blue: 1.0,  alpha: 1.0)
    private static let bgCard       = CGColor(red: 0.96, green: 0.97, blue: 0.98, alpha: 1.0)
    private static let accentCyan   = CGColor(red: 0.0,  green: 0.55, blue: 0.67, alpha: 1.0)
    private static let accentOrange = CGColor(red: 0.82, green: 0.42, blue: 0.05, alpha: 1.0)
    private static let accentGreen  = CGColor(red: 0.13, green: 0.58, blue: 0.23, alpha: 1.0)
    private static let accentRed    = CGColor(red: 0.80, green: 0.18, blue: 0.18, alpha: 1.0)
    private static let accentPink   = CGColor(red: 0.78, green: 0.22, blue: 0.42, alpha: 1.0)
    private static let accentPurple = CGColor(red: 0.42, green: 0.28, blue: 0.78, alpha: 1.0)
    private static let accentYellow = CGColor(red: 0.72, green: 0.56, blue: 0.0,  alpha: 1.0)
    private static let accentBlue   = CGColor(red: 0.16, green: 0.33, blue: 0.78, alpha: 1.0)
    private static let accentTeal   = CGColor(red: 0.08, green: 0.52, blue: 0.50, alpha: 1.0)
    private static let textWhite    = CGColor(red: 0.10, green: 0.10, blue: 0.14, alpha: 1.0)
    private static let textGray     = CGColor(red: 0.13, green: 0.14, blue: 0.18, alpha: 1.0)
    private static let textMuted    = CGColor(red: 0.58, green: 0.61, blue: 0.66, alpha: 1.0)
    private static let divider      = CGColor(red: 0.84, green: 0.86, blue: 0.90, alpha: 1.0)

    // MARK: - Localization Helper

    /// Uses the in-app language override bundle so PDF text matches the user's
    /// chosen language even when it differs from the OS language.
    private static var loc: Bundle { Bundle.forAppLanguage() }

    /// Localizes a stored weather value using literal keys so Xcode can detect them.
    private static func localizedWeather(_ value: String?) -> String {
        guard let value = value, !value.isEmpty else { return "—" }
        switch value {
        case "Sunny":    return NSLocalizedString("Sunny", bundle: loc, comment: "")
        case "Cloudy":   return NSLocalizedString("Cloudy", bundle: loc, comment: "")
        case "Overcast": return NSLocalizedString("Overcast", bundle: loc, comment: "")
        case "Rain":     return NSLocalizedString("Rain", bundle: loc, comment: "")
        case "Storm":    return NSLocalizedString("Storm", bundle: loc, comment: "")
        case "Variable": return NSLocalizedString("Variable", bundle: loc, comment: "")
        default:         return value
        }
    }

    /// Localizes a stored surface conditions value using literal keys.
    private static func localizedSurfaceConditions(_ value: String?) -> String {
        guard let value = value, !value.isEmpty else { return "—" }
        switch value {
        case "Calm":             return NSLocalizedString("Calm", bundle: loc, comment: "")
        case "Slightly choppy":  return NSLocalizedString("Slightly choppy", bundle: loc, comment: "")
        case "Choppy":           return NSLocalizedString("Choppy", bundle: loc, comment: "")
        case "Heavy swell":      return NSLocalizedString("Heavy swell", bundle: loc, comment: "")
        default:                 return value
        }
    }

    /// Localizes a stored current value using literal keys.
    private static func localizedCurrent(_ value: String?) -> String {
        guard let value = value, !value.isEmpty else { return "—" }
        switch value {
        case "None":        return NSLocalizedString("None", bundle: loc, comment: "")
        case "Weak":        return NSLocalizedString("Weak", bundle: loc, comment: "")
        case "Moderate":    return NSLocalizedString("Moderate", bundle: loc, comment: "")
        case "Strong":      return NSLocalizedString("Strong", bundle: loc, comment: "")
        case "Very strong": return NSLocalizedString("Very strong", bundle: loc, comment: "")
        default:            return value
        }
    }

    /// Localizes a stored tank type value using literal keys.
    private static func localizedTankType(_ value: String?) -> String {
        guard let value = value, !value.isEmpty else { return NSLocalizedString("Single tank", bundle: loc, comment: "") }
        switch value {
        case "Single tank":  return NSLocalizedString("Single tank", bundle: loc, comment: "")
        case "Twinset":      return NSLocalizedString("Twinset", bundle: loc, comment: "")
        case "Sidemount":    return NSLocalizedString("Sidemount", bundle: loc, comment: "")
        case "Pony":         return NSLocalizedString("Pony", bundle: loc, comment: "")
        case "Rebreather":   return NSLocalizedString("Rebreather", bundle: loc, comment: "")
        case "Other":        return NSLocalizedString("Other", bundle: loc, comment: "")
        default:             return value
        }
    }

    /// Localizes a stored site difficulty value (1–10) into "Number — Description".
    private static func localizedDifficulty(_ value: String?) -> String {
        guard let value = value, !value.isEmpty else { return "—" }
        let scale: [(level: Int, label: String)] = [
            (1, "Very Easy"),
            (2, "Easy"),
            (3, "Easy-Moderate"),
            (4, "Moderate"),
            (5, "Moderate"),
            (6, "Moderate-Challenging"),
            (7, "Challenging"),
            (8, "Very Challenging"),
            (9, "Expert"),
            (10, "Extreme")
        ]
        if let n = Int(value), let match = scale.first(where: { $0.level == n }) {
            let localized = NSLocalizedString(match.label, bundle: loc, comment: "")
            return "\(n) — \(localized)"
        }
        if let match = scale.first(where: { $0.label == value }) {
            let localized = NSLocalizedString(match.label, bundle: loc, comment: "")
            return "\(match.level) — \(localized)"
        }
        return value
    }

    /// Localizes a stored tank material value using literal keys.
    private static func localizedTankMaterial(_ value: String?) -> String {
        guard let value = value, !value.isEmpty else { return "" }
        switch value {
        case "Steel":           return NSLocalizedString("Steel", bundle: loc, comment: "")
        case "Galvanized Steel": return NSLocalizedString("Galvanized Steel", bundle: loc, comment: "")
        case "Aluminium":       return NSLocalizedString("Aluminium", bundle: loc, comment: "")
        case "Carbon":          return NSLocalizedString("Carbon", bundle: loc, comment: "")
        default:                return value
        }
    }

    // MARK: - Fonts

    private static func font(size: CGFloat) -> CTFont {
        CTFontCreateWithName("HelveticaNeue" as CFString, size, nil)
    }
    private static func boldFont(size: CGFloat) -> CTFont {
        CTFontCreateWithName("HelveticaNeue-Bold" as CFString, size, nil)
    }
    private static func mediumFont(size: CGFloat) -> CTFont {
        CTFontCreateWithName("HelveticaNeue-Medium" as CFString, size, nil)
    }
    private static func lightFont(size: CGFloat) -> CTFont {
        CTFontCreateWithName("HelveticaNeue-Light" as CFString, size, nil)
    }

    // MARK: - Field Grid (shared layout for info/stats/tanks cards)

    private typealias Field = (label: String, value: String, color: CGColor)

    /// Returns the natural card height for a given field count and column count.
    private static func fieldGridHeight(fieldCount: Int, columns: Int) -> CGFloat {
        let titleH: CGFloat = 14
        let lineH: CGFloat = 18
        let padBottom: CGFloat = 6
        let dataRows = Int(ceil(Double(fieldCount) / Double(columns)))
        return CGFloat(dataRows) * lineH + titleH + padBottom
    }

    /// Draws a card with a title and a grid of labelled fields.
    /// Returns the Y position below the card.
    private static func drawFieldGrid(
        ctx: CGContext,
        title: String,
        titleColor: CGColor,
        fields: [Field],
        columns: Int,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        minHeight: CGFloat = 0
    ) -> CGFloat {
        let titleH: CGFloat = 14
        let lineH: CGFloat = 18
        let padBottom: CGFloat = 6

        let dataRows = Int(ceil(Double(fields.count) / Double(columns)))
        let naturalH = CGFloat(dataRows) * lineH + titleH + padBottom
        let cardH = max(naturalH, minHeight)
        let cardRect = CGRect(x: x, y: y - cardH, width: width, height: cardH)
        drawRoundedRect(ctx: ctx, rect: cardRect, radius: 8, fill: bgCard)
        drawCardBorder(ctx: ctx, rect: cardRect, radius: 8)

        drawSectionTitle(ctx: ctx, title: title, x: x + 10, y: y - (titleH / 2) - 3, color: titleColor)

        let columnWidth = (width - 16) / CGFloat(columns)
        let startY = y - titleH - 1
        let dotSize: CGFloat = 2.5

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byTruncatingTail

        for (index, field) in fields.enumerated() {
            let row = index / columns
            let col = index % columns
            let sx = x + 10 + CGFloat(col) * columnWidth
            let sy = startY - CGFloat(row) * lineH

            // Coloured dot
            ctx.setFillColor(field.color)
            ctx.fillEllipse(in: CGRect(x: sx, y: sy - 4, width: dotSize, height: dotSize))

            // Label
            let labelAttrs: [NSAttributedString.Key: Any] = [
                .font: font(size: 5),
                .foregroundColor: platformColor(textGray),
                .paragraphStyle: paragraphStyle
            ]
            let labelRect = CGRect(x: sx + 5, y: sy - 7.5, width: columnWidth - 8, height: 7)
            let labelStr = NSAttributedString(string: field.label.uppercased(), attributes: labelAttrs)
            drawWrappedText(labelStr, in: ctx, rect: labelRect)

            // Value (auto-shrinks to fit)
            var fontSize: CGFloat = 7.0
            let minFontSize: CGFloat = 5.0
            let maxTextWidth = columnWidth - 8

            var valAttrs: [NSAttributedString.Key: Any] = [
                .font: mediumFont(size: fontSize),
                .foregroundColor: platformColor(textWhite),
                .paragraphStyle: paragraphStyle
            ]
            var textWidth = (field.value as NSString).size(withAttributes: valAttrs).width
            while textWidth > maxTextWidth && fontSize > minFontSize {
                fontSize -= 0.5
                valAttrs[.font] = mediumFont(size: fontSize)
                textWidth = (field.value as NSString).size(withAttributes: valAttrs).width
            }

            let valRect = CGRect(x: sx + 5, y: sy - 16, width: maxTextWidth, height: 9)
            let valStr = NSAttributedString(string: field.value, attributes: valAttrs)
            drawWrappedText(valStr, in: ctx, rect: valRect)
        }

        return y - cardH
    }

    // MARK: - Generate PDF

    static func generatePDF(for dive: Dive, allDives: [Dive]) -> Data? {
        let pageWidth: CGFloat = 612
        let pageHeight: CGFloat = 792
        let margin: CGFloat = 24
        let contentWidth = pageWidth - margin * 2

        let pdfData = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)

        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            return nil
        }

        let prefs = UserPreferences.shared
        let depthSymbol = prefs.depthUnit.symbol
        let pressSymbol = prefs.pressureUnit.symbol
        let tempUnit = prefs.temperatureUnit

        ctx.beginPage(mediaBox: &mediaBox)
        drawPageBackground(ctx: ctx, width: pageWidth, height: pageHeight)

        var y = pageHeight - margin

        // Header
        y = drawHeader(ctx: ctx, dive: dive, allDives: allDives, x: margin, y: y, width: contentWidth)

        // Dive Information + Site Details (side by side)
        y -= 6
        let infoGap: CGFloat = 6
        let infoWidth = contentWidth * 0.38
        let siteDetailWidth = contentWidth - infoWidth - infoGap
        let siteDetailX = margin + infoWidth + infoGap
        let infoY = drawDiveInfo(ctx: ctx, dive: dive, allDives: allDives, x: margin, y: y, width: infoWidth, tempUnit: tempUnit)
        let siteDetailY = drawSiteDetails(ctx: ctx, dive: dive, x: siteDetailX, y: y, width: siteDetailWidth)
        y = min(infoY, siteDetailY)

        // Dive Profile Chart (only if samples exist)
        if !dive.profileSamples.isEmpty {
            y -= 6
            y = drawDiveProfile(ctx: ctx, dive: dive, x: margin, y: y, width: contentWidth, depthSymbol: depthSymbol)
        }

        // Dive Statistics + Tanks + Deco (three columns, equal height)
        y -= 6
        let gap: CGFloat = 6
        let statsWidth = contentWidth * 0.36
        let tanksWidth = contentWidth * 0.34
        let decoWidth = contentWidth - statsWidth - tanksWidth - gap * 2
        let tanksX = margin + statsWidth + gap
        let decoX = tanksX + tanksWidth + gap

        // Pre-calculate field counts to enforce equal card heights
        let statsFieldCount = 8   // always 8 fields, 3 columns
        let tanksFieldCount = max(dive.tanks.count, 1) * 6   // 6 fields per tank (or 6 placeholder fields)
        let decoStopCount = (dive.isDecompressionDive && !dive.decoStops.isEmpty) ? dive.decoStops.count : 0
        let decoFieldCount = 4 + decoStopCount   // 4 base + deco stops

        let statsH = fieldGridHeight(fieldCount: statsFieldCount, columns: 3)
        let tanksH = fieldGridHeight(fieldCount: tanksFieldCount, columns: 2)
        let decoH  = fieldGridHeight(fieldCount: decoFieldCount, columns: 2)
        let sectionMinH = max(statsH, max(tanksH, decoH))

        let statsY = drawDiveStatistics(ctx: ctx, dive: dive, x: margin, y: y, width: statsWidth,
                                        depthSymbol: depthSymbol, minHeight: sectionMinH)
        let tanksY = drawTanksSection(ctx: ctx, dive: dive, x: tanksX, y: y, width: tanksWidth,
                                      pressSymbol: pressSymbol, minHeight: sectionMinH)
        let decoY = drawDecoSection(ctx: ctx, dive: dive, x: decoX, y: y, width: decoWidth, minHeight: sectionMinH)
        y = min(statsY, min(tanksY, decoY))

        // Equipment (skip if none)
        let hasGear = !(dive.usedGear ?? []).isEmpty
        if hasGear {
            y -= 6
            y = drawEquipmentSection(ctx: ctx, dive: dive, x: margin, y: y, width: contentWidth)
        }

        // Notes
        y -= 6
        let footerY = margin + 62
        y = drawNotesSection(ctx: ctx, dive: dive, x: margin, y: y, width: contentWidth, footerY: footerY)

        // Footer
        drawBrandedFooter(ctx: ctx, dive: dive, allDives: allDives, x: margin, y: margin - 4, width: contentWidth, pageWidth: pageWidth)

        ctx.endPage()
        ctx.closePDF()

        return pdfData as Data
    }

    // MARK: - Page Background

    private static func drawPageBackground(ctx: CGContext, width: CGFloat, height: CGFloat) {
        ctx.setFillColor(bgDark)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Top gradient bar
        ctx.saveGState()
        let barH: CGFloat = 3
        let colors = [accentCyan, accentBlue, accentPurple] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.5, 1]) {
            ctx.clip(to: CGRect(x: 0, y: height - barH, width: width, height: barH))
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: CGPoint(x: width, y: height), options: [])
        }
        ctx.restoreGState()
    }

    // MARK: - Header

    private static func drawHeader(ctx: CGContext, dive: Dive, allDives: [Dive], x: CGFloat, y: CGFloat, width: CGFloat) -> CGFloat {
        var curY = y - 2

        // App icon
        let logoSize: CGFloat = 26
        if let logoImage = loadAppIcon() {
            let logoRect = CGRect(x: x, y: curY - logoSize + 4, width: logoSize, height: logoSize)
            ctx.saveGState()
            let clipPath = CGPath(roundedRect: logoRect, cornerWidth: 5, cornerHeight: 5, transform: nil)
            ctx.addPath(clipPath)
            ctx.clip()
            ctx.draw(logoImage, in: logoRect)
            ctx.restoreGState()
        }

        // App name
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: boldFont(size: 17),
            .foregroundColor: platformColor(accentCyan)
        ]
        drawText("BLUEDIVE", attrs: titleAttrs, in: ctx, at: CGPoint(x: x + logoSize + 8, y: curY - 19))

        // Subtitle
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: lightFont(size: 7.5),
            .foregroundColor: platformColor(textGray)
        ]
        drawText(NSLocalizedString("DIVE LOGBOOK", bundle: loc, comment: ""), attrs: subAttrs, in: ctx, at: CGPoint(x: x + logoSize + 8, y: curY - 4))

        // Dive number badge (right-aligned)
        let diveNum = dive.diveNumber ?? (allDives.count - (allDives.firstIndex(where: { $0.id == dive.id }) ?? 0))
        let badgeText = String(format: NSLocalizedString("DIVE #%lld", bundle: loc, comment: ""), diveNum)

        let badgeAttrs: [NSAttributedString.Key: Any] = [
            .font: boldFont(size: 11),
            .foregroundColor: platformColor(accentCyan)
        ]
        let badgeStr = NSAttributedString(string: badgeText, attributes: badgeAttrs)
        let badgeW = badgeStr.size().width + 16
        let badgeX = x + width - badgeW

        let isRated = dive.rating > 0
        let badgeH: CGFloat = isRated ? 18 : 20
        let badgeY: CGFloat = isRated ? (curY - 12) : (curY - 19)
        let textY: CGFloat = isRated ? (curY - 8) : (curY - 14)

        let badgeRect = CGRect(x: badgeX, y: badgeY, width: badgeW, height: badgeH)
        drawRoundedRect(ctx: ctx, rect: badgeRect, radius: 6, fill: CGColor(red: 0.0, green: 0.55, blue: 0.67, alpha: 0.08))

        ctx.saveGState()
        ctx.setStrokeColor(CGColor(red: 0.0, green: 0.55, blue: 0.67, alpha: 0.25))
        ctx.setLineWidth(0.6)
        ctx.addPath(CGPath(roundedRect: badgeRect, cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.strokePath()
        ctx.restoreGState()

        drawText(badgeText, attrs: badgeAttrs, in: ctx, at: CGPoint(x: badgeX + 8, y: textY))

        // Rating stars
        if isRated {
            let starY = curY - 24
            let starSize: CGFloat = 8
            let starSpacing: CGFloat = 1.5

            #if os(macOS)
            let starFont = NSFont.systemFont(ofSize: starSize)
            #else
            let starFont = UIFont.systemFont(ofSize: starSize)
            #endif

            let totalStarsWidth = (starSize * 5) + (starSpacing * 4)
            let startX = badgeX + ((badgeW - totalStarsWidth) / 2)

            let starAttrs: [NSAttributedString.Key: Any] = [
                .font: starFont,
                .foregroundColor: platformColor(accentYellow)
            ]
            let emptyStarAttrs: [NSAttributedString.Key: Any] = [
                .font: starFont,
                .foregroundColor: platformColor(textMuted)
            ]
            for i in 0..<5 {
                let sx = startX + CGFloat(i) * (starSize + starSpacing)
                let attrs = i < dive.rating ? starAttrs : emptyStarAttrs
                drawText("★", attrs: attrs, in: ctx, at: CGPoint(x: sx, y: starY))
            }
        }

        curY -= 28

        // Gradient separator
        ctx.saveGState()
        let lineRect = CGRect(x: x, y: curY, width: width, height: 1)
        let lineColors = [
            accentCyan.copy(alpha: 0.6) ?? accentCyan,
            accentBlue.copy(alpha: 0.3) ?? accentBlue,
            accentPurple.copy(alpha: 0.0) ?? accentPurple
        ] as CFArray
        if let lineGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: lineColors, locations: [0, 0.5, 1]) {
            ctx.clip(to: lineRect)
            ctx.drawLinearGradient(lineGrad, start: CGPoint(x: x, y: curY), end: CGPoint(x: x + width, y: curY), options: [])
        }
        ctx.restoreGState()

        curY -= 2
        return curY
    }

    // MARK: - Dive Information

    private static func drawDiveInfo(ctx: CGContext, dive: Dive, allDives: [Dive], x: CGFloat, y: CGFloat, width: CGFloat, tempUnit: TemperatureUnit) -> CGFloat {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        let dateStr = dateFormatter.string(from: dive.timestamp)

        let timeFormatter = DateFormatter()
        timeFormatter.timeStyle = .short
        let timeStr = timeFormatter.string(from: dive.timestamp)

        let airTempStr: String = dive.displayAirTemperature.map {
            "\(Int($0.rounded()))\(tempUnit.symbol)"
        } ?? "—"

        // Find the trip this dive belongs to
        let tripStr: String = {
            let trips = TripBuilder.buildTrips(from: allDives)
            if let trip = trips.first(where: { $0.dives.contains(where: { $0.id == dive.id }) }) {
                return trip.name
            }
            return "—"
        }()

        let fields: [Field] = [
            (NSLocalizedString("Date", bundle: loc, comment: ""),        dateStr,       accentCyan),
            (NSLocalizedString("Time", bundle: loc, comment: ""),        timeStr,       accentCyan),
            (NSLocalizedString("Max Temp", bundle: loc, comment: ""),    dive.displayMaxTemperature != nil ? "\(Int(dive.displayMaxTemperature!.rounded()))\(tempUnit.symbol)" : "—", accentRed),
            (NSLocalizedString("Min Temp", bundle: loc, comment: ""),    dive.minTemperature != 0 ? "\(Int(dive.displayMinTemperature.rounded()))\(tempUnit.symbol)" : "—", accentBlue),
            (NSLocalizedString("Air Temp", bundle: loc, comment: ""),    airTempStr,    accentOrange),
            (NSLocalizedString("Platform", bundle: loc, comment: ""),    dive.entryType ?? "—",   accentPurple),
            (NSLocalizedString("Dive Type", bundle: loc, comment: ""),   dive.primaryDiveType ?? "—", accentPurple),
            (NSLocalizedString("Trip", bundle: loc, comment: ""),        tripStr,       accentTeal),
        ]

        return drawFieldGrid(ctx: ctx, title: NSLocalizedString("DIVE INFORMATION", bundle: loc, comment: ""), titleColor: accentCyan,
                             fields: fields, columns: 2, x: x, y: y, width: width)
    }

    // MARK: - Site Details

    private static func drawSiteDetails(ctx: CGContext, dive: Dive, x: CGFloat, y: CGFloat, width: CGFloat) -> CGFloat {
        let prefs = UserPreferences.shared
        let siteStr = dive.siteName.isEmpty ? "—" : dive.siteName

        let locationStr: String = {
            let loc = dive.location.trimmingCharacters(in: .whitespacesAndNewlines)
            if loc.isEmpty || loc == "Inconnu" || loc == NSLocalizedString("Unknown", bundle: Self.loc, comment: "") { return "—" }
            return loc
        }()

        let countryStr: String = {
            if let country = dive.siteCountry, !country.isEmpty {
                return country
            }
            return "—"
        }()

        let visStr: String = {
            guard let v = dive.visibility, !v.isEmpty else { return "—" }
            let trimmed = v.trimmingCharacters(in: .whitespaces)
            if Double(trimmed) != nil { return "\(trimmed) \(prefs.depthUnit.symbol)" }
            return trimmed
        }()

        let gpsStr: String = {
            guard let lat = dive.siteLatitude, let lon = dive.siteLongitude else { return "—" }
            return String(format: "%.6f, %.6f", lat, lon)
        }()

        let altStr: String = {
            guard let alt = dive.displaySiteAltitude else { return "—" }
            return String(format: "%.0f %@", alt, prefs.depthUnit.symbol)
        }()

        let fields: [Field] = [
            (NSLocalizedString("Site", bundle: loc, comment: ""),          siteStr,                                    accentGreen),
            (NSLocalizedString("Location", bundle: loc, comment: ""),      locationStr,                                accentOrange),
            (NSLocalizedString("Country", bundle: loc, comment: ""),       countryStr,                                 accentPurple),
            (NSLocalizedString("Visibility", bundle: loc, comment: ""),    visStr,                                     accentCyan),
            (NSLocalizedString("Weather", bundle: loc, comment: ""),       localizedWeather(dive.weather), accentYellow),
            (NSLocalizedString("Conditions", bundle: loc, comment: ""),    localizedSurfaceConditions(dive.surfaceConditions), accentBlue),
            (NSLocalizedString("Current", bundle: loc, comment: ""),       localizedCurrent(dive.current), accentTeal),
            (NSLocalizedString("Environment", bundle: loc, comment: ""),   dive.siteWaterType ?? "—",                  accentCyan),
            (NSLocalizedString("Body of Water", bundle: loc, comment: ""), dive.siteBodyOfWater ?? "—",                accentBlue),
            (NSLocalizedString("Difficulty", bundle: loc, comment: ""),     localizedDifficulty(dive.siteDifficulty),   accentPurple),
            (NSLocalizedString("GPS", bundle: loc, comment: ""),           gpsStr,                                     accentGreen),
            (NSLocalizedString("Altitude", bundle: loc, comment: ""),      altStr,                                     accentOrange),
        ]

        return drawFieldGrid(ctx: ctx, title: NSLocalizedString("SITE DETAILS", bundle: loc, comment: ""), titleColor: accentGreen,
                             fields: fields, columns: 3, x: x, y: y, width: width)
    }

    // MARK: - Dive Profile Chart

    private static func drawDiveProfile(ctx: CGContext, dive: Dive, x: CGFloat, y: CGFloat, width: CGFloat, depthSymbol: String) -> CGFloat {
        let chartH: CGFloat = 115
        let titleH: CGFloat = 16
        let padBottom: CGFloat = 8
        let cardH = chartH + titleH + padBottom
        let cardRect = CGRect(x: x, y: y - cardH, width: width, height: cardH)
        drawRoundedRect(ctx: ctx, rect: cardRect, radius: 8, fill: bgCard)
        drawCardBorder(ctx: ctx, rect: cardRect, radius: 8)

        drawSectionTitle(ctx: ctx, title: NSLocalizedString("DIVE PROFILE", bundle: loc, comment: ""), x: x + 10, y: y - 11, color: accentCyan)
        let chartX = x + 36
        let chartW = width - 48
        let chartBottom = y - cardH + padBottom + 4
        let chartTop = y - titleH - 6
        // Reserve space below the profile for the deepest-point label
        let labelPadBottom: CGFloat = 10
        let profileBottom = chartBottom + labelPadBottom

        let samples = dive.profileSamples
        guard samples.count >= 2 else {
            let noData: [NSAttributedString.Key: Any] = [
                .font: font(size: 9),
                .foregroundColor: platformColor(textMuted)
            ]
            drawText(NSLocalizedString("No profile data available", bundle: loc, comment: ""), attrs: noData, in: ctx,
                     at: CGPoint(x: chartX + chartW / 2 - 50, y: profileBottom + (chartTop - profileBottom) / 2))
            return y - cardH
        }

        let maxDepth = max(samples.map(\.depth).max() ?? 1, 0.001)
        let maxTime = max(samples.last?.time ?? 1, 0.001)

        // Horizontal grid lines + depth labels (use profileBottom so grid stays above label zone)
        ctx.setStrokeColor(CGColor(red: 0.78, green: 0.80, blue: 0.84, alpha: 0.6))
        ctx.setLineWidth(0.3)
        for i in 0...4 {
            let gy = profileBottom + (chartTop - profileBottom) * CGFloat(i) / 4.0
            ctx.move(to: CGPoint(x: chartX, y: gy))
            ctx.addLine(to: CGPoint(x: chartX + chartW, y: gy))
            ctx.strokePath()

            let depthVal = maxDepth * Double(4 - i) / 4.0
            let label = String(format: "%.0f", dive.displayDepth(depthVal))
            let labelAttrs: [NSAttributedString.Key: Any] = [
                .font: font(size: 5.5),
                .foregroundColor: platformColor(textMuted)
            ]
            drawText(label, attrs: labelAttrs, in: ctx, at: CGPoint(x: x + 10, y: gy - 3))
        }

        // Time axis labels (stay at original chartBottom)
        for i in 0...5 {
            let timeVal = maxTime * Double(i) / 5.0
            let tx = chartX + chartW * CGFloat(i) / 5.0
            let label = String(format: "%.0f", timeVal)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font(size: 5.5),
                .foregroundColor: platformColor(textMuted)
            ]
            drawText(label, attrs: attrs, in: ctx, at: CGPoint(x: tx - 3, y: chartBottom - 10))
        }

        // Axis unit labels
        let unitAttrs: [NSAttributedString.Key: Any] = [
            .font: font(size: 5),
            .foregroundColor: platformColor(textMuted)
        ]
        drawText(depthSymbol, attrs: unitAttrs, in: ctx, at: CGPoint(x: x + 8, y: chartTop + 4))
        drawText(NSLocalizedString("min", bundle: loc, comment: ""), attrs: unitAttrs, in: ctx, at: CGPoint(x: chartX + chartW + 2, y: chartBottom - 10))

        // Profile line (maps depth using profileBottom so deepest point stays above label zone)
        ctx.setStrokeColor(accentCyan)
        ctx.setLineWidth(1.4)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for (i, sample) in samples.enumerated() {
            let sx = chartX + chartW * CGFloat(sample.time / maxTime)
            let sy = chartTop - (chartTop - profileBottom) * CGFloat(sample.depth / maxDepth)
            if i == 0 { ctx.move(to: CGPoint(x: sx, y: sy)) }
            else { ctx.addLine(to: CGPoint(x: sx, y: sy)) }
        }
        ctx.strokePath()

        // Max depth marker (label goes below the line, in the reserved space above the time axis)
        if let deepest = samples.max(by: { $0.depth < $1.depth }) {
            let dx = chartX + chartW * CGFloat(deepest.time / maxTime)
            let dy = chartTop - (chartTop - profileBottom) * CGFloat(deepest.depth / maxDepth)
            ctx.setFillColor(CGColor(red: 0.0, green: 0.55, blue: 0.67, alpha: 0.15))
            ctx.fillEllipse(in: CGRect(x: dx - 4, y: dy - 4, width: 8, height: 8))
            ctx.setFillColor(accentCyan)
            ctx.fillEllipse(in: CGRect(x: dx - 2, y: dy - 2, width: 4, height: 4))
            let depthLabel = String(format: "%.1f %@", dive.displayDepth(deepest.depth), depthSymbol)
            let markerAttrs: [NSAttributedString.Key: Any] = [
                .font: boldFont(size: 5.5),
                .foregroundColor: platformColor(accentCyan)
            ]
            let labelSize = (depthLabel as NSString).size(withAttributes: markerAttrs)
            // Position label below the marker in the reserved padding zone
            let labelY = dy - labelSize.height - 4
            // Keep label to the right, but flip left if it would overflow the chart
            let labelX = (dx + 4 + labelSize.width + 6 > chartX + chartW) ? dx - labelSize.width - 8 : dx + 4
            // Background pill behind the label for readability
            let pillPadH: CGFloat = 3
            let pillPadV: CGFloat = 1.5
            let pillRect = CGRect(x: labelX - pillPadH, y: labelY - pillPadV,
                                  width: labelSize.width + pillPadH * 2, height: labelSize.height + pillPadV * 2)
            drawRoundedRect(ctx: ctx, rect: pillRect, radius: 3, fill: bgCard)
            ctx.saveGState()
            ctx.setStrokeColor(CGColor(red: 0.0, green: 0.55, blue: 0.67, alpha: 0.3))
            ctx.setLineWidth(0.4)
            ctx.addPath(CGPath(roundedRect: pillRect, cornerWidth: 3, cornerHeight: 3, transform: nil))
            ctx.strokePath()
            ctx.restoreGState()
            drawText(depthLabel, attrs: markerAttrs, in: ctx, at: CGPoint(x: labelX, y: labelY))
        }

        return y - cardH
    }

    // MARK: - Dive Statistics

    private static func drawDiveStatistics(ctx: CGContext, dive: Dive, x: CGFloat, y: CGFloat, width: CGFloat,
                                           depthSymbol: String, minHeight: CGFloat = 0) -> CGFloat {
        let maxDepthStr = String(format: "%.1f %@", dive.displayMaxDepth, depthSymbol)
        let avgDepthStr = String(format: "%.1f %@", dive.displayAverageDepth, depthSymbol)
        let durationStr = dive.formattedDuration
        let rmvStr = dive.formattedRMV

        let siStr: String = {
            let raw = dive.surfaceInterval.trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty || raw == "0h 00m" || raw == "0" { return "—" }
            return raw
        }()

        let computerStr = dive.computerName.isEmpty ? "—" : dive.computerName
        let weightsStr: String = dive.weights.map {
            UserPreferences.shared.weightUnit.formatted($0, from: dive.storedWeightUnit)
        } ?? "—"
        let serialStr = (dive.computerSerialNumber?.isEmpty == false) ? dive.computerSerialNumber!.uppercased() : "—"

        let fields: [Field] = [
            (NSLocalizedString("Max Depth", bundle: loc, comment: ""),        maxDepthStr,   accentBlue),
            (NSLocalizedString("Average Depth", bundle: loc, comment: ""),    avgDepthStr,   accentCyan),
            (NSLocalizedString("Duration", bundle: loc, comment: ""),         durationStr,   accentGreen),
            (NSLocalizedString("RMV Rate", bundle: loc, comment: ""),         rmvStr,        accentPink),
            (NSLocalizedString("Surface Interval", bundle: loc, comment: ""), siStr,         accentYellow),
            (NSLocalizedString("Weights", bundle: loc, comment: ""),          weightsStr,    textGray),
            (NSLocalizedString("Computer", bundle: loc, comment: ""),         computerStr,   accentBlue),
            (NSLocalizedString("Serial", bundle: loc, comment: ""),           serialStr,     accentTeal),
        ]

        return drawFieldGrid(ctx: ctx, title: NSLocalizedString("DIVE STATISTICS", bundle: loc, comment: ""), titleColor: accentCyan,
                             fields: fields, columns: 3, x: x, y: y, width: width, minHeight: minHeight)
    }

    // MARK: - Tanks

    private static func drawTanksSection(ctx: CGContext, dive: Dive, x: CGFloat, y: CGFloat, width: CGFloat,
                                         pressSymbol: String, minHeight: CGFloat = 0) -> CGFloat {
        let tanks = dive.tanks

        // Build rows for all tanks (show placeholder when empty)
        var allRows: [Field] = []
        if tanks.isEmpty {
            allRows.append((NSLocalizedString("Tank", bundle: loc, comment: ""), "—", accentBlue))
            allRows.append((NSLocalizedString("Gas", bundle: loc, comment: ""), "—", accentPurple))
            allRows.append((NSLocalizedString("Volume", bundle: loc, comment: ""), "—", accentCyan))
            allRows.append((NSLocalizedString("Start", bundle: loc, comment: ""), "—", accentGreen))
            allRows.append((NSLocalizedString("End", bundle: loc, comment: ""), "—", accentOrange))
            allRows.append((NSLocalizedString("Used", bundle: loc, comment: ""), "—", accentRed))
        }
        for (index, tank) in tanks.enumerated() {
            let tankLabel: String
            if tanks.count > 1 {
                tankLabel = String(format: NSLocalizedString("Tank %lld", bundle: loc, comment: ""), index + 1)
            } else {
                tankLabel = NSLocalizedString("Tank", bundle: loc, comment: "")
            }
            let typeStr = localizedTankType(tank.tankType)
            let materialStr = localizedTankMaterial(tank.tankMaterial)
            let headerValue = materialStr.isEmpty ? typeStr : "\(typeStr) · \(materialStr)"
            allRows.append((tankLabel, headerValue, accentBlue))

            let gasStr: String = {
                if tank.hePercentage > 0 {
                    return "Trimix \(tank.o2Percentage)/\(tank.hePercentage)"
                } else if tank.o2Percentage > 21 {
                    return "Nitrox \(tank.o2Percentage)%"
                }
                return "Air (21%)"
            }()
            allRows.append((NSLocalizedString("Gas", bundle: loc, comment: ""), gasStr, accentPurple))

            let volStr: String = {
                guard let vol = tank.volume else { return "—" }
                return dive.formattedVolume(vol, workingPressureRaw: tank.workingPressure)
            }()
            allRows.append((NSLocalizedString("Volume", bundle: loc, comment: ""), volStr, accentCyan))

            let startStr: String = {
                guard let sp = tank.startPressure else { return "—" }
                return dive.formattedPressure(sp)
            }()
            allRows.append((NSLocalizedString("Start", bundle: loc, comment: ""), startStr, accentGreen))

            let endStr: String = {
                guard let ep = tank.endPressure else { return "—" }
                return dive.formattedPressure(ep)
            }()
            allRows.append((NSLocalizedString("End", bundle: loc, comment: ""), endStr, accentOrange))

            let consumedStr: String = {
                guard let sp = tank.startPressure, let ep = tank.endPressure, sp > ep else { return "—" }
                let delta = dive.displayPressure(sp) - dive.displayPressure(ep)
                return String(format: "%.0f %@", delta, pressSymbol)
            }()
            allRows.append((NSLocalizedString("Used", bundle: loc, comment: ""), consumedStr, accentRed))
        }

        // Tanks use a single column since it's a narrow card now
        return drawFieldGrid(ctx: ctx, title: NSLocalizedString("TANKS", bundle: loc, comment: ""), titleColor: accentBlue,
                             fields: allRows, columns: 2, x: x, y: y, width: width, minHeight: minHeight)
    }

    // MARK: - Deco Information

    private static func drawDecoSection(ctx: CGContext, dive: Dive, x: CGFloat, y: CGFloat, width: CGFloat, minHeight: CGFloat = 0) -> CGFloat {
        // Algorithm (strip GF values since they are shown separately in GF Low/High)
        let algoStr: String = {
            guard let raw = dive.decompressionAlgorithm, !raw.isEmpty else { return "—" }
            let pattern = #"\s*GF\s*\d+/\d+"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return raw }
            let ns = raw as NSString
            let cleaned = regex.stringByReplacingMatches(in: raw, range: NSRange(location: 0, length: ns.length), withTemplate: "")
                .trimmingCharacters(in: .whitespaces)
            return cleaned.isEmpty ? raw : cleaned
        }()

        // GF values extracted from the raw algorithm string (e.g. "ZHL-16C GF 40/85")
        let gfStr: String = {
            guard let raw = dive.decompressionAlgorithm, !raw.isEmpty else { return "—" }
            let pattern = #"GF\s*(\d+)/(\d+)"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return "—" }
            let ns = raw as NSString
            let results = regex.matches(in: raw, range: NSRange(location: 0, length: ns.length))
            guard let match = results.first, match.numberOfRanges == 3 else { return "—" }
            let low = ns.substring(with: match.range(at: 1))
            let high = ns.substring(with: match.range(at: 2))
            return "\(low)/\(high)"
        }()

        // CNS
        let cnsStr: String = {
            guard let cns = dive.cnsPercentage else { return "—" }
            return String(format: "%.1f%%", cns)
        }()

        // Deco type
        let decoTypeStr: String = dive.isDecompressionDive
            ? NSLocalizedString("Deco dive", bundle: loc, comment: "")
            : NSLocalizedString("No-deco", bundle: loc, comment: "")
        let decoTypeColor: CGColor = dive.isDecompressionDive ? accentOrange : accentGreen

        var fields: [Field] = [
            (NSLocalizedString("Algorithm", bundle: loc, comment: ""),  algoStr,      accentCyan),
            (NSLocalizedString("GF Low/High", bundle: loc, comment: ""), gfStr,       accentPurple),
            (NSLocalizedString("CNS O₂", bundle: loc, comment: ""),     cnsStr,       accentYellow),
            (NSLocalizedString("Dive Type", bundle: loc, comment: ""),  decoTypeStr,  decoTypeColor),
        ]

        // Add deco stops if present
        if dive.isDecompressionDive && !dive.decoStops.isEmpty {
            for stop in dive.decoStops {
                let depthLabel: String
                if dive.importDistanceUnit == "feet" {
                    depthLabel = String(format: "%.0f ft", stop.depth * 3.28084)
                } else {
                    depthLabel = String(format: "%.0f m", stop.depth)
                }

                let timeLabel: String = {
                    let m = Int(stop.time) / 60
                    let s = Int(stop.time) % 60
                    if m > 0 { return s > 0 ? "\(m) min \(s) s" : "\(m) min" }
                    return "\(s) s"
                }()

                let typeLabel: String = {
                    switch stop.type {
                    case 1: return NSLocalizedString("Safety Stop", bundle: loc, comment: "")
                    case 2: return NSLocalizedString("Deco Stop", bundle: loc, comment: "")
                    case 3: return NSLocalizedString("Deep Stop", bundle: loc, comment: "")
                    default: return NSLocalizedString("NDL", bundle: loc, comment: "")
                    }
                }()

                fields.append((typeLabel, "\(depthLabel) · \(timeLabel)", accentOrange))
            }
        }

        return drawFieldGrid(ctx: ctx, title: NSLocalizedString("DECO INFO", bundle: loc, comment: ""), titleColor: accentPurple,
                             fields: fields, columns: 2, x: x, y: y, width: width, minHeight: minHeight)
    }

    // MARK: - Equipment

    private static func drawEquipmentSection(ctx: CGContext, dive: Dive, x: CGFloat, y: CGFloat, width: CGFloat) -> CGFloat {
        let gearList = dive.usedGear ?? []
        guard !gearList.isEmpty else { return y }

        let titleH: CGFloat = 14
        let lineH: CGFloat = 11
        let padBottom: CGFloat = 6

        let cols = 4
        let dataRows = Int(ceil(Double(gearList.count) / Double(cols)))
        let cardH = CGFloat(dataRows) * lineH + titleH + padBottom
        let cardRect = CGRect(x: x, y: y - cardH, width: width, height: cardH)

        drawRoundedRect(ctx: ctx, rect: cardRect, radius: 8, fill: bgCard)
        drawCardBorder(ctx: ctx, rect: cardRect, radius: 8)

        drawSectionTitle(ctx: ctx, title: NSLocalizedString("EQUIPMENT USED", bundle: loc, comment: ""), x: x + 10, y: y - (titleH / 2) - 3, color: accentOrange)

        let columnWidth = (width - 20) / CGFloat(cols)
        let startY = y - titleH - 1

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byTruncatingTail

        let fontSize: CGFloat = 5.5
        let dotSize: CGFloat = 2.5

        for (i, gear) in gearList.enumerated() {
            let row = i / cols
            let col = i % cols
            let gx = x + 12 + CGFloat(col) * columnWidth
            let gy = startY - CGFloat(row) * lineH

            let chipColor = gearChipColor(for: gear.category)

            ctx.setFillColor(chipColor)
            ctx.fillEllipse(in: CGRect(x: gx, y: gy - 4, width: dotSize, height: dotSize))

            let nameAttrs: [NSAttributedString.Key: Any] = [
                .font: mediumFont(size: fontSize),
                .foregroundColor: platformColor(textWhite),
                .paragraphStyle: paragraphStyle
            ]

            let textRect = CGRect(x: gx + 5, y: gy - 7.5, width: columnWidth - 8, height: 8)
            let attrStr = NSAttributedString(string: gear.name, attributes: nameAttrs)
            drawWrappedText(attrStr, in: ctx, rect: textRect)
        }

        return y - cardH
    }

    // MARK: - Notes

    private static func drawNotesSection(ctx: CGContext, dive: Dive, x: CGFloat, y: CGFloat, width: CGFloat, footerY: CGFloat) -> CGFloat {
        let notes = dive.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayNotes = notes.isEmpty ? NSLocalizedString("No notes", bundle: loc, comment: "") : notes

        let titleH: CGFloat = 14
        let padBottom: CGFloat = 6
        let maxCardH = y - footerY - 4

        guard maxCardH > 25 else { return y }

        let textAreaWidth = width - 20
        let textAreaMaxHeight = maxCardH - titleH - padBottom

        var currentFontSize: CGFloat = 7.5
        let minFontSize: CGFloat = 4.5

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 0.5
        paragraphStyle.lineBreakMode = .byWordWrapping

        func measureHeight(for size: CGFloat, text: String) -> CGFloat {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font(size: size),
                .paragraphStyle: paragraphStyle
            ]
            let attrStr = NSAttributedString(string: text, attributes: attrs)
            let framesetter = CTFramesetterCreateWithAttributedString(attrStr as CFAttributedString)
            let constraints = CGSize(width: textAreaWidth, height: CGFloat.greatestFiniteMagnitude)
            let suggestedSize = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRangeMake(0, 0), nil, constraints, nil)
            return suggestedSize.height
        }

        var textH = measureHeight(for: currentFontSize, text: displayNotes)

        while textH > textAreaMaxHeight && currentFontSize > minFontSize {
            currentFontSize -= 0.5
            textH = measureHeight(for: currentFontSize, text: displayNotes)
        }

        let finalDrawingHeight = min(textH, textAreaMaxHeight)
        let cardH = min(finalDrawingHeight + titleH + padBottom, maxCardH)
        let cardRect = CGRect(x: x, y: y - cardH, width: width, height: cardH)

        drawRoundedRect(ctx: ctx, rect: cardRect, radius: 8, fill: bgCard)
        drawCardBorder(ctx: ctx, rect: cardRect, radius: 8)

        drawSectionTitle(ctx: ctx, title: NSLocalizedString("NOTES", bundle: loc, comment: ""), x: x + 10, y: y - 10, color: textGray)

        let textColor = notes.isEmpty ? textMuted : textWhite
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: font(size: currentFontSize),
            .foregroundColor: platformColor(textColor),
            .paragraphStyle: paragraphStyle
        ]
        let attrStr = NSAttributedString(string: displayNotes, attributes: textAttrs)
        let textDrawingRect = CGRect(x: x + 10, y: y - cardH + padBottom, width: textAreaWidth, height: finalDrawingHeight)
        drawWrappedText(attrStr, in: ctx, rect: textDrawingRect)

        return y - cardH
    }

    // MARK: - Footer (signatures + branding)

    private static func drawBrandedFooter(ctx: CGContext, dive: Dive, allDives: [Dive], x: CGFloat, y: CGFloat, width: CGFloat, pageWidth: CGFloat) {
        // Brand bar at the bottom
        let brandH: CGFloat = 20
        let brandY = y

        ctx.saveGState()
        let bgColors = [
            CGColor(red: 0.95, green: 0.96, blue: 0.97, alpha: 1.0),
            bgDark
        ] as CFArray
        let brandRect = CGRect(x: 0, y: brandY, width: pageWidth, height: brandH)
        if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: bgColors, locations: [0, 1]) {
            ctx.clip(to: brandRect)
            ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: brandY), end: CGPoint(x: 0, y: brandY + brandH), options: [])
        }
        ctx.restoreGState()

        // Logo
        let logoSize: CGFloat = 12
        let logoX = x
        let logoY = brandY + (brandH - logoSize) / 2
        if let logoImage = loadAppIcon() {
            let logoRect = CGRect(x: logoX, y: logoY, width: logoSize, height: logoSize)
            ctx.saveGState()
            let clipPath = CGPath(roundedRect: logoRect, cornerWidth: 2, cornerHeight: 2, transform: nil)
            ctx.addPath(clipPath)
            ctx.clip()
            ctx.draw(logoImage, in: logoRect)
            ctx.restoreGState()
        }

        let brandAttrs: [NSAttributedString.Key: Any] = [
            .font: boldFont(size: 6.5),
            .foregroundColor: platformColor(accentCyan)
        ]
        drawText("BlueDive", attrs: brandAttrs, in: ctx, at: CGPoint(x: logoX + logoSize + 4, y: brandY + brandH / 2 - 3))

        // "Generated by" (right-aligned)
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        let genStr = String(format: NSLocalizedString("Generated by BlueDive %@ (%@) — %@", bundle: loc, comment: ""), appVersion, buildNumber, dateFormatter.string(from: Date()))
        let genAttrs: [NSAttributedString.Key: Any] = [
            .font: font(size: 5),
            .foregroundColor: platformColor(textMuted)
        ]
        let genStrNS = NSAttributedString(string: genStr, attributes: genAttrs)
        let genWidth = genStrNS.size().width
        drawText(genStr, attrs: genAttrs, in: ctx, at: CGPoint(x: x + width - genWidth, y: brandY + brandH / 2 - 3))

        // Signature section
        let sigTop = brandY + brandH + 4
        let sigH: CGFloat = 36
        let colGap: CGFloat = 12
        let cols = 4
        let colW = (width - colGap * CGFloat(cols - 1)) / CGFloat(cols)

        // Separator line
        ctx.setStrokeColor(divider)
        ctx.setLineWidth(0.4)
        ctx.move(to: CGPoint(x: x, y: sigTop - 2))
        ctx.addLine(to: CGPoint(x: x + width, y: sigTop - 2))
        ctx.strokePath()

        let diverName = dive.diverName.isEmpty ? NSLocalizedString("Solo Diver", bundle: loc, comment: "") : dive.diverName
        let buddyRaw = dive.buddies.trimmingCharacters(in: .whitespacesAndNewlines)
        let buddyName = buddyRaw.isEmpty ? NSLocalizedString("No buddy", bundle: loc, comment: "") : buddyRaw
        let masterRaw = dive.diveMaster?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let masterName = masterRaw.isEmpty ? NSLocalizedString("No dive master", bundle: loc, comment: "") : masterRaw
        let skipperRaw = dive.skipper?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let skipperName = skipperRaw.isEmpty ? NSLocalizedString("No skipper", bundle: loc, comment: "") : skipperRaw

        let sigColumns: [(label: String, name: String, placeholder: Bool)] = [
            (NSLocalizedString("Diver", bundle: loc, comment: ""), diverName, dive.diverName.isEmpty),
            (NSLocalizedString("Buddies", bundle: loc, comment: ""), buddyName, buddyRaw.isEmpty),
            (NSLocalizedString("Dive Master", bundle: loc, comment: ""), masterName, masterRaw.isEmpty),
            (NSLocalizedString("Skipper", bundle: loc, comment: ""), skipperName, skipperRaw.isEmpty),
        ]

        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: font(size: 5),
            .foregroundColor: platformColor(textGray)
        ]

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byTruncatingTail

        for (i, col) in sigColumns.enumerated() {
            let cx = x + CGFloat(i) * (colW + colGap)
            let lineWidth = colW

            // Label
            drawText(col.label.uppercased(), attrs: labelAttrs, in: ctx, at: CGPoint(x: cx, y: sigTop + sigH - 8))

            // Name (auto-shrinks, lighter style for placeholders)
            var fontSize: CGFloat = 7.5
            let minFontSize: CGFloat = 5.0
            let nameColor = col.placeholder ? textMuted : textWhite

            func nameFont(_ size: CGFloat) -> CTFont {
                col.placeholder ? lightFont(size: size) : mediumFont(size: size)
            }

            var nameAttrs: [NSAttributedString.Key: Any] = [
                .font: nameFont(fontSize),
                .foregroundColor: platformColor(nameColor),
                .paragraphStyle: paragraphStyle
            ]
            var textWidth = (col.name as NSString).size(withAttributes: nameAttrs).width
            while textWidth > lineWidth && fontSize > minFontSize {
                fontSize -= 0.5
                nameAttrs[.font] = nameFont(fontSize)
                textWidth = (col.name as NSString).size(withAttributes: nameAttrs).width
            }
            drawText(col.name, attrs: nameAttrs, in: ctx, at: CGPoint(x: cx, y: sigTop + sigH - 18))

            // Signature line
            let lineY = sigTop + 4
            ctx.setStrokeColor(textMuted)
            ctx.setLineWidth(0.4)
            ctx.move(to: CGPoint(x: cx, y: lineY))
            ctx.addLine(to: CGPoint(x: cx + lineWidth, y: lineY))
            ctx.strokePath()
        }
    }

    // MARK: - Drawing Helpers

    private static func drawRoundedRect(ctx: CGContext, rect: CGRect, radius: CGFloat, fill: CGColor) {
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(fill)
        ctx.fillPath()
    }

    private static func drawCardBorder(ctx: CGContext, rect: CGRect, radius: CGFloat) {
        ctx.saveGState()
        ctx.setStrokeColor(CGColor(red: 0.78, green: 0.80, blue: 0.84, alpha: 0.6))
        ctx.setLineWidth(0.5)
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.addPath(path)
        ctx.strokePath()
        ctx.restoreGState()
    }

    private static func drawSectionTitle(ctx: CGContext, title: String, x: CGFloat, y: CGFloat, color: CGColor) {
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: x, y: y - 2, width: 2.5, height: 9))

        let attrs: [NSAttributedString.Key: Any] = [
            .font: boldFont(size: 7.5),
            .foregroundColor: platformColor(color)
        ]
        drawText(title, attrs: attrs, in: ctx, at: CGPoint(x: x + 6, y: y - 1))
    }

    private static func drawText(_ text: String, attrs: [NSAttributedString.Key: Any], in ctx: CGContext, at point: CGPoint) {
        let str = NSAttributedString(string: text, attributes: attrs)
        drawAttributedString(str, in: ctx, at: point)
    }

    private static func drawAttributedString(_ str: NSAttributedString, in ctx: CGContext, at point: CGPoint) {
        let line = CTLineCreateWithAttributedString(str as CFAttributedString)
        ctx.saveGState()
        ctx.textPosition = point
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    private static func drawWrappedText(_ str: NSAttributedString, in ctx: CGContext, rect: CGRect) {
        let framesetter = CTFramesetterCreateWithAttributedString(str as CFAttributedString)
        let path = CGPath(rect: rect, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, 0), path, nil)
        ctx.saveGState()
        CTFrameDraw(frame, ctx)
        ctx.restoreGState()
    }

    // MARK: - Asset Loading

    private static func loadAppIcon() -> CGImage? {
        #if os(macOS)
        guard let nsImage = NSImage(named: "BlueDiveIcon") else { return nil }
        var rect = CGRect(x: 0, y: 0, width: nsImage.size.width, height: nsImage.size.height)
        return nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        #else
        guard let uiImage = UIImage(named: "BlueDiveIcon") else { return nil }
        return uiImage.cgImage
        #endif
    }

    // MARK: - Gear Colour Mapping

    private static func gearChipColor(for category: String) -> CGColor {
        guard let cat = GearCategory(exportKeyOrRawValue: category) else { return textGray }
        switch cat {
        case .suit, .drysuit, .underwear: return accentPurple
        case .tank: return accentBlue
        case .firstStage, .secondStage: return accentGreen
        case .bcd, .wing, .backplate: return accentOrange
        case .computer, .transmitter: return accentCyan
        case .fins, .mask, .snorkel: return accentPink
        case .weights: return textGray
        case .light: return accentYellow
        case .knife, .gloves: return accentRed
        default: return textGray
        }
    }

    // MARK: - Platform Colour Bridging

    private static func platformColor(_ cgColor: CGColor) -> Any {
        #if os(macOS)
        return NSColor(cgColor: cgColor) ?? NSColor.black
        #else
        return UIColor(cgColor: cgColor)
        #endif
    }
}
