import Cocoa
import Carbon.HIToolbox

/// 全局快捷键（Carbon RegisterEventHotKey，无第三方依赖）
///
/// 关键: 所有实例共享同一个事件 handler, 按 EventHotKeyID 分发回调。
/// 早期版本每个实例各装一个 handler 且不检查 ID —— Carbon 事件被第一个
/// handler 以 noErr 吞掉后不再传递, 导致多快捷键并存时只有最后/最先注册
/// 的那个生效(⌥V 失效的根因)。
func centerWindowOnMouseScreen(_ window: NSWindow) {
    let mouse = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens.first
    guard let visibleFrame = screen?.visibleFrame else { return }
    var frame = window.frame
    frame.size.width = min(frame.size.width, visibleFrame.width)
    frame.size.height = min(frame.size.height, visibleFrame.height)
    frame.origin.x = visibleFrame.midX - frame.width / 2
    frame.origin.y = visibleFrame.midY - frame.height / 2
    window.setFrame(frame, display: false)
}

final class HotKey {
    private static var nextId: UInt32 = 1
    private static var registry: [UInt32: () -> Void] = [:]
    private static var sharedHandler: EventHandlerRef?
    private static let signature = OSType(0x4453424F) // "DSBO"

    private var hotKeyRef: EventHotKeyRef?
    private var registeredId: UInt32?
    private var keyCode: UInt32 = 0
    private var modifiers: UInt32 = 0

    /// 注册是否已生效(调试面板自查用)
    var isRegistered: Bool { hotKeyRef != nil }

    /// 注册全局快捷键
    /// - Parameters:
    ///   - keyCode: 虚拟键码（如 kVK_ANSI_V = 9）
    ///   - modifiers: Carbon 修饰键掩码（controlKey / cmdKey / shiftKey / optionKey）
    ///   - callback: 触发回调（主线程）
    func register(keyCode: UInt32, modifiers: UInt32, callback: @escaping () -> Void) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        Self.installSharedHandlerOnce()

        let id = HotKey.nextId
        HotKey.nextId += 1
        HotKey.registry[id] = callback
        registeredId = id
        tryRegister(attempts: 6)
    }

    private func tryRegister(attempts: Int) {
        guard let registeredId else { return }
        let hotKeyId = EventHotKeyID(signature: HotKey.signature, id: registeredId)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyId,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        if status == noErr { return }
        hotKeyRef = nil
        guard attempts > 1 else {
            NSLog("HotKey: register failed status=\(status) keyCode=\(keyCode) modifiers=\(modifiers)")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, self.hotKeyRef == nil else { return }
            self.tryRegister(attempts: attempts - 1)
        }
    }

    /// 共享 handler: 从事件里取 EventHotKeyID, 查注册表分发; 未命中返回 eventNotHandledErr
    private static func installSharedHandlerOnce() {
        guard sharedHandler == nil else { return }
        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, eventRef, _) -> OSStatus in
                guard let eventRef else { return OSStatus(eventNotHandledErr) }
                var hotKeyId = EventHotKeyID()
                let err = GetEventParameter(eventRef,
                                            EventParamName(kEventParamDirectObject),
                                            EventParamType(typeEventHotKeyID),
                                            nil,
                                            MemoryLayout<EventHotKeyID>.size,
                                            nil,
                                            &hotKeyId)
                guard err == noErr, let cb = HotKey.registry[hotKeyId.id] else {
                    return OSStatus(eventNotHandledErr)
                }
                cb()
                return noErr
            },
            1,
            &eventSpec,
            nil,
            &sharedHandler
        )
    }

    deinit {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        if let id = registeredId { HotKey.registry[id] = nil }
    }
}
