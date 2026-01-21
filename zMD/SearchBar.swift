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

    @FocusState private var isSearchFieldFocused: Bool

    var body: some View {
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
            .help("Previous match (⇧⌘G)")

            // Next match button
            Button(action: onNext) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .disabled(totalMatches == 0)
            .keyboardShortcut("g", modifiers: .command)
            .help("Next match (⌘G)")

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
