import SwiftUI

// MARK: - Export Progress Overlay

/// The progress card shown over a view while a multi-dive export runs: a progress bar with
/// "x of y dives exported" when `total` is known, a spinner with "Exporting..." otherwise.
/// Pass `onCancel` to show a Cancel button that stops the export (the caller cancels its task).
/// Shared by the dive list's XML/UDDF exports and the Statistics CSV export.
struct ExportProgressOverlay: ViewModifier {
    let isPresented: Bool
    let current: Int
    let total: Int
    var onCancel: (() -> Void)? = nil

    func body(content: Content) -> some View {
        content
            .overlay {
                if isPresented {
                    ZStack {
                        Color.black.opacity(0.6).ignoresSafeArea()
                        VStack(spacing: 16) {
                            if total > 0 {
                                ProgressView(value: Double(current), total: Double(total))
                                    .progressViewStyle(.linear)
                                    .frame(width: 220)
                                Text(String(format: NSLocalizedString("%@ of %@ dives exported", bundle: .forAppLanguage(), value: "%@ of %@ dives exported", comment: "Progress label during dive export showing current and total count"),
                                     Double(current).localizedString(decimals: 0),
                                     Double(total).localizedString(decimals: 0)))
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                    .monospacedDigit()
                                    .transaction { $0.animation = nil }
                            } else {
                                ProgressView().scaleEffect(1.5)
                                Text("Exporting...")
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                            }
                            if let onCancel {
                                Button(role: .cancel, action: onCancel) {
                                    Text("Cancel")
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .padding(32)
                        .background(RoundedRectangle(cornerRadius: 16).fill(.ultraThinMaterial))
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: isPresented)
            .animation(.linear(duration: 0.15), value: current)
    }
}

extension View {
    /// Shows `ExportProgressOverlay` over the view while `isPresented` is true.
    func exportProgressOverlay(isPresented: Bool, current: Int, total: Int, onCancel: (() -> Void)? = nil) -> some View {
        modifier(ExportProgressOverlay(isPresented: isPresented, current: current, total: total, onCancel: onCancel))
    }
}
