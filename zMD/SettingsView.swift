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
        .background(EscapeKeyHandler())
    }
}

/// Invisible helper that closes the enclosing window when Escape is pressed.
/// The Settings scene's NSWindow is created by AppKit itself, so there's no
/// SwiftUI `@State isPresented` to flip — we have to reach the real window.
private struct EscapeKeyHandler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        EscapeKeyHandlingView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class EscapeKeyHandlingView: NSView {
    private var escapeMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
        guard let window else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak window] event in
            guard event.keyCode == 53, event.window === window else { return event }
            window?.performClose(nil)
            return nil
        }
    }

    deinit {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
        }
    }
}

// MARK: - General

struct GeneralSettingsTab: View {
    @ObservedObject var settings: SettingsManager
    @ObservedObject var documentManager: DocumentManager

    var body: some View {
        Form {
            Section("Editor") {
                Toggle("Auto-save files", isOn: $documentManager.autoSaveEnabled)

                Toggle("Scroll sync in split view", isOn: $documentManager.isScrollSyncEnabled)

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
                Picker("Mode", selection: $documentManager.viewMode) {
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
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("The quick brown fox jumps over the lazy dog")
                        .font(settings.fontStyle.font(size: 13))
                        .foregroundStyle(.secondary)
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
                    .accessibilityLabel("Zoom Out")

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
                    .accessibilityLabel("Zoom In")
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
    // Must observe UpdateManager — the button's disabled state below reads isChecking, and
    // without observation the view never re-renders when the check starts/finishes.
    @ObservedObject private var updateManager = UpdateManager.shared

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
                .foregroundStyle(.secondary)

            Text("A lightweight markdown viewer for macOS")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Button("Check for Updates...") {
                updateManager.checkForUpdates()
            }
            .disabled(updateManager.isChecking)

            Spacer()

            Text("Made with care by UMZCIO")
                .font(.system(size: 11))
                .foregroundStyle(Color.secondary.opacity(0.5))
                .padding(.bottom, 12)
        }
    }
}
