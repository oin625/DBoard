import Foundation
import SwiftUI

struct PRDStartDevelopmentDraft {
    let reqID: Int
    let requiresLaunchTime: Bool
    var launchTime: String
    let acceptorID: String
    let acceptorName: String

    enum ReadError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            if case .message(let text) = self { return text }
            return nil
        }
    }

    static func decode(_ data: Data, reqID: Int) throws -> Self {
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ReadError.message("需求详情格式异常，请重试")
        }
        guard response["success"] as? Bool == true else {
            throw ReadError.message(response["message"] as? String ?? "读取需求详情失败")
        }
        guard let detail = response["data"] as? [String: Any],
              detail["id"] as? Int == reqID,
              let type = detail["reqType"] as? String else {
            throw ReadError.message("需求详情不完整，请在网页确认后重试")
        }
        guard ["SJWC", "YJS"].contains(detail["currentStatus"] as? String ?? "") else {
            throw ReadError.message("需求状态已变化，请刷新需求流")
        }
        func text(_ key: String) -> String {
            (detail[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let existingAcceptor = text("acceptorId")
        let launch = text("launchTime")
        return Self(reqID: reqID, requiresLaunchTime: type == "10",
                    launchTime: launch.isEmpty ? "" : String(launch.prefix(10)),
                    acceptorID: existingAcceptor.isEmpty ? text("submitterId") : existingAcceptor,
                    acceptorName: existingAcceptor.isEmpty ? text("submitterName") : text("acceptorName"))
    }

    static func date(_ text: String) -> Date? {
        guard text.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil else { return nil }
        let formatter = dateFormatter()
        guard let date = formatter.date(from: text), formatter.string(from: date) == text else { return nil }
        return date
    }

    static func dateString(_ date: Date) -> String { dateFormatter().string(from: date) }

    private static func dateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }

    var validationError: String? {
        let launch = launchTime.trimmingCharacters(in: .whitespacesAndNewlines)
        if requiresLaunchTime && launch.isEmpty { return "请选择计划上线日期" }
        if !launch.isEmpty && Self.date(launch) == nil { return "请填写有效日期，格式为 yyyy-MM-dd" }
        if acceptorID.isEmpty { return "尚未设置业务验收人，请先在网页详情中设置" }
        return nil
    }
}

/// Matches the official changeStatus payload. Start-development fields are sent in the same request.
struct PRDStatusChange: Encodable {
    let id: Int
    let toStatus: String
    let operatorId = "current_user"
    let operatorName = "当前用户"
    let remark: String
    var launchTime: String?
    var acceptorId: String?
    var acceptorName: String?

    init(reqID: Int, toStatus: String, actionName: String, development: PRDStartDevelopmentDraft? = nil) throws {
        id = reqID
        self.toStatus = toStatus
        remark = actionName
        if toStatus == "KFZ" {
            guard let development, development.reqID == reqID else {
                throw PRDStartDevelopmentDraft.ReadError.message("请先填写开始开发信息")
            }
            if let error = development.validationError { throw PRDStartDevelopmentDraft.ReadError.message(error) }
            let launch = development.launchTime.trimmingCharacters(in: .whitespacesAndNewlines)
            launchTime = launch.isEmpty ? nil : launch
            acceptorId = development.acceptorID
            acceptorName = development.acceptorName
        }
    }
}

struct PRDStartDevelopmentSheet: View {
    @ObservedObject var vm: BizMapViewModel
    let item: BizPRDItem
    @State private var showCalendar = false
    @State private var calendarDate = Date()

    private var submitting: Bool { vm.statusSubmitting.contains(item.id) }
    private var launchBinding: Binding<String> {
        Binding(get: { vm.startDevelopmentDraft?.launchTime ?? "" },
                set: { vm.startDevelopmentDraft?.launchTime = $0; vm.startDevelopmentError = nil })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("开始开发").font(.system(size: 15, weight: .semibold))
            Text(item.name).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            if vm.startDevelopmentLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("读取需求信息…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            } else if let draft = vm.startDevelopmentDraft {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                    GridRow {
                        Text("计划上线日期").font(.system(size: 13))
                        HStack(spacing: 8) {
                            TextField("yyyy-MM-dd", text: launchBinding)
                                .textFieldStyle(.roundedBorder)
                            Button {
                                calendarDate = PRDStartDevelopmentDraft.date(launchBinding.wrappedValue) ?? Date()
                                showCalendar = true
                            } label: { Image(systemName: "calendar") }
                                .help("选择计划上线日期")
                                .popover(isPresented: $showCalendar) {
                                    VStack(spacing: 12) {
                                        DatePicker("计划上线日期", selection: $calendarDate, displayedComponents: .date)
                                            .datePickerStyle(.graphical).labelsHidden()
                                        Button("使用此日期") {
                                            launchBinding.wrappedValue = PRDStartDevelopmentDraft.dateString(calendarDate)
                                            showCalendar = false
                                        }.buttonStyle(.borderedProminent)
                                    }.padding(16)
                                }
                        }
                    }
                    GridRow {
                        Text("业务验收人").font(.system(size: 13))
                        Text(draft.acceptorName.isEmpty ? "尚未设置" :
                            (draft.acceptorName.components(separatedBy: " - ").last ?? draft.acceptorName))
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }.disabled(submitting)
                Text(draft.requiresLaunchTime ? "请选择计划上线日期，需求系统会发起确认。" : "计划上线日期可选。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if let error = vm.startDevelopmentError ??
                (vm.startDevelopmentDraft?.launchTime.isEmpty == false ||
                 vm.startDevelopmentDraft?.acceptorID.isEmpty == true ? vm.startDevelopmentDraft?.validationError : nil) {
                Text(error).font(.system(size: 12)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button("网页详情") { vm.openURL(item.url) }
                Spacer()
                Button("取消") { vm.cancelStartDevelopment() }
                    .keyboardShortcut(.cancelAction).disabled(submitting)
                if vm.startDevelopmentDraft == nil && !vm.startDevelopmentLoading {
                    Button("重试") { vm.beginStartDevelopment(item) }.buttonStyle(.borderedProminent)
                } else {
                    Button {
                        vm.pushStatus(reqId: item.id, toStatus: "KFZ", actionName: "开始开发",
                                      developmentDraft: vm.startDevelopmentDraft)
                    } label: {
                        if submitting { ProgressView().controlSize(.small) }
                        else { Text("开始开发") }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(submitting || vm.startDevelopmentLoading ||
                              vm.startDevelopmentDraft == nil || vm.startDevelopmentDraft?.validationError != nil)
                }
            }
        }
        .padding(20)
        .frame(width: 440)
        .background(Color(nsColor: .windowBackgroundColor))
        .interactiveDismissDisabled(submitting)
    }
}
