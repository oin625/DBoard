import Foundation

/// Completion belongs to the user; an AI test milestone never stands in for formal acceptance.
enum DemandCompletionGate {
    static func localIssue(_ item: DItem) -> String? {
        if let error = item.incidentReadError { return error }
        if let error = item.releaseChecklistReadError { return error }
        let pending = item.releaseChecklist.items.filter { !$0.done }
        guard pending.isEmpty else {
            return "还有 \(pending.count) 项上线前事项未完成：\(pending.prefix(3).map(\.text).joined(separator: "、"))。请完成并勾选后再归档。"
        }
        return nil
    }

    static func needsEmptyChecklistConfirmation(_ item: DItem) -> Bool {
        !item.isIncident && item.releaseChecklistReadError == nil && item.releaseChecklist.items.isEmpty
    }

    static func validateAcceptance(_ response: [String: Any], link: ReqFlowLink) throws {
        guard response["success"] as? Bool == true,
              let detail = response["data"] as? [String: Any],
              detail["id"] as? Int == link.id, detail["reqNo"] as? String == link.no,
              let status = detail["currentStatus"] as? String else {
            throw DemandDeliveryError.message("正式需求的验收状态无法核实，请刷新登录或重新关联后重试。")
        }
        guard ["CPYSWC", "XQWC"].contains(status) else {
            throw DemandDeliveryError.message("\(link.no) 的正式需求尚未验收完成，请在需求流完成验收后再归档。")
        }
    }

    static func verifyAcceptance(_ link: ReqFlowLink) throws {
        try validateAcceptance(DemandDeliveryRemote.request("detail/\(link.id)"), link: link)
    }
}
