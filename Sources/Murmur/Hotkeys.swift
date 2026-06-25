import AppKit
import CoreGraphics

// Global key listener.
//   • Double-tap ⌘ (clean, no other key) → toggle recording.
//   • Hold ⌥ alone → push-to-talk; release to stop. Combining ⌥ with any key/modifier
//     cancels it, so ⌘C, ⌥←, ⌘⌥… never start a recording.
// Listen-only CGEventTap on flagsChanged/keyDown. Needs Input Monitoring permission.
final class HotkeyMonitor {
    var onToggle: (() -> Void)?
    var onPushToTalkStart: (() -> Void)?
    var onPushToTalkStop: (() -> Void)?
    var onPushToTalkAbort: (() -> Void)?
    var onCancel: (() -> Void)?

    private var tap: CFMachPort?
    private var previousFlags = CGEventFlags(rawValue: 0)
    private var loggedFirstEvent = false

    // ⌘ double-tap (toggle)
    private var cmdPressStart: CFTimeInterval = 0
    private var cmdContaminated = false
    private var lastCmdTapTime: CFTimeInterval = 0

    // ⌥ hold (push-to-talk)
    private var optionContaminated = false
    private var pttStarted = false
    private var optionGeneration = 0

    func start() -> Bool {
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: hotkeyCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.error("could not create event tap — Input Monitoring permission missing")
            return false
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.info("hotkey monitor active")
        return true
    }

    func reEnableIfNeeded() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    private func abortPushToTalk() {
        optionContaminated = true
        if pttStarted {
            pttStarted = false
            optionGeneration += 1
            onPushToTalkAbort?()
        }
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Log.info("hotkey tap was disabled (\(type.rawValue)) — re-enabling")
            reEnableIfNeeded()
            return
        }

        if !loggedFirstEvent {
            loggedFirstEvent = true
            Log.info("hotkey tap received its first event — it is live")
        }

        let flags = event.flags
        let now = CACurrentMediaTime()

        if type == .keyDown {
            if event.getIntegerValueField(.keyboardEventKeycode) == 53 { onCancel?() } // Escape
            if flags.contains(.maskCommand) { cmdContaminated = true }
            if flags.contains(.maskAlternate) { abortPushToTalk() }
            lastCmdTapTime = 0 // any keystroke breaks a pending ⌘ double-tap
            previousFlags = flags
            return
        }

        // flagsChanged
        let cmdNow = flags.contains(.maskCommand), cmdWas = previousFlags.contains(.maskCommand)
        let optNow = flags.contains(.maskAlternate), optWas = previousFlags.contains(.maskAlternate)

        let otherForCmd = flags.contains(.maskControl) || flags.contains(.maskShift)
            || flags.contains(.maskAlternate) || flags.contains(.maskSecondaryFn)
        let otherForOpt = flags.contains(.maskControl) || flags.contains(.maskShift)
            || flags.contains(.maskCommand) || flags.contains(.maskSecondaryFn)

        // ⌘ double-tap → toggle
        if cmdNow && !cmdWas {
            cmdPressStart = now
            cmdContaminated = otherForCmd
        } else if !cmdNow && cmdWas {
            let duration = now - cmdPressStart
            let clean = !cmdContaminated && duration < Config.cleanTapMaxDuration
            if clean {
                if now - lastCmdTapTime <= Config.doubleTapWindow {
                    lastCmdTapTime = 0
                    Log.info("⌘⌘ double-tap detected → toggle")
                    onToggle?()
                } else {
                    lastCmdTapTime = now
                }
            } else {
                lastCmdTapTime = 0
            }
        }

        // ⌥ hold → push-to-talk
        if optNow && !optWas {
            optionContaminated = otherForOpt
            optionGeneration += 1
            let generation = optionGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + Config.pttArmDelay) { [weak self] in
                guard let self else { return }
                guard generation == self.optionGeneration,
                      !self.optionContaminated, !self.pttStarted else { return }
                self.pttStarted = true
                self.onPushToTalkStart?()
            }
        } else if optNow && otherForOpt {
            // another modifier joined ⌥ → it's a shortcut, not push-to-talk
            abortPushToTalk()
        } else if !optNow && optWas {
            optionGeneration += 1 // invalidate any pending arm
            if pttStarted {
                pttStarted = false
                onPushToTalkStop?()
            }
        }

        previousFlags = flags
    }
}

private func hotkeyCallback(proxy: CGEventTapProxy,
                            type: CGEventType,
                            event: CGEvent,
                            userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let userInfo {
        let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        monitor.handle(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)
}
