import Foundation

enum IdeaQueuePlan {
    static let defaultTarget = 20
    static let targets = [10, defaultTarget, 30, 40, 50]
    private static let mix = ["trend", "work", "data", "trend", "work"]

    static func target(_ preference: Any?) -> Int {
        guard let value = preference as? Int, targets.contains(value) else { return defaultTarget }
        return value
    }

    struct Slot {
        let id: Int
        let kind: String
        var long = false

        var fields: [String: Any] { ["slot": id, "kind": kind, "long": long] }
    }

    static func slots(open: [WorkspaceRecord], target: Int) -> [Slot] {
        let count = max(0, target - open.count)
        let order = (0..<target).map { mix[$0 % mix.count] }
        let wanted = Dictionary(grouping: order, by: { $0 }).mapValues(\.count)
        var current = Dictionary(grouping: open) { idea in
            ["trend", "data"].contains(idea["kind"]) ? idea["kind"] : "work"
        }.mapValues(\.count)
        var slots = (0..<count).map { index in
            let kind = if open.isEmpty {
                order[index]
            } else {
                ["trend", "work", "data"].max { left, right in
                    wanted[left, default: 0] - current[left, default: 0] < wanted[right, default: 0] - current[right, default: 0]
                } ?? "work"
            }
            current[kind, default: 0] += 1
            return Slot(id: index + 1, kind: kind)
        }
        let existingLong = open.filter { $0.fields["long"] as? Bool == true }.count
        let longNeeded = max(0, (target >= 20 ? 2 : 1) - existingLong)
        for index in slots.indices.filter({ slots[$0].kind != "data" }).shuffled().prefix(longNeeded) {
            slots[index].long = true
        }
        return slots
    }
}
