import SwiftUI

struct QuickOpenView: NSViewRepresentable {
    @EnvironmentObject var documentManager: DocumentManager
    @EnvironmentObject var folderManager: FolderManager
    @Binding var isPresented: Bool
    @Binding var selectedHeadingId: String?
    /// Text the field opens with — ">" for "Search in Folder…", empty for plain Quick Open.
    var initialQuery: String = ""

    func makeNSView(context: Context) -> QuickOpenNSView {
        let view = QuickOpenNSView()
        view.initialQuery = initialQuery
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
        view.searchHitHandler = { hit, query in
            documentManager.loadDocument(from: hit.url)
            isPresented = false
            // Next turn: let the newly selected document settle before the find bar searches it.
            DispatchQueue.main.async {
                documentManager.revealSearchHit(hit, query: query)
            }
        }
        return view
    }

    func updateNSView(_ nsView: QuickOpenNSView, context: Context) {
        nsView.documentManager = documentManager
        nsView.folderManager = folderManager
        // Don't reset the user's arrow-key selection: updateNSView fires for ANY @Published
        // change on the managers while the palette is open (file-watcher reload, folder tree
        // refresh), not just ones that affect this list.
        nsView.reloadData(resetSelection: false)
    }
}

struct QuickOpenItem {
    let title: String
    let subtitle: String
    let icon: NSImage?
    let matchResult: FuzzyMatchResult?
    let url: URL?
    let headingId: String?
    let headingLevel: Int?
    var searchHit: FolderSearchHit? = nil
}

class QuickOpenNSView: NSView {
    weak var documentManager: DocumentManager?
    weak var folderManager: FolderManager?
    var dismissHandler: (() -> Void)?
    var openFileHandler: ((URL) -> Void)?
    var headingSelectedHandler: ((String) -> Void)?
    var searchHitHandler: ((FolderSearchHit, String) -> Void)?
    var initialQuery = ""

    // Folder content search (">" mode). File I/O runs off the main actor; a generation token
    // drops results from superseded keystrokes, and the task is cancelled so a stale search
    // stops reading files instead of finishing a walk nobody wants.
    private var contentSearchGeneration = 0
    private var contentSearchTask: Task<Void, Never>?
    // nonisolated(unsafe): main-actor only in practice; annotated solely so nonisolated deinit
    // can invalidate it (deinit has exclusive access).
    nonisolated(unsafe) private var contentSearchDebounce: Timer?
    private var contentSearchResults: [QuickOpenItem] = []
    private var contentSearchResultsQuery = ""
    /// The query currently debouncing or in flight. `updateContentSearchResults` runs on EVERY
    /// reload — including each manager publish (FS events, file-watcher reloads, scroll-position
    /// persists) — so without this it restarted the debounce and cancelled the running search
    /// on every publish: on a big folder, results could be postponed indefinitely.
    private var pendingContentQuery: String?

    private var searchField: NSTextField!
    private var tableView: NSTableView!
    private var scrollView: NSScrollView!
    private var modeLabel: NSTextField!
    private var filteredItems: [QuickOpenItem] = []
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

        let container = NSStackView()
        container.orientation = .vertical
        container.spacing = 0
        container.translatesAutoresizingMaskIntoConstraints = false
        addSubview(container)

        // Search field container
        let searchContainer = NSView()
        searchContainer.translatesAutoresizingMaskIntoConstraints = false

        let searchIcon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Search") ?? NSImage())
        searchIcon.translatesAutoresizingMaskIntoConstraints = false
        searchIcon.contentTintColor = .secondaryLabelColor
        searchContainer.addSubview(searchIcon)

        searchField = NSTextField()
        searchField.placeholderString = "Search files... (@ headings, > text in files)"
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

        let hint3 = NSTextField(labelWithString: "@ Headings   > In Files")
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

    func reloadData(resetSelection: Bool = true) {
        let previousRow = tableView.selectedRow
        updateFilteredResults()
        tableView.reloadData()
        if !filteredItems.isEmpty {
            let row = resetSelection || previousRow < 0
                ? 0
                : min(previousRow, filteredItems.count - 1)
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    private func updateFilteredResults() {
        // `documentManager` is read in the branches below (updateHeadingResults/updateFileResults),
        // so a nil guard here just early-returns without doing anything else.
        guard documentManager != nil else {
            filteredItems = []
            return
        }

        // Determine mode from search text prefix
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix(">") {
            modeLabel.stringValue = "IN FILES"
            modeLabel.isHidden = false
            updateContentSearchResults(query: String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
        } else if trimmed.hasPrefix("@") || trimmed.hasPrefix("#") {
            modeLabel.stringValue = "HEADINGS"
            modeLabel.isHidden = false
            updateHeadingResults(query: String(trimmed.dropFirst()))
        } else {
            modeLabel.isHidden = true
            updateFileResults(query: trimmed)
        }
    }

    /// Every file Quick Open knows about: recent files, then the open folder's files (deduped).
    private func candidateFileURLs() -> [URL] {
        var seenPaths = Set<String>()
        var urls: [URL] = []
        for url in documentManager?.recentFileURLs ?? [] {
            if seenPaths.insert(url.path).inserted {
                urls.append(url)
            }
        }
        for url in folderManager?.allMarkdownFiles ?? [] {
            if seenPaths.insert(url.path).inserted {
                urls.append(url)
            }
        }
        return urls
    }

    /// ">" mode. Synchronous part only decides what to SHOW right now; the search itself is
    /// debounced and asynchronous, and re-enters via `reloadData` when results land.
    private func updateContentSearchResults(query: String) {
        guard query.count >= FolderSearch.minimumQueryLength else {
            cancelPendingContentSearch()
            contentSearchResults = []
            contentSearchResultsQuery = ""
            filteredItems = []
            return
        }
        // Results already in hand for this exact query (the post-search reload, or an unrelated
        // manager publish) — show them. Also drop any search still pending for a DIFFERENT
        // query: type "foob" then backspace to "foo" inside the debounce, and the "foob"
        // results would otherwise land under a field that reads "foo".
        if query == contentSearchResultsQuery {
            if pendingContentQuery != nil { cancelPendingContentSearch() }
            filteredItems = contentSearchResults
            return
        }
        // Keep the previous results on screen while the new search runs: blanking the list on
        // every keystroke makes it strobe.
        filteredItems = contentSearchResults
        // Already scheduled or running for this query — leave it alone (see pendingContentQuery).
        if query == pendingContentQuery { return }
        pendingContentQuery = query

        contentSearchDebounce?.invalidate()
        contentSearchDebounce = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.startContentSearch(query: query)
            }
        }
    }

    private func cancelPendingContentSearch() {
        contentSearchDebounce?.invalidate()
        contentSearchTask?.cancel()
        contentSearchGeneration += 1
        pendingContentQuery = nil
    }

    private func startContentSearch(query: String) {
        contentSearchTask?.cancel()
        contentSearchGeneration += 1
        let generation = contentSearchGeneration
        let urls = candidateFileURLs()

        contentSearchTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                FolderSearch.search(query: query, in: urls, isCancelled: { Task.isCancelled })
            }
            let hits = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard let self, !Task.isCancelled, generation == self.contentSearchGeneration else { return }
            self.contentSearchResults = hits.map { hit in
                QuickOpenItem(
                    title: hit.snippet,
                    subtitle: "\(hit.url.lastPathComponent):\(hit.lineNumber)  —  \(hit.url.deletingLastPathComponent().path)",
                    icon: nil,
                    matchResult: FuzzyMatchResult(score: 0, matchedIndices: Array(hit.matchStart..<(hit.matchStart + hit.matchLength))),
                    url: hit.url,
                    headingId: nil,
                    headingLevel: nil,
                    searchHit: hit
                )
            }
            self.contentSearchResultsQuery = query
            self.pendingContentQuery = nil
            self.reloadData()
        }
    }

    private func updateFileResults(query: String) {
        guard documentManager != nil else {
            filteredItems = []
            return
        }

        let urls = candidateFileURLs()

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

        // Share the MarkdownParser outline so Quick Switcher heading IDs match the preview's
        // click targets (stable slugs instead of line-index ids that drift on edits).
        let headings = MarkdownParser.shared.extractHeadings(document.content).map {
            OutlineItem(id: $0.id, level: $0.level, text: $0.text)
        }

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
            if !initialQuery.isEmpty, searchField.stringValue.isEmpty {
                searchField.stringValue = initialQuery
                searchText = initialQuery
            }
            reloadData()
            window?.makeFirstResponder(searchField)
            // Becoming first responder selects the field's whole text; with a prefilled ">"
            // the user's first keystroke would replace the prefix. Park the caret at the end.
            if let editor = searchField.currentEditor() {
                editor.selectedRange = NSRange(location: (searchField.stringValue as NSString).length, length: 0)
            }
        } else {
            // Overlay dismissed mid-search: stop reading files nobody is waiting for.
            contentSearchDebounce?.invalidate()
            contentSearchTask?.cancel()
        }
    }

    deinit {
        contentSearchDebounce?.invalidate()
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

        if let hit = item.searchHit {
            searchHitHandler?(hit, contentSearchResultsQuery)
        } else if let headingId = item.headingId {
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
            let charStart = text.index(text.startIndex, offsetBy: index)
            let charEnd = text.index(after: charStart)
            let range = NSRange(charStart..<charEnd, in: text)
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
                iconView = NSImageView(image: NSImage(systemSymbolName: "doc.text", accessibilityDescription: "Document") ?? NSImage())
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
    var initialQuery: String = ""
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
                    .accessibilityLabel("Dismiss")
                    .accessibilityAddTraits(.isButton)

                VStack {
                    QuickOpenView(isPresented: $isPresented, selectedHeadingId: $selectedHeadingId, initialQuery: initialQuery)
                        .environmentObject(documentManager)
                        .environmentObject(folderManager)
                        .frame(width: 500, height: 350)
                        .background(Color(NSColor.windowBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
                    Spacer()
                }
                .padding(.top, 80)
            }
        }
    }
}
