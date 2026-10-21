import AppKit

/// Shared accessory application instance that owns the menu-bar event loop.
let application = NSApplication.shared

/// Strong delegate reference retained for the full process lifetime.
let applicationDelegate = AppDelegate()

application.delegate = applicationDelegate
application.run()
