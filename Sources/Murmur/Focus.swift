import ApplicationServices

// True when the system's focused UI element is an editable text input. Used to gate recording
// so the hotkeys only fire where dictated text can be typed. Relies on the Accessibility
// permission Murmur already holds.
//
// Deliberately fail-OPEN: if the focused element can't be inspected (many apps and web views
// don't expose it), we allow recording rather than block a real text field.
enum FocusInspector {
    private static let textRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String,
    ]

    static func isTextInputFocused() -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return true } // can't tell → allow
        let element = focused as! AXUIElement

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        if let role = roleRef as? String, textRoles.contains(role) { return true }

        // Strong signal: every editable text control exposes a selected-text range.
        var selectedRange: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selectedRange) == .success {
            return true
        }

        // Editable if its value can be set (search fields, web inputs, custom controls).
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue {
            return true
        }
        return false
    }
}
