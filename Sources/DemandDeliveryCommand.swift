import Foundation
import Darwin

/// Explicit CLI uses the same durable workflow as the confirmation button, without opening a window.
enum DemandDeliveryCommand {
    static func run(_ arguments: [String]) -> Never {
        do {
            guard arguments.count >= 4, ["preview", "submit"].contains(arguments[1]) else {
                throw DemandDeliveryError.message("Use delivery preview or submit with the exact task and cache.")
            }
            let mode = arguments[1], id = arguments[2], cache = URL(fileURLWithPath: arguments[3])
            let plan = try DemandDeliveryPlan.load(id: id, at: cache)
            if mode == "preview" {
                emit(["success": true, "id": id, "title": plan.item.displayTitle, "delivery_revision": plan.key,
                    "document_title": plan.item.technicalPlan!.title, "markdown": plan.document(),
                    "projects": plan.projects.map { ["name": $0.name, "branch": $0.branch] }])
                exit(0)
            }
            guard arguments.count == 5, arguments[4] == plan.key else {
                throw DemandDeliveryError.message("方案或开发分支已变化，请重新 preview 再确认提交。")
            }
            let workflow = DemandDeliveryWorkflow()
            var receipt = try workflow.run(plan, stillCurrent: {
                try DemandDeliveryPlan.load(id: id, at: cache).key == plan.key
            })
            if !receipt.progressRecorded {
                let details = "技术方案：" + (receipt.documentURL ?? "") + "\n开发分支：" + plan.projects.map(\.declaration).joined(separator: "；")
                let latest = try DItemStore.currentItem(id: id, at: cache)
                receipt.progressRecorded = latest.milestones.contains { $0.content == DemandDeliveryPlan.feedbackSummary && $0.details == details }
                    || DItemStore.appendProgress(id: id, text: DemandDeliveryPlan.feedbackSummary, details: details, at: cache)
                try workflow.store.save(receipt)
            }
            emit(["success": receipt.confirmed && receipt.progressRecorded, "local_saved": receipt.progressRecorded,
                "id": id, "document_url": receipt.documentURL ?? "", "delivery_revision": plan.key,
                "projects": plan.projects.map { ["name": $0.name, "branch": $0.branch] }])
            exit(receipt.progressRecorded ? 0 : 3)
        } catch {
            emit(["success": false, "error": ["code": "DELIVERY_FAILED", "message": error.localizedDescription]])
            exit(2)
        }
    }
    private static func emit(_ value: [String: Any]) {
        if let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let text = String(data: bytes, encoding: .utf8) { print(text) }
    }
}
