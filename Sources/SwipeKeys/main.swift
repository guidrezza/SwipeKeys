import AppKit
import CoreGraphics
import Foundation

struct Swipe: Sendable {
    let vertical: Int32
    let horizontal: Int32
}

enum GestureMode: String, Sendable {
    case mouseDrag
    case scrollSwipe
}

struct DragSettings: Sendable {
    let distance: Int32
    let steps: Int
    let pressDelay: useconds_t
    let stepDelay: useconds_t
    let restoreDelay: useconds_t
    let tapDelay: useconds_t
}

enum InputAction: Sendable {
    case swipe(Swipe)
    case tap
}

struct QueuedAction: Sendable {
    let action: InputAction
    let generation: Int
}

struct Options {
    var appMatch = "subway"
    var intensity: Int32 = 86
    var scrollIntensity: Int32 = 18
    var repeats = 6
    var maxQueuedActions = 8
    var usesCustomDragSettings = false
    var verbose = false
}

extension Notification.Name {
    static let swipeKeysEnabledChanged = Notification.Name("SwipeKeysEnabledChanged")
    static let swipeKeysTapStatusChanged = Notification.Name("SwipeKeysTapStatusChanged")
    static let swipeKeysModeChanged = Notification.Name("SwipeKeysModeChanged")
}

final class SwipeKeys {
    private static let gestureModeDefaultsKey = "GestureMode"
    private static let defaultDragSettings = DragSettings(
        distance: 86,
        steps: 6,
        pressDelay: 9_000,
        stepDelay: 3_500,
        restoreDelay: 1_500,
        tapDelay: 12_000
    )
    private let options: Options
    private let source: CGEventSource?
    private let actionQueue = DispatchQueue(label: "com.guidrezza.SwipeKeys.actions", qos: .userInteractive)
    private let actionLock = NSLock()
    private var actionRunning = false
    private var actionGeneration = 0
    private var pendingActions: [QueuedAction] = []
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let tapKeyCode: Int64 = 49
    private let toggleKeyCode: Int64 = 40 // K
    private let stateLock = NSLock()
    private var enabled = true
    private var tapActive = false
    private var mode: GestureMode

    private lazy var keyMap: [Int64: Swipe] = [
        13: Swipe(vertical: -1, horizontal: 0), // W
        126: Swipe(vertical: -1, horizontal: 0), // Up
        1: Swipe(vertical: 1, horizontal: 0), // S
        125: Swipe(vertical: 1, horizontal: 0), // Down
        0: Swipe(vertical: 0, horizontal: -1), // A
        123: Swipe(vertical: 0, horizontal: -1), // Left
        2: Swipe(vertical: 0, horizontal: 1), // D
        124: Swipe(vertical: 0, horizontal: 1), // Right
    ]

    init(options: Options) {
        self.options = options
        self.source = CGEventSource(stateID: .hidSystemState)
        let savedMode = UserDefaults.standard.string(forKey: Self.gestureModeDefaultsKey)
        self.mode = GestureMode(rawValue: savedMode ?? "") ?? .mouseDrag
    }

    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    static var hasInputMonitoringPermission: Bool {
        if #available(macOS 10.15, *) {
            return CGPreflightListenEventAccess()
        }

        return true
    }

    static func requestInputMonitoringPermission() {
        if #available(macOS 10.15, *) {
            CGRequestListenEventAccess()
        }
    }

    func startCommandLine() {
        if !Self.hasAccessibilityPermission {
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            print("SwipeKeys needs Accessibility permission. Enable it, then run this command again.")
            exit(1)
        }

        if !Self.hasInputMonitoringPermission {
            Self.requestInputMonitoringPermission()
            print("SwipeKeys needs Input Monitoring permission. Enable it, then run this command again.")
            exit(1)
        }

        guard installEventTap() else {
            print("Could not create keyboard event tap. Check Accessibility permission and try again.")
            exit(1)
        }

        print("SwipeKeys is running. Press Command-Control-Option-K to toggle, or Control-C to quit.")
        CFRunLoopRun()
    }

    func startApp(promptForPermission: Bool = false) -> Bool {
        guard Self.hasAccessibilityPermission else {
            if promptForPermission {
                AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            }
            return false
        }

        guard Self.hasInputMonitoringPermission else {
            return false
        }

        return installEventTap()
    }

    private func installEventTap() -> Bool {
        if eventTap != nil {
            return true
        }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: swipeKeysEventCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let eventTap else {
            publishTapStatus(active: false)
            return false
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        publishTapStatus(active: true)
        return true
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            reenableEventTap()
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if isToggleEvent(keyCode: keyCode, flags: event.flags) {
            if !isRepeat {
                toggle()
            }
            return nil
        }

        if frontmostAppIsSwipeKeys() {
            return Unmanaged.passUnretained(event)
        }

        guard isEnabled else {
            return Unmanaged.passUnretained(event)
        }

        _ = perform(keyCode: keyCode)
        return Unmanaged.passUnretained(event)
    }

    private func reenableEventTap() {
        guard let eventTap else {
            publishTapStatus(active: false)
            return
        }

        CGEvent.tapEnable(tap: eventTap, enable: true)
        publishTapStatus(active: true)
    }

    func perform(keyCode: Int64) -> Bool {
        if let swipe = keyMap[keyCode] {
            enqueue(.swipe(swipe))
            return true
        }

        if keyCode == tapKeyCode {
            enqueue(.tap)
            return true
        }

        return false
    }

    private func frontmostAppIsSwipeKeys() -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    var isEnabled: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return enabled
    }

    @discardableResult
    func toggle() -> Bool {
        stateLock.lock()
        enabled.toggle()
        let newValue = enabled
        stateLock.unlock()

        if !newValue {
            cancelQueuedActions()
        }

        NotificationCenter.default.post(
            name: .swipeKeysEnabledChanged,
            object: nil,
            userInfo: ["enabled": newValue]
        )

        return newValue
    }

    var gestureMode: GestureMode {
        stateLock.lock()
        defer { stateLock.unlock() }
        return mode
    }

    func setGestureMode(_ newMode: GestureMode) {
        stateLock.lock()
        guard mode != newMode else {
            stateLock.unlock()
            return
        }

        mode = newMode
        stateLock.unlock()

        UserDefaults.standard.set(newMode.rawValue, forKey: Self.gestureModeDefaultsKey)
        NotificationCenter.default.post(
            name: .swipeKeysModeChanged,
            object: nil,
            userInfo: ["mode": newMode.rawValue]
        )
    }

    func isToggleEvent(keyCode: Int64, flags: CGEventFlags) -> Bool {
        guard keyCode == toggleKeyCode else {
            return false
        }

        let needed: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl]
        return flags.intersection(needed) == needed
    }

    func isToggleEvent(keyCode: Int64, flags: NSEvent.ModifierFlags) -> Bool {
        guard keyCode == toggleKeyCode else {
            return false
        }

        return flags.contains(.command) && flags.contains(.option) && flags.contains(.control)
    }

    private func enqueue(_ action: InputAction) {
        actionLock.lock()
        let queuedAction = QueuedAction(action: action, generation: actionGeneration)
        if actionRunning {
            let maxQueuedActions = max(1, options.maxQueuedActions)
            if pendingActions.count < maxQueuedActions {
                pendingActions.append(queuedAction)
            } else if options.verbose {
                print("Dropping input because queue is full")
            }
            actionLock.unlock()
            return
        }

        actionRunning = true
        actionLock.unlock()
        runOnActionQueue(queuedAction)
    }

    private func runOnActionQueue(_ queuedAction: QueuedAction) {
        actionQueue.async { [weak self] in
            guard let self else {
                return
            }

            self.run(queuedAction)
            self.finishAction()
        }
    }

    private func finishAction() {
        actionLock.lock()
        let next = pendingActions.isEmpty ? nil : pendingActions.removeFirst()
        if next == nil {
            actionRunning = false
        }
        actionLock.unlock()

        if let next {
            runOnActionQueue(next)
        }
    }

    private func cancelQueuedActions() {
        actionLock.lock()
        actionGeneration += 1
        pendingActions.removeAll()
        actionLock.unlock()
    }

    private func run(_ queuedAction: QueuedAction) {
        guard isEnabled, isCurrentActionGeneration(queuedAction.generation) else {
            return
        }

        switch queuedAction.action {
        case .swipe(let swipe):
            switch gestureMode {
            case .mouseDrag:
                postMouseDrag(swipe: swipe, generation: queuedAction.generation)
            case .scrollSwipe:
                postScrollSwipe(swipe: swipe, generation: queuedAction.generation)
            }
        case .tap:
            postTap(generation: queuedAction.generation)
        }
    }

    private func isCurrentActionGeneration(_ generation: Int) -> Bool {
        actionLock.lock()
        defer { actionLock.unlock() }
        return generation == actionGeneration
    }

    private func shouldContinueAction(_ generation: Int) -> Bool {
        isEnabled && isCurrentActionGeneration(generation)
    }

    private func postMouseDrag(swipe: Swipe, generation: Int) {
        let settings = currentDragSettings()
        let start = targetGesturePoint()
        let end = CGPoint(
            x: start.x + direction(for: swipe.horizontal) * CGFloat(settings.distance),
            y: start.y + direction(for: swipe.vertical) * CGFloat(settings.distance)
        )
        var lastPoint = start

        if options.verbose {
            print("Drag from x=\(Int(start.x)) y=\(Int(start.y)) to x=\(Int(end.x)) y=\(Int(end.y))")
        }

        guard let down = mouseEvent(type: .leftMouseDown, point: start, clickState: 0) else {
            return
        }

        down.post(tap: .cghidEventTap)
        usleep(settings.pressDelay)

        for step in 1...max(1, settings.steps) {
            guard shouldContinueAction(generation) else {
                if let up = mouseEvent(type: .leftMouseUp, point: lastPoint, clickState: 0) {
                    up.post(tap: .cghidEventTap)
                }
                restoreCursor(to: start, delay: settings.restoreDelay)
                return
            }

            let progress = CGFloat(step) / CGFloat(max(1, settings.steps))
            let point = CGPoint(
                x: start.x + (end.x - start.x) * progress,
                y: start.y + (end.y - start.y) * progress
            )

            guard let drag = mouseEvent(type: .leftMouseDragged, point: point, clickState: 0) else {
                continue
            }

            drag.post(tap: .cghidEventTap)
            lastPoint = point
            usleep(settings.stepDelay)
        }

        if let up = mouseEvent(type: .leftMouseUp, point: end, clickState: 0) {
            up.post(tap: .cghidEventTap)
        }

        restoreCursor(to: start, delay: settings.restoreDelay)
    }

    private func postScrollSwipe(swipe: Swipe, generation: Int) {
        let point = targetGesturePoint()

        if options.verbose {
            print("Scroll swipe vertical=\(swipe.vertical) horizontal=\(swipe.horizontal) x=\(Int(point.x)) y=\(Int(point.y))")
        }

        for _ in 0..<options.repeats {
            guard shouldContinueAction(generation) else {
                return
            }

            guard let event = CGEvent(
                scrollWheelEvent2Source: source,
                units: .pixel,
                wheelCount: 2,
                wheel1: swipe.vertical * options.scrollIntensity,
                wheel2: swipe.horizontal * options.scrollIntensity,
                wheel3: 0
            ) else {
                continue
            }

            event.location = point
            event.post(tap: .cghidEventTap)
            usleep(2_000)
        }
    }

    private func restoreCursor(to point: CGPoint, delay: useconds_t) {
        usleep(delay)
        if let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) {
            move.post(tap: .cghidEventTap)
        }
        CGWarpMouseCursorPosition(point)
    }

    private func mouseEvent(type: CGEventType, point: CGPoint, clickState: Int64) -> CGEvent? {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else {
            return nil
        }

        event.setIntegerValueField(.mouseEventButtonNumber, value: 0)
        event.setIntegerValueField(.mouseEventClickState, value: clickState)
        return event
    }

    private func direction(for value: Int32) -> CGFloat {
        if value < 0 {
            return -1
        }

        if value > 0 {
            return 1
        }

        return 0
    }

    private func postTap(generation: Int) {
        guard shouldContinueAction(generation) else {
            return
        }

        let point = targetGesturePoint()

        if options.verbose {
            print("Tap x=\(Int(point.x)) y=\(Int(point.y))")
        }

        guard
            let down = mouseEvent(type: .leftMouseDown, point: point, clickState: 1),
            let up = mouseEvent(type: .leftMouseUp, point: point, clickState: 1)
        else {
            return
        }

        down.post(tap: .cghidEventTap)
        usleep(currentDragSettings().tapDelay)
        guard shouldContinueAction(generation) else {
            up.post(tap: .cghidEventTap)
            return
        }
        up.post(tap: .cghidEventTap)
    }

    private func currentDragSettings() -> DragSettings {
        if options.usesCustomDragSettings {
            return DragSettings(
                distance: abs(options.intensity),
                steps: max(1, options.repeats),
                pressDelay: 9_000,
                stepDelay: 3_500,
                restoreDelay: 1_500,
                tapDelay: 12_000
            )
        }

        return Self.defaultDragSettings
    }

    private func targetGesturePoint() -> CGPoint {
        return CGEvent(source: nil)?.location ?? .zero
    }

    private func publishTapStatus(active: Bool) {
        stateLock.lock()
        tapActive = active
        stateLock.unlock()

        NotificationCenter.default.post(
            name: .swipeKeysTapStatusChanged,
            object: nil,
            userInfo: ["active": active]
        )
    }

    var isTapActive: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return tapActive
    }
}

extension SwipeKeys: @unchecked Sendable {}

@MainActor final class TestView: NSView {
    private var markerPoint: CGPoint?
    private var markerLabel = "Test here"
    private var markerDate = Date.distantPast

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        showDelivered(action: "tap", eventLocation: event.locationInWindow)
    }

    override func mouseDragged(with event: NSEvent) {
        showDelivered(action: "drag", eventLocation: event.locationInWindow)
    }

    override func scrollWheel(with event: NSEvent) {
        let action: String
        if abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) {
            action = event.scrollingDeltaY > 0 ? "swipe up" : "swipe down"
        } else {
            action = event.scrollingDeltaX > 0 ? "swipe right" : "swipe left"
        }

        showDelivered(action: action, eventLocation: event.locationInWindow)
    }

    private func showDelivered(action: String, eventLocation: CGPoint) {
        let localPoint = convert(eventLocation, from: nil)
        guard bounds.contains(localPoint) else {
            return
        }

        markerPoint = localPoint
        markerLabel = "\(action) received"
        markerDate = Date()
        needsDisplay = true
    }

    func contains(screenPoint: CGPoint, in window: NSWindow?) -> Bool {
        guard let window else {
            return false
        }

        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let localPoint = convert(windowPoint, from: nil)
        return bounds.contains(localPoint)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 12, yRadius: 12)
        NSColor.textBackgroundColor.withAlphaComponent(0.75).setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        if let markerPoint, Date().timeIntervalSince(markerDate) < 5 {
            NSColor.systemBlue.withAlphaComponent(0.18).setFill()
            NSBezierPath(ovalIn: NSRect(x: markerPoint.x - 24, y: markerPoint.y - 24, width: 48, height: 48)).fill()

            NSColor.systemBlue.setFill()
            NSBezierPath(ovalIn: NSRect(x: markerPoint.x - 6, y: markerPoint.y - 6, width: 12, height: 12)).fill()

            markerLabel.draw(
                in: NSRect(x: 12, y: 12, width: bounds.width - 24, height: 22),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: paragraph,
                ]
            )
        } else {
            markerLabel = "Test here"
            "Test here".draw(
                in: NSRect(x: 12, y: bounds.midY - 18, width: bounds.width - 24, height: 22),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 16, weight: .medium),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: paragraph,
                ]
            )
            "Hover, then press WASD/arrows/Space".draw(
                in: NSRect(x: 12, y: bounds.midY + 8, width: bounds.width - 24, height: 18),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.tertiaryLabelColor,
                    .paragraphStyle: paragraph,
                ]
            )
        }
    }

}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private let swipeKeys: SwipeKeys
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var permissionTimer: Timer?
    private var isRunning = false
    private var window: NSWindow?
    private let testView = TestView(frame: .zero)
    private let statusLabel = NSTextField(labelWithString: "On")
    private let readinessLabel = NSTextField(labelWithString: "Checking permissions")
    private lazy var modeControl: NSSegmentedControl = {
        let control = NSSegmentedControl(labels: ["Mouse Drag", "Scroll Swipe"], trackingMode: .selectOne, target: self, action: #selector(changeMode(_:)))
        control.segmentStyle = .rounded
        control.selectedSegment = swipeKeys.gestureMode == .mouseDrag ? 0 : 1
        return control
    }()
    private var enabledObserver: NSObjectProtocol?
    private var tapStatusObserver: NSObjectProtocol?
    private var modeObserver: NSObjectProtocol?
    private var localKeyMonitor: Any?

    init(options: Options) {
        self.swipeKeys = SwipeKeys(options: options)
        super.init()
        self.enabledObserver = NotificationCenter.default.addObserver(
            forName: .swipeKeysEnabledChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let enabled = notification.userInfo?["enabled"] as? Bool ?? true
            Task { @MainActor [weak self, enabled] in
                self?.refreshEnabledStatus(enabled)
            }
        }
        self.tapStatusObserver = NotificationCenter.default.addObserver(
            forName: .swipeKeysTapStatusChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let active = notification.userInfo?["active"] as? Bool ?? false
            Task { @MainActor [weak self, active] in
                self?.refreshTapStatus(active)
            }
        }
        self.modeObserver = NotificationCenter.default.addObserver(
            forName: .swipeKeysModeChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let rawMode = notification.userInfo?["mode"] as? String
            let mode = GestureMode(rawValue: rawMode ?? "") ?? .mouseDrag
            Task { @MainActor [weak self, mode] in
                self?.refreshModeControl(mode)
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "SwipeKeys")
        }

        showWindow()
        installLocalTestMonitor()
        installMainMenu()
        refreshStatus()
        startIfAllowed()
        refreshEnabledStatus(swipeKeys.isEnabled)
        refreshTapStatus(swipeKeys.isTapActive)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func startIfAllowed() {
        refreshPermissionStatus()
        isRunning = swipeKeys.startApp()
        refreshStatus()

        if !isRunning {
            permissionTimer?.invalidate()
            permissionTimer = Timer.scheduledTimer(timeInterval: 2, target: self, selector: #selector(retryPermission), userInfo: nil, repeats: true)
        }
    }

    @objc private func retryPermission(_ timer: Timer) {
        refreshPermissionStatus()
        isRunning = swipeKeys.startApp()
        refreshStatus()

        if isRunning {
            timer.invalidate()
            permissionTimer = nil
        }
    }

    private func refreshEnabledStatus(_ enabled: Bool) {
        refreshWindowStatus()
        refreshStatus()
    }

    private func refreshTapStatus(_ active: Bool) {
        refreshPermissionStatus()
        isRunning = active
        refreshWindowStatus()
        refreshStatus()
    }

    private func refreshPermissionStatus() {
        refreshWindowStatus()
    }

    private func refreshWindowStatus() {
        let accessibilityReady = SwipeKeys.hasAccessibilityPermission
        let inputReady = SwipeKeys.hasInputMonitoringPermission
        let enabled = swipeKeys.isEnabled

        statusLabel.stringValue = enabled ? "On" : "Off"
        statusLabel.textColor = enabled ? .systemGreen : .secondaryLabelColor

        if !accessibilityReady && !inputReady {
            readinessLabel.stringValue = "Needs Accessibility + Input Monitoring"
            readinessLabel.textColor = .systemOrange
        } else if !accessibilityReady {
            readinessLabel.stringValue = "Needs Accessibility"
            readinessLabel.textColor = .systemOrange
        } else if !inputReady {
            readinessLabel.stringValue = "Needs Input Monitoring"
            readinessLabel.textColor = .systemOrange
        } else if !swipeKeys.isTapActive {
            readinessLabel.stringValue = "Starting global listener"
            readinessLabel.textColor = .secondaryLabelColor
        } else {
            readinessLabel.stringValue = swipeKeys.gestureMode == .mouseDrag ? "Ready · Mouse Drag" : "Ready · Scroll Swipe"
            readinessLabel.textColor = .secondaryLabelColor
        }
    }

    private func refreshStatus() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: swipeKeys.isEnabled ? "On" : "Off", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: isRunning ? "Global Listener Active" : "Global Listener Waiting", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())

        let toggleItem = NSMenuItem(title: "Toggle On/Off", action: #selector(toggleFromMenu), keyEquivalent: "k")
        toggleItem.target = self
        toggleItem.keyEquivalentModifierMask = [.command, .option, .control]
        menu.addItem(toggleItem)

        let showItem = NSMenuItem(title: "Show Window", action: #selector(showWindowFromMenu), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)

        let accessibilityItem = NSMenuItem(title: "Open Accessibility Settings", action: #selector(openAccessibilitySettings), keyEquivalent: ",")
        accessibilityItem.target = self
        menu.addItem(accessibilityItem)

        let inputMonitoringItem = NSMenuItem(title: "Open Input Monitoring Settings", action: #selector(openInputMonitoringSettings), keyEquivalent: "")
        inputMonitoringItem.target = self
        menu.addItem(inputMonitoringItem)

        let quitItem = NSMenuItem(title: "Quit SwipeKeys", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func showWindow() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: "SwipeKeys")
        titleLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        titleLabel.alignment = .center

        statusLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        statusLabel.alignment = .center

        readinessLabel.font = .systemFont(ofSize: 12, weight: .medium)
        readinessLabel.alignment = .center

        let bindingsLabel = NSTextField(labelWithString: "WASD/arrows swipe · Space taps")
        bindingsLabel.font = .systemFont(ofSize: 14, weight: .medium)
        bindingsLabel.alignment = .center

        testView.translatesAutoresizingMaskIntoConstraints = false
        modeControl.translatesAutoresizingMaskIntoConstraints = false

        let accessibilityButton = linkButton(title: "Accessibility", action: #selector(openAccessibilitySettings))
        let inputMonitoringButton = linkButton(title: "Input Monitoring", action: #selector(openInputMonitoringSettings))

        let toggleLabel = NSTextField(labelWithString: "⌘⌃⌥K toggles")
        toggleLabel.font = .systemFont(ofSize: 12)
        toggleLabel.textColor = .tertiaryLabelColor
        toggleLabel.alignment = .center

        let footerStack = NSStackView(views: [toggleLabel, accessibilityButton, inputMonitoringButton])
        footerStack.orientation = .horizontal
        footerStack.alignment = .centerY
        footerStack.spacing = 12

        let headerStack = NSStackView(views: [titleLabel, statusLabel, readinessLabel])
        headerStack.orientation = .vertical
        headerStack.alignment = .centerX
        headerStack.spacing = 3

        let stackView = NSStackView(views: [headerStack, bindingsLabel, modeControl, testView, footerStack])
        stackView.orientation = .vertical
        stackView.alignment = .centerX
        stackView.spacing = 10
        stackView.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            stackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            stackView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            testView.widthAnchor.constraint(equalToConstant: 320),
            testView.heightAnchor.constraint(equalToConstant: 104),
            modeControl.widthAnchor.constraint(equalToConstant: 230),
        ])

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 296),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "SwipeKeys"
        window.contentView = contentView
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(testView)
        self.window = window
        refreshModeControl(swipeKeys.gestureMode)
    }

    private func linkButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false
        button.font = .systemFont(ofSize: 12)
        button.contentTintColor = .secondaryLabelColor
        return button
    }

    private func refreshModeControl(_ mode: GestureMode) {
        modeControl.selectedSegment = mode == .mouseDrag ? 0 : 1
        refreshWindowStatus()
    }

    private func installLocalTestMonitor() {
        guard localKeyMonitor == nil else {
            return
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else {
                return event
            }

            if event.modifierFlags.contains(.command), event.keyCode == 12 {
                NSApp.terminate(nil)
                return nil
            }

            if self.swipeKeys.isToggleEvent(keyCode: Int64(event.keyCode), flags: event.modifierFlags) {
                if !event.isARepeat {
                    self.swipeKeys.toggle()
                }
                return nil
            }

            guard self.swipeKeys.isEnabled, self.testView.contains(screenPoint: NSEvent.mouseLocation, in: self.window) else {
                return event
            }

            return self.swipeKeys.perform(keyCode: Int64(event.keyCode)) ? nil : event
        }
    }

    private func installMainMenu() {
        let appMenu = NSMenu()
        let quitItem = NSMenuItem(title: "Quit SwipeKeys", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        appMenu.addItem(quitItem)

        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu

        let mainMenu = NSMenu()
        mainMenu.addItem(appMenuItem)
        NSApp.mainMenu = mainMenu
    }

    @objc private func toggleFromMenu() {
        swipeKeys.toggle()
    }

    @objc private func changeMode(_ sender: NSSegmentedControl) {
        swipeKeys.setGestureMode(sender.selectedSegment == 0 ? .mouseDrag : .scrollSwipe)
    }

    @objc private func showWindowFromMenu() {
        showWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openInputMonitoringSettings() {
        SwipeKeys.requestInputMonitoringPermission()

        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    @MainActor @objc private func quit() {
        NSApp.terminate(nil)
    }
}

private func swipeKeysEventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }

    let app = Unmanaged<SwipeKeys>.fromOpaque(userInfo).takeUnretainedValue()
    return app.handle(type: type, event: event)
}

func parseOptions(arguments: [String]) -> Options {
    var options = Options()
    var index = 1

    while index < arguments.count {
        let argument = arguments[index]

        switch argument {
        case "--match":
            index += 1
            guard index < arguments.count else {
                print("Missing value for --match")
                exit(2)
            }
            options.appMatch = arguments[index]
        case "--intensity":
            index += 1
            guard index < arguments.count, let value = Int32(arguments[index]) else {
                print("Missing numeric value for --intensity")
                exit(2)
            }
            options.intensity = value
            options.usesCustomDragSettings = true
        case "--scroll-intensity":
            index += 1
            guard index < arguments.count, let value = Int32(arguments[index]) else {
                print("Missing numeric value for --scroll-intensity")
                exit(2)
            }
            options.scrollIntensity = value
        case "--repeats":
            index += 1
            guard index < arguments.count, let value = Int(arguments[index]) else {
                print("Missing numeric value for --repeats")
                exit(2)
            }
            options.repeats = max(1, value)
            options.usesCustomDragSettings = true
        case "--verbose":
            options.verbose = true
        case "--help", "-h":
            printHelp()
            exit(0)
        default:
            print("Unknown option: \(argument)")
            printHelp()
            exit(2)
        }

        index += 1
    }

    return options
}

func printHelp() {
    print("""
    SwipeKeys

    Turns WASD and arrow keys into mouse-drag swipe gestures, and Space into
    a tap wherever the cursor is. Swipes are short drags so games that
    accept click-and-drag input can receive them. Original key events pass through
    normally.

    Usage:
      swipekeys [--intensity pixels] [--scroll-intensity pixels] [--repeats number] [--verbose]

    Defaults:
      --intensity 86
      --scroll-intensity 18
      --repeats 6

    """)
}

let options = parseOptions(arguments: CommandLine.arguments)

if Bundle.main.bundleURL.pathExtension == "app" {
    let app = NSApplication.shared
    let delegate = AppDelegate(options: options)
    app.delegate = delegate
    app.run()
} else {
    SwipeKeys(options: options).startCommandLine()
}
