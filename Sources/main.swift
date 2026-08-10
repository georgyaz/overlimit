import Cocoa

// Entry point. Top-level code must live in main.swift once the target
// consists of more than one file.
let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.run()
