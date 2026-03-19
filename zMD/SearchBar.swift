import SwiftUI

struct SearchBar: View {
    @Binding var searchText: String
    @Binding var isSearching: Bool
    let currentMatch: Int
    let totalMatches: Int
    let onSearch: () -> Void
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onClose: () -> Void

    // Replace support
    var showReplace: Bool = false
    @Binding var replaceText: String
    var isRegex: Bool = false
    var isCaseSensitive: Bool = false
    var onToggleRegex: (() -> Void)? = nil
    var onToggleCaseSensitive: (() -> Void)? = nil
    var onReplace: (() -> Void)? = nil
    var onReplaceAll: (() -> Void)? = nil

    @FocusState private var isSearchFieldFocused: Bool

    init(searchText: Binding<String>,
         isSearching: Binding<Bool>,
         currentMatch: Int,
         totalMatches: Int,
         onSearch: @escaping () -> Void,
         onNext: @escaping () -> Void,
         onPrevious: @escaping () -> Void,
         onClose: @escaping () -> Void) {
        self._searchText = searchText
        self._isSearching = isSearching
        self.currentMatch = currentMatch
        self.totalMatches = totalMatches
        self.onSearch = onSearch
        self.onNext = onNext
        self.onPrevious = onPrevious
        self.onClose = onClose
        self.showReplace = false
        self._replaceText = .constant("")
    }

    init(searchText: Binding<String>,
         isSearching: Binding<Bool>,
         currentMatch: Int,
         totalMatches: Int,
         onSearch: @escaping () -> Void,
         onNext: @escaping () -> Void,
         onPrevious: @escaping () -> Void,
         onClose: @escaping () -> Void,
         showReplace: Bool,
         replaceText: Binding<String>,
         isRegex: Bool,
         isCaseSensitive: Bool,
         onToggleRegex: @escaping () -> Void,
         onToggleCaseSensitive: @escaping () -> Void,
         onReplace: @escaping () -> Void,
         onReplaceAll: @escaping () -> Void) {
        self._searchText = searchText
        self._isSearching = isSearching
        self.currentMatch = currentMatch
        self.totalMatches = totalMatches
        self.onSearch = onSearch
        self.onNext = onNext
        self.onPrevious = onPrevious
        self.onClose = onClose
        self.showReplace = showReplace
        self._replaceText = replaceText
        self.isRegex = isRegex
        self.isCaseSensitive = isCaseSensitive
        self.onToggleRegex = onToggleRegex
        self.onToggleCaseSensitive = onToggleCaseSensitive
        self.onReplace = onReplace
        self.onReplaceAll = onReplaceAll
    }

    var body: some View {
        VStack(spacing: 6) {
            // Search row
            HStack(spacing: 8) {
                // Search icon
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)

                // Search text field
                TextField("Find", text: $searchText)
                    .textFieldStyle(.plain)
                    .focused($isSearchFieldFocused)
                    .frame(minWidth: 150)
                    .onSubmit {
                        onNext()
                    }

                // Match counter
                if !searchText.isEmpty {
                    Text(totalMatches > 0 ? "\(currentMatch)/\(totalMatches)" : "0/0")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .frame(minWidth: 40, alignment: .trailing)
                }

                if showReplace {
                    // Toggle buttons for regex and case sensitivity
                    Button(action: { onToggleCaseSensitive?() }) {
                        Text("Aa")
                            .font(.system(size: 11, weight: isCaseSensitive ? .bold : .regular))
                            .foregroundColor(isCaseSensitive ? .accentColor : .secondary)
                            .frame(width: 24, height: 20)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(isCaseSensitive ? Color.accentColor.opacity(0.15) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Match Case")

                    Button(action: { onToggleRegex?() }) {
                        Text(".*")
                            .font(.system(size: 11, weight: isRegex ? .bold : .regular, design: .monospaced))
                            .foregroundColor(isRegex ? .accentColor : .secondary)
                            .frame(width: 24, height: 20)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(isRegex ? Color.accentColor.opacity(0.15) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Use Regular Expression")
                }

                Divider()
                    .frame(height: 16)

                // Previous match button
                Button(action: onPrevious) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .disabled(totalMatches == 0)
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .help("Previous match (\u{21E7}\u{2318}G)")

                // Next match button
                Button(action: onNext) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .disabled(totalMatches == 0)
                .keyboardShortcut("g", modifiers: .command)
                .help("Next match (\u{2318}G)")

                Divider()
                    .frame(height: 16)

                // Close button
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
                .help("Close (Esc)")
            }

            // Replace row (only in source/split mode)
            if showReplace {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.swap")
                        .foregroundColor(.secondary)

                    TextField("Replace", text: $replaceText)
                        .textFieldStyle(.plain)
                        .frame(minWidth: 150)

                    Spacer()

                    Button(action: { onReplace?() }) {
                        Text("Replace")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .disabled(totalMatches == 0)
                    .help("Replace current match")

                    Button(action: { onReplaceAll?() }) {
                        Text("All")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .disabled(totalMatches == 0)
                    .help("Replace all matches")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
        .onAppear {
            isSearchFieldFocused = true
        }
        .onChange(of: isSearching) { newValue in
            if newValue {
                isSearchFieldFocused = true
            }
        }
    }
}
