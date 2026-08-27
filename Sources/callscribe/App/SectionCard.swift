import SwiftUI

/// A titled, collapsible card: a branded icon chip + title header, and padded
/// content, on a floating translucent surface (material + soft shadow) so each
/// section reads as a distinct, elevated block.
struct SectionCard<Content: View>: View {
    let title: String
    let systemImage: String
    @Binding var isExpanded: Bool
    /// When set, a copy button appears in the header.
    var onCopy: (() -> Void)?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The whole padded header row toggles; the copy button (a real
            // Button) still intercepts its own clicks.
            HStack(spacing: Spacing.md) {
                Image(systemName: systemImage)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(LinearGradient.brand, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text(title).font(.headline)
                Spacer(minLength: 0)

                if let onCopy {
                    Button(action: onCopy) {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Copy this section")
                    .pointerCursor()
                }

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.md)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            }
            .pointerCursor()

            if isExpanded {
                Divider().opacity(0.5)
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.lg)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.10), radius: 12, y: 4)
    }
}

extension View {
    /// Show the pointing-hand cursor while hovering. Uses SwiftUI's managed
    /// pointer style (macOS 15+) rather than NSCursor.push()/pop(), whose
    /// unbalanced calls corrupt the process-wide cursor stack and leave the
    /// cursor stuck after the first hover.
    func pointerCursor() -> some View {
        pointerStyle(.link)
    }
}
