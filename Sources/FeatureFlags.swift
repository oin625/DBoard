import SwiftUI

// MARK: - 功能开关
// 钉钉值守(reply-daemon + 待回复面板)可整体关闭：
//   关 = launchctl disable + bootout（重启/重新登录也不会自己拉起），面板不再读待回复、不弹通知
//   开 = launchctl enable + bootstrap

final class FeatureFlags: ObservableObject {
    static let shared = FeatureFlags()
    static let replyLabel = "com.zz.dws-reply-daemon"

    @Published private(set) var replyEnabled: Bool

    init() {
        let d = UserDefaults.standard
        replyEnabled = d.object(forKey: "reply.enabled") as? Bool ?? true
    }

    func setReplyEnabled(_ on: Bool) {
        replyEnabled = on
        UserDefaults.standard.set(on, forKey: "reply.enabled")
        if !on { ReplyInboxViewModel.shared.items = [] } else { ReplyInboxViewModel.shared.reload() }
        let uid = getuid()
        let plist = FileManager.default.homeDirectoryForCurrentUser.path + "/Library/LaunchAgents/\(Self.replyLabel).plist"
        let cmd = on
            ? "launchctl enable gui/\(uid)/\(Self.replyLabel); launchctl bootstrap gui/\(uid) '\(plist)' 2>/dev/null; launchctl kickstart gui/\(uid)/\(Self.replyLabel)"
            : "launchctl disable gui/\(uid)/\(Self.replyLabel); launchctl bootout gui/\(uid)/\(Self.replyLabel) 2>/dev/null; true"
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = ["-c", cmd]
            p.standardOutput = Pipe(); p.standardError = Pipe()
            try? p.run(); p.waitUntilExit()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { EngineHealthModel.shared.refresh() }
        }
    }
}

extension DBoardModule {
    /// 菜单/命令面板里展示的模块（已关闭的功能不出现）
    static var visible: [DBoardModule] {
        all.filter { $0.id != "reply" || FeatureFlags.shared.replyEnabled }
    }
}
