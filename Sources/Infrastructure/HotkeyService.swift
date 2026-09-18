import AppKit
import ApplicationServices
import KeyboardShortcuts
import Foundation
import os
import SwiftData
import SwiftUI
import CoreGraphics
import ObjectiveC

extension Notification.Name {
    static let clipMenuHighlightDidChange = Notification.Name("ClipMenu.highlightDidChange")
    static let clipMenuPreviewDidShow = Notification.Name("ClipMenu.previewDidShow")
    static let clipMenuPreviewDidHide = Notification.Name("ClipMenu.previewDidHide")
}

// MARK: - Shortcut Names

extension KeyboardShortcuts.Name {
    /// Opens the main clipboard history + snippets menu (legacy: "ClipMenu", Cmd+Shift+V).
    static let openClipMenu = Self("openClipMenu",
                                   default: .init(.v, modifiers: [.command, .shift]))
    /// Opens the history-only view (legacy: "HistoryMenu", Cmd+Ctrl+V).
    static let openHistory  = Self("openHistory",
                                   default: .init(.v, modifiers: [.command, .control]))
    /// Opens the snippets view (legacy: "SnippetsMenu", Cmd+Shift+B).
    static let openSnippets = Self("openSnippets",
                                   default: .init(.b, modifiers: [.command, .shift]))
    /// Opens the actions menu for the most recent clip (Cmd+Shift+A).
    static let openActions = Self("openActions",
                                  default: .init(.a, modifiers: [.command, .shift]))
}

// MARK: - HotkeyService

/// Registers and unregisters global keyboard shortcuts using the
/// `KeyboardShortcuts` package.
///
/// Default key combos mirror `legacy/Source/AppController.m
/// +_defaultHotKeyCombos` (keyCode 9 = V, 11 = B; modifiers 768 = ⌘⇧,
/// 4352 = ⌘⌃).
final class HotkeyService {
    fileprivate static let log = Logger(subsystem: "com.naotaka.ClipMenu", category: "Hotkeys")
    @MainActor private lazy var popupMenu = HotkeyPopupMenuPresenter()

    func register() {
        Self.log.info("Registering global shortcuts")
        ensureDefaultShortcutsIfMissing()
        ClipMenuFilterKeyHook.prepareAtLaunch()

        // Trigger on key-up to avoid interacting with the menu while modifier
        // keys are still held down.
        KeyboardShortcuts.onKeyUp(for: .openClipMenu) { [weak self] in self?.presentFromHotkey(name: "openClipMenu", kind: .main) }
        KeyboardShortcuts.onKeyUp(for: .openHistory)  { [weak self] in self?.presentFromHotkey(name: "openHistory", kind: .history) }
        KeyboardShortcuts.onKeyUp(for: .openSnippets) { [weak self] in self?.presentFromHotkey(name: "openSnippets", kind: .snippets) }
        KeyboardShortcuts.onKeyUp(for: .openActions)  { [weak self] in self?.presentFromHotkey(name: "openActions", kind: .actions) }
    }

    func unregister() {
        Self.log.info("Unregistering global shortcuts")
        KeyboardShortcuts.removeAllHandlers()
    }

    @MainActor
    func makeStatusMenu(buttonMaxX: CGFloat? = nil) -> NSMenu? {
        popupMenu.statusMenu(using: AppRuntime.shared, buttonMaxX: buttonMaxX)
    }

    @MainActor
    func prepareStatusMenuPreview(_ menu: NSMenu) {
        popupMenu.prepareStatusMenuPreview(menu)
    }

    @MainActor
    func applyStatusMenuDirection(to menu: NSMenu) {
        // Obsolete (Native LTR layout handles text alignment beautifully alongside consistent minimumWidth locking)
    }

    @MainActor
    func statusMenu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        popupMenu.menu(menu, willHighlight: item)
    }

    @MainActor
    func statusMenuWillOpen(_ menu: NSMenu) {
        popupMenu.beginSlashKeyMonitorForOpenMenu()
    }

    @MainActor
    func statusMenuDidClose(_ menu: NSMenu) {
        popupMenu.menuDidClose(menu)
    }

    @MainActor
    func presentMainMenuForTesting() {
        popupMenu.show(using: AppRuntime.shared, kind: .main)
    }

    @MainActor
    func presentStatusMenuForTesting() {
        popupMenu.showStatusMenuForTesting(using: AppRuntime.shared)
    }

    @MainActor
    func showStatusMenuPreviewForTesting(_ menu: NSMenu) {
        popupMenu.showPreviewForTesting(in: menu)
    }

    @MainActor
    func showPreviewForTesting(_ clip: ClipEntry, at point: NSPoint) {
        popupMenu.showPreviewForTesting(clip, at: point)
    }

    // MARK: - Private

    private func ensureDefaultShortcutsIfMissing() {
        let names: [KeyboardShortcuts.Name] = [.openClipMenu, .openHistory, .openSnippets, .openActions]

        for name in names {
            // KeyboardShortcuts can persist disabled shortcuts as `nil`.
            // Restore the built-in default when no active shortcut exists.
            if KeyboardShortcuts.getShortcut(for: name) == nil,
               let fallback = name.defaultShortcut {
                Self.log.notice("Restoring missing shortcut for \(name.rawValue, privacy: .public)")
                KeyboardShortcuts.setShortcut(fallback, for: name)
            }
        }
    }

    private func presentFromHotkey(name: String, kind: HotkeyMenuKind) {
        Self.log.info("Hotkey triggered: \(name, privacy: .public)")
        DispatchQueue.main.async {
            // Single hotkey UX path: always show the native popup menu.
            self.popupMenu.show(using: AppRuntime.shared, kind: kind)
        }
    }
}

private enum HotkeyMenuKind {
    case main
    case history
    case snippets
    case actions
}

private enum PreviewSide {
    case left
    case right

    var flipped: PreviewSide { self == .left ? .right : .left }
}

// MARK: - Clip / snippet menu filtering

private enum ClipMenuFilter {
    static func apply(query: String, imagesOnly: Bool, to rootMenu: NSMenu) {
        resetVisibility(in: rootMenu)
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty || imagesOnly else { return }
        applyRecursive(to: rootMenu, query: q, imagesOnly: imagesOnly)
        trimRedundantSeparators(in: rootMenu)
    }

    private static func resetVisibility(in menu: NSMenu) {
        for item in menu.items {
            item.isHidden = false
            if let sub = item.submenu {
                resetVisibility(in: sub)
            }
        }
    }

    private static func applyRecursive(to menu: NSMenu, query: String, imagesOnly: Bool) {
        for item in menu.items {
            if let sub = item.submenu {
                applyRecursive(to: sub, query: query, imagesOnly: imagesOnly)
                let anyVisible = sub.items.contains { !$0.isHidden && !$0.isSeparatorItem }
                item.isHidden = !anyVisible
            } else if item.clipMenuFilterHaystack != nil {
                item.isHidden = !itemMatches(item, query: query, imagesOnly: imagesOnly)
            }
        }
    }

    private static func itemMatches(_ item: NSMenuItem, query: String, imagesOnly: Bool) -> Bool {
        if imagesOnly {
            guard let clip = item.representedObject as? ClipEntry, clip.imageData != nil else {
                return false
            }
        }
        if query.isEmpty { return true }
        guard let haystack = item.clipMenuFilterHaystack else { return !imagesOnly }
        return MenuFilterSubstring.matches(query, in: haystack)
    }

    private static func trimRedundantSeparators(in menu: NSMenu) {
        var changed = true
        while changed {
            changed = false
            var previousVisibleWasSeparator = true
            for item in menu.items {
                if item.isHidden { continue }
                if item.isSeparatorItem {
                    if previousVisibleWasSeparator {
                        item.isHidden = true
                        changed = true
                    } else {
                        previousVisibleWasSeparator = true
                    }
                } else {
                    previousVisibleWasSeparator = false
                }
            }
            if let last = menu.items.reversed().first(where: { !$0.isHidden }),
               last.isSeparatorItem {
                last.isHidden = true
                changed = true
            }
        }
    }
}

private func clipFilterHaystack(_ clip: ClipEntry) -> String {
    var parts: [String] = []
    if let s = clip.stringValue, !s.isEmpty { parts.append(s) }
    if let f = clip.filenames { parts.append(contentsOf: f) }
    if let u = clip.urlStrings { parts.append(contentsOf: u) }
    if parts.isEmpty {
        if clip.imageData != nil { parts.append("(Image)") }
        if clip.pdfData != nil { parts.append("(PDF)") }
    }
    return parts.joined(separator: " ")
}

private func snippetFilterHaystack(snippet: Snippet, folderTitle: String) -> String {
    [folderTitle, snippet.title, snippet.content].joined(separator: " ")
}

/// Search field that only accepts typing once activated (via `/`, highlight, or click).
private final class ClipMenuSearchField: NSSearchField {

    private var typingCaptureEnabled = false
    private var inactivePlaceholder: String = "Push / to search"
    private let caretOverlay = FilterCaretOverlayView(frame: .zero)
    private var caretBlinkTimer: Timer?

    var isTypingCaptureEnabledForTesting: Bool { typingCaptureEnabled }

    override var acceptsFirstResponder: Bool {
        typingCaptureEnabled
    }

    func activateForTypingFromMenuHighlight() {
        typingCaptureEnabled = true
        if let current = placeholderString, !current.isEmpty {
            inactivePlaceholder = current
        }
        // Hide placeholder while active so the insertion point reads as the prompt.
        placeholderString = ""
        applyActiveAppearance(true)

        // Focus for a real caret. Content-row highlight is suppressed while filter
        // mode is active, so this no longer jumps the menu to row 1.
        ensureInsertionPointVisible()
        // Menu field editors often fail to blink until after the first edit — keep a
        // fallback caret visible whenever filter mode is active.
        startFallbackCaret()
        realignSearchChrome()
    }

    /// After navigating with ↓ from the field, the menu owns keyboard again until filter is re-activated.
    func releaseTypingCaptureForMenuNavigation() {
        typingCaptureEnabled = false
        placeholderString = inactivePlaceholder
        applyActiveAppearance(false)
        stopFallbackCaret()
        window?.makeFirstResponder(nil)
        realignSearchChrome()
    }

    override func mouseDown(with event: NSEvent) {
        typingCaptureEnabled = true
        super.mouseDown(with: event)
        applyActiveAppearance(true)
        ensureInsertionPointVisible()
        startFallbackCaret()
        realignSearchChrome()
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            applyActiveAppearance(true)
            ensureInsertionPointVisible()
            startFallbackCaret()
            realignSearchChrome()
        }
        return ok
    }

    override var stringValue: String {
        didSet {
            if typingCaptureEnabled {
                positionFallbackCaret()
            }
        }
    }

    override func layout() {
        super.layout()
        // AppKit drops the magnifying glass when the empty field editor attaches;
        // re-assert button frames every layout pass.
        (cell as? ClipMenuSearchFieldCell)?.recenterAccessoryButtons(in: bounds)
        if typingCaptureEnabled {
            positionFallbackCaret()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        let searchCell = ClipMenuSearchFieldCell(textCell: "")
        searchCell.isEditable = true
        searchCell.isSelectable = true
        searchCell.isScrollable = true
        searchCell.isBezeled = true
        searchCell.bezelStyle = .roundedBezel
        searchCell.placeholderString = inactivePlaceholder
        searchCell.font = NSFont.menuFont(ofSize: NSFont.systemFontSize)
        searchCell.drawsBackground = true
        searchCell.searchButtonCell?.isBordered = false
        searchCell.cancelButtonCell?.isBordered = false
        cell = searchCell

        drawsBackground = true
        textColor = .labelColor
        focusRingType = .exterior
        isBezeled = true
        bezelStyle = .roundedBezel
        applyActiveAppearance(false)

        caretOverlay.isHidden = true
        caretOverlay.wantsLayer = true
        addSubview(caretOverlay)
    }

    private func applyActiveAppearance(_ active: Bool) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if active {
            backgroundColor = dark
                ? NSColor.white.withAlphaComponent(0.14)
                : NSColor.black.withAlphaComponent(0.06)
            textColor = .labelColor
            focusRingType = .exterior
        } else {
            backgroundColor = dark
                ? NSColor.white.withAlphaComponent(0.06)
                : NSColor.black.withAlphaComponent(0.04)
            textColor = .labelColor
            focusRingType = .none
        }
        if let cell = cell as? NSSearchFieldCell {
            cell.drawsBackground = true
            cell.backgroundColor = backgroundColor
        }
        needsDisplay = true
    }

    private func realignSearchChrome() {
        (cell as? ClipMenuSearchFieldCell)?.recenterAccessoryButtons(in: bounds)
        needsDisplay = true
        // Field-editor attach is async relative to focus; realign again next turn.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            (self.cell as? ClipMenuSearchFieldCell)?.recenterAccessoryButtons(in: self.bounds)
            self.needsDisplay = true
            if self.typingCaptureEnabled {
                self.positionFallbackCaret()
            }
        }
    }

    /// Installs / wakes the field editor so an empty focused field still blinks a caret.
    private func ensureInsertionPointVisible() {
        let styleCaret: () -> Void = { [weak self] in
            guard let self else { return }
            let targetWindow = self.window ?? NSApp.keyWindow
            guard let targetWindow else { return }

            // `selectText` is what actually installs the field editor for an empty field.
            if targetWindow.firstResponder !== self.currentEditor() {
                targetWindow.makeFirstResponder(self)
                self.selectText(nil)
            }

            guard let editor = (self.currentEditor() as? NSTextView)
                ?? (targetWindow.fieldEditor(true, for: self) as? NSTextView)
            else { return }

            editor.isEditable = true
            editor.isSelectable = true
            editor.drawsBackground = false
            editor.backgroundColor = .clear
            editor.textColor = .labelColor
            // Hide system caret — menu field editors often don't blink until after an
            // edit; our overlay caret is the reliable insertion point.
            editor.insertionPointColor = .clear
            let end = editor.string.utf16.count
            editor.setSelectedRange(NSRange(location: end, length: 0))
            editor.needsDisplay = true
        }

        styleCaret()
        DispatchQueue.main.async(execute: styleCaret)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: styleCaret)
    }

    private func startFallbackCaret() {
        positionFallbackCaret()
        caretOverlay.isHidden = false
        caretOverlay.alphaValue = 1
        caretBlinkTimer?.invalidate()
        let timer = Timer(timeInterval: 0.53, repeats: true) { [weak self] _ in
            guard let self, self.typingCaptureEnabled else { return }
            self.caretOverlay.alphaValue = self.caretOverlay.alphaValue > 0.5 ? 0 : 1
        }
        caretBlinkTimer = timer
        RunLoop.main.add(timer, forMode: .eventTracking)
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopFallbackCaret() {
        caretBlinkTimer?.invalidate()
        caretBlinkTimer = nil
        caretOverlay.isHidden = true
        caretOverlay.alphaValue = 1
    }

    fileprivate func refreshFallbackCaret() {
        guard typingCaptureEnabled else { return }
        positionFallbackCaret()
    }

    private func positionFallbackCaret() {
        let cellBounds = bounds
        let drawing = (cell as? NSSearchFieldCell)?.drawingRect(forBounds: cellBounds)
            ?? cellBounds.insetBy(dx: 28, dy: 4)
        let font = self.font ?? NSFont.menuFont(ofSize: NSFont.systemFontSize)
        let text = stringValue as NSString
        let textWidth = text.size(withAttributes: [.font: font]).width
        let caretHeight = max(font.pointSize + 2, 12)
        let x = drawing.minX + min(textWidth, max(0, drawing.width - 2))
        let y = drawing.midY - caretHeight / 2
        caretOverlay.frame = NSRect(x: x.rounded(.towardZero), y: y.rounded(.towardZero), width: 1.5, height: caretHeight)
        caretOverlay.updateColor(for: effectiveAppearance)
        if typingCaptureEnabled {
            caretOverlay.isHidden = false
        }
    }
}

/// Simple blinking insertion-point drawn above the search field (menu field editors are flaky).
private final class FilterCaretOverlayView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateColor(for appearance: NSAppearance) {
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.backgroundColor = (dark ? NSColor.white : NSColor.black).cgColor
    }
}

/// Keeps the magnifying glass / cancel buttons vertically centered.
/// Stock `NSSearchFieldCell` drops them when an empty field editor is attached.
private final class ClipMenuSearchFieldCell: NSSearchFieldCell {

    override func searchButtonRect(forBounds rect: NSRect) -> NSRect {
        verticallyCentered(super.searchButtonRect(forBounds: rect), in: rect)
    }

    override func cancelButtonRect(forBounds rect: NSRect) -> NSRect {
        verticallyCentered(super.cancelButtonRect(forBounds: rect), in: rect)
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        // Only inset horizontally for the search/cancel chrome. Leave AppKit's
        // vertical metrics alone — shrinking height here hid the empty-field caret.
        var drawing = super.drawingRect(forBounds: rect)
        let search = searchButtonRect(forBounds: rect)
        let cancel = cancelButtonRect(forBounds: rect)
        let left = search.maxX + 2
        let right = cancel.width > 0 ? cancel.minX - 2 : rect.maxX - 4
        drawing.origin.x = left
        drawing.size.width = max(0, right - left)
        return drawing
    }

    fileprivate func recenterAccessoryButtons(in bounds: NSRect) {
        // Drawing uses searchButtonRect(forBounds:) / cancelButtonRect(forBounds:);
        // force those paths to repaint after the field editor attaches.
        let searchRect = searchButtonRect(forBounds: bounds)
        let cancelRect = cancelButtonRect(forBounds: bounds)
        controlView?.setNeedsDisplay(searchRect.union(cancelRect))
        controlView?.needsDisplay = true
    }

    private func verticallyCentered(_ buttonRect: NSRect, in bounds: NSRect) -> NSRect {
        var centered = buttonRect
        centered.origin.y = bounds.origin.y + ((bounds.height - buttonRect.height) / 2).rounded(.towardZero)
        return centered
    }
}

/// Single menu-row filter control: search field + images toggle.
private final class ClipMenuFilterBarView: NSView {
    let searchField: ClipMenuSearchField
    let imagesButton: NSButton
    var onImagesFilterToggle: (() -> Void)?

    init(width: CGFloat) {
        let height: CGFloat = 36
        searchField = ClipMenuSearchField(frame: .zero)
        imagesButton = NSButton(frame: .zero)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))

        searchField.placeholderString = "Push / to search · Tab images"
        searchField.font = NSFont.menuFont(ofSize: NSFont.systemFontSize)
        searchField.setAccessibilityLabel("Push / to search, Tab for images only")
        searchField.translatesAutoresizingMaskIntoConstraints = false

        imagesButton.image = NSImage(systemSymbolName: "photo", accessibilityDescription: "Show images only")
        imagesButton.imagePosition = .imageOnly
        imagesButton.bezelStyle = .flexiblePush
        imagesButton.isBordered = true
        imagesButton.setButtonType(.pushOnPushOff)
        imagesButton.toolTip = "Show images only (Tab)"
        imagesButton.setAccessibilityLabel("Show images only")
        imagesButton.target = self
        imagesButton.action = #selector(imagesButtonClicked(_:))
        imagesButton.translatesAutoresizingMaskIntoConstraints = false
        imagesButton.setContentHuggingPriority(.required, for: .horizontal)
        imagesButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        addSubview(searchField)
        addSubview(imagesButton)

        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            searchField.centerYAnchor.constraint(equalTo: centerYAnchor),
            searchField.heightAnchor.constraint(equalToConstant: 24),

            imagesButton.leadingAnchor.constraint(equalTo: searchField.trailingAnchor, constant: 6),
            imagesButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            imagesButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            imagesButton.widthAnchor.constraint(equalToConstant: 28),
            imagesButton.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 36)
    }

    func setImagesFilterActive(_ active: Bool) {
        imagesButton.state = active ? .on : .off
        imagesButton.contentTintColor = active ? NSColor.controlAccentColor : nil
    }

    @objc private func imagesButtonClicked(_ sender: NSButton) {
        onImagesFilterToggle?()
    }
}

/// Intercepts `/` (and filter typing) before NSMenu type-ahead steals keys.
///
/// Primary path: CFRunLoop `beforeSources` observer in `.eventTracking` that
/// dequeues keyDowns from NSApp's queue (same Sonoma+ approach KeyboardShortcuts
/// uses — Carbon `GetEventDispatcherTarget` no longer sees menu keys).
/// Optional: CGEvent tap when Accessibility is granted (swallows earlier).
private enum ClipMenuFilterKeyHook {
    private static var eventTap: CFMachPort?
    private static var runLoopSource: CFRunLoopSource?
    private static var runLoopObserver: CFRunLoopObserver?
    private static weak var activeTarget: HotkeyPopupActionTarget?
    private(set) static var eventTapInstalled = false
    private(set) static var runLoopMonitorInstalled = false

    static func prepareAtLaunch() {
        installEventTapIfNeeded()
    }

    static func setActiveTarget(_ target: HotkeyPopupActionTarget?) {
        prepareAtLaunch()
        activeTarget = target
        startRunLoopMonitorIfNeeded()
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
    }

    static func clearActiveTarget(_ target: HotkeyPopupActionTarget) {
        if activeTarget === target {
            activeTarget = nil
            stopRunLoopMonitor()
        }
    }

    private static func installEventTapIfNeeded() {
        guard eventTap == nil else { return }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, _ in
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = ClipMenuFilterKeyHook.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    return Unmanaged.passUnretained(event)
                }
                guard type == .keyDown else {
                    return Unmanaged.passUnretained(event)
                }
                guard let target = ClipMenuFilterKeyHook.activeTarget else {
                    return Unmanaged.passUnretained(event)
                }

                var consume = false
                let handle = {
                    consume = target.handleGlobalKeyDown(cgEvent: event)
                }
                if Thread.isMainThread {
                    handle()
                } else {
                    DispatchQueue.main.sync(execute: handle)
                }
                return consume ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: nil
        ) else {
            fputs("[ClipMenu] Filter key event tap unavailable — using run-loop monitor\n", stderr)
            return
        }

        eventTap = tap
        eventTapInstalled = true
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        fputs("[ClipMenu] Filter key event tap installed\n", stderr)
    }

    private static func startRunLoopMonitorIfNeeded() {
        guard runLoopObserver == nil else { return }

        let keyMask: NSEvent.EventTypeMask = [.keyDown]
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            CFRunLoopActivity.beforeSources.rawValue,
            true,
            0
        ) { _, _ in
            guard ClipMenuFilterKeyHook.activeTarget != nil else { return }

            // Peek-only until a keyDown is at the head. Dequeuing while mouse-moved
            // events lead would drain the menu's tracking flood and lag highlight.
            var pendingToRepost: [NSEvent] = []
            while
                let head = NSApp.nextEvent(
                    matching: .any,
                    until: nil,
                    inMode: .eventTracking,
                    dequeue: false
                ),
                keyMask.contains(NSEvent.EventTypeMask(rawValue: 1 << head.type.rawValue)),
                let event = NSApp.nextEvent(
                    matching: keyMask,
                    until: nil,
                    inMode: .eventTracking,
                    dequeue: true
                )
            {
                let consumed: Bool
                if let target = ClipMenuFilterKeyHook.activeTarget,
                   let cgEvent = event.cgEvent {
                    consumed = target.handleGlobalKeyDown(cgEvent: cgEvent)
                } else {
                    consumed = false
                }
                if !consumed {
                    pendingToRepost.append(event)
                }
            }

            for event in pendingToRepost.reversed() {
                NSApp.postEvent(event, atStart: true)
            }
        }

        runLoopObserver = observer
        let mode = CFRunLoopMode(RunLoop.Mode.eventTracking.rawValue as CFString)
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, mode)
        runLoopMonitorInstalled = true
        fputs("[ClipMenu] Filter key run-loop monitor installed\n", stderr)
    }

    private static func stopRunLoopMonitor() {
        guard let observer = runLoopObserver else { return }
        let mode = CFRunLoopMode(RunLoop.Mode.eventTracking.rawValue as CFString)
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, mode)
        runLoopObserver = nil
        runLoopMonitorInstalled = false
    }
}

@MainActor
private final class HotkeyPopupMenuPresenter: NSObject, NSMenuDelegate {
    private let actionTarget = HotkeyPopupActionTarget()
    private let previewController = ClipPreviewPanelController()
    private let isUITestMode = ProcessInfo.processInfo.environment["CLIPMENU_UI_TEST_MODE"] == "1"
    private let testPopupStore = ClipMenuTestPopupStore.shared
    private var targetAppForPaste: NSRunningApplication?
    private var lastTargetApplication: NSRunningApplication?
    private var highlightPollingTimer: Timer?
    private var pendingPreviewItem: ClipPreviewItem?
    private var previewedItemID: PersistentIdentifier?
    private var currentSettings: ClipMenuSettings?
    private var previewAnchorPoint: NSPoint?
    private var activeMenuOrigin: NSPoint?
    private var rootMenuFrame: NSRect = .zero
    private var currentMenuFrame: NSRect = .zero
    private var previewSide: PreviewSide = .right
    private var knownMenuFrames: [NSRect] = []
    private var isStatusBarMenu = false
    private var statusBarMainMenuWidth: CGFloat = 0
    private var statusBarMenuRightEdge: CGFloat = 0
    private var previewRequestID = 0
    private weak var highlightedMenu: NSMenu?
    private weak var highlightedMenuItem: NSMenuItem?
    private lazy var anchorWindow: NSWindow = {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.backgroundColor = .clear
        window.alphaValue = 0.001
        window.ignoresMouseEvents = true
        window.level = .statusBar
        return window
    }()

    override init() {
        super.init()
        updateLastTargetApplication(NSWorkspace.shared.frontmostApplication)
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeApplicationDidChange(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @MainActor
    func show(using runtime: AppRuntime, kind: HotkeyMenuKind) {
        guard let context = runtime.modelContainer?.mainContext else {
            HotkeyService.log.error("Fallback popup requested but modelContext is nil")
            return
        }

        let menu = buildMenu(runtime: runtime, context: context, kind: kind)
        currentSettings = runtime.settings
        actionTarget.runtime = runtime
        targetAppForPaste = currentTargetApplication()
        actionTarget.targetAppForPaste = targetAppForPaste
        prepareMenuPreview(menu, settings: runtime.settings)

        if isUITestMode {
            testPopupStore.activationHandler = { [weak self] node in
                self?.activateTestNode(node)
            }
            testPopupStore.show(
                nodes: makeNodes(from: menu, level: 0, path: "root"),
                source: .hotkey
            )
            HotkeyService.log.notice("Presented UI-test popup window")
            return
        }

        let mouse = popupPresentationPoint()
        let anchorOrigin = popupAnchorOrigin(for: menu, mouse: mouse)
        anchorWindow.setFrameOrigin(anchorOrigin)
        activeMenuOrigin = anchorOrigin
        previewAnchorPoint = anchorOrigin
        let menuH = estimatedMenuHeight(for: menu)
        let menuW = estimatedMenuWidth(for: menu)
        currentMenuFrame = NSRect(x: anchorOrigin.x, y: anchorOrigin.y - menuH, width: menuW, height: menuH)
        rootMenuFrame = currentMenuFrame
        previewSide = preferredPreviewSide(for: currentMenuFrame)
        knownMenuFrames = [currentMenuFrame]
        anchorWindow.orderFront(nil)
        beginSlashKeyMonitorForOpenMenu()

        let selfTestFilterSlash = ProcessInfo.processInfo.arguments.contains("--self-test-filter-slash")
        if selfTestFilterSlash {
            scheduleFilterSlashSelfTest(for: menu)
        }

        NSApp.activate(ignoringOtherApps: true)
        if let contentView = anchorWindow.contentView {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: contentView)
        } else {
            menu.popUp(positioning: nil, at: mouse, in: nil)
        }

        stopHighlightPolling()
        anchorWindow.orderOut(nil)
        HotkeyService.log.notice("Presented fallback NSMenu popup")
    }

    private func scheduleFilterSlashSelfTest(for menu: NSMenu) {
        fputs("[FILTER SELFTEST] scheduled\n", stderr)
        let timer = Timer(timeInterval: 0.5, repeats: false) { [weak self] _ in
            fputs("[FILTER SELFTEST] timer fired\n", stderr)
            MainActor.assumeIsolated {
                self?.runFilterSlashSelfTest(menu: menu)
            }
        }
        RunLoop.main.add(timer, forMode: .eventTracking)
        RunLoop.main.add(timer, forMode: .common)
    }

    private func runFilterSlashSelfTest(menu: NSMenu) {
        fputs("[FILTER SELFTEST] running\n", stderr)
        ClipMenuFilterKeyHook.prepareAtLaunch()
        // Ensure the run-loop monitor is armed (menu-open path also does this).
        actionTarget.beginSlashKeyMonitorIfNeeded()

        guard actionTarget.filterSearchField != nil else {
            fputs("[FILTER SELFTEST] FAIL: filter search field missing\n", stderr)
            Darwin.exit(1)
        }

        if let screen = NSScreen.main {
            CGWarpMouseCursorPosition(CGPoint(x: screen.frame.minX + 2, y: screen.frame.minY + 2))
        }
        // Discover a working highlight API — setHighlightedItem: is absent on modern macOS.
        let highlightCandidates = ["highlightItem:", "setHighlightedItem:", "_highlightItem:"]
        var highlightSel: Selector?
        for name in highlightCandidates {
            let sel = NSSelectorFromString(name)
            if menu.responds(to: sel) {
                highlightSel = sel
                fputs("[FILTER SELFTEST] highlight API=\(name)\n", stderr)
                break
            }
        }
        if highlightSel == nil {
            var count: UInt32 = 0
            if let list = class_copyMethodList(NSMenu.self, &count) {
                defer { free(list) }
                var found: [String] = []
                for i in 0..<Int(count) {
                    let name = NSStringFromSelector(method_getName(list[i]))
                    if name.lowercased().contains("highlight") {
                        found.append(name)
                    }
                }
                fputs("[FILTER SELFTEST] NSMenu highlight methods=\(found)\n", stderr)
            }
        }

        let clearSel = highlightSel ?? NSSelectorFromString("highlightItem:")

        // Reproduce the user-visible bug: first content row is highlighted, then `/`.
        let firstContent = menu.items.first { item in
            item.view == nil
                && item.isEnabled
                && !item.isSeparatorItem
                && !item.isHidden
                && item.title.hasPrefix("1.")
        }
        if let firstContent, menu.responds(to: clearSel) {
            menu.perform(clearSel, with: firstContent)
            fputs("[FILTER SELFTEST] pre-highlighted '\(firstContent.title.prefix(40))' now=\(menu.highlightedItem?.title.prefix(40) ?? "nil")\n", stderr)
        } else {
            fputs("[FILTER SELFTEST] WARN: could not pre-highlight (selResponds=\(menu.responds(to: clearSel)))\n", stderr)
        }

        if actionTarget.isFilterModeActiveForTesting {
            fputs("[FILTER SELFTEST] FAIL: filter mode already active before '/'\n", stderr)
            Darwin.exit(1)
        }

        // Post real key events into the app queue — do NOT call handleGlobalKeyDown
        // directly (that false-passed while AppKit still type-ahead-selected row 1).
        let winNum = NSApp.keyWindow?.windowNumber
            ?? actionTarget.filterSearchField?.window?.windowNumber
            ?? 0

        func postKey(_ keyCode: UInt16, chars: String) {
            guard let down = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: winNum,
                context: nil,
                characters: chars,
                charactersIgnoringModifiers: chars,
                isARepeat: false,
                keyCode: keyCode
            ) else { return }
            // atStart so the eventTracking run-loop monitor sees it before menu type-ahead.
            NSApp.postEvent(down, atStart: true)
        }

        postKey(44, chars: "/")

        let evaluate = Timer(timeInterval: 0.45, repeats: false) { _ in
            MainActor.assumeIsolated {
                let modeOn = self.actionTarget.isFilterModeActiveForTesting
                let highlighted = menu.highlightedItem
                let stillOnFirst = firstContent != nil && highlighted === firstContent
                let jumpedToContent = stillOnFirst
                    || highlighted?.representedObject is ClipEntry
                    || highlighted?.representedObject is Snippet
                    || (highlighted?.title.hasPrefix("1.") == true)

                guard modeOn, !jumpedToContent else {
                    fputs(
                        "[FILTER SELFTEST] FAIL after '/': mode=\(modeOn) highlighted=\(highlighted?.title ?? "nil") jumped=\(jumpedToContent) stillFirst=\(stillOnFirst) runloop=\(ClipMenuFilterKeyHook.runLoopMonitorInstalled) tap=\(ClipMenuFilterKeyHook.eventTapInstalled)\n",
                        stderr
                    )
                    menu.cancelTracking()
                    Darwin.exit(1)
                }

                // Simulate cursor still sitting on the first row (common real-world case).
                if let firstContent {
                    self.actionTarget.clipMenuWillHighlight(menu: menu, item: firstContent)
                    let modeAfterHover = self.actionTarget.isFilterModeActiveForTesting
                    let highlightedAfterHover = menu.highlightedItem
                    let hoverReselected = highlightedAfterHover === firstContent
                        || highlightedAfterHover?.title.hasPrefix("1.") == true
                    if !modeAfterHover || hoverReselected {
                        fputs(
                            "[FILTER SELFTEST] FAIL hover-after-/: mode=\(modeAfterHover) highlighted=\(highlightedAfterHover?.title ?? "nil") reselected=\(hoverReselected)\n",
                            stderr
                        )
                        menu.cancelTracking()
                        Darwin.exit(1)
                    }
                }

                postKey(0, chars: "a")

                let evaluate2 = Timer(timeInterval: 0.35, repeats: false) { _ in
                    MainActor.assumeIsolated {
                        let query = self.actionTarget.filterSearchField?.stringValue ?? ""
                        let stillMode = self.actionTarget.isFilterModeActiveForTesting
                        let highlighted2 = menu.highlightedItem
                        let jumped2 = (firstContent != nil && highlighted2 === firstContent)
                            || highlighted2?.representedObject is ClipEntry
                            || highlighted2?.representedObject is Snippet
                            || (highlighted2?.title.hasPrefix("1.") == true)

                        if stillMode && query.lowercased().contains("a") && !jumped2 {
                            fputs(
                                "[FILTER SELFTEST] PASS: '/' filter mode; 'a' in query=\(query); no content jump (runloop=\(ClipMenuFilterKeyHook.runLoopMonitorInstalled) tap=\(ClipMenuFilterKeyHook.eventTapInstalled))\n",
                                stderr
                            )
                            menu.cancelTracking()
                            Darwin.exit(0)
                        }
                        fputs(
                            "[FILTER SELFTEST] FAIL after 'a': mode=\(stillMode) query=\(query) highlighted=\(highlighted2?.title ?? "nil") jumped=\(jumped2)\n",
                            stderr
                        )
                        menu.cancelTracking()
                        Darwin.exit(1)
                    }
                }
                RunLoop.main.add(evaluate2, forMode: .eventTracking)
                RunLoop.main.add(evaluate2, forMode: .common)
            }
        }
        RunLoop.main.add(evaluate, forMode: .eventTracking)
        RunLoop.main.add(evaluate, forMode: .common)
    }

    private func popupPresentationPoint() -> NSPoint {
        guard ProcessInfo.processInfo.environment["CLIPMENU_UI_TEST_MODE"] == "1",
              let window = NSApp.keyWindow ?? NSApp.mainWindow
        else {
            return NSEvent.mouseLocation
        }

        return NSPoint(x: window.frame.midX, y: window.frame.midY)
    }

    @MainActor
    func showStatusMenuForTesting(using runtime: AppRuntime) {
        guard let menu = statusMenu(using: runtime) else { return }
        prepareMenuPreview(menu, settings: runtime.settings)

        if isUITestMode {
            testPopupStore.activationHandler = { [weak self] node in
                self?.activateTestNode(node)
            }
            testPopupStore.show(
                nodes: makeNodes(from: menu, level: 0, path: "root"),
                source: .status
            )
            return
        }

        let point = NSPoint(x: NSScreen.main?.visibleFrame.midX ?? 400, y: NSScreen.main?.visibleFrame.midY ?? 400)
        activeMenuOrigin = point
        previewAnchorPoint = point
        startHighlightPolling(for: menu)
        menu.popUp(positioning: nil, at: point, in: nil)
        stopHighlightPolling()
        activeMenuOrigin = nil
        previewAnchorPoint = nil
    }

    private func popupAnchorOrigin(for menu: NSMenu, mouse: NSPoint) -> NSPoint {
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        let frame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero

        let menuHeight = estimatedMenuHeight(for: menu)
        let bottomEdge = mouse.y - menuHeight
        
        let padding: CGFloat = 8
        if bottomEdge < frame.minY + padding {
            let requiredY = frame.minY + padding + menuHeight
            let finalY = min(requiredY, frame.maxY - padding)
            return NSPoint(x: mouse.x, y: finalY)
        }

        return mouse
    }

    private func estimatedMenuHeight(for menu: NSMenu) -> CGFloat {
        let visibleItems = menu.items.filter { !$0.isHidden }
        guard !visibleItems.isEmpty else { return 0 }

        let rowHeight: CGFloat = 22
        let separatorHeight: CGFloat = 10

        return visibleItems.reduce(CGFloat(0)) { total, item in
            total + (item.isSeparatorItem ? separatorHeight : rowHeight)
        }
    }

    @MainActor
    func statusMenu(using runtime: AppRuntime, buttonMaxX: CGFloat? = nil) -> NSMenu? {
        guard let context = runtime.modelContainer?.mainContext else {
            HotkeyService.log.error("Status menu requested but modelContext is nil")
            return nil
        }

        let menu = buildMenu(runtime: runtime, context: context, kind: .main)
        currentSettings = runtime.settings
        actionTarget.runtime = runtime
        targetAppForPaste = currentTargetApplication()
        actionTarget.targetAppForPaste = targetAppForPaste
        isStatusBarMenu = true
        statusBarMainMenuWidth = estimatedMenuWidth(for: menu)
        let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main
        let fallbackMaxX = screen?.visibleFrame.maxX ?? 1440
        statusBarMenuRightEdge = buttonMaxX ?? fallbackMaxX
        let menuH = estimatedMenuHeight(for: menu)
        let screenMaxY = screen?.visibleFrame.maxY ?? 900
        currentMenuFrame = NSRect(x: statusBarMenuRightEdge - statusBarMainMenuWidth, y: screenMaxY - menuH, width: statusBarMainMenuWidth, height: menuH)
        rootMenuFrame = currentMenuFrame
        previewSide = .left
        knownMenuFrames = [currentMenuFrame]
        prepareMenuPreview(menu, settings: runtime.settings)
        return menu
    }

    // Native LTR behavior preserves text alignment without structural hacks.

    @MainActor
    func prepareStatusMenuPreview(_ menu: NSMenu) {
        prepareMenuPreview(menu, settings: currentSettings)
        // Items were moved onto the live status menu — keep filter targeting that menu.
        if actionTarget.filterSearchField != nil {
            actionTarget.filterRootMenu = menu
        }
    }

    @MainActor
    func showPreviewForTesting(in menu: NSMenu) {
        guard let item = findFirstClipItem(in: menu),
              let clip = item.representedObject as? ClipEntry else { return }

        previewAnchorPoint = previewAnchorPoint(for: item, in: menu)
        pendingPreviewItem = nil
        previewRequestID += 1
        showPreview(for: .clip(clip))
    }

    private func findFirstClipItem(in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if item.representedObject is ClipEntry {
                return item
            }
            if let submenu = item.submenu, let child = findFirstClipItem(in: submenu) {
                return child
            }
        }
        return nil
    }

    @MainActor
    func showPreviewForTesting(_ clip: ClipEntry, at point: NSPoint) {
        previewAnchorPoint = point
        pendingPreviewItem = nil
        previewRequestID += 1
        showPreview(for: .clip(clip))
    }

    func menuDidClose(_ menu: NSMenu) {
        // Submenus close during normal navigation (e.g. moving between folders).
        // Only tear down the session when the root menu closes.
        guard menu.supermenu == nil else {
            previewController.hide()
            return
        }

        stopHighlightPolling()
        previewRequestID += 1
        previewedItemID = nil
        activeMenuOrigin = nil
        previewAnchorPoint = nil
        rootMenuFrame = .zero
        currentMenuFrame = .zero
        knownMenuFrames = []
        previewSide = .right
        isStatusBarMenu = false
        statusBarMainMenuWidth = 0
        statusBarMenuRightEdge = 0
        previewController.hide()
        highlightedMenu = nil
        highlightedMenuItem = nil
        clipMenuDidCloseCleanup()
        anchorWindow.orderOut(nil)
        testPopupStore.dismiss()
    }

    fileprivate func clipMenuDidCloseCleanup() {
        actionTarget.clipMenuFilterMenuDidClose()
    }

    fileprivate func beginSlashKeyMonitorForOpenMenu() {
        actionTarget.beginSlashKeyMonitorIfNeeded()
    }

    func menuWillOpen(_ menu: NSMenu) {
        beginSlashKeyMonitorForOpenMenu()
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        fputs("[DEBUG] menu:willHighlight item=\(item?.title ?? "nil") in menu=\(menu.title)\n", stderr)
        actionTarget.clipMenuWillHighlight(menu: menu, item: item)
        handleHighlightedItem(item, in: menu)
        if let item {
            ensureTypeSelectedItemIsVisible(item, in: menu)
        }
    }

    /// NSMenu type-select (e.g. Q → Quit) can highlight a row that sits just below the
    /// scrolled viewport. Nudge the open menu so trailing chrome stays on-screen.
    private func ensureTypeSelectedItemIsVisible(_ item: NSMenuItem, in menu: NSMenu) {
        guard menu.supermenu == nil else { return }
        let index = menu.index(of: item)
        guard index >= 0 else { return }

        let footerTitles: Set<String> = [
            "Quit ClipMenu",
            "Preferences…",
            "Edit Snippets…",
            "Clear History",
        ]
        let isTrailingChrome = footerTitles.contains(item.title) || index >= menu.numberOfItems - 4
        guard isTrailingChrome else { return }

        updateMenuGeometry(for: menu)
        let frame = currentMenuFrame
        guard frame.width > 0, frame.height > 0 else { return }

        let timer = Timer(timeInterval: 0.02, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scrollOpenMenuToRevealTrailingItem(title: item.title, menuFrame: frame, menu: menu, item: item)
            }
        }
        RunLoop.current.add(timer, forMode: .eventTracking)
        RunLoop.current.add(timer, forMode: .default)
    }

    private func scrollOpenMenuToRevealTrailingItem(title: String, menuFrame: NSRect, menu: NSMenu, item: NSMenuItem) {
        // Prefer Accessibility scroll-into-view when it works.
        if scrollAXMenuItemIntoView(titled: title) {
            rehighlight(item, in: menu)
            return
        }

        // Fallback: line-scroll the menu window toward its bottom, then re-highlight.
        let mainH = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height
            ?? 900
        let cgPoint = CGPoint(x: menuFrame.midX, y: mainH - menuFrame.midY)
        for _ in 0..<10 {
            guard let event = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .line,
                wheelCount: 1,
                wheel1: -20,
                wheel2: 0,
                wheel3: 0
            ) else { continue }
            event.location = cgPoint
            event.post(tap: .cghidEventTap)
        }
        rehighlight(item, in: menu)
    }

    private func rehighlight(_ item: NSMenuItem, in menu: NSMenu) {
        let sel = Selector(("highlightItem:"))
        if menu.responds(to: sel) {
            menu.perform(sel, with: item)
        }
    }

    @discardableResult
    private func scrollAXMenuItemIntoView(titled title: String) -> Bool {
        let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            return false
        }

        for window in windows {
            if let element = findAXElement(in: window, role: kAXMenuItemRole as String, title: title)
                ?? findAXElement(in: window, role: "AXMenuItem", title: title) {
                let scrollResult = AXUIElementPerformAction(element, "AXScrollToVisible" as CFString)
                if scrollResult == .success { return true }
                // Some menu rows expose a parent that accepts scroll-to-visible.
                var parentRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parentRef) == .success,
                   let parent = parentRef {
                    let parentEl = parent as! AXUIElement
                    if AXUIElementPerformAction(parentEl, "AXScrollToVisible" as CFString) == .success {
                        return true
                    }
                }
            }
        }
        return false
    }

    private func findAXElement(in root: AXUIElement, role: String, title: String) -> AXUIElement? {
        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(root, kAXRoleAttribute as CFString, &roleRef) == .success,
           let rootRole = roleRef as? String, rootRole == role {
            var titleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(root, kAXTitleAttribute as CFString, &titleRef) == .success,
               let rootTitle = titleRef as? String, rootTitle == title {
                return root
            }
        }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else {
            return nil
        }
        for child in children {
            if let match = findAXElement(in: child, role: role, title: title) {
                return match
            }
        }
        return nil
    }

    @MainActor
    private func prepareMenuPreview(_ menu: NSMenu, settings: ClipMenuSettings?) {
        currentSettings = settings
        menu.delegate = self

        for item in menu.items {
            item.toolTip = nil
            if let submenu = item.submenu {
                prepareMenuPreview(submenu, settings: settings)
            }
        }
    }

    @MainActor
    private func showPreview(for previewItem: ClipPreviewItem) {
        fputs("[DEBUG] showPreview called for item! anchor=\(previewAnchorPoint ?? .zero) currentMenuFrame=\(currentMenuFrame)\n", stderr)
        HotkeyService.log.notice("showPreview called for item: \(String(describing: previewItem.persistentModelID), privacy: .public)")
        previewedItemID = previewItem.persistentModelID
        if !isUITestMode, let menu = highlightedMenu {
            updateMenuGeometry(for: menu)
            if let item = highlightedMenuItem {
                updatePreviewAnchor(for: item, in: menu)
            }
        }
        let anchor = previewAnchorPoint ?? NSEvent.mouseLocation
        previewController.show(
            item: previewItem,
            near: anchor,
            menuFrame: currentMenuFrame,
            preferredSide: previewSide,
            otherMenuFrames: knownMenuFrames,
            parentWindow: nil
        )
    }

    func dismissPreview(force: Bool = false) {
        if !force && previewController.panelWindow.isVisible {
            let mouse = NSEvent.mouseLocation
            let hoverRegion = previewController.panelWindow.frame.insetBy(dx: -20, dy: -10)
            if NSPointInRect(mouse, hoverRegion) {
                scheduleDismissalCheck()
                return
            }
        }

        dismissTimer?.invalidate()
        dismissTimer = nil
        previewDelayTimer?.invalidate()
        previewDelayTimer = nil
        pendingPreviewItem = nil
        previewRequestID += 1
        previewedItemID = nil
        previewController.hide()
    }

    private var dismissTimer: Timer?

    private func scheduleDismissalCheck() {
        dismissTimer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let mouse = NSEvent.mouseLocation
                if self.previewController.panelWindow.isVisible {
                    let hoverRegion = self.previewController.panelWindow.frame.insetBy(dx: -20, dy: -10)
                    if !NSPointInRect(mouse, hoverRegion) {
                        self.dismissPreview(force: true)
                    }
                } else {
                    self.dismissTimer?.invalidate()
                    self.dismissTimer = nil
                }
            }
        }
        dismissTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    func highlightTestNode(_ node: TestPopupNode?, anchorPoint: NSPoint?) {
        guard currentSettings?.showTooltipsInMenu == true, let node else {
            dismissPreview()
            return
        }

        let previewItem: ClipPreviewItem
        if let clip = node.clip {
            previewItem = .clip(clip)
        } else if let snippet = node.snippet {
            previewItem = .snippet(snippet)
        } else {
            dismissPreview()
            return
        }

        if isUITestMode {
            NotificationCenter.default.post(
                name: .clipMenuHighlightDidChange,
                object: nil,
                userInfo: ["title": node.title]
            )
        }

        if let anchorPoint {
            previewAnchorPoint = anchorPoint
        }

        let itemID = previewItem.persistentModelID
        if previewedItemID == itemID || pendingPreviewItem?.persistentModelID == itemID {
            return
        }

        pendingPreviewItem = previewItem
        previewRequestID += 1
        let requestID = previewRequestID
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.2) { [weak self] in
            DispatchQueue.main.async {
                guard let self,
                      self.previewRequestID == requestID,
                      self.pendingPreviewItem?.persistentModelID == itemID
                else { return }
                self.showPendingPreview()
            }
        }
    }

    func activateTestNode(_ node: TestPopupNode) {
        if let clip = node.clip {
            actionTarget.selectClipEntry(clip)
            return
        }

        if let snippet = node.snippet {
            actionTarget.selectSnippetModel(snippet)
        }
    }

    private func makeNodes(from menu: NSMenu, level: Int, path: String) -> [TestPopupNode] {
        menu.items.enumerated().map { index, item in
            let title = item.title.isEmpty && item.isSeparatorItem ? "separator-\(index)" : item.title
            let nodeID = "\(path).\(index)"
            let children = item.submenu.map { makeNodes(from: $0, level: level + 1, path: nodeID) } ?? []
            return TestPopupNode(
                id: nodeID,
                title: title,
                clip: item.representedObject as? ClipEntry,
                snippet: item.representedObject as? Snippet,
                children: children,
                isEnabled: item.isEnabled,
                isSeparator: item.isSeparatorItem,
                level: level
            )
        }
    }

    func testPopupDidDismiss() {
        dismissPreview()
    }

    private func showPendingPreview() {
        fputs("[DEBUG] showPendingPreview called! pendingPreviewItem=\(pendingPreviewItem != nil)\n", stderr)
        guard let item = pendingPreviewItem else { return }
        showPreview(for: item)
    }

    private func handleHighlightedItem(_ item: NSMenuItem?, in menu: NSMenu?) {
        fputs("[DEBUG] handleHighlightedItem item=\(item?.title ?? "nil"), showTooltips=\(self.currentSettings?.showTooltipsInMenu ?? false)\n", stderr)
        guard currentSettings?.showTooltipsInMenu == true else {
            dismissPreview()
            return
        }

        let previewItem: ClipPreviewItem
        if let clip = item?.representedObject as? ClipEntry {
            previewItem = .clip(clip)
            if ProcessInfo.processInfo.environment["CLIPMENU_UI_TEST_MODE"] == "1" {
                NotificationCenter.default.post(
                    name: .clipMenuHighlightDidChange,
                    object: nil,
                    userInfo: ["title": clip.stringValue ?? ""]
                )
            }
        } else if let snippet = item?.representedObject as? Snippet {
            previewItem = .snippet(snippet)
        } else {
            HotkeyService.log.notice("handleHighlightedItem: item has no clip or snippet representedObject. Title=\(item?.title ?? "nil", privacy: .public)")
            dismissPreview()
            return
        }

        if let menu, let item {
            highlightedMenu = menu
            highlightedMenuItem = item
            if !isUITestMode {
                updateMenuGeometry(for: menu)
            }
            updatePreviewAnchor(for: item, in: menu)
        }

        let itemID = previewItem.persistentModelID
        if previewedItemID == itemID || pendingPreviewItem?.persistentModelID == itemID {
            return
        }

        schedulePreview(for: previewItem)
    }

    private var previewDelayTimer: Timer?

    private func schedulePreview(for previewItem: ClipPreviewItem) {
        previewDelayTimer?.invalidate()
        pendingPreviewItem = previewItem
        previewRequestID += 1
        let requestID = previewRequestID
        let itemID = previewItem.persistentModelID

        let timer = Timer(timeInterval: 0.1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self,
                      self.previewRequestID == requestID,
                      self.pendingPreviewItem?.persistentModelID == itemID
                else { return }
                self.showPendingPreview()
            }
        }
        previewDelayTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    private func startHighlightPolling(for menu: NSMenu) {
        stopHighlightPolling()

        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self, weak menu] _ in
            MainActor.assumeIsolated {
                guard let self, let menu else { return }
                if let (item, subMenu) = self.findHighlightedItemAndMenu(in: menu) {
                    self.handleHighlightedItem(item, in: subMenu)
                } else {
                    fputs("[DEBUG] poll: no highlighted item found in \(menu.title)\n", stderr)
                    self.handleHighlightedItem(nil, in: menu)
                }
            }
        }
        highlightPollingTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    private func findHighlightedItemAndMenu(in menu: NSMenu) -> (NSMenuItem, NSMenu)? {
        if let item = menu.highlightedItem {
            if let submenu = item.submenu, let child = findHighlightedItemAndMenu(in: submenu) {
                return child
            }
            return (item, menu)
        }
        for item in menu.items {
            if let submenu = item.submenu, let child = findHighlightedItemAndMenu(in: submenu) {
                return child
            }
        }
        return nil
    }

    private func stopHighlightPolling() {
        highlightPollingTimer?.invalidate()
        highlightPollingTimer = nil
    }

    private func previewAnchorPoint(for item: NSMenuItem, in menu: NSMenu) -> NSPoint {
        NSEvent.mouseLocation
    }

    private func updatePreviewAnchor(for item: NSMenuItem, in menu: NSMenu) {
        let mouse = NSEvent.mouseLocation
        let visibleItems = menu.items.filter { !$0.isHidden }
        let itemIndex = max(visibleItems.firstIndex(of: item) ?? 0, 0)
        let rowOffset = visibleItems.prefix(itemIndex).reduce(CGFloat(0)) { total, current in
            total + menuItemHeight(current)
        } + menuItemHeight(item) / 2
        let calculatedRowY = currentMenuFrame.maxY - rowOffset

        // Follow the mouse only when it is actually over the menu that owns
        // the highlighted item. Keyboard navigation often leaves the cursor
        // sitting on the root popup while a submenu is open.
        if NSPointInRect(mouse, currentMenuFrame) {
            previewAnchorPoint = mouse
        } else {
            previewAnchorPoint = NSPoint(x: currentMenuFrame.midX, y: calculatedRowY)
        }
    }

    private func preferredPreviewSide(for menuFrame: NSRect) -> PreviewSide {
        if isStatusBarMenu { return .left }

        let probe = NSPoint(x: menuFrame.midX, y: menuFrame.midY)
        let screen = NSScreen.screens.first(where: { NSMouseInRect(probe, $0.frame, false) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        guard visible.width > 0 else { return .right }

        let spaceOnLeft = menuFrame.minX - visible.minX
        let spaceOnRight = visible.maxX - menuFrame.maxX
        return spaceOnRight >= spaceOnLeft ? .right : .left
    }

    private func updateMenuGeometry(for menu: NSMenu) {
        let windows = visiblePopupMenuFrames()
        let isSubmenu = menu.supermenu != nil

        if !isSubmenu {
            if let actual = matchingMenuWindow(
                expected: rootMenuFrame.width > 0 ? rootMenuFrame : currentMenuFrame,
                in: windows,
                preferring: activeMenuOrigin
            ) {
                rootMenuFrame = actual
            } else if windows.count == 1 {
                rootMenuFrame = windows[0]
            }
            currentMenuFrame = rootMenuFrame
            knownMenuFrames = windows.isEmpty ? [rootMenuFrame] : windows
            previewSide = preferredPreviewSide(for: rootMenuFrame)
            return
        }

        if let actualRoot = matchingMenuWindow(expected: rootMenuFrame, in: windows, preferring: activeMenuOrigin) {
            rootMenuFrame = actualRoot
        }

        let expectedSide = preferredPreviewSide(for: rootMenuFrame)
        let estimatedSubmenu = estimatedSubmenuFrame(for: menu, root: rootMenuFrame, side: expectedSide)
        let submenuWindows = windows.filter { !isApproximatelySameWindow($0, rootMenuFrame) }

        if let submenu = matchingMenuWindow(expected: estimatedSubmenu, in: submenuWindows, preferring: nil)
            ?? submenuWindows.max(by: { abs($0.midX - rootMenuFrame.midX) < abs($1.midX - rootMenuFrame.midX) }) {
            currentMenuFrame = submenu
            previewSide = submenu.midX < rootMenuFrame.midX ? .left : .right
        } else {
            previewSide = expectedSide
            currentMenuFrame = estimatedSubmenu
        }

        knownMenuFrames = windows.isEmpty ? [rootMenuFrame, currentMenuFrame] : windows
    }

    private func estimatedSubmenuFrame(for menu: NSMenu, root: NSRect, side: PreviewSide) -> NSRect {
        let menuW = estimatedMenuWidth(for: menu)
        let menuH = estimatedMenuHeight(for: menu)
        let x = side == .right ? root.maxX : root.minX - menuW
        return NSRect(x: x, y: root.maxY - menuH, width: menuW, height: menuH)
    }

    private func isApproximatelySameWindow(_ a: NSRect, _ b: NSRect) -> Bool {
        if abs(a.midX - b.midX) < 30 && abs(a.minY - b.minY) < 40 {
            return true
        }
        let overlap = a.intersection(b)
        return overlap.width > min(a.width, b.width) * 0.6
    }

    private func matchingMenuWindow(expected: NSRect, in windows: [NSRect], preferring point: NSPoint?) -> NSRect? {
        if let point, let containing = windows.first(where: { NSPointInRect(point, $0) }) {
            if expected.width <= 0 || abs(containing.midX - expected.midX) < 80 {
                return containing
            }
        }

        guard expected.width > 0, !windows.isEmpty else { return windows.first }
        return windows.min { a, b in
            hypot(a.midX - expected.midX, a.midY - expected.midY) < hypot(b.midX - expected.midX, b.midY - expected.midY)
        }
    }

    private func visiblePopupMenuFrames() -> [NSRect] {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        let pid = ProcessInfo.processInfo.processIdentifier
        let mainScreenHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.screens.first?.frame.height
            ?? 900
        let previewFrame = previewController.panelWindow.isVisible ? previewController.panelWindow.frame : .null

        var frames: [NSRect] = []
        for info in windowList {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t, ownerPID == pid,
                  let layer = info[kCGWindowLayer as String] as? Int, (100...110).contains(layer),
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  rect.width > 40, rect.height > 20
            else { continue }

            let cocoaRect = NSRect(
                x: rect.origin.x,
                y: mainScreenHeight - rect.origin.y - rect.height,
                width: rect.width,
                height: rect.height
            )

            if !previewFrame.isNull,
               cocoaRect.intersects(previewFrame.insetBy(dx: 4, dy: 4)),
               abs(cocoaRect.width - previewFrame.width) < 40 {
                continue
            }

            frames.append(cocoaRect)
        }
        return frames
    }

    /// Prefer attributed titles (image thumbnails) over plain `.title`; optionally
    /// include hidden rows so a filter toggle does not remasure against a narrower set.
    private func estimatedMenuWidth(for menu: NSMenu, includingHidden: Bool = false) -> CGFloat {
        let items = includingHidden ? menu.items : menu.items.filter { !$0.isHidden }
        let contentWidths: [CGFloat] = items.map { item in
            if let attributed = item.attributedTitle, attributed.length > 0 {
                return ceil(attributed.size().width)
            }
            return ceil((item.title as NSString).size(withAttributes: [.font: NSFont.menuFont(ofSize: 0)]).width)
        }
        // +120 covers menu chrome (icons, padding, key equivalents); room for ~100pt thumbs.
        return min(max((contentWidths.max() ?? 220) + 120, 280), 520)
    }

    private func menuItemHeight(_ item: NSMenuItem) -> CGFloat {
        item.isSeparatorItem ? 10 : 22
    }

    private func currentTargetApplication() -> NSRunningApplication? {
        if let frontmost = NSWorkspace.shared.frontmostApplication, isValidTargetApplication(frontmost) {
            updateLastTargetApplication(frontmost)
            return frontmost
        }

        if let lastTargetApplication, !lastTargetApplication.isTerminated {
            return lastTargetApplication
        }

        return nil
    }

    @objc private func activeApplicationDidChange(_ notification: Notification) {
        updateLastTargetApplication(notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
    }

    private func updateLastTargetApplication(_ application: NSRunningApplication?) {
        guard let application, isValidTargetApplication(application) else { return }
        lastTargetApplication = application
    }

    private func isValidTargetApplication(_ application: NSRunningApplication) -> Bool {
        application.processIdentifier != NSRunningApplication.current.processIdentifier
            && !application.isTerminated
            && application.activationPolicy == .regular
            && application.bundleIdentifier != nil
    }

    private func buildMenu(runtime: AppRuntime, context: ModelContext, kind: HotkeyMenuKind) -> NSMenu {
        let menu = NSMenu(title: "ClipMenu")
        menu.minimumWidth = 240.0
        let settings = runtime.settings
        if kind != .actions {
            insertFilterMenuItems(into: menu)
        } else {
            actionTarget.filterRootMenu = nil
            actionTarget.filterSearchField = nil
            actionTarget.filterTitleMenuItem = nil
        }

        let fetchedClips = (try? context.fetch(FetchDescriptor<ClipEntry>(
            sortBy: [SortDescriptor(\ClipEntry.lastUsedAt, order: .reverse)]
        ))) ?? []
        let clips = Array(fetchedClips.prefix(max(settings.maxHistorySize, 0)))

        let folders = (try? context.fetch(FetchDescriptor<SnippetFolder>(
            sortBy: [SortDescriptor(\SnippetFolder.sortIndex, order: .forward)]
        ))) ?? []

        let showSnippetsInMain = kind == .main
        let showHistory = kind != .snippets && kind != .actions
        let showActionsInMain = false

        if showSnippetsInMain && settings.positionOfSnippets == 0 {
            addSnippets(to: menu, folders: folders, settings: settings)
            if showHistory { menu.addItem(.separator()) }
        }

        if kind == .snippets {
            addSnippets(to: menu, folders: folders, settings: settings)
        }

        if kind == .actions {
            addActions(to: menu, clips: clips, context: context, runtime: runtime)
        }

        if showHistory {
            addHistory(to: menu, clips: clips, settings: settings)
        }

        if showSnippetsInMain && settings.positionOfSnippets == 1 {
            if showHistory { menu.addItem(.separator()) }
            addSnippets(to: menu, folders: folders, settings: settings)
        }

        if showActionsInMain {
            menu.addItem(.separator())
            addActionsSubmenu(to: menu, clips: clips, context: context, runtime: runtime)
        }

        if showHistory && settings.showClearHistoryItem {
            menu.addItem(.separator())
            let clear = NSMenuItem(title: "Clear History", action: #selector(HotkeyPopupActionTarget.clearHistory(_:)), keyEquivalent: "")
            clear.target = actionTarget
            clear.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
            menu.addItem(clear)
        }

        menu.addItem(.separator())
        let editSnippets = NSMenuItem(title: "Edit Snippets…", action: #selector(HotkeyPopupActionTarget.openSnippetsEditor(_:)), keyEquivalent: "")
        editSnippets.target = actionTarget
        editSnippets.image = NSImage(systemSymbolName: "text.badge.plus", accessibilityDescription: nil)
        menu.addItem(editSnippets)

        let prefs = NSMenuItem(title: "Preferences…", action: #selector(HotkeyPopupActionTarget.openPreferences(_:)), keyEquivalent: "")
        prefs.target = actionTarget
        prefs.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(prefs)

        let quit = NSMenuItem(title: "Quit ClipMenu", action: #selector(HotkeyPopupActionTarget.quit(_:)), keyEquivalent: "")
        quit.target = actionTarget
        quit.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        menu.addItem(quit)

        if kind != .actions {
            actionTarget.filterRootMenu = menu
            // Lock width after all items (incl. image thumbnails) exist so toggling
            // images-only filter does not remasure the popup from a different set of rows.
            let locked = estimatedMenuWidth(for: menu, includingHidden: true)
            menu.minimumWidth = locked
            actionTarget.lockedFilterMenuWidth = locked
            if let bar = actionTarget.filterImagesButtonHost {
                bar.frame.size.width = locked
            }
        } else {
            actionTarget.lockedFilterMenuWidth = nil
        }

        for (idx, item) in menu.items.enumerated() {
            fputs("[DEBUG MENU ITEM \(idx)] '\(item.title)' isSeparator=\(item.isSeparatorItem) hasSubmenu=\(item.submenu != nil) rep=\(String(describing: type(of: item.representedObject as Any)))\n", stderr)
        }
        return menu
    }

    private func insertFilterMenuItems(into menu: NSMenu) {
        // Placeholder width; finalized once history/snippet rows are attached.
        let width = max(estimatedMenuWidth(for: menu, includingHidden: true), 280)
        let bar = ClipMenuFilterBarView(width: width)
        bar.searchField.delegate = actionTarget
        bar.onImagesFilterToggle = { [weak actionTarget] in
            actionTarget?.toggleImagesOnlyFilter()
        }
        bar.setImagesFilterActive(actionTarget.isImagesOnlyFilter)

        // Single search row. Do NOT set keyEquivalent to "/": AppKit then tries to
        // highlight this view-backed item, fails, and jumps to the first regular row.
        let filterItem = NSMenuItem(title: "Push / to search", action: nil, keyEquivalent: "")
        filterItem.toolTip = "Push / to search, then type to filter. Tab shows images only."
        filterItem.view = bar

        actionTarget.filterTitleMenuItem = filterItem
        actionTarget.filterSearchField = bar.searchField
        actionTarget.filterImagesButtonHost = bar

        menu.addItem(filterItem)
        menu.addItem(.separator())
    }

    private func addActionsSubmenu(to menu: NSMenu, clips: [ClipEntry], context: ModelContext, runtime: AppRuntime) {
        let actionsItem = NSMenuItem(title: "Actions", action: nil, keyEquivalent: "")
        actionsItem.image = NSImage(systemSymbolName: "bolt", accessibilityDescription: nil)

        guard let targetClip = clips.first else {
            let submenu = NSMenu(title: "Actions")
            submenu.minimumWidth = 240.0
            let empty = NSMenuItem(title: "No clips available", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
            actionsItem.submenu = submenu
            menu.addItem(actionsItem)
            return
        }

        let roots = (try? context.fetch(FetchDescriptor<ActionNode>(
            predicate: #Predicate<ActionNode> { $0.parent == nil },
            sortBy: [SortDescriptor(\ActionNode.sortIndex)]
        ))) ?? []

            let actionMenu = ActionMenuBuilder.makeMenu(
                from: roots,
                target: targetClip,
                service: runtime.actionService,
                executionContext: .transformOnly,
                postAction: { [weak self] in
                    await self?.pasteAfterActionIfNeeded(runtime: runtime)
                }
            )
        if actionMenu.items.isEmpty {
            let submenu = NSMenu(title: "Actions")
            submenu.minimumWidth = 240.0
            let empty = NSMenuItem(title: "No actions configured", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
            actionsItem.submenu = submenu
        } else {
            actionsItem.submenu = actionMenu
        }

        menu.addItem(actionsItem)
    }

    private func addActions(to menu: NSMenu, clips: [ClipEntry], context: ModelContext, runtime: AppRuntime) {
        guard let targetClip = clips.first else {
            let empty = NSMenuItem(title: "No clips available", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }

        let titleItem = NSMenuItem(title: "Actions for Most Recent Clip", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)
        menu.addItem(.separator())

        let roots = (try? context.fetch(FetchDescriptor<ActionNode>(
            predicate: #Predicate<ActionNode> { $0.parent == nil },
            sortBy: [SortDescriptor(\ActionNode.sortIndex)]
        ))) ?? []

            let actionsMenu = ActionMenuBuilder.makeMenu(
                from: roots,
                target: targetClip,
                service: runtime.actionService,
                executionContext: .transformOnly,
                postAction: { [weak self] in
                    await self?.pasteAfterActionIfNeeded(runtime: runtime)
                }
            )
        if actionsMenu.items.isEmpty {
            let empty = NSMenuItem(title: "No actions configured", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }

        while let first = actionsMenu.items.first {
            actionsMenu.removeItem(first)
            menu.addItem(first)
        }
    }

        @MainActor
        private func pasteAfterActionIfNeeded(runtime: AppRuntime) async {
            guard runtime.settings.autoPasteAfterSelection else { return }
            targetAppForPaste?.activate(options: [])
            try? await Task.sleep(nanoseconds: 180_000_000)
            await actionTarget.pasteFromHotkeyAction()
        }
    private func addSnippets(to menu: NSMenu, folders: [SnippetFolder], settings: ClipMenuSettings) {
        let enabledFolders = folders.filter(\.isEnabled)
        guard !enabledFolders.isEmpty else { return }

        if settings.showLabelsInMenu {
            let label = NSMenuItem(title: "Snippets", action: nil, keyEquivalent: "")
            label.isEnabled = false
            menu.addItem(label)
        }

        for folder in enabledFolders {
            let snippets = folder.snippets
                .filter(\.isEnabled)
                .sorted { $0.sortIndex < $1.sortIndex }

            guard !snippets.isEmpty else { continue }

            let folderItem = NSMenuItem(title: folder.title, action: nil, keyEquivalent: "")
            folderItem.image = folderMenuIcon(settings: settings)
            let submenu = NSMenu(title: folder.title)
            submenu.minimumWidth = 240.0
            for snippet in snippets {
                let item = NSMenuItem(title: snippet.title, action: #selector(HotkeyPopupActionTarget.selectSnippetMenuItem(_:)), keyEquivalent: "")
                item.target = actionTarget
                item.representedObject = snippet
                item.clipMenuFilterHaystack = snippetFilterHaystack(snippet: snippet, folderTitle: folder.title)
                submenu.addItem(item)
            }
            folderItem.submenu = submenu
            menu.addItem(folderItem)
        }
    }

    private func addHistory(to menu: NSMenu, clips: [ClipEntry], settings: ClipMenuSettings) {
        if settings.showLabelsInMenu {
            let label = NSMenuItem(title: "History", action: nil, keyEquivalent: "")
            label.isEnabled = false
            menu.addItem(label)
        }

        let inlineCount = max(settings.numberOfItemsInline, 0)
        let perFolder = max(settings.numberOfItemsInsideFolder, 1)

        let inlineClips = inlineCount == 0 ? [] : Array(clips.prefix(inlineCount))
        let folderClips = inlineCount == 0 ? clips : Array(clips.dropFirst(inlineCount))

        for (idx, clip) in inlineClips.enumerated() {
            let itemNumber = listNumber(for: idx, settings: settings)
            let item = NSMenuItem(title: clipTitle(for: clip, settings: settings, listNumber: itemNumber),
                                  action: #selector(HotkeyPopupActionTarget.selectClipMenuItem(_:)),
                                  keyEquivalent: "")
            item.target = actionTarget
            item.representedObject = clip
            if shouldShowTrailingNumericShortcut(settings: settings) {
                item.keyEquivalent = String(itemNumber % 10)
                item.keyEquivalentModifierMask = []
            }
            if let thumbnail = thumbnailImage(for: clip, settings: settings) {
                item.attributedTitle = imageClipTitle(title: item.title, thumbnail: thumbnail)
                HotkeyService.log.debug("Attached inline popup thumbnail for clip index=\(idx, privacy: .public)")
            } else if clip.imageData != nil {
                HotkeyService.log.debug("Inline popup clip has imageData but no thumbnail index=\(idx, privacy: .public) bytes=\(clip.imageData?.count ?? 0, privacy: .public)")
            }
            item.clipMenuFilterHaystack = clipFilterHaystack(clip)
            menu.addItem(item)
        }

        let groups = stride(from: 0, to: folderClips.count, by: perFolder).map {
            Array(folderClips[$0..<min($0 + perFolder, folderClips.count)])
        }

        for (groupIndex, group) in groups.enumerated() {
            let start = inlineCount + groupIndex * perFolder + 1
            let end = start + group.count - 1
            let folderItem = NSMenuItem(title: "\(start) - \(end)", action: nil, keyEquivalent: "")
            folderItem.image = folderMenuIcon(settings: settings)

            let submenu = NSMenu(title: folderItem.title)
            submenu.minimumWidth = 240.0
            for (idx, clip) in group.enumerated() {
                let absoluteIndex = inlineCount + groupIndex * perFolder + idx
                let itemNumber = listNumber(for: absoluteIndex, settings: settings)
                let item = NSMenuItem(title: clipTitle(for: clip, settings: settings, listNumber: itemNumber),
                                      action: #selector(HotkeyPopupActionTarget.selectClipMenuItem(_:)),
                                      keyEquivalent: "")
                item.target = actionTarget
                item.representedObject = clip
                if shouldShowTrailingNumericShortcut(settings: settings) {
                    item.keyEquivalent = String(itemNumber % 10)
                    item.keyEquivalentModifierMask = []
                }
                if let thumbnail = thumbnailImage(for: clip, settings: settings) {
                    item.attributedTitle = imageClipTitle(title: item.title, thumbnail: thumbnail)
                    HotkeyService.log.debug("Attached grouped popup thumbnail group=\(groupIndex, privacy: .public) idx=\(idx, privacy: .public)")
                } else if clip.imageData != nil {
                    HotkeyService.log.debug("Grouped popup clip has imageData but no thumbnail group=\(groupIndex, privacy: .public) idx=\(idx, privacy: .public) bytes=\(clip.imageData?.count ?? 0, privacy: .public)")
                }
                item.clipMenuFilterHaystack = clipFilterHaystack(clip)
                submenu.addItem(item)
            }

            folderItem.submenu = submenu
            menu.addItem(folderItem)
        }
    }

    private func listNumber(for index: Int, settings: ClipMenuSettings) -> Int {
        if settings.numberingStartsAtZero {
            return index % 10
        }
        let n = index + 1
        return n > 10 ? n % 10 : n
    }

    private func shouldShowTrailingNumericShortcut(settings: ClipMenuSettings) -> Bool {
        false
    }

    private func clipTitle(for clip: ClipEntry, settings: ClipMenuSettings, listNumber: Int) -> String {
        let source = clip.stringValue
            ?? clip.filenames?.first
            ?? clip.urlStrings?.first
            ?? ""

        let stripped = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine: String
        if let nl = stripped.firstIndex(of: "\n") {
            firstLine = String(stripped[..<nl])
        } else {
            firstLine = stripped
        }

        let maxLen = max(settings.maxMenuItemTitleLength, 45) // Boost default bounds against old cached defaults of 20
        let trimmed: String
        if firstLine.count > maxLen {
            trimmed = String(firstLine.prefix(max(maxLen - 3, 0))) + "..."
        } else if firstLine.isEmpty, clip.imageData != nil {
            trimmed = ""
        } else {
            trimmed = firstLine.isEmpty ? "(binary)" : firstLine
        }

        if settings.numberedMenuItems {
            return trimmed.isEmpty ? "\(listNumber)." : "\(listNumber). \(trimmed)"
        }
        return trimmed
    }

    private func imageClipTitle(title: String, thumbnail: NSImage) -> NSAttributedString {
        let result = NSMutableAttributedString(string: title.isEmpty ? "" : "\(title) ")
        let attachment = NSTextAttachment()
        attachment.image = thumbnail
        result.append(NSAttributedString(attachment: attachment))
        return result
    }

    private func thumbnailImage(for clip: ClipEntry, settings: ClipMenuSettings) -> NSImage? {
        guard settings.showImageInMenu,
              let imageData = clip.imageData,
              let image = decodedImage(from: imageData)
        else {
            if clip.imageData != nil {
                HotkeyService.log.debug("Popup thumbnail decode failed bytes=\(clip.imageData?.count ?? 0, privacy: .public)")
            }
            return nil
        }

        let targetSize = NSSize(width: CGFloat(settings.thumbnailWidth),
                                height: CGFloat(settings.thumbnailHeight))
        return scaledImage(image, to: targetSize)
    }

    private func folderMenuIcon(settings: ClipMenuSettings) -> NSImage? {
        guard let image = NSImage(named: NSImage.folderName) else { return nil }
        let size = CGFloat(max(settings.menuIconSize, 1))
        return scaledImage(image, to: NSSize(width: size, height: size))
    }

    private func scaledImage(_ image: NSImage, to size: NSSize) -> NSImage {
        guard image.size.width > 0, image.size.height > 0,
              size.width > 0, size.height > 0 else {
            return image
        }

        let ratio = min(size.width / image.size.width, size.height / image.size.height)
        let drawSize = NSSize(width: image.size.width * ratio, height: image.size.height * ratio)
        let drawOrigin = NSPoint(x: (size.width - drawSize.width) / 2,
                                 y: (size.height - drawSize.height) / 2)

        let scaled = NSImage(size: size)
        scaled.lockFocus()
        image.draw(in: NSRect(origin: drawOrigin, size: drawSize),
                   from: .zero,
                   operation: .sourceOver,
                   fraction: 1.0)
        scaled.unlockFocus()
        return scaled
    }

    private func decodedImage(from data: Data) -> NSImage? {
        if let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 {
            HotkeyService.log.debug("Popup decode via NSImage size=\(Int(image.size.width), privacy: .public)x\(Int(image.size.height), privacy: .public)")
            return image
        }

        if let rep = NSBitmapImageRep(data: data) {
            let image = NSImage(size: rep.size)
            image.addRepresentation(rep)
            HotkeyService.log.debug("Popup decode via NSBitmapImageRep size=\(Int(rep.size.width), privacy: .public)x\(Int(rep.size.height), privacy: .public)")
            return image
        }

        HotkeyService.log.debug("Popup decode failed for image bytes=\(data.count, privacy: .public)")
        return NSImage(data: data)
    }
}

enum TestPopupSource {
    case hotkey
    case status
}

struct TestPopupNode: Identifiable {
    let id: String
    let title: String
    let clip: ClipEntry?
    let snippet: Snippet?
    let children: [TestPopupNode]
    let isEnabled: Bool
    let isSeparator: Bool
    let level: Int

    var isFolder: Bool { !children.isEmpty }
}

@MainActor
final class ClipMenuTestPopupStore: ObservableObject {
    static let shared = ClipMenuTestPopupStore()

    @Published private(set) var levels: [Int: [TestPopupNode]] = [:]
    @Published private(set) var selectedNodeIDs: [Int: String] = [:]
    @Published private(set) var previewNode: TestPopupNode?
    @Published private(set) var previewLevel: Int?
    @Published private(set) var source: TestPopupSource = .hotkey
    @Published private(set) var isVisible = false

    var activationHandler: ((TestPopupNode) -> Void)?
    private var previewTask: Task<Void, Never>?

    func show(nodes: [TestPopupNode], source: TestPopupSource) {
        dismiss()
        self.source = source
        levels[0] = nodes
        isVisible = true
        if let first = nodes.first(where: { !$0.isSeparator && $0.isEnabled }) {
            select(node: first, level: 0, openSubmenu: false, schedulePreview: source == .status)
        }
    }

    func dismiss() {
        previewTask?.cancel()
        previewTask = nil
        levels = [:]
        selectedNodeIDs = [:]
        previewNode = nil
        previewLevel = nil
        isVisible = false
    }

    func hover(node: TestPopupNode, level: Int) {
        select(node: node, level: level, openSubmenu: true, schedulePreview: true)
    }

    func moveSelection(delta: Int, level: Int) {
        guard let nodes = levels[level] else { return }
        let interactive = nodes.filter { !$0.isSeparator && $0.isEnabled }
        guard !interactive.isEmpty else { return }

        let currentIndex = interactive.firstIndex(where: { $0.id == selectedNodeIDs[level] }) ?? -1
        let nextIndex = max(0, min(interactive.count - 1, currentIndex + delta))
        select(node: interactive[nextIndex], level: level, openSubmenu: true, schedulePreview: true)
    }

    func openSelectedSubmenu(level: Int) {
        guard let selectedID = selectedNodeIDs[level],
              let node = levels[level]?.first(where: { $0.id == selectedID }),
              node.isFolder else { return }
        select(node: node, level: level, openSubmenu: true, schedulePreview: false)
    }

    func closeSubmenu(level: Int) {
        guard level > 0 else { return }
        for key in levels.keys where key >= level {
            levels.removeValue(forKey: key)
            selectedNodeIDs.removeValue(forKey: key)
        }
        previewNode = nil
        previewLevel = nil
    }

    func activateSelected(level: Int) {
        guard let selectedID = selectedNodeIDs[level],
              let node = levels[level]?.first(where: { $0.id == selectedID })
        else { return }

        if node.isFolder {
            select(node: node, level: level, openSubmenu: true, schedulePreview: false)
            return
        }

        activationHandler?(node)
        dismiss()
    }

    func openFirstFolderSubmenu() {
        guard let firstFolder = levels[0]?.first(where: { $0.isFolder && $0.isEnabled }) else { return }
        select(node: firstFolder, level: 0, openSubmenu: true, schedulePreview: false)
    }

    private func select(node: TestPopupNode, level: Int, openSubmenu: Bool, schedulePreview: Bool) {
        selectedNodeIDs[level] = node.id

        if ProcessInfo.processInfo.environment["CLIPMENU_UI_TEST_MODE"] == "1" {
            let title = node.clip?.stringValue ?? node.snippet?.title ?? node.title
            NotificationCenter.default.post(
                name: .clipMenuHighlightDidChange,
                object: nil,
                userInfo: ["title": title]
            )
        }

        if node.isFolder && openSubmenu {
            levels[level + 1] = node.children
            if let first = node.children.first(where: { !$0.isSeparator && $0.isEnabled }) {
                selectedNodeIDs[level + 1] = first.id
                schedulePreviewIfNeeded(for: first, level: level + 1)
            }
        } else {
            for key in levels.keys where key > level {
                levels.removeValue(forKey: key)
                selectedNodeIDs.removeValue(forKey: key)
            }
        }

        guard schedulePreview else {
            previewTask?.cancel()
            previewNode = nil
            previewLevel = nil
            return
        }

        schedulePreviewIfNeeded(for: node, level: level)
    }

    private func schedulePreviewIfNeeded(for node: TestPopupNode, level: Int) {
        previewTask?.cancel()
        previewNode = nil
        previewLevel = nil
        guard node.clip != nil || node.snippet != nil else { return }

        previewTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            previewNode = node
            previewLevel = level
        }
    }

    func selectedNodeID(for level: Int) -> String? {
        selectedNodeIDs[level]
    }

    func nodes(for level: Int) -> [TestPopupNode] {
        levels[level] ?? []
    }

    func isSelected(_ node: TestPopupNode, level: Int) -> Bool {
        selectedNodeIDs[level] == node.id
    }
}

private enum ClipPreviewItem {
    case clip(ClipEntry)
    case snippet(Snippet)

    var persistentModelID: PersistentIdentifier {
        switch self {
        case .clip(let c): return c.persistentModelID
        case .snippet(let s): return s.persistentModelID
        }
    }
}

@MainActor
private final class ClipPreviewPanelController {
    private let panel: NSWindow
    private let hostingController = NSHostingController(rootView: AnyView(EmptyView()))
    private weak var parentWindow: NSWindow?
    private let isUITestMode = ProcessInfo.processInfo.environment["CLIPMENU_UI_TEST_MODE"] == "1"

    init() {
        if isUITestMode {
            panel = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
                styleMask: [.titled, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
        } else {
            panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
        }
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .screenSaver // Maximum possible window-level to guarantee z-index superiority
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.collectionBehavior = [.transient, .ignoresCycle]
        panel.contentViewController = hostingController
        if isUITestMode {
            panel.title = "Clip Preview"
            panel.titleVisibility = .visible
            panel.titlebarAppearsTransparent = true
            panel.isMovable = false
            panel.standardWindowButton(.closeButton)?.isHidden = true
            panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
            panel.standardWindowButton(.zoomButton)?.isHidden = true
            panel.setAccessibilityIdentifier("clipPreviewPanel")
        } else if let panel = panel as? NSPanel {
            panel.isFloatingPanel = true
        }
    }

    var panelWindow: NSWindow { panel }

    func show(
        item: ClipPreviewItem,
        near point: NSPoint,
        menuFrame: NSRect = .zero,
        preferredSide: PreviewSide = .right,
        otherMenuFrames: [NSRect] = [],
        parentWindow: NSWindow? = nil
    ) {
        let size = ClipPreviewContentView.preferredSize(for: item)
        hostingController.rootView = AnyView(
            ClipPreviewContentView(item: item, preferredSize: size)
                .accessibilityIdentifier("clipPreviewContent")
        )
        panel.setContentSize(size)
        position(near: point, menuFrame: menuFrame, preferredSide: preferredSide, otherMenuFrames: otherMenuFrames)

        if self.parentWindow !== parentWindow {
            self.parentWindow?.removeChildWindow(panel)
            self.parentWindow = parentWindow
        }

        if let parentWindow {
            if panel.parent == nil {
                parentWindow.addChildWindow(panel, ordered: .above)
            }
            panel.orderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
        fputs("[DEBUG] ClipPreviewPanelController.show size=\(size) frame=\(panel.frame) isVisible=\(panel.isVisible) level=\(panel.level.rawValue)\n", stderr)

        if isUITestMode {
            let (title, hasImage): (String, Bool)
            switch item {
            case .clip(let clip):
                title = clip.stringValue ?? ""
                hasImage = clip.imageData != nil
            case .snippet(let snippet):
                title = snippet.title
                hasImage = false
            }
            NotificationCenter.default.post(
                name: .clipMenuPreviewDidShow,
                object: nil,
                userInfo: [
                    "title": title,
                    "hasImage": hasImage,
                    "frame": NSStringFromRect(panel.frame)
                ]
            )
        }
    }

    func hide() {
        parentWindow?.removeChildWindow(panel)
        parentWindow = nil
        panel.orderOut(nil)

        if isUITestMode {
            NotificationCenter.default.post(name: .clipMenuPreviewDidHide, object: nil)
        }
    }

    private func position(
        near point: NSPoint,
        menuFrame: NSRect,
        preferredSide: PreviewSide,
        otherMenuFrames: [NSRect]
    ) {
        let size = panel.frame.size
        let probe = menuFrame.width > 0 ? NSPoint(x: menuFrame.midX, y: menuFrame.midY) : point
        let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) })
            ?? NSScreen.screens.first(where: { NSMouseInRect(probe, $0.frame, false) })
            ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let gap: CGFloat = 8

        var y = point.y - (size.height / 2)
        if y < visible.minY + gap {
            y = visible.minY + gap
        }
        if y + size.height > visible.maxY - gap {
            y = visible.maxY - size.height - gap
        }

        let obstacles: [NSRect]
        if !otherMenuFrames.isEmpty {
            obstacles = otherMenuFrames
        } else if menuFrame.width > 0, menuFrame.height > 0 {
            obstacles = [menuFrame]
        } else {
            obstacles = []
        }

        let clusterSeed = menuFrame.width > 0 ? menuFrame : NSRect(origin: point, size: .zero)
        let cluster = obstacles.reduce(clusterSeed) { $0.union($1) }
        let adjacentFrame = menuFrame.width > 0 ? menuFrame : cluster

        func rect(beside frame: NSRect, side: PreviewSide) -> NSRect {
            let x = side == .left ? frame.minX - size.width - gap : frame.maxX + gap
            return NSRect(x: x, y: y, width: size.width, height: size.height)
        }

        func isOnscreen(_ rect: NSRect) -> Bool {
            rect.minX >= visible.minX + gap - 0.5 && rect.maxX <= visible.maxX - gap + 0.5
        }

        func overlapsMenus(_ rect: NSRect) -> Bool {
            guard !obstacles.isEmpty else { return false }
            let padded = rect.insetBy(dx: -2, dy: -2)
            return obstacles.contains { $0.intersects(padded) }
        }

        var chosen = rect(beside: adjacentFrame, side: preferredSide)
        if !isOnscreen(chosen) || overlapsMenus(chosen) {
            let outer = rect(beside: cluster, side: preferredSide)
            if isOnscreen(outer) && !overlapsMenus(outer) {
                chosen = outer
            } else {
                let flipped = rect(beside: cluster, side: preferredSide.flipped)
                if isOnscreen(flipped) && !overlapsMenus(flipped) {
                    chosen = flipped
                } else if isOnscreen(outer) {
                    chosen = outer
                } else if isOnscreen(flipped) {
                    chosen = flipped
                }
            }
        }

        var origin = chosen.origin
        let clampedX = min(max(origin.x, visible.minX + gap), visible.maxX - size.width - gap)
        let clampedRect = NSRect(x: clampedX, y: origin.y, width: size.width, height: size.height)
        if !overlapsMenus(clampedRect) {
            origin.x = clampedX
        }

        panel.setFrameOrigin(origin)
    }
}

private struct ClipPreviewContentView: View {
    let item: ClipPreviewItem
    let preferredSize: CGSize

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let image = previewImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: imageHeight)
            }

            if let text = textPreview {
                Text(text)
                    .font(.system(size: NSFont.systemFontSize))
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .frame(width: preferredSize.width, height: preferredSize.height, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    private var imageHeight: CGFloat {
        max(80, preferredSize.height - 28 - (textPreview == nil ? 0 : 70))
    }

    private var textPreview: String? {
        switch item {
        case .clip(let clip):
            if let stringValue = clip.stringValue, !stringValue.isEmpty { return stringValue }
            if let filenames = clip.filenames, !filenames.isEmpty { return filenames.joined(separator: "\n") }
            if let urls = clip.urlStrings, !urls.isEmpty { return urls.joined(separator: "\n") }
            return previewImage == nil ? "(binary)" : nil
        case .snippet(let snippet):
            return snippet.content.isEmpty ? "(empty)" : snippet.content
        }
    }

    private var previewImage: NSImage? {
        switch item {
        case .clip(let clip):
            return Self.clipImage(from: clip.imageData)
        case .snippet:
            return nil
        }
    }

    static func preferredSize(for item: ClipPreviewItem) -> CGSize {
        switch item {
        case .clip(let clip):
            return preferredSizeForClip(clip)
        case .snippet(let snippet):
            let text = snippet.content.isEmpty ? "(empty)" : snippet.content
            return preferredSizeForText(text)
        }
    }

    private static func preferredSizeForClip(_ clip: ClipEntry) -> CGSize {
        let horizontalPadding: CGFloat = 28
        let verticalPadding: CGFloat = 28
        let maxWidth: CGFloat = 480
        let minWidth: CGFloat = 200
        let maxHeight: CGFloat = 600
        let minHeight: CGFloat = 90

        if let image = clipImage(from: clip.imageData) {
            let maxImageWidth: CGFloat = 380
            let maxImageHeight: CGFloat = 280
            let scale = min(maxImageWidth / max(image.size.width, 1),
                            maxImageHeight / max(image.size.height, 1),
                            1)
            let imageWidth = max(120, image.size.width * scale)
            let imageHeight = max(90, image.size.height * scale)

            if let text = clipTextPreview(for: clip) {
                let textRect = text.boundingRect(
                    with: NSSize(width: max(imageWidth, 320), height: 1000),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]
                )
                let width = min(max(max(imageWidth, ceil(textRect.width)) + horizontalPadding, minWidth), maxWidth)
                let height = min(max(imageHeight + min(ceil(textRect.height), 280) + verticalPadding + 12, minHeight), maxHeight)
                return CGSize(width: width, height: height)
            }

            return CGSize(
                width: min(max(imageWidth + horizontalPadding, minWidth), maxWidth),
                height: min(max(imageHeight + verticalPadding, minHeight), maxHeight)
            )
        }

        let text = clipTextPreview(for: clip) ?? "(binary)"
        return preferredSizeForText(text)
    }

    private static func preferredSizeForText(_ text: String) -> CGSize {
        let horizontalPadding: CGFloat = 28
        let verticalPadding: CGFloat = 28
        let maxWidth: CGFloat = 480
        let minWidth: CGFloat = 220
        let maxHeight: CGFloat = 720
        let minHeight: CGFloat = 90
        let textWidth: CGFloat = 400

        let rect = text.boundingRect(
            with: NSSize(width: textWidth, height: 3000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]
        )
        return CGSize(
            width: min(max(ceil(rect.width) + horizontalPadding, minWidth), maxWidth),
            height: min(max(ceil(rect.height) + verticalPadding, minHeight), maxHeight)
        )
    }

    private static func clipTextPreview(for clip: ClipEntry) -> String? {
        if let stringValue = clip.stringValue, !stringValue.isEmpty { return stringValue }
        if let filenames = clip.filenames, !filenames.isEmpty { return filenames.joined(separator: "\n") }
        if let urls = clip.urlStrings, !urls.isEmpty { return urls.joined(separator: "\n") }
        return nil
    }

    private static func clipImage(from data: Data?) -> NSImage? {
        guard let data else { return nil }
        if let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 { return image }
        if let rep = NSBitmapImageRep(data: data) {
            let image = NSImage(size: rep.size)
            image.addRepresentation(rep)
            return image
        }
        return NSImage(data: data)
    }
}

private final class HotkeyPopupActionTarget: NSObject {
    private static let menuDismissSettleDelay: UInt64 = 40_000_000
    private static let reactivationSettleDelay: UInt64 = 40_000_000
    private static let prePasteDelay: UInt64 = 70_000_000

    weak var runtime: AppRuntime?
    weak var targetAppForPaste: NSRunningApplication?
    weak var filterRootMenu: NSMenu?
    weak var filterSearchField: ClipMenuSearchField?
    weak var filterTitleMenuItem: NSMenuItem?
    weak var filterImagesButtonHost: ClipMenuFilterBarView?
    /// Width locked when the menu is built so filter toggles do not resize the popup.
    var lockedFilterMenuWidth: CGFloat?
    /// True after `/` until Escape / ↓ / highlight leaves the filter.
    private(set) var isFilterModeActive = false
    /// When true, only clipboard rows with image data remain visible.
    private(set) var isImagesOnlyFilter = false
    private var isSuppressingContentHighlight = false
    private let pasteService = PasteService()
    /// Modifiers observed while the popup menu is open (flags can clear before the item action runs).
    private var trackedModifierFlags: NSEvent.ModifierFlags = []
    private var modifierMonitor: Any?
    /// Menu tracking runs in `.eventTracking`; a local flagsChanged monitor alone often misses
    /// modifier presses while the popup is already open over a clip.
    private var modifierPollTimer: Timer?
    /// Last row reported by `menu:willHighlight:` (more reliable than `highlightedItem` mid-tracking).
    private weak var lastHighlightedMenuItem: NSMenuItem?
    /// Clip/snippet row that currently has a dynamically attached actions submenu.
    private weak var actionSubmenuHostItem: NSMenuItem?
    private var actionSubmenuHostBackup: (action: Selector?, target: AnyObject?)?
    /// Strong retain so choosing an action still works after we detach from the host row.
    private var retainedActionSubmenu: NSMenu?
    /// Keep the clip being acted on alive for the action menu's lifetime.
    private var retainedActionTargetClip: ClipEntry?

    func beginSlashKeyMonitorIfNeeded() {
        installModifierMonitorIfNeeded()
        guard filterSearchField != nil else { return }
        ClipMenuFilterKeyHook.setActiveTarget(self)
    }

    private func installModifierMonitorIfNeeded() {
        guard modifierMonitor == nil else { return }
        trackedModifierFlags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        modifierMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged, .leftMouseDown, .leftMouseUp, .rightMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            self.trackedModifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // Attach before click/Return so the cascade opens instead of dismissing ClipMenu.
            if event.type == .flagsChanged || event.type == .leftMouseDown || event.type == .keyDown {
                MainActor.assumeIsolated {
                    self.refreshActionSubmenuAttachment()
                }
            }
            return event
        }

        // Poll modifiers in the menu-tracking run loop so pressing the action key while
        // already hovered still attaches/opens the cascade.
        let timer = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
                guard flags != self.trackedModifierFlags else { return }
                self.trackedModifierFlags = flags
                self.refreshActionSubmenuAttachment()
            }
        }
        RunLoop.main.add(timer, forMode: .eventTracking)
        RunLoop.main.add(timer, forMode: .default)
        modifierPollTimer = timer
    }

    private func removeModifierMonitor() {
        clearAttachedActionSubmenu()
        lastHighlightedMenuItem = nil
        modifierPollTimer?.invalidate()
        modifierPollTimer = nil
        if let modifierMonitor {
            NSEvent.removeMonitor(modifierMonitor)
            self.modifierMonitor = nil
        }
        trackedModifierFlags = []
    }

    private func selectionModifierFlags() -> NSEvent.ModifierFlags {
        let fromEvent = (NSApp.currentEvent?.modifierFlags ?? []).intersection(.deviceIndependentFlagsMask)
        let live = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return fromEvent.union(live).union(trackedModifierFlags)
    }

    private func isActionModifierHeld() -> Bool {
        guard let runtime else { return false }
        return selectionModifierFlags().contains(actionModifierMask(for: runtime.settings.actionModifierKey))
    }

    /// Attach/remove the actions submenu on the highlighted clip/snippet so it cascades
    /// beside the still-open ClipMenu popup while the action modifier is held.
    @MainActor
    func refreshActionSubmenuAttachment(highlighted: NSMenuItem? = nil) {
        if let highlighted {
            lastHighlightedMenuItem = highlighted
        }
        // Prefer the live highlight argument, then last hovered row, then AppKit's idea of highlight.
        // `willHighlight(nil)` is common when modifiers change — don't drop the hovered clip.
        let item = highlighted
            ?? lastHighlightedMenuItem
            ?? findHighlightedMenuItem(in: filterRootMenu)
        updateActionSubmenu(for: item)
    }

    private func findHighlightedMenuItem(in menu: NSMenu?) -> NSMenuItem? {
        guard let menu else { return nil }
        if let item = menu.highlightedItem {
            if let submenu = item.submenu, let nested = findHighlightedMenuItem(in: submenu) {
                return nested
            }
            return item
        }
        for child in menu.items {
            if let submenu = child.submenu, let nested = findHighlightedMenuItem(in: submenu) {
                return nested
            }
        }
        return nil
    }

    @MainActor
    private func updateActionSubmenu(for item: NSMenuItem?) {
        // Modifier summons the cascade; releasing it must NOT tear the menu down mid-choice.
        if let host = actionSubmenuHostItem, host.submenu != nil {
            if item == nil || item === host {
                return
            }
            // Highlight moved into the actions submenu itself — keep showing.
            if isItem(item!, inSubtreeOf: host.submenu) {
                return
            }
            if actionTargetClip(from: item!) != nil {
                // Different clip/snippet — retarget only while modifier is still held.
                guard isActionModifierHeld() else { return }
                clearAttachedActionSubmenu()
            } else {
                clearAttachedActionSubmenu()
                return
            }
        }

        guard isActionModifierHeld(),
              let item,
              let runtime,
              let context = runtime.modelContainer?.mainContext,
              let targetClip = actionTargetClip(from: item)
        else {
            return
        }

        // Folder rows already have real submenus — don't replace them.
        if item.submenu != nil && actionSubmenuHostItem !== item {
            return
        }

        if actionSubmenuHostItem === item, item.submenu != nil {
            return
        }

        clearAttachedActionSubmenu()

        let roots = (try? context.fetch(FetchDescriptor<ActionNode>(
            predicate: #Predicate<ActionNode> { $0.parent == nil },
            sortBy: [SortDescriptor(\.sortIndex)]
        ))) ?? []
        let enabledRoots = roots.filter(\.isEnabled)
        let leaves = enabledLeafActions(from: enabledRoots)

        // Single leaf still uses click-to-run; no submenu needed.
        guard leaves.count != 1 else { return }

        // Keep the live history clip (in the model context). An uninserted SwiftData
        // snapshot often reads back nil fields, so the action no-ops and Cmd+V
        // pastes the previous pasteboard contents.
        retainedActionTargetClip = targetClip

        let actionsMenu = ActionMenuBuilder.makeMenu(
            from: enabledRoots,
            target: targetClip,
            service: runtime.actionService,
            // Transform first; paste after we reactivate the app that invoked ClipMenu.
            executionContext: .transformOnly,
            postAction: { [weak self] in
                await self?.finishHotkeyActionPaste()
            }
        )
        actionsMenu.minimumWidth = 240.0
        actionsMenu.autoenablesItems = false
        if actionsMenu.items.isEmpty {
            let empty = NSMenuItem(title: "No actions configured", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            actionsMenu.addItem(empty)
        }

        actionSubmenuHostBackup = (item.action, item.target)
        // Submenu-only: click/→ opens the cascade and keeps ClipMenu visible.
        item.action = nil
        item.target = nil
        item.submenu = actionsMenu
        actionSubmenuHostItem = item
        retainedActionSubmenu = actionsMenu

        // AppKit won't notice a submenu attached after highlight — re-kick and open it.
        rehighlightMenuItem(item)
        openSubmenu(for: item)
    }

    private func isItem(_ item: NSMenuItem, inSubtreeOf menu: NSMenu?) -> Bool {
        guard let menu else { return false }
        for candidate in menu.items {
            if candidate === item { return true }
            if isItem(item, inSubtreeOf: candidate.submenu) { return true }
        }
        return false
    }

    private func clearAttachedActionSubmenu() {
        guard actionSubmenuHostItem != nil || retainedActionSubmenu != nil else { return }
        let host = actionSubmenuHostItem
        let backup = actionSubmenuHostBackup
        let retained = retainedActionSubmenu
        let retainedClip = retainedActionTargetClip
        actionSubmenuHostItem = nil
        actionSubmenuHostBackup = nil

        // Defer destruction so NSMenu can deliver the clicked item's action first.
        DispatchQueue.main.async { [weak self] in
            if let host {
                if host.submenu === retained {
                    host.submenu = nil
                }
                if let backup {
                    host.action = backup.action
                    host.target = backup.target
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if self.retainedActionSubmenu === retained {
                    self.retainedActionSubmenu = nil
                }
                if self.retainedActionTargetClip === retainedClip {
                    self.retainedActionTargetClip = nil
                }
            }
        }
    }

    private func rehighlightMenuItem(_ item: NSMenuItem) {
        guard let menu = item.menu else { return }
        for name in ["highlightItem:", "_highlightItem:"] {
            let sel = NSSelectorFromString(name)
            guard menu.responds(to: sel) else { continue }
            menu.perform(sel, with: nil)
            menu.perform(sel, with: item)
            return
        }
    }

    private func openSubmenu(for item: NSMenuItem) {
        guard let menu = item.menu, item.submenu != nil else { return }
        for name in ["_openSubmenuForItem:", "openSubmenuForItem:"] {
            let sel = NSSelectorFromString(name)
            guard menu.responds(to: sel) else { continue }
            menu.perform(sel, with: item)
            return
        }
        // Fallback: right-arrow opens the highlighted item's submenu.
        let winNum = NSApp.keyWindow?.windowNumber ?? 0
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: winNum,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 124
        ) else { return }
        NSApp.postEvent(event, atStart: false)
    }

    private func actionTargetClip(from item: NSMenuItem) -> ClipEntry? {
        if let clip = item.representedObject as? ClipEntry {
            return clip
        }
        if let snippet = item.representedObject as? Snippet {
            let mock = ClipEntry()
            mock.stringValue = snippet.content
            mock.types = ["public.utf8-plain-text"]
            return mock
        }
        return nil
    }

    /// Called from the CGEvent tap on the main thread. Return true to swallow the key.
    fileprivate func handleGlobalKeyDown(cgEvent: CGEvent) -> Bool {
        guard filterSearchField != nil else { return false }

        let flags = cgEvent.flags
        if flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate) {
            return false
        }

        let keyCode = cgEvent.getIntegerValueField(.keyboardEventKeycode)
        let shift = flags.contains(.maskShift)

        if !isFilterModeActive {
            // Only `/` enters filter mode. Leave numbers/letters for menu type-ahead.
            guard isUnmodifiedSlash(keyCode: keyCode, shift: shift, cgEvent: cgEvent) else {
                return false
            }
            enterFilterMode()
            return true
        }

        // Filter mode: own typing so the menu cannot type-ahead.
        switch keyCode {
        case 53: // escape
            exitFilterMode(clearQuery: true)
            return true
        case 125: // down arrow — hand control back to the menu list
            exitFilterMode(clearQuery: false)
            return false
        case 51: // delete
            deleteLastFilterCharacter()
            return true
        case 36, 76: // return / keypad enter — stay in filter, don't activate a row
            return true
        case 48: // tab — toggle images-only filter
            toggleImagesOnlyFilter()
            return true
        default:
            if let chars = characters(from: cgEvent), !chars.isEmpty {
                appendFilterCharacters(chars)
                return true
            }
            // Unknown key while filtering — swallow to avoid accidental menu jumps.
            return true
        }
    }

    var isFilterModeActiveForTesting: Bool { isFilterModeActive }

    private func enterFilterMode() {
        isFilterModeActive = true
        // IMPORTANT: never setHighlightedItem(filterRow). AppKit cannot highlight a
        // view-backed row and jumps to the first real menu item — the bug users saw.
        clearMenuHighlight()
        filterSearchField?.activateForTypingFromMenuHighlight()
        applyCurrentFilterQuery()
        fputs("[ClipMenu] Filter mode ON\n", stderr)
    }

    private func exitFilterMode(clearQuery: Bool) {
        isFilterModeActive = false
        if clearQuery, let field = filterSearchField {
            field.stringValue = ""
            setImagesOnlyFilter(false)
            applyCurrentFilterQuery()
        }
        filterSearchField?.releaseTypingCaptureForMenuNavigation()
        if let window = filterSearchField?.window ?? NSApp.keyWindow {
            window.makeFirstResponder(nil)
        }
        fputs("[ClipMenu] Filter mode OFF\n", stderr)
    }

    func toggleImagesOnlyFilter() {
        setImagesOnlyFilter(!isImagesOnlyFilter)
        if isImagesOnlyFilter, !isFilterModeActive {
            enterFilterMode()
        } else {
            applyCurrentFilterQuery()
        }
    }

    private func setImagesOnlyFilter(_ enabled: Bool) {
        isImagesOnlyFilter = enabled
        filterImagesButtonHost?.setImagesFilterActive(enabled)
    }

    private func clearMenuHighlight() {
        guard let menu = filterTitleMenuItem?.menu else { return }
        // Modern AppKit exposes `highlightItem:` (private). `setHighlightedItem:` does not exist.
        for name in ["highlightItem:", "setHighlightedItem:", "_highlightItem:"] {
            let sel = NSSelectorFromString(name)
            guard menu.responds(to: sel) else { continue }
            menu.perform(sel, with: nil)
            return
        }
    }

    private func appendFilterCharacters(_ chars: String) {
        guard let field = filterSearchField else { return }
        field.stringValue += chars
        syncFilterFieldEditor(field)
        applyCurrentFilterQuery()
    }

    private func deleteLastFilterCharacter() {
        guard let field = filterSearchField, !field.stringValue.isEmpty else { return }
        field.stringValue.removeLast()
        syncFilterFieldEditor(field)
        applyCurrentFilterQuery()
    }

    private func syncFilterFieldEditor(_ field: ClipMenuSearchField) {
        guard let window = field.window ?? NSApp.keyWindow,
              let editor = window.fieldEditor(false, for: field) as? NSTextView
        else {
            field.refreshFallbackCaret()
            return
        }
        if editor.string != field.stringValue {
            editor.string = field.stringValue
        }
        let end = editor.string.utf16.count
        editor.setSelectedRange(NSRange(location: end, length: 0))
        editor.insertionPointColor = .clear
        field.refreshFallbackCaret()
    }

    private func applyCurrentFilterQuery() {
        guard let field = filterSearchField else { return }
        let menu = field.enclosingMenuItem?.menu ?? filterRootMenu
        guard let menu else { return }
        ClipMenuFilter.apply(query: field.stringValue, imagesOnly: isImagesOnlyFilter, to: menu)
        // Re-assert after visibility changes — AppKit otherwise remasures from visible rows.
        if let locked = lockedFilterMenuWidth {
            menu.minimumWidth = locked
            filterImagesButtonHost?.frame.size.width = locked
        }
    }

    private func isUnmodifiedSlash(keyCode: Int64, shift: Bool, cgEvent: CGEvent) -> Bool {
        if keyCode == 75 { return true } // keypad /
        if keyCode == 44 { return !shift } // `/` vs `?`
        if let chars = characters(from: cgEvent), chars == "/" { return true }
        return false
    }

    private func characters(from cgEvent: CGEvent) -> String? {
        guard let nsEvent = NSEvent(cgEvent: cgEvent) else { return nil }
        return nsEvent.characters
    }

    /// Mouse highlight: hovering the filter row can enter filter mode. While filtering,
    /// content-row hover must NOT exit filter mode (mouse often still sits on row 1 after `/`).
    @MainActor
    func clipMenuWillHighlight(menu: NSMenu, item: NSMenuItem?) {
        defer {
            if !isFilterModeActive {
                refreshActionSubmenuAttachment(highlighted: item)
            }
        }
        guard let field = filterSearchField, let filterItem = filterTitleMenuItem else { return }
        let isFilterRow = item === filterItem
            || (item?.view != nil && field.isDescendant(of: item!.view!))
        if isFilterRow {
            if !isFilterModeActive {
                enterFilterMode()
            }
            return
        }
        if isFilterModeActive {
            // Suppress content highlight while filtering — otherwise AppKit immediately
            // re-highlights the row under the cursor and `/` looks like it "selected" it.
            if item != nil, !isSuppressingContentHighlight {
                isSuppressingContentHighlight = true
                defer { isSuppressingContentHighlight = false }
                clearMenuHighlight()
            }
            return
        }
    }

    func clipMenuFilterMenuDidClose() {
        isFilterModeActive = false
        setImagesOnlyFilter(false)
        removeModifierMonitor()
        ClipMenuFilterKeyHook.clearActiveTarget(self)
        filterSearchField?.releaseTypingCaptureForMenuNavigation()
        if let field = filterSearchField {
            field.stringValue = ""
        }
        filterImagesButtonHost = nil
        lockedFilterMenuWidth = nil
    }

    private func moveFilterFocusToMenuList(field: ClipMenuSearchField) {
        exitFilterMode(clearQuery: false)
        let winNum = field.window?.windowNumber ?? NSApp.keyWindow?.windowNumber ?? 0
        DispatchQueue.main.async { [weak self] in
            self?.repostMenuListArrowKeyDown(windowNumber: winNum)
        }
    }

    private func repostMenuListArrowKeyDown(windowNumber: Int) {
        guard let replay = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 125
        ) else { return }
        NSApp.postEvent(replay, atStart: false)
    }

    @MainActor
    private func reactivateTargetAppIfNeeded() {
        guard let targetAppForPaste else { return }
        HotkeyService.log.debug("Re-activating target app pid=\(targetAppForPaste.processIdentifier, privacy: .public)")
        NSApp.hide(nil)
        targetAppForPaste.activate(options: [])
    }

    @objc func selectClipMenuItem(_ sender: NSMenuItem) {
        guard let clip = sender.representedObject as? ClipEntry, let runtime else { return }

        let wantsActions = selectionModifierFlags().contains(actionModifierMask(for: runtime.settings.actionModifierKey))
        fputs("[ClipMenu] selectClip wantsActions=\(wantsActions) flags=\(selectionModifierFlags().rawValue) tracked=\(trackedModifierFlags.rawValue)\n", stderr)
        if wantsActions {
            // Multi-action uses the cascading submenu (parent stays open). Only auto-run
            // when there is a single leaf; otherwise ignore so we don't dismiss for a second menu.
            handleSingleLeafActionIfNeeded(for: clip, runtime: runtime)
        } else {
            selectClipEntry(clip)
        }
    }

    private func actionModifierMask(for key: Int) -> NSEvent.ModifierFlags {
        switch key {
        case 1: return .command
        case 2: return .control
        case 3: return .shift
        default: return .option
        }
    }

    private func handleSingleLeafActionIfNeeded(for clip: ClipEntry, runtime: AppRuntime) {
        Task { @MainActor in
            guard let context = runtime.modelContainer?.mainContext else { return }
            let roots = (try? context.fetch(FetchDescriptor<ActionNode>(
                predicate: #Predicate<ActionNode> { $0.parent == nil },
                sortBy: [SortDescriptor(\.sortIndex)]
            ))) ?? []
            let leaves = enabledLeafActions(from: roots.filter(\.isEnabled))
            guard leaves.count == 1, let only = leaves.first else { return }
            await runtime.actionService.perform(action: only, on: clip, executionContext: .pasteContext)
            await pasteFromHotkeyAction()
        }
    }

    private func enabledLeafActions(from roots: [ActionNode]) -> [ActionNode] {
        var leaves: [ActionNode] = []
        func walk(_ nodes: [ActionNode]) {
            for node in nodes where node.isEnabled {
                if node.isLeaf {
                    leaves.append(node)
                } else {
                    walk(Array(node.children))
                }
            }
        }
        walk(roots)
        return leaves
    }

    func selectClipEntry(_ clip: ClipEntry) {
        guard let runtime else { return }
        Task { @MainActor in
            reactivateTargetAppIfNeeded()
            // Allow menu interaction to settle before writing pasteboard.
            try? await Task.sleep(nanoseconds: Self.menuDismissSettleDelay)
            await runtime.clipsService.select(clip, pasteImmediately: false)
            if runtime.settings.autoPasteAfterSelection {
                // Give AppKit a beat to finish foreground activation.
                try? await Task.sleep(nanoseconds: Self.reactivationSettleDelay)
                reactivateTargetAppIfNeeded()
                try? await Task.sleep(nanoseconds: Self.prePasteDelay)
                await pasteService.paste()
            }
        }
    }

    @objc func selectSnippetMenuItem(_ sender: NSMenuItem) {
        guard let snippet = sender.representedObject as? Snippet, let runtime else { return }

        if selectionModifierFlags().contains(actionModifierMask(for: runtime.settings.actionModifierKey)) {
            let mockClip = ClipEntry()
            mockClip.stringValue = snippet.content
            mockClip.types = ["public.utf8-plain-text"]
            handleSingleLeafActionIfNeeded(for: mockClip, runtime: runtime)
        } else {
            selectSnippetModel(snippet)
        }
    }

    func selectSnippetModel(_ snippet: Snippet) {
        guard let runtime else { return }
        Task { @MainActor in
            reactivateTargetAppIfNeeded()
            try? await Task.sleep(nanoseconds: Self.menuDismissSettleDelay)
            await runtime.clipsService.copyStringToPasteboard(snippet.content, pasteImmediately: false)
            if runtime.settings.autoPasteAfterSelection {
                try? await Task.sleep(nanoseconds: Self.reactivationSettleDelay)
                reactivateTargetAppIfNeeded()
                try? await Task.sleep(nanoseconds: Self.prePasteDelay)
                await pasteService.paste()
            }
        }
    }

    @objc func clearHistory(_ sender: NSMenuItem) {
        guard let runtime else { return }
        Task { try? await runtime.clipsService.clearAll() }
    }

    @objc func openPreferences(_ sender: NSMenuItem) {
        guard let runtime else { return }
        Task { @MainActor in
            runtime.showPreferences()
        }
    }

    @objc func openSnippetsEditor(_ sender: NSMenuItem) {
        guard let runtime else { return }
        Task { @MainActor in
            runtime.showPreferences(tab: .snippets)
        }
    }

    @objc func quit(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }

    @MainActor
    func pasteFromHotkeyAction() async {
        await pasteService.paste()
    }

    @MainActor
    private func finishHotkeyActionPaste() async {
        reactivateTargetAppIfNeeded()
        try? await Task.sleep(nanoseconds: Self.reactivationSettleDelay)
        reactivateTargetAppIfNeeded()
        try? await Task.sleep(nanoseconds: Self.prePasteDelay)
        await pasteService.paste()
    }
}

extension HotkeyPopupActionTarget: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? ClipMenuSearchField,
              field === filterSearchField else { return }
        if !isFilterModeActive {
            isFilterModeActive = true
        }
        applyCurrentFilterQuery()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard let field = filterSearchField, control === field else { return false }
        if commandSelector == #selector(NSResponder.moveDown(_:)) {
            moveFilterFocusToMenuList(field: field)
            return true
        }
        if commandSelector == #selector(NSResponder.insertTab(_:))
            || commandSelector == #selector(NSResponder.insertBacktab(_:)) {
            toggleImagesOnlyFilter()
            return true
        }
        return false
    }
}
