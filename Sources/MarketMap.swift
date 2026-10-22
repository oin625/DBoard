import SwiftUI
import AppKit

// MARK: - 大盘云图(自绘版): 东方财富公开行情 + squarified treemap
// 面积=流通市值, 颜色=涨跌幅(红涨绿跌), 按行业分块, 30秒自动刷新

struct MStock: Identifiable {
    let code: String
    let name: String
    let price: Double
    let pct: Double
    let cap: Double      // 流通市值
    let industry: String
    var id: String { code }
}

struct MIndex {
    let name: String
    let price: Double
    let pct: Double
}

final class MarketMapViewModel: ObservableObject {
    @Published var stocks: [MStock] = []
    @Published var indexes: [MIndex] = []
    @Published var lastUpdate: Date? = nil
    @Published var loading = false
    @Published var upCount = 0
    @Published var downCount = 0
    @Published var statusText = ""

    private var timer: Timer?

    // 标的维度(代码/名称/行业/流通市值): 东财低频获取+磁盘缓存; 实时报价走腾讯
    struct UStock: Codable {
        let code: String
        let name: String
        let industry: String
        let cap: Double
    }
    private var universe: [UStock] = []
    private var universeAt: Date? = nil
    private static let universePath = FileManager.default.homeDirectoryForCurrentUser.path + "/.dboard-market-universe.json"

    func start() {
        refresh()
        timer?.invalidate()
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// 窗口关闭时停止轮询(曾因关窗后30秒×56请求持续轰炸导致东财封IP)
    func pause() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        guard !loading else { return }
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let idx = Self.fetchIndexes()
            DispatchQueue.main.async { if !idx.isEmpty { self.indexes = idx } }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            self.ensureUniverse()
            let uni = self.universe
            var merged: [MStock] = []
            var msg = ""
            if uni.isEmpty {
                msg = "标的维度获取失败(行情源限流中)，60秒后自动重试"
            } else {
                let quotes = Self.fetchTencentQuotes(codes: uni.map { $0.code })
                if quotes.count >= uni.count * 85 / 100 {
                    merged = uni.compactMap { u in
                        guard let q = quotes[u.code] else { return nil }
                        return MStock(code: u.code, name: u.name, price: q.0, pct: q.1, cap: u.cap, industry: u.industry)
                    }
                } else {
                    msg = "实时行情不完整(\(quotes.count)/\(uni.count))，保留上次数据，稍后自动重试"
                }
            }
            DispatchQueue.main.async {
                if !merged.isEmpty {
                    self.stocks = merged
                    self.upCount = merged.filter { $0.pct > 0 }.count
                    self.downCount = merged.filter { $0.pct < 0 }.count
                    self.lastUpdate = Date()
                }
                self.statusText = msg
                self.loading = false
            }
        }
    }

    // MARK: 标的维度(东财, 4小时刷一次, 失败用磁盘缓存)

    private func ensureUniverse() {
        if universe.isEmpty,
           let d = try? Data(contentsOf: URL(fileURLWithPath: Self.universePath)),
           let obj = try? JSONDecoder().decode(CachedUniverse.self, from: d), !obj.items.isEmpty {
            universe = obj.items
            universeAt = Date(timeIntervalSince1970: obj.ts)
        }
        let stale = universeAt.map { Date().timeIntervalSince($0) > 4 * 3600 } ?? true
        guard stale else { return }
        let fresh = Self.fetchUniverseEastmoney()
        if fresh.count >= 5000 {
            universe = fresh
            universeAt = Date()
            let obj = CachedUniverse(ts: Date().timeIntervalSince1970, items: fresh)
            if let d = try? JSONEncoder().encode(obj) {
                try? d.write(to: URL(fileURLWithPath: Self.universePath), options: .atomic)
            }
        }
    }

    private struct CachedUniverse: Codable {
        let ts: Double
        let items: [UStock]
    }

    private static func fetchJSON(_ urlString: String) -> [String: Any]? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        let sem = DispatchSemaphore(value: 0)
        var result: [String: Any]? = nil
        URLSession.shared.dataTask(with: req) { data, _, _ in
            if let d = data { result = try? JSONSerialization.jsonObject(with: d) as? [String: Any] }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 9)
        return result
    }

    private static func num(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        return nil
    }

    private static func fetchIndexes() -> [MIndex] {
        let url = "https://push2.eastmoney.com/api/qt/ulist.np/get?secids=1.000001,0.399001,0.399006,1.000300,1.000688&fields=f2,f3,f12,f14&fltt=2&invt=2"
        guard let root = fetchJSON(url),
              let data = root["data"] as? [String: Any],
              let diff = data["diff"] as? [[String: Any]] else { return [] }
        return diff.compactMap { e in
            guard let name = e["f14"] as? String,
                  let price = num(e["f2"]), let pct = num(e["f3"]) else { return nil }
            return MIndex(name: name, price: price, pct: pct)
        }
    }

    private static func fetchUniverseEastmoney() -> [UStock] {
        let base = "https://push2.eastmoney.com/api/qt/clist/get?po=1&np=1&fltt=2&invt=2&fid=f3"
            + "&fs=m:0+t:6,m:0+t:80,m:1+t:2,m:1+t:23&fields=f12,f14,f21,f100&pz=100"
        func page(_ n: Int) -> (total: Int, items: [UStock]) {
            for attempt in 0..<2 {
                if attempt > 0 { Thread.sleep(forTimeInterval: 0.4) }
                guard let root = fetchJSON(base + "&pn=\(n)"),
                      let data = root["data"] as? [String: Any],
                      let diff = data["diff"] as? [[String: Any]] else { continue }
                let total = (data["total"] as? Int) ?? 0
                let items: [UStock] = diff.compactMap { e in
                    guard let code = e["f12"] as? String,
                          let name = e["f14"] as? String,
                          let cap = num(e["f21"]), cap > 0 else { return nil }
                    return UStock(code: code, name: name, industry: (e["f100"] as? String) ?? "其他", cap: cap)
                }
                if !items.isEmpty { return (total, items) }
            }
            return (0, [])
        }
        let first = page(1)
        guard first.total > 0 else { return [] }
        let pages = Int((Double(first.total) / 100.0).rounded(.up))
        var results = [[UStock]](repeating: [], count: pages + 1)
        results[1] = first.items
        let lock = NSLock()
        // 温和并发: 每批4页, 批间歇0.15秒, 避免触发限流封IP
        var n = 2
        while n <= pages {
            let batch = Array(n...min(n + 3, pages))
            DispatchQueue.concurrentPerform(iterations: batch.count) { i in
                let pn = batch[i]
                let r = page(pn)
                lock.lock(); results[pn] = r.items; lock.unlock()
            }
            n += 4
            Thread.sleep(forTimeInterval: 0.15)
        }
        let all = (1...pages).flatMap { results[$0] }
        return all.count >= first.total * 9 / 10 ? all : []
    }

    // MARK: 实时报价(腾讯, 抗高频)

    private static func fetchTencentQuotes(codes: [String]) -> [String: (Double, Double)] {
        var result: [String: (Double, Double)] = [:]
        let lock = NSLock()
        let batches: [[String]] = stride(from: 0, to: codes.count, by: 60).map {
            Array(codes[$0..<min($0 + 60, codes.count)])
        }
        func fetchBatch(_ b: [String]) -> Bool {
            let syms = b.map { ($0.hasPrefix("6") || $0.hasPrefix("9")) ? "sh" + $0 : "sz" + $0 }
            guard let url = URL(string: "https://qt.gtimg.cn/q=" + syms.joined(separator: ",")) else { return false }
            var req = URLRequest(url: url, timeoutInterval: 8)
            req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            let sem = DispatchSemaphore(value: 0)
            var raw: Data? = nil
            URLSession.shared.dataTask(with: req) { d, _, _ in raw = d; sem.signal() }.resume()
            _ = sem.wait(timeout: .now() + 9)
            guard let d = raw else { return false }
            let enc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
            guard let text = String(data: d, encoding: enc) ?? String(data: d, encoding: .utf8) else { return false }
            var got = 0
            for seg in text.components(separatedBy: ";") {
                guard let eq = seg.range(of: "=\""),
                      let vr = seg.range(of: "v_") else { continue }
                let sym = String(seg[vr.upperBound..<eq.lowerBound])
                let code = String(sym.dropFirst(2))
                let body = String(seg[eq.upperBound...])
                let f = body.components(separatedBy: "~")
                guard f.count > 32, let price = Double(f[3]), let pct = Double(f[32]), price > 0 else { continue }
                lock.lock(); result[code] = (price, pct); lock.unlock()
                got += 1
            }
            return got > 0
        }
        var failed: [[String]] = []
        var i = 0
        while i < batches.count {
            let group = Array(batches[i..<min(i + 4, batches.count)])
            DispatchQueue.concurrentPerform(iterations: group.count) { gi in
                if !fetchBatch(group[gi]) {
                    lock.lock(); failed.append(group[gi]); lock.unlock()
                }
            }
            i += 4
        }
        for b in failed { _ = fetchBatch(b) }   // 失败批重试一轮
        return result
    }
}

// MARK: - Squarified Treemap

enum Treemap {
    static func layout(values: [Double], in rect: CGRect) -> [CGRect] {
        guard !values.isEmpty, rect.width > 1, rect.height > 1 else { return values.map { _ in .zero } }
        let total = values.reduce(0, +)
        guard total > 0 else { return values.map { _ in .zero } }
        let scale = Double(rect.width * rect.height) / total
        let areas = values.map { $0 * scale }
        var result: [CGRect] = []
        var r = rect
        var i = 0
        while i < areas.count {
            let side = Double(min(r.width, r.height))
            var row: [Double] = []
            var rowSum = 0.0
            var bestWorst = Double.infinity
            var j = i
            while j < areas.count {
                let a = max(areas[j], 0.01)
                let worst = worstRatio(row + [a], rowSum + a, side)
                if !row.isEmpty && worst > bestWorst { break }
                row.append(a); rowSum += a; bestWorst = worst; j += 1
            }
            let vertical = r.width >= r.height   // 列铺在左侧
            let thickness = CGFloat(rowSum / side)
            var offset: CGFloat = 0
            for a in row {
                let len = CGFloat(a) / max(thickness, 0.0001)
                if vertical {
                    result.append(CGRect(x: r.minX, y: r.minY + offset, width: thickness, height: len))
                } else {
                    result.append(CGRect(x: r.minX + offset, y: r.minY, width: len, height: thickness))
                }
                offset += len
            }
            if vertical {
                r = CGRect(x: r.minX + thickness, y: r.minY, width: r.width - thickness, height: r.height)
            } else {
                r = CGRect(x: r.minX, y: r.minY + thickness, width: r.width, height: r.height - thickness)
            }
            i += row.count
        }
        return result
    }

    private static func worstRatio(_ row: [Double], _ sum: Double, _ side: Double) -> Double {
        guard let mx = row.max(), let mn = row.min(), sum > 0, side > 0, mn > 0 else { return .infinity }
        let s2 = sum * sum, w2 = side * side
        return max(w2 * mx / s2, s2 / (w2 * mn))
    }
}

// MARK: - 视图

struct MarketTile {
    let rect: CGRect
    let stock: MStock
}

struct MarketGroupTile {
    let rect: CGRect
    let name: String
}

struct MarketMapView: View {
    @EnvironmentObject var vm: MarketMapViewModel
    @EnvironmentObject var theme: ThemeManager
    @EnvironmentObject var fm: FontManager

    @State private var tiles: [MarketTile] = []
    @State private var groups: [MarketGroupTile] = []
    @State private var hoverStock: MStock? = nil
    @State private var hoverPoint: CGPoint = .zero
    @State private var mapSize: CGSize = .zero

    // 相机: 当前可视的世界区域(世界坐标 = 满幅布局坐标)
    @State private var camera: CGRect = .zero
    @State private var worldSize: CGSize = .zero
    @State private var lastMag: CGFloat = 1
    @State private var dragStartCamera: CGRect? = nil
    @State private var animTimer: Timer? = nil

    private var world: CGRect { CGRect(origin: .zero, size: worldSize) }
    private var zoomed: Bool { worldSize.width > 0 && camera.width < worldSize.width * 0.999 }

    var body: some View {
        VStack(spacing: 0) {
            header
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    Canvas { ctx, size in
                        draw(ctx: ctx, size: size)
                    }
                    if vm.stocks.isEmpty {
                        VStack(spacing: 12) {
                            ProgressView().controlSize(.large)
                            Text(vm.loading ? "全市场行情拉取中…" : (vm.statusText.isEmpty ? "暂无数据，点右上角刷新" : vm.statusText))
                                .font(fm.font(13))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                        .frame(width: geo.size.width, height: geo.size.height)
                    }
                    if let s = hoverStock {
                        tooltip(s)
                            .position(x: min(max(hoverPoint.x + 110, 110), geo.size.width - 110),
                                      y: max(hoverPoint.y - 52, 44))
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p):
                        hoverPoint = p
                        let wp = toWorld(p, geo.size)
                        hoverStock = tiles.last(where: { $0.rect.contains(wp) })?.stock
                    case .ended:
                        hoverStock = nil
                    }
                }
                // 触控板捏合缩放(以指针为锚点)
                .gesture(
                    MagnificationGesture()
                        .onChanged { v in
                            let f = v / lastMag
                            lastMag = v
                            zoom(by: f, at: hoverPoint, size: geo.size)
                        }
                        .onEnded { _ in lastMag = 1 }
                )
                // 拖拽平移(放大后)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { g in
                            guard zoomed else { return }
                            if dragStartCamera == nil { dragStartCamera = camera }
                            guard var c = dragStartCamera else { return }
                            c.origin.x -= g.translation.width * c.width / geo.size.width
                            c.origin.y -= g.translation.height * c.height / geo.size.height
                            camera = clampCamera(c)
                        }
                        .onEnded { _ in dragStartCamera = nil }
                )
                // 双击: 全景时聚焦行业块 / 放大态复位
                .onTapGesture(count: 2) { p in
                    if zoomed {
                        animateCamera(to: world)
                    } else {
                        let wp = toWorld(p, geo.size)
                        if let g = groups.first(where: { $0.rect.contains(wp) }) {
                            animateCamera(to: fitRect(g.rect.insetBy(dx: -3, dy: -3)))
                        }
                    }
                }
                .onChange(of: geo.size) { _, sz in mapSize = sz; relayout() }
                .onAppear { mapSize = geo.size; relayout() }
            }
            .background(Color(hex: "#1c1c22"))
        }
        .frame(minWidth: 900, minHeight: 620)
        .focusEffectDisabled()
        .background(ThemeBackground().environmentObject(theme).environmentObject(ThemeManager.shared))
        .onChange(of: vm.lastUpdate) { _, _ in relayout() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("大盘云图")
                .font(fm.font(18))
                .foregroundStyle(theme.current.accentGradient)
            ForEach(vm.indexes, id: \.name) { idx in
                VStack(alignment: .leading, spacing: 1) {
                    Text(idx.name).font(fm.font(10)).foregroundStyle(theme.current.textTertiary)
                    Text(String(format: "%.2f  %+.2f%%", idx.price, idx.pct))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(idx.pct >= 0 ? Color(hex: "#d94f4f") : Color(hex: "#2e9e5b"))
                }
            }
            Spacer()
            if zoomed {
                Button(action: { animateCamera(to: world) }) {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .font(.system(size: 9, weight: .bold))
                        Text("复位")
                    }
                    .font(fm.font(11))
                    .foregroundStyle(theme.current.accentPrimary)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(theme.current.accentPrimary.opacity(0.12)))
                }
                .buttonStyle(SmoothButtonStyle())
            }
            Text("涨\(vm.upCount) / 跌\(vm.downCount)")
                .font(fm.font(11))
                .foregroundStyle(theme.current.textTertiary)
            if let d = vm.lastUpdate {
                Text(d, style: .time)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(theme.current.textTertiary)
            }
            Button(action: { vm.refresh() }) {
                if vm.loading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.current.accentPrimary)
                }
            }
            .buttonStyle(SmoothButtonStyle())
            .disabled(vm.loading)
        }
        .padding(.leading, 84)   // 让出左上角红绿灯
        .padding(.trailing, 16)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private func tooltip(_ s: MStock) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(s.name).font(fm.font(14)).foregroundStyle(.white)
                Text(s.code).font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.55))
            }
            Text(String(format: "%.2f   %+.2f%%", s.price, s.pct))
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(s.pct >= 0 ? Color(hex: "#ff7b7b") : Color(hex: "#5fd08a"))
            Text("\(s.industry) · 流通市值 \(capText(s.cap))")
                .font(fm.font(10)).foregroundStyle(.white.opacity(0.6))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.82)))
        .frame(width: 220)
        .allowsHitTesting(false)
    }

    private func capText(_ v: Double) -> String {
        v >= 1e8 ? String(format: "%.0f亿", v / 1e8) : String(format: "%.0f万", v / 1e4)
    }

    // MARK: 相机变换

    private func toScreen(_ r: CGRect, _ size: CGSize) -> CGRect {
        let sx = size.width / camera.width, sy = size.height / camera.height
        return CGRect(x: (r.minX - camera.minX) * sx, y: (r.minY - camera.minY) * sy,
                      width: r.width * sx, height: r.height * sy)
    }

    private func toWorld(_ p: CGPoint, _ size: CGSize) -> CGPoint {
        guard camera.width > 0 else { return p }
        return CGPoint(x: camera.minX + p.x / size.width * camera.width,
                       y: camera.minY + p.y / size.height * camera.height)
    }

    private func clampCamera(_ c: CGRect) -> CGRect {
        var c = c
        let w = world
        guard w.width > 0 else { return c }
        // 尺寸钳制以中心为锚: 否则小目标命中30倍上限时会被顶到左上角而非居中
        let cx = c.midX, cy = c.midY
        c.size.width = min(max(c.width, w.width / 30), w.width)   // 最大放大30倍
        c.size.height = c.width * w.height / w.width
        c.origin.x = cx - c.width / 2
        c.origin.y = cy - c.height / 2
        // 放大状态允许相机越界半个视口: 边缘/角落的聚焦目标也能居中显示(越界部分为深色底)
        let zoomedIn = c.width < w.width * 0.98
        let mx = zoomedIn ? c.width * 0.5 : 0
        let my = zoomedIn ? c.height * 0.5 : 0
        c.origin.x = min(max(c.minX, w.minX - mx), w.maxX - c.width + mx)
        c.origin.y = min(max(c.minY, w.minY - my), w.maxY - c.height + my)
        return c
    }

    private func zoom(by f: CGFloat, at p: CGPoint, size: CGSize) {
        guard f.isFinite, f > 0, camera.width > 0 else { return }
        animTimer?.invalidate()
        let wp = toWorld(p, size)
        var c = camera
        c.size.width = c.width / f
        c.size.height = c.height / f
        c.origin.x = wp.x - p.x / size.width * c.width
        c.origin.y = wp.y - p.y / size.height * c.height
        camera = clampCamera(c)
    }

    private func fitRect(_ r: CGRect) -> CGRect {
        let w = world
        guard w.width > 0, w.height > 0 else { return r }
        let aspect = w.width / w.height
        var rw = r.width, rh = r.height
        if rw / rh > aspect { rh = rw / aspect } else { rw = rh * aspect }
        return clampCamera(CGRect(x: r.midX - rw / 2, y: r.midY - rh / 2, width: rw, height: rh))
    }

    private func animateCamera(to target: CGRect) {
        animTimer?.invalidate()
        let startC = camera
        let t0 = Date()
        let dur = 0.32
        let timer = Timer(timeInterval: 1.0 / 90.0, repeats: true) { tm in
            let t = min(Date().timeIntervalSince(t0) / dur, 1)
            let e = 1 - pow(1 - t, 3)   // easeOutCubic
            camera = CGRect(x: startC.minX + (target.minX - startC.minX) * e,
                            y: startC.minY + (target.minY - startC.minY) * e,
                            width: startC.width + (target.width - startC.width) * e,
                            height: startC.height + (target.height - startC.height) * e)
            if t >= 1 { tm.invalidate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        animTimer = timer
    }

    // MARK: 布局

    private func relayout() {
        guard mapSize.width > 10, mapSize.height > 10, !vm.stocks.isEmpty else { return }
        let full = CGRect(origin: .zero, size: mapSize).insetBy(dx: 2, dy: 2)
        var byInd: [String: [MStock]] = [:]
        for s in vm.stocks { byInd[s.industry, default: []].append(s) }
        let indList = byInd.map { (name: $0.key, cap: $0.value.reduce(0) { $0 + $1.cap }, items: $0.value.sorted { $0.cap > $1.cap }) }
            .sorted { $0.cap > $1.cap }
        let groupRects = Treemap.layout(values: indList.map { $0.cap }, in: full)
        var newTiles: [MarketTile] = []
        var newGroups: [MarketGroupTile] = []
        for (gi, ind) in indList.enumerated() {
            let gr = groupRects[gi]
            guard gr.width > 3, gr.height > 3 else { continue }
            newGroups.append(MarketGroupTile(rect: gr, name: ind.name))
            let titleH: CGFloat = (gr.width > 70 && gr.height > 44) ? 14 : 0
            let inner = CGRect(x: gr.minX + 1, y: gr.minY + 1 + titleH, width: gr.width - 2, height: gr.height - 2 - titleH)
            guard inner.width > 2, inner.height > 2 else { continue }
            let rects = Treemap.layout(values: ind.items.map { $0.cap }, in: inner)
            for (si, r) in rects.enumerated() where r.width > 1 && r.height > 1 {
                newTiles.append(MarketTile(rect: r, stock: ind.items[si]))
            }
        }
        tiles = newTiles
        groups = newGroups
        // 视图尺寸变化时重置相机, 数据刷新时保留缩放位置
        if worldSize != mapSize {
            worldSize = mapSize
            camera = CGRect(origin: .zero, size: mapSize)
        }
    }

    // MARK: 绘制

    private func color(for pct: Double) -> Color {
        let t = min(abs(pct) / 8.0, 1.0)
        if pct > 0 {
            return Color(red: 0.32 + 0.50 * t, green: 0.20 - 0.05 * t, blue: 0.19 - 0.04 * t)
        } else if pct < 0 {
            return Color(red: 0.11, green: 0.30 + 0.32 * t, blue: 0.20 + 0.12 * t)
        }
        return Color(red: 0.26, green: 0.27, blue: 0.30)
    }

    private func draw(ctx: GraphicsContext, size: CGSize) {
        guard camera.width > 0 else { return }
        let viewport = CGRect(origin: .zero, size: size)
        for t in tiles {
            let r = toScreen(t.rect, size)
            guard r.intersects(viewport) else { continue }
            ctx.fill(Path(r.insetBy(dx: 0.5, dy: 0.5)), with: .color(color(for: t.stock.pct)))
            if r.width > 52 && r.height > 30 {
                let fontSize = min(max(r.width / 8, 9), 16)
                var text = Text(t.stock.name).font(.system(size: fontSize, weight: .semibold)).foregroundStyle(.white)
                if r.height > 46 {
                    text = text + Text("\n" + String(format: "%+.2f%%", t.stock.pct))
                        .font(.system(size: fontSize - 1, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                }
                ctx.draw(text, in: r.insetBy(dx: 2, dy: 2))
            }
        }
        for g in groups {
            let r = toScreen(g.rect, size)
            guard r.intersects(viewport) else { continue }
            ctx.stroke(Path(r), with: .color(Color(hex: "#1c1c22")), lineWidth: 1.5)
            if r.width > 70 && r.height > 44 {
                let label = Text(g.name).font(.system(size: 10, weight: .bold)).foregroundStyle(Color(hex: "#c9b98a"))
                ctx.draw(label, in: CGRect(x: r.minX + 3, y: r.minY + 1, width: r.width - 6, height: 13))
            }
        }
    }
}

// MARK: - 窗口

final class MarketMapWindowController {
    static let shared = MarketMapWindowController()
    private var window: NSWindow?
    private let vm = MarketMapViewModel()

    func show() {
        vm.start()
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = MarketMapView()
            .environmentObject(vm)
            .environmentObject(ThemeManager.shared)
            .environmentObject(FontManager.shared)
        let host = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: host)
        win.title = "大盘云图"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.setContentSize(NSSize(width: 1280, height: 800))
        win.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
        win.isReleasedWhenClosed = false
        // 原生毛玻璃需要窗口透明才能透出桌面壁纸
        // 窗口透明度: 只在 nativeBlur 主题下透出桌面壁纸, 其它主题保持不透明避免顶栏透视
        let _needsTransparent = ThemeManager.shared.current.nativeBlur
        win.isOpaque = !_needsTransparent
        win.backgroundColor = _needsTransparent ? .clear : .windowBackgroundColor
        win.contentMinSize = NSSize(width: 720, height: 500)
        win.contentMaxSize = NSSize(width: 2600, height: 2200)
        win.setFrameAutosaveName("DBoardMarketMapWindow")
        win.collectionBehavior = [.moveToActiveSpace, .fullScreenPrimary]  // 跟随当前桌面 + 保留全屏能力(赋值会覆盖默认行为集)
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = win
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: win, queue: .main) { [weak self] _ in
            self?.vm.pause()   // 关窗停止轮询, 防止后台持续请求触发行情源封禁
        }
    }
}
