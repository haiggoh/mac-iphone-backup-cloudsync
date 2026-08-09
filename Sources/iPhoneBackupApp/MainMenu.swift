import AppKit

/// Builds the application menu.
///
/// A bare `NSApplication` created in code has **no main menu at all**. The app name
/// still appears in the menu bar, so it looks present, but clicking it opens nothing
/// — no About, no Quit, and, less obviously, no Cmd-Q, Cmd-W or Cmd-C, because those
/// shortcuts are delivered by menu items rather than by the window. That was true of
/// the original single-file version too; it was never a regression, just a gap that
/// only shows up when someone reaches for the menu.
enum MainMenu {

    static func install(applicationName: String, showSettings: Selector?) {
        let mainMenu = NSMenu()

        mainMenu.addItem(applicationMenuItem(
            applicationName: applicationName, showSettings: showSettings))
        // Edit exists purely so the standard text shortcuts work. Without it, Cmd-C
        // in any future text field silently does nothing.
        mainMenu.addItem(editMenuItem())
        mainMenu.addItem(windowMenuItem())

        NSApp.mainMenu = mainMenu
    }

    private static func applicationMenuItem(
        applicationName: String, showSettings: Selector?
    ) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu()

        menu.addItem(
            withTitle: L("menu.about", applicationName),
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: "")

        if let showSettings {
            menu.addItem(.separator())
            let settings = NSMenuItem(
                title: L("menu.settings"), action: showSettings, keyEquivalent: ",")
            // Cmd-, is the platform convention; users try it before they look.
            settings.keyEquivalentModifierMask = [.command]
            menu.addItem(settings)
        }

        menu.addItem(.separator())
        menu.addItem(
            withTitle: L("menu.hide", applicationName),
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h")
        menu.addItem(
            withTitle: L("menu.hideOthers"),
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "")
        menu.addItem(
            withTitle: L("menu.showAll"),
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: "")

        menu.addItem(.separator())
        menu.addItem(
            withTitle: L("menu.quit", applicationName),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")

        item.submenu = menu
        return item
    }

    private static func editMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: L("menu.edit"))

        menu.addItem(withTitle: L("menu.cut"),
                     action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: L("menu.copy"),
                     action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: L("menu.paste"),
                     action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: L("menu.selectAll"),
                     action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        item.submenu = menu
        return item
    }

    private static func windowMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: L("menu.window"))

        menu.addItem(withTitle: L("menu.minimize"),
                     action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: L("menu.close"),
                     action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        item.submenu = menu
        NSApp.windowsMenu = menu
        return item
    }
}

/// Opens the System Settings pane a user needs, rather than describing where it is.
enum SystemSettingsLink {

    /// Privacy & Security → Full Disk Access.
    ///
    /// Needed because Full Disk Access is **not** a promptable permission: macOS
    /// shows no allow/deny dialog for `kTCCServiceSystemPolicyAllFiles`, it simply
    /// denies the read. An app that waits for a prompt that will never come leaves
    /// the user stuck, so the only reliable design is to detect the denial and take
    /// them there.
    static func openFullDiskAccess() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }
}
