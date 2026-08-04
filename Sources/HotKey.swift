import Cocoa
import Carbon.HIToolbox

/// 全局快捷键（Carbon RegisterEventHotKey，无第三方依赖）
final class HotKey {
    static let shared = HotKey()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var callback: (() -> Void)?

    /// 注册全局快捷键
    /// - Parameters:
    ///   - keyCode: 虚拟键码（如 kVK_D = 2）
    ///   - modifiers: 修饰键掩码（Carbon: controlKey / cmdKey / shiftKey / optionKey）
    ///   - callback: 触发回调
    func register(keyCode: UInt32, modifiers: UInt32, callback: @escaping () -> Void) {
        self.callback = callback

        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, eventRef, userData) -> OSStatus in
                guard let userData = userData else { return noErr }
                let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
                hotKey.callback?()
                return noErr
            },
            1,
            &eventSpec,
            selfPtr,
            &eventHandler
        )

        let hotKeyId = EventHotKeyID(signature: OSType(0x4453424F), id: 1)  // "DSBO"
        RegisterEventHotKey(keyCode, modifiers, hotKeyId, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    deinit {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        if let handler = eventHandler { RemoveEventHandler(handler) }
    }
}
