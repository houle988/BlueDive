import SwiftUI

/// The paged container of the Welcome Tour and Getting Started: background, the page itself
/// (swiped on iOS, one page at a time on macOS, which has no paging TabView), the page dots and
/// the Back / Next / Skip buttons. Each guide passes its own pages and what its buttons do.
///
/// On the last page, Next becomes `lastPagePrimary`, and Skip is replaced by
/// `lastPageSecondary` when given (hidden otherwise, keeping its place so the buttons above do
/// not move).
struct GuidePager<Page: View>: View {
    let pageCount: Int
    @Binding var current: Int
    /// The main button on the last page (e.g. Done).
    let lastPagePrimary: Text
    let onLastPagePrimary: () -> Void
    /// Replaces Skip on the last page, when set.
    var lastPageSecondary: Text? = nil
    var onLastPageSecondary: () -> Void = {}
    /// Skip, on every page but the last.
    let onSkip: () -> Void
    @ViewBuilder let page: (Int) -> Page

    @State private var appeared = false

    private var isLastPage: Bool { current >= pageCount - 1 }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.platformBackground, Color.cyan.opacity(0.06), Color.platformBackground],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                #if os(iOS)
                TabView(selection: $current) {
                    ForEach(0..<pageCount, id: \.self) { index in
                        page(index)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                #else
                page(current)
                    .id(current)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.3), value: current)
                #endif

                bottomControls
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 20)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.5)) {
                appeared = true
            }
        }
    }

    // MARK: - Bottom Controls

    private var bottomControls: some View {
        VStack(spacing: 20) {
            Divider().opacity(0.3).padding(.horizontal, 24)

            HStack(spacing: 8) {
                ForEach(0..<pageCount, id: \.self) { index in
                    Capsule()
                        .fill(index == current ? Color.cyan : Color.primary.opacity(0.2))
                        .frame(width: index == current ? 24 : 8, height: 8)
                        .animation(.spring(response: 0.3), value: current)
                }
            }
            // The dots are purely decorative; this exposes the position they convey
            // visually as a single spoken element instead of dropping it entirely.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: String(format: NSLocalizedString("Page %lld of %lld", bundle: .forAppLanguage(), comment: "Announces the current page's position in the welcome wizard's page indicator"), current + 1, pageCount)))

            HStack {
                if current > 0 {
                    Button {
                        move(by: -1)
                    } label: {
                        Text("Back")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            // The padding responds too, not only the text.
                            .contentShape(Rectangle())
                    }
                    .transition(.opacity)
                    .borderlessButton()
                }

                Spacer()

                Button {
                    if isLastPage {
                        onLastPagePrimary()
                    } else {
                        move(by: 1)
                    }
                } label: {
                    Group {
                        if isLastPage {
                            lastPagePrimary
                        } else {
                            Text("Next")
                        }
                    }
                    .font(.subheadline)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 12)
                    .background(Capsule().fill(Color.cyan))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)

            secondaryButton
        }
        .animation(.easeInOut(duration: 0.25), value: current)
        .padding(.top, 8)
        .padding(.bottom, 40)
        .padding(.horizontal, 8)
    }

    /// Skip, or on the last page `lastPageSecondary` (hidden without one).
    @ViewBuilder
    private var secondaryButton: some View {
        if isLastPage, let lastPageSecondary {
            Button(action: onLastPageSecondary) {
                lastPageSecondary
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        } else {
            Button(action: onSkip) {
                Text("Skip")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(isLastPage ? 0 : 1)
            .disabled(isLastPage)
            .accessibilityHidden(isLastPage)
        }
    }

    private func move(by offset: Int) {
        let target = min(max(current + offset, 0), pageCount - 1)
        #if os(iOS)
        current = target
        #else
        withAnimation { current = target }
        #endif
    }
}

/// The icon, title and subtitle at the top of a guide page.
struct GuidePageHeader: View {
    let icon: String
    let color: Color
    let title: Text
    let subtitle: Text

    var body: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.12))
                    .frame(width: 90, height: 90)
                Image(systemName: icon)
                    .font(.system(size: 40))
                    .foregroundStyle(color)
                    .accessibilityHidden(true)
            }

            VStack(spacing: 6) {
                title
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)

                subtitle
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A row of a guide page: a tinted icon tile, a bold title and a caption, with an optional link
/// below (the Welcome Tour's features, Getting Started's "More in Settings").
struct GuideFeatureRow: View {
    let icon: String
    let color: Color
    let title: Text
    let detail: Text
    var link: URL? = nil

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(color.opacity(0.12))
                    .frame(width: 42, height: 42)

                Image(systemName: icon)
                    .font(.body)
                    .foregroundStyle(color)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 2) {
                title
                    .font(.subheadline)
                    .fontWeight(.bold)
                    .foregroundStyle(.primary)

                detail
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let link {
                    ExternalLinkView(url: link)
                        .padding(.top, 2)
                }
            }

            Spacer()
        }
        .padding(12)
        .sectionCardBackground()
        // Read as one element, except a row with a link, which VoiceOver must reach on its own.
        .accessibilityElement(children: link == nil ? .combine : .contain)
    }
}
