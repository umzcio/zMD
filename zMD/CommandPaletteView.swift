import SwiftUI

// MARK: - Command Registry

enum CommandCategory: String, CaseIterable {
    case file = "File"
    case view = "View"
    case edit = "Edit"
    case export = "Export"
    case navigation = "Navigation"

    var color: Color {
        switch self {
        case .file: return .blue
        case .view: return .purple
        case .edit: return .orange
        case .export: return .green
        case .navigation: return .teal
        }
    }
}

struct CommandAction: Identifiable {
    let id = UUID()
    let name: String
    let category: CommandCategory
    let shortcut: String?
    let icon: String
    let isEnabled: () -> Bool
    let action: () -> Void
}

class CommandRegistry {
    static func commands(documentManager: DocumentManager, folderManager: FolderManager) -> [CommandAction] {
        let hasDoc = { !documentManager.openDocuments.isEmpty }

        return [
            // File
            CommandAction(name: "Open File", category: .file, shortcut: "\u{2318}O", icon: "doc", isEnabled: { true }) {
                documentManager.openFile()
            },
            CommandAction(name: "Open Folder", category: .file, shortcut: "\u{2318}\u{2325}O", icon: "folder", isEnabled: { true }) {
                folderManager.openFolder()
            },
            CommandAction(name: "Save", category: .file, shortcut: "\u{2318}S", icon: "square.and.arrow.down", isEnabled: hasDoc) {
                documentManager.saveCurrentDocument()
            },
            CommandAction(name: "Close Tab", category: .file, shortcut: "\u{2318}W", icon: "xmark.square", isEnabled: hasDoc) {
                if let id = documentManager.selectedDocumentId,
                   let doc = documentManager.openDocuments.first(where: { $0.id == id }) {
                    documentManager.closeDocument(doc)
                }
            },
            CommandAction(name: "Refresh", category: .file, shortcut: "\u{2318}R", icon: "arrow.clockwise", isEnabled: hasDoc) {
                documentManager.refreshCurrentDocument()
            },
            CommandAction(name: "Open File Location", category: .file, shortcut: nil, icon: "folder.badge.gearshape", isEnabled: hasDoc) {
                if let id = documentManager.selectedDocumentId,
                   let doc = documentManager.openDocuments.first(where: { $0.id == id }) {
                    documentManager.revealInFinder(document: doc)
                }
            },
            CommandAction(name: "Duplicate", category: .file, shortcut: "\u{2318}\u{21E7}S", icon: "doc.on.doc", isEnabled: hasDoc) {
                if let id = documentManager.selectedDocumentId,
                   let doc = documentManager.openDocuments.first(where: { $0.id == id }) {
                    documentManager.duplicateDocument(document: doc)
                }
            },
            CommandAction(name: "Rename", category: .file, shortcut: nil, icon: "pencil", isEnabled: hasDoc) {
                if let id = documentManager.selectedDocumentId,
                   let doc = documentManager.openDocuments.first(where: { $0.id == id }) {
                    documentManager.renameDocument(document: doc)
                }
            },

            // View
            CommandAction(name: "Preview Mode", category: .view, shortcut: "\u{2318}1", icon: "doc.richtext", isEnabled: { true }) {
                documentManager.viewMode = .preview
            },
            CommandAction(name: "Source Mode", category: .view, shortcut: "\u{2318}2", icon: "doc.text", isEnabled: { true }) {
                documentManager.viewMode = .source
            },
            CommandAction(name: "Split Mode", category: .view, shortcut: "\u{2318}3", icon: "rectangle.split.2x1", isEnabled: { true }) {
                documentManager.viewMode = .split
            },
            CommandAction(name: "Toggle Focus Mode", category: .view, shortcut: "\u{2318}\u{21E7}F", icon: "arrow.up.left.and.arrow.down.right", isEnabled: { true }) {
                NotificationCenter.default.post(name: .toggleFocusMode, object: nil)
            },
            CommandAction(name: "Zoom In", category: .view, shortcut: "\u{2318}=", icon: "plus.magnifyingglass", isEnabled: { true }) {
                SettingsManager.shared.zoomIn()
            },
            CommandAction(name: "Zoom Out", category: .view, shortcut: "\u{2318}-", icon: "minus.magnifyingglass", isEnabled: { true }) {
                SettingsManager.shared.zoomOut()
            },
            CommandAction(name: "Reset Zoom", category: .view, shortcut: "\u{2318}0", icon: "1.magnifyingglass", isEnabled: { true }) {
                SettingsManager.shared.resetZoom()
            },

            // Edit
            CommandAction(name: "Find", category: .edit, shortcut: "\u{2318}F", icon: "magnifyingglass", isEnabled: hasDoc) {
                documentManager.startSearch()
            },

            // Export
            CommandAction(name: "Export as PDF", category: .export, shortcut: nil, icon: "doc.text.fill", isEnabled: hasDoc) {
                if let id = documentManager.selectedDocumentId,
                   let doc = documentManager.openDocuments.first(where: { $0.id == id }) {
                    ExportManager.shared.exportToPDF(content: doc.content, fileName: doc.name)
                }
            },
            CommandAction(name: "Export as HTML", category: .export, shortcut: nil, icon: "globe", isEnabled: hasDoc) {
                if let id = documentManager.selectedDocumentId,
                   let doc = documentManager.openDocuments.first(where: { $0.id == id }) {
                    ExportManager.shared.exportToHTML(content: doc.content, fileName: doc.name, includeStyles: true)
                }
            },
            CommandAction(name: "Export as HTML (no styles)", category: .export, shortcut: nil, icon: "globe", isEnabled: hasDoc) {
                if let id = documentManager.selectedDocumentId,
                   let doc = documentManager.openDocuments.first(where: { $0.id == id }) {
                    ExportManager.shared.exportToHTML(content: doc.content, fileName: doc.name, includeStyles: false)
                }
            },
            CommandAction(name: "Export as Word (.docx)", category: .export, shortcut: nil, icon: "doc.fill", isEnabled: hasDoc) {
                if let id = documentManager.selectedDocumentId,
                   let doc = documentManager.openDocuments.first(where: { $0.id == id }) {
                    ExportManager.shared.exportToDOCX(content: doc.content, fileName: doc.name, baseURL: doc.url)
                }
            },
            CommandAction(name: "Export as Word (.rtf)", category: .export, shortcut: nil, icon: "doc.fill", isEnabled: hasDoc) {
                if let id = documentManager.selectedDocumentId,
                   let doc = documentManager.openDocuments.first(where: { $0.id == id }) {
                    ExportManager.shared.exportToWord(content: doc.content, fileName: doc.name)
                }
            },
            CommandAction(name: "Print", category: .export, shortcut: "\u{2318}P", icon: "printer", isEnabled: hasDoc) {
                if let id = documentManager.selectedDocumentId,
                   let doc = documentManager.openDocuments.first(where: { $0.id == id }) {
                    PrintManager.shared.print(content: doc.content, fileName: doc.name)
                }
            },

            // Navigation
            CommandAction(name: "Quick Open", category: .navigation, shortcut: "\u{2318}\u{21E7}O", icon: "magnifyingglass", isEnabled: { true }) {
                NotificationCenter.default.post(name: .showQuickOpen, object: nil)
            },
            CommandAction(name: "Next Tab", category: .navigation, shortcut: "\u{2303}\u{21E5}", icon: "arrow.right", isEnabled: hasDoc) {
                documentManager.selectNextTab()
            },
            CommandAction(name: "Previous Tab", category: .navigation, shortcut: "\u{2303}\u{21E7}\u{21E5}", icon: "arrow.left", isEnabled: hasDoc) {
                documentManager.selectPreviousTab()
            },
        ]
    }
}

// MARK: - Command Palette Overlay

struct CommandPaletteOverlay: View {
    @EnvironmentObject var documentManager: DocumentManager
    @EnvironmentObject var folderManager: FolderManager
    @Binding var isPresented: Bool
    @State private var searchText = ""
    @State private var selectedIndex = 0

    private var filteredCommands: [CommandAction] {
        let all = CommandRegistry.commands(documentManager: documentManager, folderManager: folderManager)
        if searchText.isEmpty { return all }

        return all.compactMap { cmd -> (CommandAction, Int)? in
            guard let result = fuzzyMatch(query: searchText, target: cmd.name) else { return nil }
            return (cmd, result.score)
        }
        .sorted { $0.1 > $1.1 }
        .map { $0.0 }
    }

    var body: some View {
        ZStack {
            // Dimmed background
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .onTapGesture {
                    isPresented = false
                }

            // Palette
            VStack(spacing: 0) {
                // Search field
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)

                    CommandPaletteTextField(
                        text: $searchText,
                        selectedIndex: $selectedIndex,
                        itemCount: filteredCommands.count,
                        onEscape: { isPresented = false },
                        onSubmit: { executeSelected() }
                    )
                    .font(.system(size: 14))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                Divider()

                // Results
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(filteredCommands.enumerated()), id: \.element.id) { index, command in
                                CommandRow(
                                    command: command,
                                    isSelected: index == selectedIndex
                                )
                                .id(index)
                                .onTapGesture {
                                    selectedIndex = index
                                    executeSelected()
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(maxHeight: 320)
                    .onChange(of: selectedIndex) { _ in
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo(selectedIndex, anchor: .center)
                        }
                    }
                }

                if filteredCommands.isEmpty {
                    Text("No matching commands")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .padding(.vertical, 20)
                }
            }
            .frame(width: 460)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.2), radius: 20, y: 8)
            .padding(.top, 80)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .onChange(of: searchText) { _ in
            selectedIndex = 0
        }
    }

    private func executeSelected() {
        guard selectedIndex < filteredCommands.count else { return }
        let cmd = filteredCommands[selectedIndex]
        guard cmd.isEnabled() else { return }
        isPresented = false
        // Slight delay to allow dismiss animation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            cmd.action()
        }
    }
}

struct CommandRow: View {
    let command: CommandAction
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            // Category badge
            Text(command.category.rawValue)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(command.category.color)
                )

            // Icon
            Image(systemName: command.icon)
                .font(.system(size: 12))
                .foregroundColor(command.isEnabled() ? .primary : .secondary)
                .frame(width: 16)

            // Name
            Text(command.name)
                .font(.system(size: 13))
                .foregroundColor(command.isEnabled() ? .primary : .secondary)

            Spacer()

            // Shortcut
            if let shortcut = command.shortcut {
                Text(shortcut)
                    .font(.system(size: 11, design: .rounded))
                    .foregroundColor(Color(NSColor.tertiaryLabelColor))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(NSColor.controlBackgroundColor))
                    )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
    }
}

// MARK: - NSTextField wrapper for keyboard handling

struct CommandPaletteTextField: NSViewRepresentable {
    @Binding var text: String
    @Binding var selectedIndex: Int
    let itemCount: Int
    let onEscape: () -> Void
    let onSubmit: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = "Type a command..."
        field.isBordered = false
        field.backgroundColor = .clear
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: 14)
        field.delegate = context.coordinator
        context.coordinator.field = field

        // Become first responder after a short delay
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
        }

        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        context.coordinator.itemCount = itemCount
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CommandPaletteTextField
        weak var field: NSTextField?
        var itemCount: Int = 0

        init(parent: CommandPaletteTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.moveUp(_:)) {
                if parent.selectedIndex > 0 {
                    parent.selectedIndex -= 1
                }
                return true
            }
            if commandSelector == #selector(NSResponder.moveDown(_:)) {
                if parent.selectedIndex < itemCount - 1 {
                    parent.selectedIndex += 1
                }
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onEscape()
                return true
            }
            return false
        }
    }
}
