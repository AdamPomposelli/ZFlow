import SwiftUI

// Overlay style chooser. It lived in the setup wizard; the wizard is gone
// but the appearance settings still offer the same choice.

struct OverlayStylePreview: View {
    let isMinimalist: Bool

    private let frameWidth: CGFloat = 110
    private let frameHeight: CGFloat = 56
    private let menuBarHeight: CGFloat = 8
    private let notchWidth: CGFloat = 26
    private let notchHeight: CGFloat = 8

    var body: some View {
        ZStack(alignment: .top) {
            // Screen background — represents the host app behind the bar.
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .windowBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.primary.opacity(0.15), lineWidth: 0.5)
                )

            // Menu bar strip.
            Rectangle()
                .fill(Color.primary.opacity(0.10))
                .frame(height: menuBarHeight)

            // Tab strip stand-in below menu bar (so collisions read).
            HStack(spacing: 3) {
                ForEach(0..<5, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.primary.opacity(0.18))
                        .frame(height: 5)
                }
            }
            .padding(.horizontal, 6)
            .padding(.top, menuBarHeight + 4)

            // Notch (always visible).
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 3,
                bottomTrailingRadius: 3,
                topTrailingRadius: 0
            )
            .fill(Color.black)
            .frame(width: notchWidth, height: notchHeight)

            // Style-specific overlay rendering.
            if isMinimalist {
                // Two slim wings flanking the notch, inside menu bar height.
                HStack(spacing: notchWidth) {
                    UnevenRoundedRectangle(
                        topLeadingRadius: 0,
                        bottomLeadingRadius: 3,
                        bottomTrailingRadius: 0,
                        topTrailingRadius: 0
                    )
                    .fill(Color.black)
                    .frame(width: 16, height: notchHeight)

                    UnevenRoundedRectangle(
                        topLeadingRadius: 0,
                        bottomLeadingRadius: 0,
                        bottomTrailingRadius: 3,
                        topTrailingRadius: 0
                    )
                    .fill(Color.black)
                    .frame(width: 16, height: notchHeight)
                }
            } else {
                // Drop-down pill hanging below the menu bar from the notch.
                UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: 5,
                    bottomTrailingRadius: 5,
                    topTrailingRadius: 0
                )
                .fill(Color.black)
                .frame(width: notchWidth + 10, height: notchHeight + 12)
            }
        }
        .frame(width: frameWidth, height: frameHeight)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct OverlayStyleOptionRow: View {
    let title: String
    let subtitle: String
    let isMinimalist: Bool
    @Binding var selection: Bool

    var body: some View {
        let isSelected = (selection == isMinimalist)
        Button(action: {
            selection = isMinimalist
        }) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isSelected ? Color.blue : Color.secondary)

                OverlayStylePreview(isMinimalist: isMinimalist)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}
