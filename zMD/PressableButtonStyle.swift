import SwiftUI

/// Subtle scale feedback while a button is pressed.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(Motion.fast, value: configuration.isPressed)
    }
}
