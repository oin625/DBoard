import Foundation

/// A start day schedules a one-way transition from pending to in progress.
/// Completion and suspension remain explicit user actions.
enum DemandCycle {
    static func hasStarted(start: String?, deadline: String?, on now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let startDate = DemandDates.period(start: start, deadline: deadline, on: now, calendar: calendar)?.start else { return false }
        return startDate <= calendar.startOfDay(for: now)
    }

    static func status(_ status: ItemStatus, start: String?, deadline: String?,
                       on now: Date = Date(), calendar: Calendar = .current) -> ItemStatus {
        status == .pending && hasStarted(start: start, deadline: deadline, on: now, calendar: calendar)
            ? .inProgress : status
    }

    struct Update {
        let content: String
        let startedIDs: [String]
    }

    static func reconcile(_ content: String, on now: Date = Date(), calendar: Calendar = .current) -> Update {
        let ready = CacheParser.parse(content: content).items.filter {
            $0.status == .pending && hasStarted(start: $0.startDate, deadline: $0.deadline, on: now, calendar: calendar)
        }
        var lines = content.components(separatedBy: "\n")
        var started: [String] = []
        for item in ready {
            guard let block = DItemStore.blockRange(lines, id: item.id),
                  let marker = lines[block.lowerBound].range(of: ItemStatus.pending.rawValue, options: .backwards) else { continue }
            lines[block.lowerBound].replaceSubrange(marker, with: ItemStatus.inProgress.rawValue)
            started.append(item.id)
        }
        return Update(content: lines.joined(separator: "\n"), startedIDs: started)
    }
}

extension DItemDraft {
    var scheduledStatus: ItemStatus { DemandCycle.status(status, start: start, deadline: deadline) }
}
