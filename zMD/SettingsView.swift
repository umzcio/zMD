import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings = SettingsManager.shared
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Settings")
                    .font(.system(size: 20, weight: .semibold))
                Spacer()

                // Hidden button for ESC key support
                Button("") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .frame(width: 0, height: 0)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    // Appearance Section
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Appearance")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.secondary)

                        VStack(spacing: 12) {
                            // Light/Dark Mode Toggle
                            HStack {
                                Text("Theme")
                                    .font(.system(size: 14))
                                Spacer()
                                Picker("", selection: $settings.colorScheme) {
                                    Text("System").tag(nil as ColorScheme?)
                                    Text("Light").tag(ColorScheme.light as ColorScheme?)
                                    Text("Dark").tag(ColorScheme.dark as ColorScheme?)
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 240)
                            }
                        }
                        .padding()
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(8)
                    }

                    // Font Section
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Font")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.secondary)

                        VStack(spacing: 8) {
                            ForEach(SettingsManager.FontStyle.allCases, id: \.self) { fontStyle in
                                FontStyleOption(
                                    fontStyle: fontStyle,
                                    isSelected: settings.fontStyle == fontStyle
                                ) {
                                    settings.fontStyle = fontStyle
                                }
                            }
                        }
                        .padding()
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(8)
                    }
                }
                .padding()
            }
        }
        .frame(width: 600, height: 480)
    }
}

struct FontStyleOption: View {
    let fontStyle: SettingsManager.FontStyle
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(fontStyle.displayName)
                        .font(fontStyle.font(size: 14))
                        .foregroundColor(.primary)

                    Text("The quick brown fox jumps over the lazy dog")
                        .font(fontStyle.font(size: 12))
                        .foregroundColor(.secondary)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.accentColor)
                        .font(.system(size: 16))
                }
            }
            .padding(12)
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }
}
