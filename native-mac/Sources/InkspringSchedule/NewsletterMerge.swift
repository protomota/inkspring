import Foundation

public enum NewsletterMerge {
    /// Merge changes on separate lines and preserve overlapping changes for manual resolution.
    public static func merge(base: String, mac: String, mobile: String) -> String? {
        if mac == base || mac == mobile { return mobile }
        if mobile == base { return mac }

        let original = base.components(separatedBy: "\n")
        let macLines = mac.components(separatedBy: "\n")
        let mobileLines = mobile.components(separatedBy: "\n")
        guard max(original.count, macLines.count, mobileLines.count) <= 4_000 else { return nil }
        let macEdits = edits(to: macLines, from: original)
        let mobileEdits = edits(to: mobileLines, from: original)
        var edits = macEdits
        var macIndex = 0
        for mobileEdit in mobileEdits {
            while macIndex < macEdits.count, macEdits[macIndex].range.upperBound < mobileEdit.range.lowerBound {
                macIndex += 1
            }
            var duplicate = false
            for macEdit in macEdits[macIndex...] {
                if macEdit.range.lowerBound > mobileEdit.range.upperBound { break }
                if mobileEdit == macEdit {
                    duplicate = true
                } else if mobileEdit.overlaps(macEdit) {
                    return nil
                }
            }
            if !duplicate { edits.append(mobileEdit) }
        }
        var result: [String] = []
        var cursor = 0
        for edit in edits.sorted(by: {
            ($0.range.lowerBound, $0.range.upperBound) < ($1.range.lowerBound, $1.range.upperBound)
        }) {
            result.append(contentsOf: original[cursor..<edit.range.lowerBound])
            result.append(contentsOf: edit.replacement)
            cursor = edit.range.upperBound
        }
        result.append(contentsOf: original[cursor...])
        return result.joined(separator: "\n")
    }

    private struct Edit: Equatable {
        var range: Range<Int>
        var replacement: [String]

        func overlaps(_ other: Self) -> Bool {
            if range.isEmpty && other.range.isEmpty { return range.lowerBound == other.range.lowerBound }
            if range.isEmpty { return other.range.lowerBound < range.lowerBound && range.lowerBound < other.range.upperBound }
            if other.range.isEmpty { return other.overlaps(self) }
            return range.overlaps(other.range)
        }
    }

    private static func edits(to changed: [String], from original: [String]) -> [Edit] {
        let difference = changed.difference(from: original)
        let removals = Set(difference.removals.compactMap { change -> Int? in
            guard case let .remove(offset, _, _) = change else { return nil }
            return offset
        })
        let insertions = Set(difference.insertions.compactMap { change -> Int? in
            guard case let .insert(offset, _, _) = change else { return nil }
            return offset
        })
        var result: [Edit] = []
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < original.count || newIndex < changed.count {
            let start = oldIndex
            let newStart = newIndex
            while removals.contains(oldIndex) { oldIndex += 1 }
            while insertions.contains(newIndex) { newIndex += 1 }
            if oldIndex != start || newIndex != newStart {
                result.append(Edit(range: start..<oldIndex, replacement: Array(changed[newStart..<newIndex])))
            }
            if oldIndex == original.count && newIndex == changed.count { break }
            oldIndex += 1
            newIndex += 1
        }
        return result
    }
}
