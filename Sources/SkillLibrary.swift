import Foundation

struct SkillLibraryMetadata: Codable {
    var favorites: Set<String> = []
    var notes: [String: String] = [:]
    static let defaultURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/DBoard/skills-library.json")
}

extension SkillItem {
    var displayName: String { name.isEmpty ? dir : name }

    /// These labels describe file locations, not whether a running AI loaded them.
    var sourceLabels: [String] {
        let labels = sources.map { source -> String in
            switch source {
            case "Claude 兼容", "共享": return "共享"
            case "Codex 系统": return "系统"
            case "Codex 插件", "Qoder CN 插件": return "插件"
            case "Claude 遗留": return "Claude 本地"
            case "已归档": return "归档"
            case "分享版": return "分享"
            default: return source
            }
        }
        return Array(Set(labels)).sorted()
    }

    var availableInstallations: [SkillInstallation] {
        installations.isEmpty
            ? [SkillInstallation(source: sources.first ?? "本地", path: path)]
            : installations
    }

    func invocation(at selectedPath: String? = nil) -> String {
        let entry = (selectedPath ?? path) + "/SKILL.md"
        return "请阅读并按以下 Skill 的说明执行：\n\(entry)\n\n我的任务：\n"
    }
}
