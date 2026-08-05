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
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(
                Motion.reduceMotion ? nil : .easeOut(duration: configuration.isPressed ? 0.16 : 0.1),
                value: configuration.isPressed
            )
            .onHover { hovering in
                withAnimation(Motion.fast) {
                    isHovered = hovering
                }
            }
    }
}
