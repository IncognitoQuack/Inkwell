import AppKit

/// Modal password dialogs. Passwords live only in memory for as long as the notebook is open.
enum PasswordPrompt {
    /// Asks for an existing password. Returns nil if cancelled.
    static func ask(title: String, message: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Password"
        alert.accessoryView = field
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    /// Asks for a new password twice. Returns nil if cancelled; re-asks until both match and are long enough.
    static func choose(title: String) -> String? {
        var note = "There is no way to recover a forgotten password: write it down somewhere safe."
        while true {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = note
            let a = NSSecureTextField(frame: NSRect(x: 0, y: 30, width: 260, height: 24))
            a.placeholderString = "New password (at least 4 characters)"
            let b = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            b.placeholderString = "Repeat password"
            let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 54))
            box.addSubview(a)
            box.addSubview(b)
            alert.accessoryView = box
            alert.addButton(withTitle: "Lock")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = a
            a.nextKeyView = b
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            if a.stringValue.count < 4 { note = "The password must be at least 4 characters."; continue }
            if a.stringValue != b.stringValue { note = "The two passwords don’t match. Please try again."; continue }
            return a.stringValue
        }
    }
}
