import AppKit

struct CursorState {
    var range: NSRange
}

class MultiCursorController {
    var additionalCursors: [CursorState] = []

    func addCursor(at range: NSRange) {
        // Don't add duplicate cursors at same location
        guard !additionalCursors.contains(where: { $0.range.location == range.location && $0.range.length == range.length }) else { return }
        additionalCursors.append(CursorState(range: range))
    }

    func clearAll() {
        additionalCursors.removeAll()
    }

    /// Rebuild cursor locations from explicit post-edit ranges produced by the caller.
    /// Pass the list of (original range, new location) pairs in any order. This replaces the
    /// previous math-based `adjustAfterInsert` / `adjustAfterDelete`, which assumed cursors were
    /// sorted and applied a single uniform delta — wrong whenever edits had differing lengths or
    /// the primary selection was interleaved with the additional cursors.
    func updatePositions(_ mapping: [(original: NSRange, newLocation: Int)]) {
        additionalCursors = additionalCursors.compactMap { cursor in
            guard let entry = mapping.first(where: { $0.original.location == cursor.range.location && $0.original.length == cursor.range.length }) else {
                return cursor
            }
            return CursorState(range: NSRange(location: max(0, entry.newLocation), length: 0))
        }
    }
}
