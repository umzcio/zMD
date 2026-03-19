import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings = SettingsManager.shared
    @ObservedObject var documentManager = DocumentManager.shared

    var body: some View {
        TabView {
            GeneralSettingsTab(settings: settings, documentManager: documentManager)
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            AppearanceSettingsTab(settings: settings)
                .tabItem {
                    Label("Appearance", systemImage: "paintbrush")
                }

            AboutTab()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 480, height: 480)
    }
}

// MARK: - General

struct GeneralSettingsTab: View {
    @ObservedObject var settings: SettingsManager
    @ObservedObject var documentManager: DocumentManager

    var body: some View {
        Form {
            Section("Editor") {
                Toggle("Auto-save files", isOn: Binding(
                    get: { documentManager.autoSaveEnabled },
                    set: { documentManager.autoSaveEnabled = $0 }
                ))

                Toggle("Scroll sync in split view", isOn: Binding(
                    get: { documentManager.isScrollSyncEnabled },
                    set: { documentManager.isScrollSyncEnabled = $0 }
                ))

                Toggle("Auto-close brackets & quotes", isOn: $settings.autoCloseBrackets)

                Picker("Tab width", selection: $settings.tabWidth) {
                    Text("2 spaces").tag(2)
                    Text("4 spaces").tag(4)
                }
                .pickerStyle(.segmented)
            }

            Section("Source Editor") {
                Toggle("Show line numbers", isOn: $settings.showLineNumbers)
                Toggle("Show minimap", isOn: $settings.showMinimap)
                Toggle("Show editor toolbar", isOn: $settings.showEditorToolbar)
            }

            Section("Default View") {
                Picker("Mode", selection: Binding(
                    get: { documentManager.viewMode },
                    set: { documentManager.viewMode = $0 }
                )) {
                    Text("Preview").tag(ViewMode.preview)
                    Text("Source").tag(ViewMode.source)
                    Text("Split").tag(ViewMode.split)
                }
                .pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}

// MARK: - Appearance

struct AppearanceSettingsTab: View {
    @ObservedObject var settings: SettingsManager

    var body: some View {
        Form {
            Section("Theme") {
                Picker("Appearance", selection: $settings.colorScheme) {
                    Text("System").tag(nil as ColorScheme?)
                    Text("Light").tag(ColorScheme.light as ColorScheme?)
                    Text("Dark").tag(ColorScheme.dark as ColorScheme?)
                }
                .pickerStyle(.segmented)
            }

            Section("Font") {
                Picker("Style", selection: $settings.fontStyle) {
                    ForEach(SettingsManager.FontStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }

                HStack {
                    Text("Preview")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("The quick brown fox jumps over the lazy dog")
                        .font(settings.fontStyle.font(size: 13))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Section("Zoom") {
                HStack {
                    Button {
                        settings.zoomOut()
                    } label: {
                        Image(systemName: "minus.magnifyingglass")
                    }
                    .buttonStyle(.borderless)
                    .disabled(settings.zoomLevel <= 0.5)

                    Spacer()

                    Text("\(Int(settings.zoomLevel * 100))%")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .frame(width: 50)

                    Spacer()

                    Button {
                        settings.zoomIn()
                    } label: {
                        Image(systemName: "plus.magnifyingglass")
                    }
                    .buttonStyle(.borderless)
                    .disabled(settings.zoomLevel >= 2.0)
                }

                if settings.zoomLevel != 1.0 {
                    Button("Reset to 100%") {
                        settings.resetZoom()
                    }
                    .font(.system(size: 12))
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}

// MARK: - About

struct AboutTab: View {
    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 80, height: 80)

            Text("zMD")
                .font(.system(size: 20, weight: .semibold))

            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                .font(.system(size: 13))
                .foregroundColor(.secondary)

            Text("A lightweight markdown viewer for macOS")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            Button("Check for Updates...") {
                UpdateManager.shared.checkForUpdates()
            }
            .disabled(UpdateManager.shared.isChecking)

            Spacer()

            Text("Made with care by UMZCIO")
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.5))
                .padding(.bottom, 12)
        }
    }
}
