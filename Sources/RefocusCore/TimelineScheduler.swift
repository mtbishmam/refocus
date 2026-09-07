import Foundation

public enum TimelineScheduler {
    /// Expands one task and moves only the contiguous chain that now overlaps
    /// it. A genuine free gap absorbs the added duration without disturbing
    /// unrelated later work.
    public static func tasksAfterExpanding(
        _ tasks: [PlanTask],
        taskID: UUID,
        previousCycles: Int,
        protectedRanges: [Range<Int>]
    ) -> [PlanTask]? {
        guard let anchor = tasks.first(where: { $0.id == taskID }), anchor.hasScheduledTime else {
            return tasks
        }
        let previousEnd = anchor.startMinute + previousCycles * 30
        guard anchor.endMinute > previousEnd else { return tasks }

        func isAnchor(_ task: PlanTask) -> Bool {
            let title = task.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return task.fixedRole != nil || task.isRoutineBlock || title == "rest" || title == "break"
        }

        var result = tasks
        let fixedRanges = protectedRanges + tasks.compactMap { task -> Range<Int>? in
            guard task.id != taskID, task.hasScheduledTime, isAnchor(task) else { return nil }
            return task.startMinute..<task.endMinute
        }
        let movableIDs = tasks.filter {
            $0.id != taskID && $0.hasScheduledTime && $0.startMinute >= previousEnd && !isAnchor($0)
        }
        .sorted {
            if $0.startMinute != $1.startMinute { return $0.startMinute < $1.startMinute }
            return $0.id.uuidString < $1.id.uuidString
        }
        .map(\.id)

        var occupiedByMovedChainUntil = anchor.endMinute
        for id in movableIDs {
            guard let index = result.firstIndex(where: { $0.id == id }) else { continue }
            let task = result[index]
            guard task.startMinute < occupiedByMovedChainUntil else {
                // The added duration has reached a real empty gap. Later work
                // is unrelated and should stay exactly where it is.
                break
            }

            let duration = task.endMinute - task.startMinute
            var candidate = occupiedByMovedChainUntil
            while let collision = fixedRanges
                .filter({ candidate < $0.upperBound && candidate + duration > $0.lowerBound })
                .min(by: { $0.lowerBound < $1.lowerBound }) {
                candidate = collision.upperBound
            }
            guard candidate + duration <= 1_440 else { return nil }
            result[index].startMinute = candidate
            occupiedByMovedChainUntil = candidate + duration
        }
        return result
    }
}
