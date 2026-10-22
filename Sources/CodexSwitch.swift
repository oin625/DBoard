import SwiftUI

// MARK: - Codex 供应商切换面板(csw 可视化前端)
// 数据与切换逻辑全部复用 ~/.agents/skills/codex-switch/codex_switch.py(外科手术式改 config.toml),
// 本文件只做展示 + 调脚本。⌥C 呼出。

final class CodexSwitchModel: ObservableObject {
    struct Profile: Identifiable {
        let name: String
        let type: String      // key / env / official
        let baseUrl: String
        let model: String
        let desc: String
        let secretHint: String
        let fullKey: String
        var id: String { name }

        var icon: String {
            switch type {
            case "official": return "crown.fill"
            case "env": return "terminal.fill"
            default: return "key.fill"
            }
        }
    }

    @Published var profiles: [Profile] = []
    @Published var currentProvider = ""
    @Published var currentModel = ""
    @Published var busy: String?
    @Published var message: String?
    @Published var deleteTarget: String?
    @Published var showAdd = false
    @Published var addName = ""
    @Published var addUrl = ""
    @Published var addKey = ""
    @Published var addModel = ""
    @Published var addDesc = ""
    @Published var editingId: String?
    @Published var editUrl = ""
    @Published var editKey = ""
    @Published var editModel = ""
    @Published var editDesc = ""
    @Published var testResult: [String: String] = [:]
    @Published var testing: String?
    @Published var availableModels: [String] = []
    @Published var fetchingModels = false
    @Published var modelQuery = ""
    @Published var modelsMessage: String?
    @Published var pinned = false

    private let home = NSHomeDirectory()
    private var script: String { home + "/.agents/skills/codex-switch/codex_switch.py" }
    private var profilesPath: String { home + "/.agents/skills/codex-switch/profiles.json" }
    private var configPath: String { home + "/.codex/config.toml" }

    init() { reload() }

    func isCurrent(_ p: Profile) -> Bool {
        p.type == "official" ? currentProvider == "openai" : currentProvider == p.name
    }

    func reload() {
        if !FileManager.default.fileExists(atPath: profilesPath) {
            _ = runScript(["list"])   // 首次运行播种 profile 库
        }
        profiles = Self.parseProfiles(at: profilesPath)
        let cur = Self.parseCurrentConfig(at: configPath)
        currentProvider = cur.0
        currentModel = cur.1
    }

    func use(_ name: String) {
        guard busy == nil else { return }
        busy = name
        message = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let (ok, out) = self?.runScript(["use", name]) ?? (false, "model 已释放")
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = nil
                withAnimation(.easeOut(duration: 0.25)) {
                    self.message = ok ? "✅ 已切到 \(name),新线程生效" : "❌ 切换失败:\(Self.tail(out))"
                }
                self.reload()
            }
        }
    }

    func remove(_ name: String) {
        guard busy == nil else { return }
        busy = name
        message = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let (ok, out) = self?.runScript(["rm", name]) ?? (false, "model 已释放")
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = nil
                self.deleteTarget = nil
                self.message = ok
                    ? "🗑 已删除 \(name)(config.toml 未动,要换供应商点别的行)"
                    : "❌ 删除失败:\(Self.tail(out))"
                self.reload()
            }
        }
    }

    func startEdit(_ p: Profile) {
        availableModels = []
        modelsMessage = nil
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            editingId = p.name
        }
        editUrl = p.baseUrl
        editKey = p.fullKey
        editModel = p.model
        editDesc = p.desc
    }

    func cancelEdit() {
        availableModels = []
        modelsMessage = nil
        withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) { editingId = nil }
    }

    func saveEdit() {
        guard let name = editingId, busy == nil else { return }
        busy = name
        message = nil
        var args = ["edit", name]
        args += ["--url", editUrl, "--key", editKey, "--model", editModel, "--desc", editDesc]
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let (ok, out) = self?.runScript(args) ?? (false, "model 已释放")
            var reapplied = false
            if ok {
                self?.reload()
                if let s = self, s.profiles.first(where: { $0.name == name }).map({ s.isCurrent($0) }) == true {
                    let (ok2, _) = s.runScript(["use", name])
                    reapplied = ok2
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = nil
                if ok {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) { self.editingId = nil }
                    withAnimation(.easeOut(duration: 0.25)) {
                        self.message = reapplied
                            ? "✅ 已保存并应用 \(name) 到 config.toml"
                            : "✅ 已保存 \(name) 的修改"
                    }
                } else {
                    self.message = "❌ 保存失败:\(Self.tail(out))"
                }
                self.reload()
            }
        }
    }

    func testProfile(_ name: String) {
        guard testing == nil else { return }
        testing = name
        testResult.removeValue(forKey: name)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let (ok, out) = self?.runScript(["test", name]) ?? (false, "model 已释放")
            DispatchQueue.main.async {
                guard let self else { return }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    self.testing = nil
                    self.testResult[name] = (ok ? out : out).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
    }

    func fetchModels(for name: String) {
        guard !fetchingModels else { return }
        fetchingModels = true
        availableModels = []
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let (ok, out) = self?.runScript(["models", name, "--json"]) ?? (false, "")
            DispatchQueue.main.async {
                guard let self else { return }
                self.fetchingModels = false
                if ok, let data = out.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
                   let arr = try? JSONSerialization.jsonObject(with: data) as? [String], !arr.isEmpty {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        self.availableModels = arr
                        self.modelsMessage = "✅ 拉到 \(arr.count) 个模型,点选即用"
                    }
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        self.modelsMessage = "❌ 未能获取模型列表"
                    }
                }
            }
        }
    }

    func addAndUse() {
        guard busy == nil else { return }
        let name = addName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !addUrl.isEmpty, !addModel.isEmpty, !addKey.isEmpty else {
            message = "❌ 名称 / URL / Key / 模型 都要填"
            return
        }
        busy = name
        message = nil
        let args = ["add", name, "--url", addUrl, "--key", addKey, "--model", addModel, "--desc", addDesc]
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let (okAdd, outAdd) = self?.runScript(args) ?? (false, "")
            var final = (okAdd, outAdd)
            if okAdd { final = self?.runScript(["use", name]) ?? final }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = nil
                self.message = final.0 ? "✅ 已登记并切到 \(name)" : "❌ \(Self.tail(final.1))"
                if final.0 {
                    self.addName = ""; self.addUrl = ""; self.addKey = ""
                    self.addModel = ""; self.addDesc = ""; self.showAdd = false
                }
                self.reload()
            }
        }
    }

    // MARK: 解析

    private static func parseProfiles(at path: String) -> [Profile] {
        guard let data = FileManager.default.contents(atPath: path),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: [String: Any]] else { return [] }
        var result: [Profile] = []
        for (name, p) in root {
            let type = p["type"] as? String ?? "key"
            let url = p["base_url"] as? String ?? ""
            let model = p["model"] as? String ?? ""
            let desc = p["desc"] as? String ?? ""
            let hint: String
            if type == "official" { hint = "ChatGPT 登录态" }
            else if type == "env" { hint = "env:\(p["env"] as? String ?? "")" }
            else {
                let k = p["key"] as? String ?? ""
                hint = k.count > 12 ? String(k.prefix(12)) + "…" : k
            }
            let rawKey = p["key"] as? String ?? ""
            result.append(Profile(name: name, type: type, baseUrl: url, model: model, desc: desc, secretHint: hint, fullKey: rawKey))
        }
        return result.sorted { a, b in
            let ao = a.type == "official"
            let bo = b.type == "official"
            if ao != bo { return ao }
            return a.name < b.name
        }
    }

    private static func parseCurrentConfig(at path: String) -> (String, String) {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return ("", "") }
        var provider = ""; var model = ""
        for line in text.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("[") { break }
            if l.hasPrefix("model_provider =") { provider = value(of: l) }
            if l.hasPrefix("model =") { model = value(of: l) }
        }
        return (provider, model)
    }

    private static func value(of line: String) -> String {
        guard let i = line.firstIndex(of: "=") else { return "" }
        return String(line[line.index(after: i)...])
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    private static func tail(_ s: String) -> String {
        let lines = s.split(separator: "\n").map(String.init)
        return String(lines.last ?? s)
    }

    // MARK: 调 csw 脚本

    private func runScript(_ args: [String]) -> (Bool, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [script] + args
        let out = Pipe(); let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return (false, error.localizedDescription) }
        let o = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return (p.terminationStatus == 0, o + e)
    }
}

// MARK: - 视图

struct CodexSwitchView: View {
    @EnvironmentObject var model: CodexSwitchModel
    @EnvironmentObject var theme: ThemeManager

    var body: some View {
        let t = theme.current
        VStack(alignment: .leading, spacing: 18) {
            header(t)
            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) { ForEach(model.profiles) { row($0, t) } }
                .padding(.vertical, 2)
            }
            addSection(t)
            footer(t)
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 560)
        .background(panelBg(t).opacity(0.99))
    }

    /// 毛玻璃等主题的 background 是 .clear,直接用会透穿;回退到实色卡片底
    private func panelBg(_ t: DBoardTheme) -> Color {
        t.background == .clear ? t.cardFill : t.background
    }

    private func header(_ t: DBoardTheme) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.swap.circle.fill")
                .font(.system(size: 30))
                .foregroundStyle(t.accentGradient)
            VStack(alignment: .leading, spacing: 3) {
                Text("Codex 切换")
                    .font(.system(size: 21, weight: .heavy))
                    .foregroundColor(t.textPrimary)
                Text("当前  \(model.currentProvider) · \(model.currentModel)")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(t.textSecondary)
            }
            Spacer()
            Button {
                model.pinned.toggle()
                CodexSwitchWindowController.shared.setPinned(model.pinned)
            } label: {
                Image(systemName: model.pinned ? "pin.fill" : "pin.slash")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(model.pinned ? t.accentPrimary : t.textMuted)
                    .padding(8)
                    .background(Circle().fill(model.pinned ? t.accentPrimary.opacity(0.12) : t.cardFill.opacity(0.6)))
            }
            .buttonStyle(BounceButtonStyle())
            .help(model.pinned ? "取消置顶(点别处会自动收起)" : "置顶窗口")

            Button { model.reload() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(t.textSecondary)
                    .padding(8)
                    .background(Circle().fill(t.cardFill.opacity(0.6)))
            }
            .buttonStyle(BounceButtonStyle())
            .help("刷新")
        }
    }

    private func row(_ p: CodexSwitchModel.Profile, _ t: DBoardTheme) -> some View {
        let current = model.isCurrent(p)
        let busy = model.busy == p.name
        let confirming = model.deleteTarget == p.name
        return VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: p.icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(current ? t.accentPrimary : t.textTertiary)
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: 11).fill(t.accentPrimary.opacity(current ? 0.16 : 0.07)))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(p.name)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(t.textPrimary)
                        Text(p.model)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(t.chrome.opacity(0.35))
                            .foregroundColor(t.textSecondary)
                            .cornerRadius(6)
                        if !p.desc.isEmpty {
                            Text(p.desc)
                                .font(.system(size: 12))
                                .foregroundColor(t.textTertiary)
                                .lineLimit(1)
                        }
                    }
                    Text(p.type == "official" ? "内置 openai · \(p.secretHint)" : "\(p.baseUrl) · \(p.secretHint)")
                        .font(.system(size: 12))
                        .foregroundColor(t.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)

                if busy {
                    ProgressView().controlSize(.regular)
                } else if confirming {
                    HStack(spacing: 8) {
                        Button { model.remove(p.name) } label: {
                            Text("确认删除")
                                .font(.system(size: 13, weight: .bold))
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(Color.red)
                                .foregroundColor(.white)
                                .cornerRadius(8)
                        }.buttonStyle(.plain)
                        Button { model.deleteTarget = nil } label: {
                            Text("取消")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(t.textSecondary)
                        }.buttonStyle(.plain)
                    }
                } else {
                    HStack(spacing: 8) {
                        Button { model.use(p.name) } label: {
                            Text(current ? "使用中" : "切换")
                                .font(.system(size: 13, weight: .bold))
                                .padding(.horizontal, 14).padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(current ? AnyShapeStyle(t.chrome.opacity(0.3)) : AnyShapeStyle(t.accentGradient))
                                )
                                .foregroundColor(current ? t.textTertiary : .white)
                        }
                        .buttonStyle(BounceButtonStyle())
                        .disabled(current)

                        if model.testing == p.name {
                            ProgressView().controlSize(.small)
                                .frame(width: 28, height: 28)
                                .transition(.opacity)
                        } else {
                            Button { model.testProfile(p.name) } label: {
                                Image(systemName: "bolt.horizontal.circle")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundColor(t.textSecondary)
                                    .frame(width: 28, height: 28)
                                    .background(Circle().fill(t.chrome.opacity(0.001)))
                                    .contentShape(Circle())
                            }
                            .buttonStyle(BounceButtonStyle())
                            .help("测试连通性")
                        }

                        if p.type != "official" {
                            Button { model.startEdit(p) } label: {
                                Image(systemName: model.editingId == p.name ? "pencil.circle.fill" : "pencil")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundColor(model.editingId == p.name ? t.accentPrimary : t.textSecondary)
                                    .frame(width: 28, height: 28)
                                    .background(Circle().fill(t.chrome.opacity(0.001)))
                                    .contentShape(Circle())
                            }
                            .buttonStyle(BounceButtonStyle())
                            .help("编辑 \(p.name)")
                        }

                        Button { model.deleteTarget = p.name } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(t.textMuted)
                                .frame(width: 28, height: 28)
                                .background(Circle().fill(t.chrome.opacity(0.001)))
                                .contentShape(Circle())
                        }
                        .buttonStyle(BounceButtonStyle())
                        .help("删除 \(p.name)")
                    }
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(t.cardFill.opacity(current ? t.cardFillOpacity : t.cardFillOpacity * 0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(current ? t.accentPrimary.opacity(0.65) : t.separator.opacity(0.6),
                            lineWidth: current ? 1.5 : 1)
            )

            if let result = model.testResult[p.name] {
                let testOk = result.hasPrefix("✅")
                let testBgColor: Color = testOk ? .green : .red
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: testOk ? "checkmark.seal.fill" : "xmark.octagon.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(testOk ? .green : .red)
                        Text(testOk ? "连通成功" : "连通失败")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(testOk ? .green : .red)
                        Spacer()
                        Button {
                            withAnimation(.easeOut(duration: 0.2)) { _ = model.testResult.removeValue(forKey: p.name) }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundColor(t.textMuted)
                        }.buttonStyle(.plain)
                    }
                    Text(result)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(testOk ? t.accentPrimary : Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .foregroundColor(testBgColor.opacity(0.08))
                )
                .padding(.horizontal, 4).padding(.top, 4)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.95, anchor: .top)),
                    removal: .opacity
                ))
            }

            if model.editingId == p.name {
                Divider().padding(.horizontal, 12).padding(.top, 4)
                VStack(spacing: 8) {
                    HStack(spacing: 10) {
                        modelField($model.editModel, profileName: p.name, t)
                        field("备注", $model.editDesc, t)
                    }
                    field("Base URL", $model.editUrl, t)
                    field("API Key", $model.editKey, t)
                    HStack(spacing: 10) {
                        Button { model.saveEdit() } label: {
                            Text(model.busy == nil ? "保存" : "处理中…")
                                .font(.system(size: 13, weight: .bold))
                                .padding(.horizontal, 16).padding(.vertical, 6)
                                .background(t.accentGradient)
                                .foregroundColor(.white)
                                .cornerRadius(8)
                        }.buttonStyle(BounceButtonStyle()).disabled(model.busy != nil)
                        Button { withAnimation(.easeOut(duration: 0.15)) { model.cancelEdit() } } label: {
                            Text("取消")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(t.textSecondary)
                        }.buttonStyle(.plain)
                        Spacer()
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(t.cardFill.opacity(0.4)))
                .padding(.horizontal, 4).padding(.top, 4)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .top)).combined(with: .scale(scale: 0.97, anchor: .top)),
                    removal: .opacity.combined(with: .scale(scale: 0.97, anchor: .top))
                ))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: model.editingId)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.testResult[p.name] != nil)
        .disabled(model.busy != nil)
    }

    private func addSection(_ t: DBoardTheme) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { withAnimation(.easeOut(duration: 0.15)) { model.showAdd.toggle() } } label: {
                Label(model.showAdd ? "收起" : "登记新供应商",
                      systemImage: model.showAdd ? "chevron.up.circle.fill" : "plus.circle.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(t.accentPrimary)
            }.buttonStyle(.plain)

            if model.showAdd {
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        field("名称", $model.addName, t)
                        field("模型(手动输入)", $model.addModel, t)
                    }
                    field("Base URL", $model.addUrl, t)
                    field("API Key", $model.addKey, t)
                    field("备注(可选)", $model.addDesc, t)
                    Button { model.addAndUse() } label: {
                        Text(model.busy == nil ? "登记并切换" : "处理中…")
                            .font(.system(size: 14, weight: .heavy))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(t.accentGradient)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }.buttonStyle(.plain).disabled(model.busy != nil)
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 14).fill(t.cardFill.opacity(0.5)))
            }
        }
    }

    private func field(_ ph: String, _ v: Binding<String>, _ t: DBoardTheme) -> some View {
        TextField(ph, text: v)
            .textFieldStyle(.plain)
            .font(.system(size: 13, design: .monospaced))
            .padding(9)
            .background(RoundedRectangle(cornerRadius: 8).fill(t.cardFill.opacity(0.8)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(t.separator.opacity(0.8), lineWidth: 1))
            .foregroundColor(t.textPrimary)
    }

    private func modelField(_ v: Binding<String>, profileName: String, _ t: DBoardTheme) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField("模型", text: v)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, design: .monospaced))
                    .padding(9)
                    .background(RoundedRectangle(cornerRadius: 8).fill(t.cardFill.opacity(0.8)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(t.separator.opacity(0.8), lineWidth: 1))
                    .foregroundColor(t.textPrimary)
                Button {
                    model.modelsMessage = nil
                    model.fetchModels(for: profileName)
                } label: {
                    HStack(spacing: 4) {
                        if model.fetchingModels {
                            ProgressView().controlSize(.small)
                        } else if !model.availableModels.isEmpty {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.green)
                            Text("\(model.availableModels.count)")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(t.textSecondary)
                        } else {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(t.textSecondary)
                            Text("拉取")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(t.textSecondary)
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 7).fill(t.chrome.opacity(0.2)))
                }
                .buttonStyle(BounceButtonStyle())
                .help("拉取该 Key 可用的所有模型")
                .disabled(model.fetchingModels)
            }
            if let msg = model.modelsMessage, model.availableModels.isEmpty {
                Text(msg)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(msg.hasPrefix("✅") ? .green : .red)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if !model.availableModels.isEmpty {
                let q = model.modelQuery.lowercased().trimmingCharacters(in: .whitespaces)
                let filtered = q.isEmpty ? model.availableModels : model.availableModels.filter { $0.lowercased().contains(q) }
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkle")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(t.accentPrimary)
                        Text("可用模型 \(filtered.count) 个")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(t.textSecondary)
                        Spacer()
                        Button {
                            withAnimation(.easeOut(duration: 0.2)) { model.availableModels = []; model.modelsMessage = nil; model.modelQuery = "" }
                        } label: {
                            Text("收起")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(t.textMuted)
                        }.buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)

                    HStack(spacing: 4) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11))
                            .foregroundColor(t.textMuted)
                        TextField("搜索模型…", text: $model.modelQuery)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(t.textPrimary)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(t.cardFill.opacity(0.6)))
                    .padding(.horizontal, 8).padding(.bottom, 4)

                    Divider().padding(.horizontal, 8)
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(filtered, id: \.self) { m in
                                Button {
                                    withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
                                        v.wrappedValue = m
                                        model.availableModels = []
                                        model.modelsMessage = nil
                                        model.modelQuery = ""
                                    }
                                } label: {
                                    HStack(spacing: 6) {
                                        Text(m)
                                            .font(.system(size: 12, design: .monospaced))
                                            .foregroundColor(m == v.wrappedValue ? t.accentPrimary : t.textPrimary)
                                        Spacer()
                                        if m == v.wrappedValue {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.system(size: 11, weight: .bold))
                                                .foregroundColor(t.accentPrimary)
                                        }
                                    }
                                    .padding(.horizontal, 10).padding(.vertical, 7)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(
                                        m == v.wrappedValue ? t.accentPrimary.opacity(0.08) : t.chrome.opacity(0.001)
                                    ))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(BounceButtonStyle())
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(t.cardFill.opacity(0.95)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(t.accentPrimary.opacity(0.3), lineWidth: 1))
                .shadow(color: t.accentPrimary.opacity(0.1), radius: 8, y: 4)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.92, anchor: .top)).combined(with: .move(edge: .top)),
                    removal: .opacity.combined(with: .scale(scale: 0.95, anchor: .top))
                ))
            }
        }
    }

    private func footer(_ t: DBoardTheme) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if let m = model.message {
                Text(m)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(t.textSecondary)
                    .lineLimit(2)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            Text("⌥C 呼出/收起 · 只影响新线程,老线程绑定原 provider")
                .font(.system(size: 11))
                .foregroundColor(t.textMuted)
        }
    }
}

// MARK: - 按钮动效

struct BounceButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// MARK: - 窗口

final class CodexSwitchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    var pinned = false

    override func resignKey() {
        super.resignKey()
        if !pinned { orderOut(nil) }
    }
}

final class CodexSwitchWindowController {
    static let shared = CodexSwitchWindowController()
    private var window: NSWindow?
    private let model = CodexSwitchModel()

    func toggle() {
        if let w = window, w.isVisible { w.orderOut(nil); return }
        show()
    }

    func setPinned(_ pinned: Bool) {
        guard let w = window as? CodexSwitchPanel else { return }
        w.pinned = pinned
        w.level = pinned ? .floating : .normal
    }

    func show() {
        model.reload()
        if let w = window {
            centerWindowOnMouseScreen(w)
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        let view = CodexSwitchView()
            .environmentObject(model)
            .environmentObject(ThemeManager.shared)
            .environmentObject(FontManager.shared)
        let host = NSHostingController(rootView: view)
        let win = CodexSwitchPanel(contentViewController: host)
        win.title = "Codex 切换"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.setContentSize(NSSize(width: 600, height: 720))
        win.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        win.standardWindowButton(.miniaturizeButton)?.isHidden = true
        win.isReleasedWhenClosed = false
        win.level = .floating
        win.hidesOnDeactivate = false
        win.pinned = false
        win.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        win.contentMinSize = NSSize(width: 520, height: 480)
        centerWindowOnMouseScreen(win)
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        window = win
    }
}
