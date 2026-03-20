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

    func adjustAfterInsert(insertedLength: Int, deletedLength: Int) {
        let delta = insertedLength - deletedLength
        // Each cursor shifts by cumulative delta
        // Since we insert in reverse order, cursors at earlier positions need adjustment
        for i in 0..<additionalCursors.count {
            additionalCursors[i].range = NSRange(
                location: additionalCursors[i].range.location + delta * (additionalCursors.count - i),
                length: 0
            )
        }
    }

    func adjustAfterDelete() {
        // After deletion, adjust each cursor position down by 1 per cursor before it
        for i in 0..<additionalCursors.count {
            let newLoc = max(0, additionalCursors[i].range.location - (additionalCursors.count - i))
            additionalCursors[i].range = NSRange(location: newLoc, length: 0)
        }
    }
}
