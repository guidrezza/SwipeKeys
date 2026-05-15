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

final class SwipeKeys {
    private let options: Options
    private let source: CGEventSource?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let tapKeyCode: Int64 = 49

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

        print("SwipeKeys is running. App match: \"\(options.appMatch)\". Press Control-C to quit.")
        CFRunLoopRun()
    }

    func startApp(promptForPermission: Bool = false) -> Bool {
        guard AXIsProcessTrusted() else {
            if promptForPermission {
                AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            }
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
        guard frontmostAppMatches() else {
            return Unmanaged.passUnretained(event)
        }

        if let swipe = keyMap[keyCode] {
            post(swipe: swipe)
        } else if keyCode == tapKeyCode {
            postTap()
        }

        return Unmanaged.passUnretained(event)
    }

    private func frontmostAppMatches() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return false
        }

        let needle = options.appMatch.lowercased()
        let name = app.localizedName?.lowercased() ?? ""
        let bundleID = app.bundleIdentifier?.lowercased() ?? ""

        return name.contains(needle) || bundleID.contains(needle)
    }

    private func post(swipe: Swipe) {
        let point = targetGesturePoint()

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
            usleep(4_500)
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
    }

    private func targetGesturePoint() -> CGPoint {
        guard
            let app = NSWorkspace.shared.frontmostApplication,
            let windowInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else {
            return CGEvent(source: source)?.location ?? .zero
        }

        for window in windowInfo {
            guard
                window[kCGWindowOwnerPID as String] as? pid_t == app.processIdentifier,
                window[kCGWindowLayer as String] as? Int == 0,
                let boundsValue = window[kCGWindowBounds as String]
            else {
                continue
            }

            let boundsDictionary = boundsValue as! CFDictionary
            guard
                let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                bounds.width > 0,
                bounds.height > 0
            else {
                continue
            }

            let mouse = CGEvent(source: source)?.location ?? .zero
            if bounds.contains(mouse) {
                return mouse
            }

            return CGPoint(x: bounds.midX, y: bounds.midY)
        }

        return CGEvent(source: source)?.location ?? .zero
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private let swipeKeys: SwipeKeys
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var permissionTimer: Timer?
    private var isRunning = false
    private var window: NSWindow?
    private let statusLabel = NSTextField(labelWithString: "Starting...")

    init(options: Options) {
        self.swipeKeys = SwipeKeys(options: options)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "SwipeKeys")
            button.title = " SwipeKeys"
        }

        showWindow()
        refreshStatus()
        startIfAllowed()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func startIfAllowed() {
        isRunning = swipeKeys.startApp(promptForPermission: true)
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

    private func refreshStatus() {
        statusLabel.stringValue = isRunning ? "SwipeKeys is on" : "Enable Accessibility permission"

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: isRunning ? "Running" : "Needs Accessibility Permission", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Show Window", action: #selector(showWindowFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open Accessibility Settings", action: #selector(openAccessibilitySettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Quit SwipeKeys", action: #selector(quit), keyEquivalent: "q"))
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

        statusLabel.font = .systemFont(ofSize: 16, weight: .medium)
        statusLabel.alignment = .center

        let bindingsLabel = NSTextField(labelWithString: "WASD / arrows -> swipe\nSpace -> tap")
        bindingsLabel.font = .systemFont(ofSize: 14)
        bindingsLabel.textColor = .secondaryLabelColor
        bindingsLabel.alignment = .center
        bindingsLabel.maximumNumberOfLines = 2

        let hintLabel = NSTextField(labelWithString: "Gestures happen at the mouse when it is over the game, otherwise at the game window center.")
        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.alignment = .center
        hintLabel.maximumNumberOfLines = 2

        let stackView = NSStackView(views: [titleLabel, statusLabel, bindingsLabel, hintLabel])
        stackView.orientation = .vertical
        stackView.alignment = .centerX
        stackView.spacing = 10
        stackView.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            stackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            stackView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 190),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "SwipeKeys"
        window.contentView = contentView
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
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
    a tap, while a matching app is frontmost. Original key events still pass
    through normally.

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
