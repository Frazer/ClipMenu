import AppKit
import SwiftData
import SwiftUI

/// Lifecycle hooks that must live in an NSApplicationDelegate rather than the
/// SwiftUI App struct (e.g. applicationWillTerminate, Sparkle delegate).
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let runtime = AppRuntime.shared
    var statusItemController: StatusItemController?
    private let pasteHarnessWindowController = PasteHarnessWindowController()
    private let isPasteUITestMode = ProcessInfo.processInfo.environment["CLIPMENU_UI_TEST_MODE"] == "1"

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ensure persisted settings are hydrated and normalized before services read them.
        runtime.settings.reload()
        let statusItemController = StatusItemController(runtime: runtime)
        statusItemController.install(runtime: runtime)
        self.statusItemController = statusItemController

        if isPasteUITestMode {
            pasteHarnessWindowController.show(modelContainer: runtime.modelContainer)
            return
        }

        // Register global hotkeys immediately. This should not depend on
        // SwiftData container readiness.
        runtime.hotkeyService.register()

        do {
            try runtime.loginItemService.setEnabled(runtime.settings.launchAtLogin)
        } catch {
            // Keep startup resilient when login item registration fails.
        }

        startDataServicesWhenReady(retryCount: 10)
    }

    @MainActor
    private func startDataServicesWhenReady(retryCount: Int) {
        guard let modelContext = runtime.modelContainer?.mainContext else {
            guard retryCount > 0 else { return }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 100_000_000)
                startDataServicesWhenReady(retryCount: retryCount - 1)
            }
            return
        }

        if LegacyMigration.isNeeded {
            LegacyMigration.run(in: modelContext)
        }

        Task {
            runtime.clipsService.start(context: modelContext)
            await runtime.snippetService.start(context: modelContext)
            await runtime.actionService.start(context: modelContext)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        runtime.hotkeyService.unregister()
        Task {
            runtime.clipsService.stop()
        }
    }
}

@MainActor
private final class PasteHarnessWindowController: NSWindowController, NSWindowDelegate {
    func show(modelContainer: ModelContainer?) {
        let window = window ?? makeWindow()
        let rootView = makeHarnessView(modelContainer: modelContainer)
        window.contentViewController = NSHostingController(rootView: rootView)

        NSRunningApplication.current.activate(options: [.activateAllWindows])
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentViewController = nil
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Paste Integration"
        window.contentMinSize = NSSize(width: 1100, height: 820)
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
        return window
    }

    private func makeHarnessView(modelContainer: ModelContainer?) -> AnyView {
        let rootView = PasteIntegrationHarnessView()

        if let modelContainer {
            return AnyView(rootView.modelContainer(modelContainer))
        }

        return AnyView(rootView)
    }
}

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private weak var runtime: AppRuntime?
    private let menu = NSMenu(title: "ClipMenu")

    init(runtime: AppRuntime) {
        self.runtime = runtime
        super.init()
        menu.delegate = self
        statusItem.menu = menu
    }

    func install(runtime: AppRuntime) {
        self.runtime = runtime

        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "clipboard.fill", accessibilityDescription: "ClipMenu")
        button.image?.isTemplate = true

        // Set RTL once so submenus always open to the left. Done here rather than
        // in menuNeedsUpdate to avoid triggering a re-call while the menu is live.
        // Native LTR alignment provides correct text flow
    }

    func openMenuForTesting() {
        menu.cancelTrackingWithoutAnimation()
        menu.removeAllItems()
        menuNeedsUpdate(menu)

        if let button = statusItem.button {
            button.performClick(nil)
        } else {
            statusItem.popUpMenu(menu)
        }
    }

    func openMenuForTestingAsync() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            self.runtime?.hotkeyService.presentStatusMenuForTesting()
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // macOS re-calls menuNeedsUpdate while the menu is being tracked (e.g. when
        // a submenu is about to open). Guard against mid-tracking rebuilds: removeAllItems()
        // while the menu is live causes it to briefly blank out, appearing to disappear.
        // Items are cleared in menuDidClose so the next genuine open triggers a fresh build.
        guard menu.numberOfItems == 0 else { return }
        guard let runtime, let freshMenu = runtime.hotkeyService.makeStatusMenu(buttonMaxX: statusButtonMaxX) else { return }

        while !freshMenu.items.isEmpty {
            let item = freshMenu.items[0]
            freshMenu.removeItem(item)
            menu.addItem(item)
        }

        runtime.hotkeyService.prepareStatusMenuPreview(menu)
    }

    private var statusButtonMaxX: CGFloat {
        guard let button = statusItem.button, let window = button.window else {
            return NSScreen.main?.visibleFrame.maxX ?? 1440
        }
        return window.convertToScreen(button.frame).maxX
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        runtime?.hotkeyService.statusMenu(menu, willHighlight: item)
    }

    func menuDidClose(_ menu: NSMenu) {
        runtime?.hotkeyService.statusMenuDidClose(menu)
        menu.removeAllItems()  // Reset so menuNeedsUpdate rebuilds fresh on next open
    }
}
