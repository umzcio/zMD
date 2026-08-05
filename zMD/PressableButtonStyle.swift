import SwiftUI

/// Subtle scale feedback while a button is pressed. The press (deliberate
/// user phase) runs slower than the release (system response), which snaps.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(
                Motion.reduceMotion ? nil : .easeOut(duration: configuration.isPressed ? 0.16 : 0.1),
                value: configuration.isPressed
            )
    }
}
