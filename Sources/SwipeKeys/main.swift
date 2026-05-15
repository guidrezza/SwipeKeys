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

    func start() {
        if !AXIsProcessTrusted() {
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            print("SwipeKeys needs Accessibility permission. Enable it, then run this command again.")
            exit(1)
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
            print("Could not create keyboard event tap. Check Accessibility permission and try again.")
            exit(1)
        }

        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)

        print("SwipeKeys is running. App match: \"\(options.appMatch)\". Press Control-C to quit.")
        CFRunLoopRun()
    }

    fileprivate func handle(event: CGEvent) -> Unmanaged<CGEvent>? {
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if isRepeat {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard let swipe = keyMap[keyCode], frontmostAppMatches() else {
            return Unmanaged.passUnretained(event)
        }

        post(swipe: swipe)
        return nil
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
        if options.verbose {
            print("Swipe vertical=\(swipe.vertical) horizontal=\(swipe.horizontal)")
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

            event.post(tap: .cghidEventTap)
            usleep(4_500)
        }
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

    Turns WASD and arrow keys into trackpad-like swipe events while a matching
    app is frontmost.

    Usage:
      swipekeys [--match text] [--intensity number] [--repeats number] [--verbose]

    Defaults:
      --match subway
      --intensity 18
      --repeats 5
    """)
}

let options = parseOptions(arguments: CommandLine.arguments)
SwipeKeys(options: options).start()
