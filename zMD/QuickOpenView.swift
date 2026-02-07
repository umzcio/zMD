import SwiftUI

struct QuickOpenView: NSViewRepresentable {
    @EnvironmentObject var documentManager: DocumentManager
    @EnvironmentObject var folderManager: FolderManager
    @Binding var isPresented: Bool
    @Binding var selectedHeadingId: String?

    func makeNSView(context: Context) -> QuickOpenNSView {
        let view = QuickOpenNSView()
        view.documentManager = documentManager
        view.folderManager = folderManager
        view.dismissHandler = { isPresented = false }
        view.openFileHandler = { url in
            documentManager.loadDocument(from: url)
            isPresented = false
        }
        view.headingSelectedHandler = { headingId in
            selectedHeadingId = headingId
            isPresented = false
        }
        return view
    }

    func updateNSView(_ nsView: QuickOpenNSView, context: Context) {
        nsView.documentManager = documentManager
        nsView.folderManager = folderManager
        nsView.reloadData()
    }
}

enum QuickOpenMode {
    case fileSearch
    case headingSearch
}

struct QuickOpenItem {
    let title: String
    let subtitle: String
    let icon: NSImage?
    let matchResult: FuzzyMatchResult?
    let url: URL?
    let headingId: String?
    let headingLevel: Int?
}

class QuickOpenNSView: NSView {
    weak var documentManager: DocumentManager?
    weak var folderManager: FolderManager?
    var dismissHandler: (() -> Void)?
    var openFileHandler: ((URL) -> Void)?
    var headingSelectedHandler: ((String) -> Void)?

    private var searchField: NSTextField!
    private var tableView: NSTableView!
    private var scrollView: NSScrollView!
    private var modeLabel: NSTextField!
    private var filteredItems: [QuickOpenItem] = []
    private var searchText = ""
    private var mode: QuickOpenMode = .fileSearch

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
        searchField.placeholderString = "Search files... (@ or # for headings)"
        searchField.isBordered = false
        searchField.backgroundColor = .clear
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 16)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchFieldAction)
        searchContainer.addSubview(searchField)

        modeLabel = NSTextField(labelWithString: "")
        modeLabel.font = .systemFont(ofSize: 10, weight: .medium)
        modeLabel.textColor = .secondaryLabelColor
        modeLabel.translatesAutoresizingMaskIntoConstraints = false
        modeLabel.isHidden = true
        searchContainer.addSubview(modeLabel)

        container.addArrangedSubview(searchContainer)

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

        let hint3 = NSTextField(labelWithString: "@ or # Headings")
        hint3.textColor = .secondaryLabelColor
        hint3.font = .systemFont(ofSize: 11)

        let hint4 = NSTextField(labelWithString: "esc Close")
        hint4.textColor = .secondaryLabelColor
        hint4.font = .systemFont(ofSize: 11)

        footer.addArrangedSubview(hint1)
        footer.addArrangedSubview(hint2)
        footer.addArrangedSubview(hint3)
        footer.addArrangedSubview(hint4)
        container.addArrangedSubview(footer)

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
            searchField.trailingAnchor.constraint(equalTo: modeLabel.leadingAnchor, constant: -8),
            searchField.centerYAnchor.constraint(equalTo: searchContainer.centerYAnchor),

            modeLabel.trailingAnchor.constraint(equalTo: searchContainer.trailingAnchor, constant: -12),
            modeLabel.centerYAnchor.constraint(equalTo: searchContainer.centerYAnchor),

            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),

            footer.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    func reloadData() {
        updateFilteredResults()
        tableView.reloadData()
        if !filteredItems.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    private func updateFilteredResults() {
        guard let documentManager = documentManager else {
            filteredItems = []
            return
        }

        // Determine mode from search text prefix
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("@") || trimmed.hasPrefix("#") {
            mode = .headingSearch
            modeLabel.stringValue = "HEADINGS"
            modeLabel.isHidden = false
            updateHeadingResults(query: String(trimmed.dropFirst()))
        } else {
            mode = .fileSearch
            modeLabel.isHidden = true
            updateFileResults(query: trimmed)
        }
    }

    private func updateFileResults(query: String) {
        guard let documentManager = documentManager else {
            filteredItems = []
            return
        }

        // Merge recent files with folder files (deduped)
        var seenPaths = Set<String>()
        var urls: [URL] = []
        for url in documentManager.recentFileURLs {
            if seenPaths.insert(url.path).inserted {
                urls.append(url)
            }
        }
        if let folderFiles = folderManager?.allMarkdownFiles {
            for url in folderFiles {
                if seenPaths.insert(url.path).inserted {
                    urls.append(url)
                }
            }
        }

        if query.isEmpty {
            filteredItems = urls.map { url in
                QuickOpenItem(
                    title: url.lastPathComponent,
                    subtitle: url.deletingLastPathComponent().path,
                    icon: NSWorkspace.shared.icon(forFile: url.path),
                    matchResult: nil,
                    url: url,
                    headingId: nil,
                    headingLevel: nil
                )
            }
        } else {
            filteredItems = urls.compactMap { url -> (QuickOpenItem, Int)? in
                guard let result = fuzzyMatch(query: query, target: url.lastPathComponent) else { return nil }
                let item = QuickOpenItem(
                    title: url.lastPathComponent,
                    subtitle: url.deletingLastPathComponent().path,
                    icon: NSWorkspace.shared.icon(forFile: url.path),
                    matchResult: result,
                    url: url,
                    headingId: nil,
                    headingLevel: nil
                )
                return (item, result.score)
            }
            .sorted { $0.1 > $1.1 }
            .map { $0.0 }
        }
    }

    private func updateHeadingResults(query: String) {
        guard let documentManager = documentManager,
              let selectedId = documentManager.selectedDocumentId,
              let document = documentManager.openDocuments.first(where: { $0.id == selectedId }) else {
            filteredItems = []
            return
        }

        let headings = OutlineItem.extractHeadings(from: document.content)

        if query.isEmpty {
            filteredItems = headings.map { heading in
                QuickOpenItem(
                    title: heading.text,
                    subtitle: "",
                    icon: nil,
                    matchResult: nil,
                    url: nil,
                    headingId: heading.id,
                    headingLevel: heading.level
                )
            }
        } else {
            filteredItems = headings.compactMap { heading -> (QuickOpenItem, Int)? in
                guard let result = fuzzyMatch(query: query, target: heading.text) else { return nil }
                let item = QuickOpenItem(
                    title: heading.text,
                    subtitle: "",
                    icon: nil,
                    matchResult: result,
                    url: nil,
                    headingId: heading.id,
                    headingLevel: heading.level
                )
                return (item, result.score)
            }
            .sorted { $0.1 > $1.1 }
            .map { $0.0 }
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
            let newRow = min(tableView.selectedRow + 1, filteredItems.count - 1)
            if newRow >= 0 {
                tableView.selectRowIndexes(IndexSet(integer: newRow), byExtendingSelection: false)
                tableView.scrollRowToVisible(newRow)
            }
        case 126: // Up arrow
            let newRow = max(tableView.selectedRow - 1, 0)
            if newRow >= 0 && !filteredItems.isEmpty {
                tableView.selectRowIndexes(IndexSet(integer: newRow), byExtendingSelection: false)
                tableView.scrollRowToVisible(newRow)
            }
        case 53: // Escape
            dismissHandler?()
        case 36: // Return/Enter
            openSelectedItem()
        default:
            super.keyDown(with: event)
        }
    }

    @objc private func searchFieldAction() {
        openSelectedItem()
    }

    @objc private func tableDoubleClick() {
        openSelectedItem()
    }

    private func openSelectedItem() {
        let row = tableView.selectedRow
        guard row >= 0 && row < filteredItems.count else { return }
        let item = filteredItems[row]

        if let headingId = item.headingId {
            headingSelectedHandler?(headingId)
        } else if let url = item.url {
            openFileHandler?(url)
        }
    }

    // MARK: - Highlighted String Helper

    private func highlightedString(_ text: String, matchResult: FuzzyMatchResult?, baseFont: NSFont, baseColor: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: baseFont,
            .foregroundColor: baseColor
        ])

        guard let match = matchResult else { return result }

        let boldFont = NSFont.systemFont(ofSize: baseFont.pointSize, weight: .bold)
        for index in match.matchedIndices {
            guard index < text.count else { continue }
            let range = NSRange(location: index, length: 1)
            result.addAttributes([
                .font: boldFont,
                .foregroundColor: NSColor.controlAccentColor
            ], range: range)
        }

        return result
    }
}

extension QuickOpenNSView: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        searchText = searchField.stringValue
        updateFilteredResults()
        tableView.reloadData()
        if !filteredItems.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(moveDown(_:)) {
            let newRow = min(tableView.selectedRow + 1, filteredItems.count - 1)
            if newRow >= 0 {
                tableView.selectRowIndexes(IndexSet(integer: newRow), byExtendingSelection: false)
                tableView.scrollRowToVisible(newRow)
            }
            return true
        } else if commandSelector == #selector(moveUp(_:)) {
            let newRow = max(tableView.selectedRow - 1, 0)
            if newRow >= 0 && !filteredItems.isEmpty {
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
        return filteredItems.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < filteredItems.count else { return nil }
        let item = filteredItems[row]

        let cell = NSTableCellView()

        if let headingLevel = item.headingLevel {
            // Heading cell: level badge + highlighted text
            let badge = NSTextField(labelWithString: "H\(headingLevel)")
            badge.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
            badge.textColor = .secondaryLabelColor
            badge.alignment = .center
            badge.wantsLayer = true
            badge.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.2).cgColor
            badge.layer?.cornerRadius = 3
            badge.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(badge)

            let nameLabel = NSTextField(labelWithAttributedString:
                highlightedString(item.title, matchResult: item.matchResult, baseFont: .systemFont(ofSize: 14, weight: .medium), baseColor: .labelColor))
            nameLabel.lineBreakMode = .byTruncatingTail
            nameLabel.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(nameLabel)

            NSLayoutConstraint.activate([
                badge.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
                badge.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                badge.widthAnchor.constraint(equalToConstant: 28),
                badge.heightAnchor.constraint(equalToConstant: 20),

                nameLabel.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 10),
                nameLabel.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12),
                nameLabel.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        } else {
            // File cell: icon + highlighted name + path
            let iconView: NSImageView
            if let icon = item.icon {
                iconView = NSImageView(image: icon)
            } else {
                iconView = NSImageView(image: NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)!)
            }
            iconView.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(iconView)

            let nameLabel = NSTextField(labelWithAttributedString:
                highlightedString(item.title, matchResult: item.matchResult, baseFont: .systemFont(ofSize: 14, weight: .medium), baseColor: .labelColor))
            nameLabel.lineBreakMode = .byTruncatingTail
            nameLabel.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(nameLabel)

            let pathLabel = NSTextField(labelWithString: item.subtitle)
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
        }

        return cell
    }
}

// Overlay view for presenting Quick Open
struct QuickOpenOverlay: View {
    @Binding var isPresented: Bool
    @Binding var selectedHeadingId: String?
    @EnvironmentObject var documentManager: DocumentManager
    @EnvironmentObject var folderManager: FolderManager

    var body: some View {
        ZStack {
            if isPresented {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .onTapGesture {
                        isPresented = false
                    }

                VStack {
                    QuickOpenView(isPresented: $isPresented, selectedHeadingId: $selectedHeadingId)
                        .environmentObject(documentManager)
                        .environmentObject(folderManager)
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
