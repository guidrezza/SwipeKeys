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

enum KeyPreset: String, Sendable {
    case arrows
    case wasd
    case custom
}

enum BindingSlot: String, CaseIterable, Sendable {
    case up
    case down
    case left
    case right
    case tap

    var title: String {
        switch self {
        case .up:
            "Up"
        case .down:
            "Down"
        case .left:
            "Left"
        case .right:
            "Right"
        case .tap:
            "Tap"
        }
    }

    var swipe: Swipe? {
        switch self {
        case .up:
            Swipe(vertical: -1, horizontal: 0)
        case .down:
            Swipe(vertical: 1, horizontal: 0)
        case .left:
            Swipe(vertical: 0, horizontal: -1)
        case .right:
            Swipe(vertical: 0, horizontal: 1)
        case .tap:
            nil
        }
    }

    var index: Int {
        switch self {
        case .up:
            0
        case .down:
            1
        case .left:
            2
        case .right:
            3
        case .tap:
            4
        }
    }

    static func slot(for index: Int) -> BindingSlot? {
        allCases.first { $0.index == index }
    }
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
    static let swipeKeysBindingsChanged = Notification.Name("SwipeKeysBindingsChanged")
}

final class SwipeKeys {
    private static let gestureModeDefaultsKey = "GestureMode"
    private static let keyPresetDefaultsKey = "KeyPreset"
    private static let customKeyPrefix = "CustomKey."
    private static let arrowBindings: [BindingSlot: Int64] = [
        .up: 126,
        .down: 125,
        .left: 123,
        .right: 124,
        .tap: 36,
    ]
    private static let wasdBindings: [BindingSlot: Int64] = [
        .up: 13,
        .down: 1,
        .left: 0,
        .right: 2,
        .tap: 49,
    ]
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
    private let toggleKeyCode: Int64 = 40 // K
    private let stateLock = NSLock()
    private var enabled = true
    private var tapActive = false
    private var mode: GestureMode
    private var keyPreset: KeyPreset
    private var customBindings: [BindingSlot: Int64]

    init(options: Options) {
        self.options = options
        self.source = CGEventSource(stateID: .hidSystemState)
        let savedMode = UserDefaults.standard.string(forKey: Self.gestureModeDefaultsKey)
        self.mode = GestureMode(rawValue: savedMode ?? "") ?? .mouseDrag
        let savedPreset = UserDefaults.standard.string(forKey: Self.keyPresetDefaultsKey)
        self.keyPreset = KeyPreset(rawValue: savedPreset ?? "") ?? .arrows
        self.customBindings = Self.loadCustomBindings()
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
        if let action = inputAction(for: keyCode) {
            enqueue(action)
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

    var currentKeyPreset: KeyPreset {
        stateLock.lock()
        defer { stateLock.unlock() }
        return keyPreset
    }

    func setKeyPreset(_ preset: KeyPreset) {
        stateLock.lock()
        guard keyPreset != preset else {
            stateLock.unlock()
            return
        }

        keyPreset = preset
        stateLock.unlock()

        UserDefaults.standard.set(preset.rawValue, forKey: Self.keyPresetDefaultsKey)
        publishBindingsChanged()
    }

    func keyCode(for slot: BindingSlot) -> Int64? {
        stateLock.lock()
        defer { stateLock.unlock() }

        switch keyPreset {
        case .arrows:
            return Self.arrowBindings[slot]
        case .wasd:
            return Self.wasdBindings[slot]
        case .custom:
            return customBindings[slot]
        }
    }

    func customKeyCode(for slot: BindingSlot) -> Int64? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return customBindings[slot]
    }

    func setCustomKeyCode(_ keyCode: Int64?, for slot: BindingSlot) {
        stateLock.lock()
        if let keyCode {
            for otherSlot in BindingSlot.allCases where otherSlot != slot && customBindings[otherSlot] == keyCode {
                customBindings.removeValue(forKey: otherSlot)
                Self.saveCustomKeyCode(nil, for: otherSlot)
            }
            customBindings[slot] = keyCode
        } else {
            customBindings.removeValue(forKey: slot)
        }
        Self.saveCustomKeyCode(keyCode, for: slot)
        stateLock.unlock()

        publishBindingsChanged()
    }

    var bindingsSummary: String {
        stateLock.lock()
        let preset = keyPreset
        let customBindings = customBindings
        stateLock.unlock()

        switch preset {
        case .arrows:
            return "Arrows swipe · Enter taps"
        case .wasd:
            return "WASD swipe · Space taps"
        case .custom:
            let tap = customBindings[.tap].map(Self.displayName(for:)) ?? "Unbound"
            return "Custom keys · \(tap) taps"
        }
    }

    private func inputAction(for keyCode: Int64) -> InputAction? {
        stateLock.lock()
        let preset = keyPreset
        let customBindings = customBindings
        stateLock.unlock()

        let bindings: [BindingSlot: Int64]
        switch preset {
        case .arrows:
            bindings = Self.arrowBindings
        case .wasd:
            bindings = Self.wasdBindings
        case .custom:
            bindings = customBindings
        }

        for slot in BindingSlot.allCases where bindings[slot] == keyCode {
            if let swipe = slot.swipe {
                return .swipe(swipe)
            }
            return .tap
        }

        return nil
    }

    private func publishBindingsChanged() {
        NotificationCenter.default.post(name: .swipeKeysBindingsChanged, object: nil)
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

    private static func loadCustomBindings() -> [BindingSlot: Int64] {
        var bindings = arrowBindings

        for slot in BindingSlot.allCases {
            let key = customDefaultsKey(for: slot)
            guard let savedValue = UserDefaults.standard.object(forKey: key) as? Int else {
                continue
            }

            if savedValue >= 0 {
                bindings[slot] = Int64(savedValue)
            } else {
                bindings.removeValue(forKey: slot)
            }
        }

        return bindings
    }

    private static func saveCustomKeyCode(_ keyCode: Int64?, for slot: BindingSlot) {
        UserDefaults.standard.set(Int(keyCode ?? -1), forKey: customDefaultsKey(for: slot))
    }

    private static func customDefaultsKey(for slot: BindingSlot) -> String {
        customKeyPrefix + slot.rawValue
    }

    static func displayName(for keyCode: Int64) -> String {
        switch keyCode {
        case 0:
            "A"
        case 1:
            "S"
        case 2:
            "D"
        case 3:
            "F"
        case 4:
            "H"
        case 5:
            "G"
        case 6:
            "Z"
        case 7:
            "X"
        case 8:
            "C"
        case 9:
            "V"
        case 11:
            "B"
        case 12:
            "Q"
        case 13:
            "W"
        case 14:
            "E"
        case 15:
            "R"
        case 16:
            "Y"
        case 17:
            "T"
        case 31:
            "O"
        case 32:
            "U"
        case 34:
            "I"
        case 35:
            "P"
        case 37:
            "L"
        case 38:
            "J"
        case 40:
            "K"
        case 45:
            "N"
        case 46:
            "M"
        case 36, 76:
            "Enter"
        case 49:
            "Space"
        case 51:
            "Delete"
        case 53:
            "Esc"
        case 123:
            "Left Arrow"
        case 124:
            "Right Arrow"
        case 125:
            "Down Arrow"
        case 126:
            "Up Arrow"
        default:
            "Key \(keyCode)"
        }
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
            "Hover, then press a bound key".draw(
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
    private var keyOptionsWindow: NSWindow?
    private let testView = TestView(frame: .zero)
    private let statusLabel = NSTextField(labelWithString: "On")
    private let readinessLabel = NSTextField(labelWithString: "Checking permissions")
    private let bindingsLabel = NSTextField(labelWithString: "Arrows swipe · Enter taps")
    private lazy var modeControl: NSSegmentedControl = {
        let control = NSSegmentedControl(labels: ["Mouse Drag", "Scroll Swipe"], trackingMode: .selectOne, target: self, action: #selector(changeMode(_:)))
        control.segmentStyle = .rounded
        control.selectedSegment = swipeKeys.gestureMode == .mouseDrag ? 0 : 1
        return control
    }()
    private lazy var keyPresetControl: NSSegmentedControl = {
        let control = NSSegmentedControl(labels: ["Arrows", "WASD", "Custom"], trackingMode: .selectOne, target: self, action: #selector(changeKeyPreset(_:)))
        control.segmentStyle = .rounded
        control.selectedSegment = selectedSegment(for: swipeKeys.currentKeyPreset)
        return control
    }()
    private var customKeyButtons: [BindingSlot: NSButton] = [:]
    private var customClearButtons: [BindingSlot: NSButton] = [:]
    private var captureSlot: BindingSlot?
    private var enabledObserver: NSObjectProtocol?
    private var tapStatusObserver: NSObjectProtocol?
    private var modeObserver: NSObjectProtocol?
    private var bindingsObserver: NSObjectProtocol?
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
        self.bindingsObserver = NotificationCenter.default.addObserver(
            forName: .swipeKeysBindingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshBindingsStatus()
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
        refreshBindingsStatus()
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

        bindingsLabel.font = .systemFont(ofSize: 14, weight: .medium)
        bindingsLabel.alignment = .center

        testView.translatesAutoresizingMaskIntoConstraints = false
        modeControl.translatesAutoresizingMaskIntoConstraints = false

        let keysButton = linkButton(title: "Keys", action: #selector(showKeyOptions))
        let accessibilityButton = linkButton(title: "Accessibility", action: #selector(openAccessibilitySettings))
        let inputMonitoringButton = linkButton(title: "Input Monitoring", action: #selector(openInputMonitoringSettings))

        let toggleLabel = NSTextField(labelWithString: "⌘⌃⌥K toggles")
        toggleLabel.font = .systemFont(ofSize: 12)
        toggleLabel.textColor = .tertiaryLabelColor
        toggleLabel.alignment = .center

        let footerStack = NSStackView(views: [toggleLabel, keysButton, accessibilityButton, inputMonitoringButton])
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
            testView.heightAnchor.constraint(equalToConstant: 150),
            modeControl.widthAnchor.constraint(equalToConstant: 230),
        ])

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 350),
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

    private func refreshBindingsStatus() {
        bindingsLabel.stringValue = swipeKeys.bindingsSummary
        keyPresetControl.selectedSegment = selectedSegment(for: swipeKeys.currentKeyPreset)

        let customEnabled = swipeKeys.currentKeyPreset == .custom
        for slot in BindingSlot.allCases {
            let keyCode = swipeKeys.keyCode(for: slot)
            let customKeyCode = swipeKeys.customKeyCode(for: slot)
            let title = keyCode.map(SwipeKeys.displayName(for:)) ?? "Unbound"
            customKeyButtons[slot]?.title = captureSlot == slot ? "Press key..." : title
            customKeyButtons[slot]?.isEnabled = customEnabled
            customClearButtons[slot]?.isEnabled = customEnabled && customKeyCode != nil
        }
    }

    private func selectedSegment(for preset: KeyPreset) -> Int {
        switch preset {
        case .arrows:
            0
        case .wasd:
            1
        case .custom:
            2
        }
    }

    private func keyPreset(for segment: Int) -> KeyPreset {
        switch segment {
        case 1:
            .wasd
        case 2:
            .custom
        default:
            .arrows
        }
    }

    @objc private func showKeyOptions() {
        if let keyOptionsWindow {
            keyOptionsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: "Key Options")
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.alignment = .center

        keyPresetControl.translatesAutoresizingMaskIntoConstraints = false

        let customStack = NSStackView()
        customStack.orientation = .vertical
        customStack.alignment = .leading
        customStack.spacing = 8
        customStack.translatesAutoresizingMaskIntoConstraints = false

        for slot in BindingSlot.allCases {
            let label = NSTextField(labelWithString: slot.title)
            label.font = .systemFont(ofSize: 13, weight: .medium)
            label.widthAnchor.constraint(equalToConstant: 52).isActive = true

            let keyButton = NSButton(title: "Unbound", target: self, action: #selector(beginCustomKeyCapture(_:)))
            keyButton.bezelStyle = .rounded
            keyButton.tag = slot.index
            keyButton.widthAnchor.constraint(equalToConstant: 128).isActive = true
            customKeyButtons[slot] = keyButton

            let clearButton = NSButton(title: "Clear", target: self, action: #selector(clearCustomKey(_:)))
            clearButton.bezelStyle = .rounded
            clearButton.tag = slot.index
            clearButton.widthAnchor.constraint(equalToConstant: 70).isActive = true
            customClearButtons[slot] = clearButton

            let row = NSStackView(views: [label, keyButton, clearButton])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 10
            customStack.addArrangedSubview(row)
        }

        let stackView = NSStackView(views: [titleLabel, keyPresetControl, customStack])
        stackView.orientation = .vertical
        stackView.alignment = .centerX
        stackView.spacing = 16
        stackView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            stackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            stackView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            keyPresetControl.widthAnchor.constraint(equalToConstant: 250),
        ])

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 310),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Key Options"
        window.contentView = contentView
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.keyOptionsWindow = window
        refreshBindingsStatus()
        NSApp.activate(ignoringOtherApps: true)
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

            if let captureSlot = self.captureSlot {
                if event.keyCode != 53 {
                    self.swipeKeys.setCustomKeyCode(Int64(event.keyCode), for: captureSlot)
                }
                self.captureSlot = nil
                self.refreshBindingsStatus()
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

    @objc private func changeKeyPreset(_ sender: NSSegmentedControl) {
        captureSlot = nil
        swipeKeys.setKeyPreset(keyPreset(for: sender.selectedSegment))
        refreshBindingsStatus()
    }

    @objc private func beginCustomKeyCapture(_ sender: NSButton) {
        guard let slot = BindingSlot.slot(for: sender.tag) else {
            return
        }

        if swipeKeys.currentKeyPreset != .custom {
            swipeKeys.setKeyPreset(.custom)
        }

        captureSlot = slot
        refreshBindingsStatus()
        keyOptionsWindow?.makeFirstResponder(sender)
    }

    @objc private func clearCustomKey(_ sender: NSButton) {
        guard let slot = BindingSlot.slot(for: sender.tag) else {
            return
        }

        captureSlot = nil
        swipeKeys.setCustomKeyCode(nil, for: slot)
        refreshBindingsStatus()
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

    Turns bound keys into mouse-drag swipe gestures and taps wherever the cursor is.
    Defaults are arrow keys for swipes and Enter for tap. Original key events pass
    through normally.

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
