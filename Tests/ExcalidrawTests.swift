import XCTest
import AppKit
import WebKit
import Carbon.HIToolbox
@testable import DBoard

final class ExcalidrawTests: XCTestCase {
    private func fixture() -> [String: Any] {
        ["type": "excalidraw", "version": 2, "source": "original-source", "customRoot": ["keep": true],
         "elements": [["id": "one", "type": "rectangle", "x": 20, "y": 20, "width": 120, "height": 80,
                       "customField": "retain"], ["id": "two", "type": "rectangle", "x": 200]],
         "appState": ["viewBackgroundColor": "#ffffff", "customState": "retain", "scrollX": 123],
         "files": ["image": ["id": "image", "dataURL": "data:image/png;base64,abc"]]]
    }
    private func json(_ scene: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: scene, options: [.prettyPrinted, .sortedKeys])
    }
    private func temporaryFile(_ scene: [String: Any]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".excalidraw")
        try json(scene).write(to: url); addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testRoutingRejectsWebAndUnrelatedFiles() {
        XCTAssertTrue(ExcalidrawDocument.handles(URL(fileURLWithPath: "/tmp/map.EXCALIDRAW")))
        XCTAssertFalse(ExcalidrawDocument.handles(URL(string: "https://example.com/map.excalidraw")!))
        XCTAssertFalse(ExcalidrawDocument.handles(URL(fileURLWithPath: "/tmp/map.svg")))
    }
    func testBlankDrawingStaysInMemoryUntilFirstSave() throws {
        let document = ExcalidrawDocument()
        XCTAssertTrue(document.isUntitled)
        XCTAssertFalse(document.url.isFileURL)
        XCTAssertEqual((document.original["elements"] as? [[String: Any]])?.count, 0)
        let snapshot = String(decoding: try json(document.original), as: UTF8.self)
        try document.recordRestoredSnapshot(snapshot)
        XCTAssertThrowsError(try document.save(snapshot: snapshot))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".excalidraw")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(try document.save(snapshot: snapshot, to: url))
        XCTAssertFalse(document.isUntitled)
        XCTAssertEqual(document.url, url)
        XCTAssertEqual((try ExcalidrawDocument(url: url).original["elements"] as? [[String: Any]])?.count, 0)
        XCTAssertFalse(try document.save(snapshot: snapshot))
    }
    func testFirstSaveCannotOverwriteUnapprovedOrChangedDestination() throws {
        let url = try temporaryFile(fixture()), before = try Data(contentsOf: url)
        let document = ExcalidrawDocument()
        let snapshot = String(decoding: try json(document.original), as: UTF8.self)
        XCTAssertThrowsError(try document.save(snapshot: snapshot, to: url))
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertTrue(try document.save(snapshot: snapshot, to: url, expectedDestinationData: before))
        XCTAssertFalse(document.isUntitled)
    }
    func testRejectsInvalidOrFutureSceneWithoutWriting() throws {
        for scene: [String: Any] in [
            ["type": "other", "version": 2, "elements": []],
            ["type": "excalidraw", "version": 99, "elements": []],
            ["type": "excalidraw", "version": 2, "elements": [["id": "one"]]],
            ["type": "excalidraw", "version": 2, "elements": [], "files": "bad"]
        ] {
            let url = try temporaryFile(scene), before = try Data(contentsOf: url)
            XCTAssertThrowsError(try ExcalidrawDocument(url: url))
            XCTAssertEqual(try Data(contentsOf: url), before)
        }
    }
    func testRestorationAndViewChangesDoNotRewriteOriginal() throws {
        let url = try temporaryFile(fixture()), before = try Data(contentsOf: url)
        let document = try ExcalidrawDocument(url: url)
        var normalized = fixture()
        var elements = normalized["elements"] as! [[String: Any]]
        elements[0]["version"] = 1; elements[0].removeValue(forKey: "customField")
        normalized["elements"] = elements
        normalized["appState"] = ["viewBackgroundColor": "#ffffff", "scrollX": -100, "zoom": ["value": 0.5]]
        normalized["files"] = [:]
        let snapshot = String(decoding: try json(normalized), as: UTF8.self)
        try document.recordRestoredSnapshot(snapshot)
        XCTAssertFalse(try document.save(snapshot: snapshot))
        XCTAssertEqual(try Data(contentsOf: url), before)
    }
    func testEditSavePreservesUntouchedElementsCustomFieldsAndImages() throws {
        let url = try temporaryFile(fixture()), document = try ExcalidrawDocument(url: url)
        try document.recordRestoredSnapshot(String(decoding: try json(fixture()), as: UTF8.self))
        var edited = fixture()
        var elements = edited["elements"] as! [[String: Any]]
        elements[0]["x"] = 99; elements[0].removeValue(forKey: "customField")
        elements[1]["isDeleted"] = true
        edited["elements"] = elements
        edited["appState"] = ["viewBackgroundColor": "#eeeeee", "scrollX": -888]
        edited["files"] = [:]
        XCTAssertTrue(try document.save(snapshot: String(decoding: try json(edited), as: UTF8.self)))
        let saved = try ExcalidrawDocument.parse(Data(contentsOf: url))
        let savedElements = saved["elements"] as! [[String: Any]]
        XCTAssertEqual(savedElements[0]["x"] as? Int, 99)
        XCTAssertEqual(savedElements[0]["customField"] as? String, "retain")
        XCTAssertEqual(savedElements[1]["isDeleted"] as? Bool, true)
        XCTAssertEqual(saved["source"] as? String, "original-source")
        XCTAssertNotNil(saved["customRoot"])
        XCTAssertEqual((saved["appState"] as? [String: Any])?["customState"] as? String, "retain")
        XCTAssertEqual((saved["appState"] as? [String: Any])?["scrollX"] as? Int, 123)
        XCTAssertNotNil((saved["files"] as? [String: Any])?["image"])
    }
    func testRefusesOverwriteWhenAnotherProgramChangesFile() throws {
        let url = try temporaryFile(fixture()), document = try ExcalidrawDocument(url: url)
        var other = fixture(); other["source"] = "another editor"
        let disk = try json(other); try disk.write(to: url)
        XCTAssertThrowsError(try document.save(snapshot: String(decoding: try json(fixture()), as: UTF8.self)))
        XCTAssertEqual(try Data(contentsOf: url), disk)
    }

    @MainActor
    func testCommandWClosesCleanCanvasWithWebViewFocusedAndKeepsOtherWindowOpen() throws {
        _ = NSApplication.shared
        let controller = ExcalidrawWindowController(document: ExcalidrawDocument(), activates: false)
        controller.show()
        let other = NSWindow(contentRect: NSRect(x: -10000, y: 0, width: 300, height: 200),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        other.orderBack(nil)
        defer { controller.window.close(); other.close() }
        let deadline = Date().addingTimeInterval(10)
        while !controller.isReady && controller.lastError == nil && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(controller.isReady, controller.lastError ?? "Editor should load")
        controller.window.makeFirstResponder(controller.webView)
        var closed = false
        controller.onClose = { closed = true }
        XCTAssertTrue(controller.window.performKeyEquivalent(with: commandW(controller.window)))
        XCTAssertTrue(closed)
        XCTAssertFalse(controller.window.isVisible)
        XCTAssertTrue(other.isVisible, "Closing the canvas must keep the other window open")
    }
    @MainActor private func commandW(_ window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: 1, windowNumber: window.windowNumber, context: nil, characters: "w",
            charactersIgnoringModifiers: "w", isARepeat: false, keyCode: UInt16(kVK_ANSI_W))!
    }

    @MainActor
    func testOfflineEditorLoadsChineseMapAndRoundTripsWithoutChangingSource() throws {
        _ = NSApplication.shared
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = project.appendingPathComponent("LearningMaps/T007/ai-model-knowledge-map.excalidraw")
        let original = try Data(contentsOf: source)
        let scene = try ExcalidrawDocument.parse(original)
        let url = try temporaryFile(scene), before = try Data(contentsOf: url)
        let controller = ExcalidrawWindowController(document: try ExcalidrawDocument(url: url), activates: false,
            resources: project.appendingPathComponent("Resources/ExcalidrawEditor"))
        controller.show()
        defer { controller.window.close() }
        let deadline = Date().addingTimeInterval(25)
        while !controller.isReady && controller.lastError == nil && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        if !controller.isReady {
            let detail = try? evaluate(controller.webView, "JSON.stringify({bridge:!!window.dboardDrawing,canvas:!!document.querySelector('canvas'),text:document.body.innerText.slice(0,1500)})")
            XCTFail(controller.lastError ?? String(describing: detail))
        }
        guard controller.isReady else { return }
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        XCTAssertFalse(controller.isDirty)
        let loaded = try snapshot(controller)
        let loadedScene = try ExcalidrawDocument.parse(Data(loaded.json.utf8))
        let elements = loadedScene["elements"] as! [[String: Any]]
        XCTAssertEqual(elements.filter { $0["isDeleted"] as? Bool != true }.count, 46)
        XCTAssertTrue(elements.contains { ($0["text"] as? String)?.contains("结构与能力") == true })
        XCTAssertEqual(try evaluate(controller.webView, "!!document.querySelector('canvas')") as? Bool, true)
        let saved = expectation(description: "Save completed")
        controller.save { success in XCTAssertTrue(success); saved.fulfill() }
        wait(for: [saved], timeout: 10)
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(try Data(contentsOf: source), original)

        if let folder = ProcessInfo.processInfo.environment["DBOARD_EXCALIDRAW_SNAPSHOTS"] {
            let done = expectation(description: "Canvas snapshot")
            controller.webView.takeSnapshot(with: nil) { image, error in
                XCTAssertNil(error)
                if let image, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                   let png = bitmap.representation(using: .png, properties: [:]) {
                    try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
                    try? png.write(to: URL(fileURLWithPath: folder + "/editor.png"))
                }
                done.fulfill()
            }
            wait(for: [done], timeout: 8)
        }
        // Exercise the real editor's select-all and delete shortcuts, then save the source.
        _ = try evaluate(controller.webView, """
            document.querySelector('.excalidraw').focus();
            document.querySelector('.excalidraw').dispatchEvent(new KeyboardEvent('keydown', {
              key:'a', code:'KeyA', keyCode:65, metaKey:true, bubbles:true, cancelable:true}));
            true
            """)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        _ = try evaluate(controller.webView, """
            document.querySelector('.excalidraw').dispatchEvent(new KeyboardEvent('keydown', {
              key:'Delete', code:'Delete', keyCode:46, bubbles:true, cancelable:true}));
            true
            """)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertTrue(controller.isDirty, "Actual keyboard edit should mark the scene dirty")
        controller.window.makeFirstResponder(controller.webView)
        XCTAssertTrue(controller.window.performKeyEquivalent(with: commandW(controller.window)))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let sheet = try XCTUnwrap(controller.window.attachedSheet, "Unsaved edits need a close decision")
        controller.window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(controller.window.isVisible)
        XCTAssertTrue(controller.isDirty)
        let edited = try snapshot(controller)
        let editedScene = try ExcalidrawDocument.parse(Data(edited.json.utf8))
        let changedElements = editedScene["elements"] as! [[String: Any]]
        XCTAssertTrue(changedElements.contains { $0["isDeleted"] as? Bool == true })
        let changed = expectation(description: "Edited scene saved")
        controller.save { success in XCTAssertTrue(success); changed.fulfill() }
        wait(for: [changed], timeout: 10)
        XCTAssertNotEqual(try Data(contentsOf: url), before)
        let reopened = try ExcalidrawDocument(url: url)
        XCTAssertTrue((reopened.original["elements"] as! [[String: Any]]).contains { $0["isDeleted"] as? Bool == true })
        XCTAssertEqual(try Data(contentsOf: source), original)
    }
    @MainActor private func snapshot(_ controller: ExcalidrawWindowController) throws -> ExcalidrawWindowController.Snapshot {
        let done = expectation(description: "Editor snapshot"); var result: Result<ExcalidrawWindowController.Snapshot, Error>?
        controller.snapshot { result = $0; done.fulfill() }; wait(for: [done], timeout: 8)
        return try XCTUnwrap(result).get()
    }
    @MainActor private func evaluate(_ web: WKWebView, _ script: String) throws -> Any? {
        let done = expectation(description: "JavaScript"); var value: Any?; var failure: Error?
        web.evaluateJavaScript(script) { value = $0; failure = $1; done.fulfill() }; wait(for: [done], timeout: 8)
        if let failure { throw failure }; return value
    }
}
