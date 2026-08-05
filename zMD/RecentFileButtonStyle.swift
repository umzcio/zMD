import SwiftUI

struct RecentFileButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.accentColor.opacity(0.08) : Color.clear)
                    .padding(.horizontal, 4)
            )
            .onHover { hovering in
                withAnimation(Motion.fast) {
                    isHovered = hovering
                }
            }
    }
}
