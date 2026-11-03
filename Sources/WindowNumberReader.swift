import SwiftUI
import AppKit

struct WindowNumberReader: NSViewRepresentable {
    let onWindow: (Int?) -> Void
    final class ReaderView: NSView {
        var onWindow: ((Int?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.onWindow?(self?.window?.windowNumber) }
        }
    }
    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onWindow = onWindow
        return view
    }
    func updateNSView(_ view: ReaderView, context: Context) { view.onWindow = onWindow }
}
