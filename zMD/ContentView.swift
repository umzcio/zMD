import SwiftUI

struct ContentView: View {
    @EnvironmentObject var documentManager: DocumentManager
    @EnvironmentObject var folderManager: FolderManager
    @AppStorage(DefaultsKeys.showOutline) private var showOutline = false
    @State private var selectedHeadingId: String?
    @State private var showQuickOpen = false
    @State private var showCommandPalette = false
    @State private var showFocusExitPill = false
    @State private var magnifyMonitor: Any?
    @State private var baseZoomForGesture: CGFloat = 1.0

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                if !documentManager.openDocuments.isEmpty {
                    // Tab bar (hidden in focus mode)
                    if !documentManager.isFocusModeActive {
                        TabBar(showOutline: $showOutline)
                            .environmentObject(documentManager)

                        Divider()
                    }

                    // Search bar
                    if documentManager.isSearching && !documentManager.isFocusModeActive {
                        Group {
                            if documentManager.showReplace && documentManager.viewMode != .preview {
                                SearchBar(
                                    searchText: $documentManager.searchText,
                                    isSearching: $documentManager.isSearching,
                                    currentMatch: documentManager.searchControlMatchCount > 0 ? documentManager.currentMatchIndex + 1 : 0,
                                    totalMatches: documentManager.searchControlMatchCount,
                                    onNext: { documentManager.nextMatch() },
                                    onPrevious: { documentManager.previousMatch() },
                                    onClose: { documentManager.endSearch() },
                                    showReplace: true,
                                    replaceText: $documentManager.replaceText,
                                    isRegex: documentManager.isRegexSearch,
                                    isCaseSensitive: documentManager.isCaseSensitive,
                                    onToggleRegex: { documentManager.isRegexSearch.toggle(); documentManager.performSearch() },
                                    onToggleCaseSensitive: { documentManager.isCaseSensitive.toggle(); documentManager.performSearch() },
                                    onReplace: { documentManager.replaceCurrentMatch() },
                                    onReplaceAll: { documentManager.replaceAllMatches() }
                                )
                            } else {
                                SearchBar(
                                    searchText: $documentManager.searchText,
                                    isSearching: $documentManager.isSearching,
                                    currentMatch: documentManager.searchControlMatchCount > 0 ? documentManager.currentMatchIndex + 1 : 0,
                                    totalMatches: documentManager.searchControlMatchCount,
                                    onNext: { documentManager.nextMatch() },
                                    onPrevious: { documentManager.previousMatch() },
                                    onClose: { documentManager.endSearch() }
                                )
                            }
                        }
                        .padding(8)
                        .transition(Motion.slideOrFade(edge: .top))

                        Divider()
                    }

                    // Content area
                    if documentManager.isFocusModeActive {
                        // Focus mode: centered content, no sidebars
                        FocusModeContentView(selectedHeadingId: $selectedHeadingId)
                    } else {
                        // Normal mode: sidebars and outline
                        NormalContentView(
                            showOutline: $showOutline,
                            selectedHeadingId: $selectedHeadingId
                        )
                    }

                    // Status bar (hidden in focus mode)
                    if !documentManager.isFocusModeActive {
                        Divider()
                        StatusBarView()
                            .environmentObject(documentManager)
                    }
                } else {
                    WelcomeView()
                }
            }
            .animation(Motion.morph, value: documentManager.isFocusModeActive)
            .animation(Motion.fast, value: documentManager.isSearching)
            .frame(minWidth: 600, minHeight: 400)

            // Focus mode exit pill + Escape handler. Attach a hidden cancelAction button so
            // Escape triggers `isFocusModeActive = false` without needing a local NSEvent monitor.
            if documentManager.isFocusModeActive {
                // Invisible Escape-to-exit button; accessibility: labeled for screen readers.
                Button("Exit Focus Mode") {
                    withAnimation(Motion.morph) {
                        documentManager.isFocusModeActive = false
                    }
                }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityLabel("Exit Focus Mode")

                VStack {
                    if showFocusExitPill {
                        Button(action: {
                            documentManager.isFocusModeActive = false
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.down.left.and.arrow.up.right")
                                    .font(.system(size: 10, weight: .medium))
                                Text("Exit Focus Mode")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .transition(Motion.slideOrFade(edge: .top))
                    }
                    Spacer()
                }
                .padding(.top, 12)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onHover { hovering in
                    withAnimation(Motion.standard) {
                        showFocusExitPill = hovering
                    }
                }
                .allowsHitTesting(true)
            }
        }
        .overlay {
            QuickOpenOverlay(isPresented: $showQuickOpen, selectedHeadingId: $selectedHeadingId)
                .environmentObject(documentManager)
        }
        .overlay {
            if showCommandPalette {
                CommandPaletteOverlay(isPresented: $showCommandPalette)
                    .environmentObject(documentManager)
                    .environmentObject(folderManager)
            }
        }
        .overlay {
            ToastOverlay()
        }
        // The `.keyboardShortcut("o", [.command, .shift])` previously attached here was dead —
        // SwiftUI's .keyboardShortcut only binds to an interactable control (Button, MenuItem).
        // Without a control it was never wired to anything; the real Quick Open shortcut lives
        // on the File menu. Removed.
        // Live search: every keystroke in the find bar must rebuild searchMatches, otherwise
        // Replace operates on stale ranges (or empty array) and silently no-ops or — worse —
        // corrupts the doc by applying replacement at offsets that no longer match. Mirroring
        // the same trigger to regex/case toggles keeps the highlight + replace target in sync.
        .onChange(of: documentManager.searchText) { _ in
            documentManager.performSearch()
        }
        .onChange(of: documentManager.isRegexSearch) { _ in
            documentManager.performSearch()
        }
        .onChange(of: documentManager.isCaseSensitive) { _ in
            documentManager.performSearch()
        }
        .onReceive(NotificationCenter.default.publisher(for: .showQuickOpen)) { _ in
            showCommandPalette = false
            showQuickOpen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showCommandPalette)) { _ in
            showQuickOpen = false
            showCommandPalette = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleFocusMode)) { _ in
            withAnimation(Motion.morph) {
                documentManager.isFocusModeActive.toggle()
            }
        }
        .onAppear {
            magnifyMonitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { event in
                if event.phase == .began {
                    baseZoomForGesture = SettingsManager.shared.zoomLevel
                }
                // Accumulate delta magnification
                baseZoomForGesture += event.magnification
                let clamped = min(2.0, max(0.5, baseZoomForGesture))
                // Snap to 10% increments on gesture end
                if event.phase == .ended || event.phase == .cancelled {
                    SettingsManager.shared.zoomLevel = (clamped * 10).rounded() / 10
                    baseZoomForGesture = SettingsManager.shared.zoomLevel
                } else {
                    SettingsManager.shared.zoomLevel = clamped
                }
                return event
            }
        }
        .onDisappear {
            if let monitor = magnifyMonitor {
                NSEvent.removeMonitor(monitor)
                magnifyMonitor = nil
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            DropHandler.handle(providers: providers, documentManager: documentManager)
            return true
        }
    }

}

extension Notification.Name {
    static let showQuickOpen = Notification.Name("showQuickOpen")
    static let showCommandPalette = Notification.Name("showCommandPalette")
    static let toggleFocusMode = Notification.Name("toggleFocusMode")
}

#Preview {
    ContentView()
        .environmentObject(DocumentManager())
        .environmentObject(FolderManager.shared)
        .environmentObject(SettingsManager.shared)
}
