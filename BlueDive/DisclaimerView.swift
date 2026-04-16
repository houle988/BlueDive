import SwiftUI

struct DisclaimerView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("hasAcceptedDisclaimer") private var hasAcceptedDisclaimer = false
    @State private var agreed = false
    @State private var appeared = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.platformBackground, Color.orange.opacity(0.06), Color.platformBackground],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 24) {
                        Spacer().frame(height: 30)

                        // Icon
                        ZStack {
                            Circle()
                                .fill(Color.orange.opacity(0.12))
                                .frame(width: 90, height: 90)

                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 40))
                                .foregroundStyle(.orange)
                        }

                        // Title
                        VStack(spacing: 6) {
                            Text("Important Notice")
                                .font(.system(size: 26, weight: .bold, design: .rounded))
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.center)

                            Text("Please read before continuing")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }

                        // Disclaimer content
                        VStack(alignment: .leading, spacing: 16) {
                            disclaimerRow(
                                icon: "book.closed.fill",
                                color: .blue,
                                title: "Dive Log Only",
                                description: "BlueDive is strictly a dive logging application designed to record and organize your dive history. It is not a dive planning tool and must never be used as such."
                            )

                            disclaimerRow(
                                icon: "graduationcap.fill",
                                color: .green,
                                title: "Proper Training Required",
                                description: "All dives should be planned and conducted with proper training and certification from a recognized dive agency (e.g. PADI, SSI, NAUI, CMAS, BSAC, or equivalent)."
                            )

                            disclaimerRow(
                                icon: "shield.lefthalf.filled",
                                color: .red,
                                title: "No Liability",
                                description: "BlueDive and its developers assume no responsibility or liability for dive planning, dive safety decisions, or any incidents related to diving activities. Always follow safe diving practices and your training."
                            )
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 8)

                        Spacer().frame(height: 8)
                    }
                    .padding(.horizontal)
                }

                // Bottom section with checkbox and button
                VStack(spacing: 16) {
                    Divider().opacity(0.3).padding(.horizontal, 24)

                    // Agree checkbox
                    Button {
                        agreed.toggle()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: agreed ? "checkmark.square.fill" : "square")
                                .font(.title3)
                                .foregroundStyle(agreed ? .cyan : .secondary)

                            Text("I understand that BlueDive is a dive log only and not a dive planning tool")
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                        }
                        .padding(.horizontal, 24)
                    }
                    .buttonStyle(.plain)

                    // Continue button
                    Button {
                        hasAcceptedDisclaimer = true
                        dismiss()
                    } label: {
                        Text("Continue")
                            .font(.subheadline)
                            .fontWeight(.bold)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                Capsule().fill(agreed ? Color.cyan : Color.gray.opacity(0.4))
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!agreed)
                    .padding(.horizontal, 32)
                    .animation(.easeInOut(duration: 0.2), value: agreed)
                }
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 20)
        }
        .interactiveDismissDisabled()
        .onAppear {
            withAnimation(.easeOut(duration: 0.5)) {
                appeared = true
            }
        }
        #if os(macOS)
        .frame(minWidth: 550, idealWidth: 650, maxWidth: 800, minHeight: 600, idealHeight: 700, maxHeight: 850)
        #endif
    }

    // MARK: - Disclaimer Row

    private func disclaimerRow(icon: String, color: Color, title: LocalizedStringKey, description: LocalizedStringKey) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(color.opacity(0.12))
                    .frame(width: 42, height: 42)

                Image(systemName: icon)
                    .font(.body)
                    .foregroundStyle(color)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.bold)
                    .foregroundStyle(.primary)

                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.primary.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
        )
    }
}
