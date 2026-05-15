import AppKit
import CoreGraphics
import Foundation

struct Swipe {
    let vertical: Int32
    let horizontal: Int32
}

struct Options {
    var appMatch = "subway"
    var intensity: Int32 = 18
    var repeats = 5
    var verbose = false
}

extension Notification.Name {
    static let swipeKeysAction = Notification.Name("SwipeKeysAction")
    static let swipeKeysEnabledChanged = Notification.Name("SwipeKeysEnabledChanged")
}

final class SwipeKeys {
    private let options: Options
    private let source: CGEventSource?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let tapKeyCode: Int64 = 49
    private let toggleKeyCode: Int64 = 40 // K
    private let stateLock = NSLock()
    private var enabled = true

    private lazy var keyMap: [Int64: Swipe] = [
        13: Swipe(vertical: -options.intensity, horizontal: 0), // W
        126: Swipe(vertical: -options.intensity, horizontal: 0), // Up
        1: Swipe(vertical: options.intensity, horizontal: 0), // S
        125: Swipe(vertical: options.intensity, horizontal: 0), // Down
        0: Swipe(vertical: 0, horizontal: -options.intensity), // A
        123: Swipe(vertical: 0, horizontal: -options.intensity), // Left
        2: Swipe(vertical: 0, horizontal: options.intensity), // D
        124: Swipe(vertical: 0, horizontal: options.intensity), // Right
    ]

    init(options: Options) {
        self.options = options
        self.source = CGEventSource(stateID: .hidSystemState)
    }

    func startCommandLine() {
        if !AXIsProcessTrusted() {
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            print("SwipeKeys needs Accessibility permission. Enable it, then run this command again.")
            exit(1)
        }

        guard installEventTap() else {
            print("Could not create keyboard event tap. Check Accessibility permission and try again.")
            exit(1)
        }

        print("SwipeKeys is running. Press Control-Option-Command-K to toggle, or Control-C to quit.")
        CFRunLoopRun()
    }

    func startApp(promptForPermission: Bool = false) -> Bool {
        guard AXIsProcessTrusted() else {
            if promptForPermission {
                AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            }
            return false
        }

        return true
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
            return false
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        return true
    }

    fileprivate func handle(event: CGEvent) -> Unmanaged<CGEvent>? {
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if isRepeat {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if isToggleEvent(keyCode: keyCode, flags: event.flags) {
            toggle()
            return nil
        }

        guard isEnabled else {
            return Unmanaged.passUnretained(event)
        }

        _ = perform(keyCode: keyCode)
        return Unmanaged.passUnretained(event)
    }

    func perform(keyCode: Int64) -> Bool {
        if let swipe = keyMap[keyCode] {
            post(swipe: swipe)
            return true
        }

        if keyCode == tapKeyCode {
            postTap()
            return true
        }

        return false
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

        NotificationCenter.default.post(
            name: .swipeKeysEnabledChanged,
            object: nil,
            userInfo: ["enabled": newValue]
        )

        return newValue
    }

    func isToggleEvent(keyCode: Int64, flags: CGEventFlags) -> Bool {
        guard keyCode == toggleKeyCode else {
            return false
        }

        let needed: CGEventFlags = [.maskAlternate, .maskControl]
        return flags.intersection(needed) == needed
    }

    func isToggleEvent(keyCode: Int64, flags: NSEvent.ModifierFlags) -> Bool {
        guard keyCode == toggleKeyCode else {
            return false
        }

        return flags.contains(.option) && flags.contains(.control)
    }

    private func post(swipe: Swipe) {
        let point = targetGesturePoint()
        var posted = false

        if options.verbose {
            print("Swipe vertical=\(swipe.vertical) horizontal=\(swipe.horizontal) x=\(Int(point.x)) y=\(Int(point.y))")
        }

        for _ in 0..<options.repeats {
            guard let event = CGEvent(
                scrollWheelEvent2Source: source,
                units: .pixel,
                wheelCount: 2,
                wheel1: swipe.vertical,
                wheel2: swipe.horizontal,
                wheel3: 0
            ) else {
                continue
            }

            event.location = point
            event.post(tap: .cghidEventTap)
            posted = true
            usleep(4_500)
        }

        if posted {
            publishAction(label(for: swipe), at: point)
        }
    }

    private func postTap() {
        let point = targetGesturePoint()

        if options.verbose {
            print("Tap x=\(Int(point.x)) y=\(Int(point.y))")
        }

        guard
            let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
            let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        else {
            return
        }

        down.post(tap: .cghidEventTap)
        usleep(20_000)
        up.post(tap: .cghidEventTap)
        publishAction("tap", at: point)
    }

    private func targetGesturePoint() -> CGPoint {
        return CGEvent(source: nil)?.location ?? .zero
    }

    private func label(for swipe: Swipe) -> String {
        if swipe.vertical < 0 {
            return "swipe up"
        }
        if swipe.vertical > 0 {
            return "swipe down"
        }
        if swipe.horizontal < 0 {
            return "swipe left"
        }
        return "swipe right"
    }

    private func publishAction(_ label: String, at point: CGPoint) {
        NotificationCenter.default.post(
            name: .swipeKeysAction,
            object: nil,
            userInfo: ["action": label, "x": point.x, "y": point.y]
        )
    }
}

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
    }

    func show(action: String, quartzPoint: CGPoint, in window: NSWindow?) {
        guard let window else {
            return
        }

        let screenPoint = appKitScreenPoint(fromQuartzPoint: quartzPoint)
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let localPoint = convert(windowPoint, from: nil)

        guard bounds.contains(localPoint) else {
            return
        }

        markerPoint = localPoint
        markerLabel = action
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
            "Move cursor here, then press a bound key".draw(
                in: NSRect(x: 12, y: bounds.midY + 8, width: bounds.width - 24, height: 18),
                withAttributes: [
                    .font: NSFont.systemFont(ofSize: 11),
                    .foregroundColor: NSColor.tertiaryLabelColor,
                    .paragraphStyle: paragraph,
                ]
            )
        }
    }

    private func appKitScreenPoint(fromQuartzPoint point: CGPoint) -> CGPoint {
        for screen in NSScreen.screens {
            guard
                let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else {
                continue
            }

            let displayID = CGDirectDisplayID(screenNumber.uint32Value)
            let displayBounds = CGDisplayBounds(displayID)
            guard displayBounds.contains(point) else {
                continue
            }

            return CGPoint(
                x: screen.frame.minX + (point.x - displayBounds.minX),
                y: screen.frame.maxY - (point.y - displayBounds.minY)
            )
        }

        return NSEvent.mouseLocation
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
    private var actionObserver: NSObjectProtocol?
    private var enabledObserver: NSObjectProtocol?
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?

    init(options: Options) {
        self.swipeKeys = SwipeKeys(options: options)
        super.init()
        self.actionObserver = NotificationCenter.default.addObserver(
            forName: .swipeKeysAction,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let action = notification.userInfo?["action"] as? String,
                let x = notification.userInfo?["x"] as? CGFloat,
                let y = notification.userInfo?["y"] as? CGFloat
            else {
                return
            }

            Task { @MainActor [weak self, action, x, y] in
                guard let self else {
                    return
                }

                self.testView.show(action: action, quartzPoint: CGPoint(x: x, y: y), in: self.window)
            }
        }
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
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "SwipeKeys")
        }

        showWindow()
        installLocalTestMonitor()
        installGlobalMonitor()
        installMainMenu()
        refreshStatus()
        startIfAllowed()
        refreshEnabledStatus(swipeKeys.isEnabled)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func startIfAllowed() {
        isRunning = swipeKeys.startApp()
        refreshStatus()

        if !isRunning {
            permissionTimer?.invalidate()
            permissionTimer = Timer.scheduledTimer(timeInterval: 2, target: self, selector: #selector(retryPermission), userInfo: nil, repeats: true)
        }
    }

    @objc private func retryPermission(_ timer: Timer) {
        isRunning = swipeKeys.startApp()
        refreshStatus()

        if isRunning {
            timer.invalidate()
            permissionTimer = nil
        }
    }

    private func refreshEnabledStatus(_ enabled: Bool) {
        statusLabel.stringValue = enabled ? "On" : "Off"
        statusLabel.textColor = enabled ? .systemGreen : .secondaryLabelColor
        refreshStatus()
    }

    private func refreshStatus() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: swipeKeys.isEnabled ? "On" : "Off", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: isRunning ? "Accessibility Ready" : "Needs Accessibility Permission", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())

        let toggleItem = NSMenuItem(title: "Toggle On/Off", action: #selector(toggleFromMenu), keyEquivalent: "k")
        toggleItem.target = self
        toggleItem.keyEquivalentModifierMask = [.option, .control]
        menu.addItem(toggleItem)

        let showItem = NSMenuItem(title: "Show Window", action: #selector(showWindowFromMenu), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)

        let accessibilityItem = NSMenuItem(title: "Open Accessibility Settings", action: #selector(openAccessibilitySettings), keyEquivalent: ",")
        accessibilityItem.target = self
        menu.addItem(accessibilityItem)

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
        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        titleLabel.alignment = .center

        statusLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        statusLabel.alignment = .center

        let swipeLabel = NSTextField(labelWithString: "WASD & arrows --> swipe")
        swipeLabel.font = .systemFont(ofSize: 14, weight: .medium)
        swipeLabel.alignment = .center

        let tapLabel = NSTextField(labelWithString: "Spacebar --> tap")
        tapLabel.font = .systemFont(ofSize: 14, weight: .medium)
        tapLabel.alignment = .center

        let bindingsStack = NSStackView(views: [swipeLabel, tapLabel])
        bindingsStack.orientation = .vertical
        bindingsStack.alignment = .centerX
        bindingsStack.spacing = 4

        testView.translatesAutoresizingMaskIntoConstraints = false

        let cursorButton = linkButton(title: "Actions happen around the cursor", action: #selector(openAccessibilitySettings))
        let permissionButton = linkButton(title: "Enable accessibility permission", action: #selector(openAccessibilitySettings))

        let footerStack = NSStackView(views: [cursorButton, permissionButton])
        footerStack.orientation = .vertical
        footerStack.alignment = .centerX
        footerStack.spacing = 3

        let toggleLabel = NSTextField(labelWithString: "Toggle: control + option + K")
        toggleLabel.font = .systemFont(ofSize: 11)
        toggleLabel.textColor = .tertiaryLabelColor
        toggleLabel.alignment = .center

        let headerStack = NSStackView(views: [titleLabel, statusLabel])
        headerStack.orientation = .vertical
        headerStack.alignment = .centerX
        headerStack.spacing = 2

        let stackView = NSStackView(views: [headerStack, bindingsStack, testView, toggleLabel, footerStack])
        stackView.orientation = .vertical
        stackView.alignment = .centerX
        stackView.spacing = 12
        stackView.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            stackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            stackView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            testView.widthAnchor.constraint(equalToConstant: 320),
            testView.heightAnchor.constraint(equalToConstant: 118),
        ])

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
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
    }

    private func linkButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false
        button.font = .systemFont(ofSize: 12)
        button.contentTintColor = .secondaryLabelColor
        return button
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
                self.swipeKeys.toggle()
                return nil
            }

            guard self.swipeKeys.isEnabled, self.testView.contains(screenPoint: NSEvent.mouseLocation, in: self.window) else {
                return event
            }

            return self.swipeKeys.perform(keyCode: Int64(event.keyCode)) ? nil : event
        }
    }

    private func installGlobalMonitor() {
        guard globalKeyMonitor == nil else {
            return
        }

        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else {
                return
            }

            let keyCode = Int64(event.keyCode)
            if self.swipeKeys.isToggleEvent(keyCode: keyCode, flags: event.modifierFlags) {
                self.swipeKeys.toggle()
                return
            }

            guard self.swipeKeys.isEnabled else {
                return
            }

            _ = self.swipeKeys.perform(keyCode: keyCode)
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

    @objc private func showWindowFromMenu() {
        showWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
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
    guard type == .keyDown, let userInfo else {
        return Unmanaged.passUnretained(event)
    }

    let app = Unmanaged<SwipeKeys>.fromOpaque(userInfo).takeUnretainedValue()
    return app.handle(event: event)
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
        case "--repeats":
            index += 1
            guard index < arguments.count, let value = Int(arguments[index]) else {
                print("Missing numeric value for --repeats")
                exit(2)
            }
            options.repeats = max(1, value)
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

    Turns WASD and arrow keys into trackpad-like swipe events, and Space into
    a tap wherever the cursor is. Original key events still pass through
    normally.

    Usage:
      swipekeys [--match text] [--intensity number] [--repeats number] [--verbose]

    Defaults:
      --match subway
      --intensity 18
      --repeats 5
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
