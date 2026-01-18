import SwiftUI

struct QuickOpenView: NSViewRepresentable {
    @EnvironmentObject var documentManager: DocumentManager
    @Binding var isPresented: Bool

    func makeNSView(context: Context) -> QuickOpenNSView {
        let view = QuickOpenNSView()
        view.documentManager = documentManager
        view.dismissHandler = { isPresented = false }
        view.openFileHandler = { url in
            documentManager.loadDocument(from: url)
            isPresented = false
        }
        return view
    }

    func updateNSView(_ nsView: QuickOpenNSView, context: Context) {
        nsView.documentManager = documentManager
        nsView.reloadData()
    }
}

class QuickOpenNSView: NSView {
    weak var documentManager: DocumentManager?
    var dismissHandler: (() -> Void)?
    var openFileHandler: ((URL) -> Void)?

    private var searchField: NSTextField!
    private var tableView: NSTableView!
    private var scrollView: NSScrollView!
    private var filteredFiles: [URL] = []
    private var searchText = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.cornerRadius = 12

        // Container stack
        let container = NSStackView()
        container.orientation = .vertical
        container.spacing = 0
        container.translatesAutoresizingMaskIntoConstraints = false
        addSubview(container)

        // Search field container
        let searchContainer = NSView()
        searchContainer.translatesAutoresizingMaskIntoConstraints = false

        let searchIcon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)!)
        searchIcon.translatesAutoresizingMaskIntoConstraints = false
        searchIcon.contentTintColor = .secondaryLabelColor
        searchContainer.addSubview(searchIcon)

        searchField = NSTextField()
        searchField.placeholderString = "Search recent files..."
        searchField.isBordered = false
        searchField.backgroundColor = .clear
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 16)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchFieldAction)
        searchContainer.addSubview(searchField)

        container.addArrangedSubview(searchContainer)

        // Divider
        let divider1 = NSBox()
        divider1.boxType = .separator
        container.addArrangedSubview(divider1)

        // Table view
        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.backgroundColor = .clear

        tableView = NSTableView()
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.headerView = nil
        tableView.rowHeight = 44
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.selectionHighlightStyle = .regular
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.doubleAction = #selector(tableDoubleClick)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        column.width = 476
        tableView.addTableColumn(column)

        scrollView.documentView = tableView
        container.addArrangedSubview(scrollView)

        // Divider
        let divider2 = NSBox()
        divider2.boxType = .separator
        container.addArrangedSubview(divider2)

        // Footer
        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.distribution = .equalSpacing
        footer.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)

        let hint1 = NSTextField(labelWithString: "↑↓ Navigate")
        hint1.textColor = .secondaryLabelColor
        hint1.font = .systemFont(ofSize: 11)

        let hint2 = NSTextField(labelWithString: "↵ Open")
        hint2.textColor = .secondaryLabelColor
        hint2.font = .systemFont(ofSize: 11)

        let hint3 = NSTextField(labelWithString: "esc Close")
        hint3.textColor = .secondaryLabelColor
        hint3.font = .systemFont(ofSize: 11)

        footer.addArrangedSubview(hint1)
        footer.addArrangedSubview(hint2)
        footer.addArrangedSubview(hint3)
        container.addArrangedSubview(footer)

        // Constraints
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: topAnchor),
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),

            searchContainer.heightAnchor.constraint(equalToConstant: 44),

            searchIcon.leadingAnchor.constraint(equalTo: searchContainer.leadingAnchor, constant: 12),
            searchIcon.centerYAnchor.constraint(equalTo: searchContainer.centerYAnchor),
            searchIcon.widthAnchor.constraint(equalToConstant: 20),
            searchIcon.heightAnchor.constraint(equalToConstant: 20),

            searchField.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: searchContainer.trailingAnchor, constant: -12),
            searchField.centerYAnchor.constraint(equalTo: searchContainer.centerYAnchor),

            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),

            footer.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    func reloadData() {
        updateFilteredFiles()
        tableView.reloadData()
        if !filteredFiles.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    private func updateFilteredFiles() {
        guard let documentManager = documentManager else {
            filteredFiles = []
            return
        }

        if searchText.isEmpty {
            filteredFiles = documentManager.recentFileURLs
        } else {
            filteredFiles = documentManager.recentFileURLs.filter { url in
                url.lastPathComponent.localizedCaseInsensitiveContains(searchText)
            }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            reloadData()
            window?.makeFirstResponder(searchField)
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: // Down arrow
            let newRow = min(tableView.selectedRow + 1, filteredFiles.count - 1)
            if newRow >= 0 {
                tableView.selectRowIndexes(IndexSet(integer: newRow), byExtendingSelection: false)
                tableView.scrollRowToVisible(newRow)
            }
        case 126: // Up arrow
            let newRow = max(tableView.selectedRow - 1, 0)
            if newRow >= 0 && !filteredFiles.isEmpty {
                tableView.selectRowIndexes(IndexSet(integer: newRow), byExtendingSelection: false)
                tableView.scrollRowToVisible(newRow)
            }
        case 53: // Escape
            dismissHandler?()
        case 36: // Return/Enter
            openSelectedFile()
        default:
            super.keyDown(with: event)
        }
    }

    @objc private func searchFieldAction() {
        openSelectedFile()
    }

    @objc private func tableDoubleClick() {
        openSelectedFile()
    }

    private func openSelectedFile() {
        let row = tableView.selectedRow
        guard row >= 0 && row < filteredFiles.count else { return }
        openFileHandler?(filteredFiles[row])
    }
}

extension QuickOpenNSView: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        searchText = searchField.stringValue
        updateFilteredFiles()
        tableView.reloadData()
        if !filteredFiles.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(moveDown(_:)) {
            let newRow = min(tableView.selectedRow + 1, filteredFiles.count - 1)
            if newRow >= 0 {
                tableView.selectRowIndexes(IndexSet(integer: newRow), byExtendingSelection: false)
                tableView.scrollRowToVisible(newRow)
            }
            return true
        } else if commandSelector == #selector(moveUp(_:)) {
            let newRow = max(tableView.selectedRow - 1, 0)
            if newRow >= 0 && !filteredFiles.isEmpty {
                tableView.selectRowIndexes(IndexSet(integer: newRow), byExtendingSelection: false)
                tableView.scrollRowToVisible(newRow)
            }
            return true
        } else if commandSelector == #selector(cancelOperation(_:)) {
            dismissHandler?()
            return true
        }
        return false
    }
}

extension QuickOpenNSView: NSTableViewDelegate, NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return filteredFiles.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < filteredFiles.count else { return nil }
        let url = filteredFiles[row]

        let cell = NSTableCellView()

        let iconView = NSImageView(image: NSWorkspace.shared.icon(forFile: url.path))
        iconView.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(iconView)

        let nameLabel = NSTextField(labelWithString: url.lastPathComponent)
        nameLabel.font = .systemFont(ofSize: 14, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(nameLabel)

        let pathLabel = NSTextField(labelWithString: url.deletingLastPathComponent().path)
        pathLabel.font = .systemFont(ofSize: 11)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(pathLabel)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            nameLabel.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12),
            nameLabel.topAnchor.constraint(equalTo: cell.topAnchor, constant: 6),

            pathLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            pathLabel.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12),
            pathLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
        ])

        return cell
    }
}

// Overlay view for presenting Quick Open
struct QuickOpenOverlay: View {
    @Binding var isPresented: Bool
    @EnvironmentObject var documentManager: DocumentManager

    var body: some View {
        ZStack {
            if isPresented {
                // Dimmed background
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .onTapGesture {
                        isPresented = false
                    }

                // Quick Open panel
                VStack {
                    QuickOpenView(isPresented: $isPresented)
                        .environmentObject(documentManager)
                        .frame(width: 500, height: 350)
                        .background(Color(NSColor.windowBackgroundColor))
                        .cornerRadius(12)
                        .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
                    Spacer()
                }
                .padding(.top, 80)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: isPresented)
    }
}
