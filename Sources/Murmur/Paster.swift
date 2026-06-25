import AppKit

// Inserts text at the current cursor by writing to the pasteboard and synthesizing ⌘V,
// then restoring the previous clipboard. Requires Accessibility permission to post events.
enum Paster {
    private static let pasteboard = NSPasteboard.general

    static func paste(_ text: String) {
        let saved = snapshot()   // preserve ALL clipboard contents (text, images, files…)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        synthesizeCommandV()

        // Restore the user's clipboard once the paste has landed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
        }
    }

    private static func snapshot() -> [NSPasteboardItem] {
        guard let items = pasteboard.pasteboardItems else { return [] }
        return items.map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    private static func synthesizeCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 0x09 // 'v'

        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        up?.flags = .maskCommand

        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
