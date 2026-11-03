import Foundation
import Dispatch
import Darwin

/// 每个 source 独占并关闭自己的 fd；原子替换重绑，文件暂时不存在由低频巡检恢复。
final class FileRefreshObserver {
    private let url: URL
    private let changed: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var timer: Timer?
    private var refresh: DispatchWorkItem?
    private var signature: String?

    init(url: URL, interval: TimeInterval = 15, changed: @escaping () -> Void) {
        self.url = url; self.changed = changed
        signature = currentSignature()
        bind()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.check() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func currentSignature() -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return "\(attributes[.systemFileNumber] ?? ""):\(attributes[.size] ?? ""):\(attributes[.modificationDate] ?? "")"
    }

    private func bind() {
        source?.cancel(); source = nil
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let next = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        next.setCancelHandler { close(fd) }
        next.setEventHandler { [weak self] in
            guard let self else { return }
            self.refresh?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.signature = self.currentSignature()
                self.bind()
                self.changed()
            }
            self.refresh = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }
        source = next
        next.resume()
    }

    func check() {
        let value = currentSignature()
        guard value != signature else { if source == nil { bind() }; return }
        signature = value
        bind()
        changed()
    }

    deinit { refresh?.cancel(); timer?.invalidate(); source?.cancel() }
}
