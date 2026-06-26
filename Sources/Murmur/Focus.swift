import ApplicationServices

// True when the system's focused UI element is an editable text input. Used to gate recording
// so the hotkeys only fire where dictated text can actually be typed. Relies on the Accessibility
// permission Murmur already holds.
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
              let focused else { return false }
        let element = focused as! AXUIElement

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        if let role = roleRef as? String, textRoles.contains(role) { return true }

        // Fallback: any element whose value can be set is an editable input
        // (covers search fields, web text areas, custom inputs).
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue { return true }
        return false
    }
}
