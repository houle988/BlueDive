import SwiftUI

/// A downward-pointing triangle, sized and positioned by whatever frame it's given.
///
/// Shared by every map pin in the app (`MapPointerPin` below, plus `DiveMapPin` and
/// `DiveMapClusterPin` in `DiveMapView.swift`) so the triangle's geometry lives in exactly
/// one place. It used to be copy-pasted three times as a raw `Path` built from literal
/// coordinates (`x: -10` … `x: 10`) — SwiftUI does NOT re-centre a literal `Path` to match
/// an applied `.frame()`, so that path rendered with its apex ~10pt left of where the
/// circle above it was centred, in all three copies at once, since they'd all been pasted
/// from the same wrong example. A real `Shape` doesn't have this failure mode: `path(in:)`
/// always receives the exact, correctly-positioned `rect` the shape is being drawn into,
/// so drawing relative to that rect (rather than to hand-picked literal coordinates) can't
/// drift out of sync with whatever size the caller's `.frame()` asks for.
struct PinTrianglePointer: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// A map annotation pin shaped like the Map tab's `DiveMapPin`: a tinted circle with a
/// white stroke above a downward-pointing triangle whose apex is a single precise point.
///
/// Use it inside an `Annotation(..., anchor: .bottom)` so the triangle's tip sits exactly
/// on the annotated coordinate — unlike a plain `.circle.fill` SF Symbol anchored at
/// `.center`, which marks the coordinate with the middle of a disc rather than a point.
///
/// This is a sibling of `DiveMapPin` / `DiveMapClusterPin` (which carry dive-specific
/// content and tint rules), not a replacement for them: the geometry here — circle size,
/// 2pt white stroke, 5pt shadow, 20×15 triangle, and the `-2` triangle offset that closes
/// the seam against the circle — is deliberately copied so pins on the Site Details map
/// and the coordinate picker match the Map tab's pins exactly.
struct MapPointerPin: View {
    /// Bare SF Symbol name (e.g. `"arrow.down"`), without a `.circle` / `.circle.fill`
    /// variant — the circle is drawn by this view.
    let systemImage: String
    /// Fill colour of both the circle and the triangle. Callers keep their own semantics
    /// (green entry, orange exit, purple combined, …).
    let tint: Color
    /// Diameter of the circle. Defaults to 32 to match `DiveMapPin`'s unselected size;
    /// pass a smaller value for compact preview maps.
    var diameter: CGFloat = 32

    /// Square box the glyph is fitted into. Sizing the glyph by box rather than by font
    /// point size keeps wide "combined" symbols such as `arrow.up.arrow.down` clear of the
    /// white stroke: `scaledToFit` constrains the wide axis, so the glyph can never grow
    /// past half the inner circle in either direction.
    private var glyphSize: CGFloat { diameter * 0.5 }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(tint)
                    .frame(width: diameter, height: diameter)
                    .overlay(
                        Circle()
                            .stroke(.white, lineWidth: 2)
                    )
                    .shadow(radius: 5)

                Image(systemName: systemImage)
                    .resizable()
                    .scaledToFit()
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .frame(width: glyphSize, height: glyphSize)
                    // The enclosing Annotation supplies the accessible label (its own
                    // `label:` closure or title), so the glyph must stay silent.
                    .accessibilityHidden(true)
            }
            // VStack siblings still paint in declaration order where they overlap (same
            // as a ZStack), so without this the triangle — declared second — would paint
            // over the circle's bottom edge in the `-2` seam below. Keeping the circle on
            // top lets its round edge cleanly cover the triangle's flat top corners.
            .zIndex(1)

            // Triangle pointer — apex at the bottom (flat edge at top, against the
            // circle) so the tip is a single precise point, matching anchor: .bottom.
            // The `-2` offset closes the seam against the circle above it.
            PinTrianglePointer()
                .fill(tint)
                .frame(width: 20, height: 15)
                .offset(y: -2)
        }
    }
}
