import AppKit

enum MeetingActivity: Equatable {
    case hidden
    case starting(String)
    case recording(String)
    case transcribing(String)
    case ready(String)
    case failed(String)
    case recordingOffer(String)
}

@MainActor
final class MeetingActivityPanel {
    var onStop: (() -> Void)?
    var onAcceptRecording: (() -> Void)?
    var onDeclineRecording: (() -> Void)?
    private var panel: NSPanel?
    private var dot: NSView?
    private var titleLabel: NSTextField?
    private var detailLabel: NSTextField?
    private var stopButton: NSButton?
    private var declineButton: NSButton?
    private var spinner: NSProgressIndicator?
    private var countdownLayer: CAShapeLayer?
    private var generation = 0

    func update(_ activity: MeetingActivity) {
        generation += 1
        let currentGeneration = generation
        if activity == .hidden { panel?.orderOut(nil); return }
        if panel == nil { build() }
        guard let panel else { return }
        switch activity {
        case .recordingOffer(let name):
            configure(title: "Record this meeting?", detail: "\(name) · choose within 5 seconds", color: .systemGreen, processing: false, canStop: false)
            stopButton?.isHidden = false; stopButton?.title = "Record"; declineButton?.isHidden = false; startCountdown()
        case .starting(let name): configure(title: "Preparing recording", detail: name, color: .systemOrange, processing: true, canStop: true)
        case .recording(let name): configure(title: "Recording meeting", detail: "\(name) · audio stays on this Mac", color: .systemRed, processing: false, canStop: true)
        case .transcribing(let name): configure(title: "Transcribing locally", detail: name, color: .systemOrange, processing: true, canStop: false)
        case .ready(let name):
            configure(title: "Transcript ready", detail: name, color: .systemGreen, processing: false, canStop: false)
        case .failed(let message):
            configure(title: "Meeting capture needs attention", detail: message, color: .systemRed, processing: false, canStop: false)
        case .hidden: break
        }
        position(panel)
        panel.orderFrontRegardless()
        let delay: TimeInterval
        if case .recordingOffer = activity { delay = 5 } else { delay = 3 }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard self?.generation == currentGeneration else { return }
            self?.panel?.orderOut(nil); self?.countdownLayer?.removeAllAnimations(); self?.onDeclineRecording?()
        }
    }

    private func configure(title: String, detail: String, color: NSColor, processing: Bool, canStop: Bool) {
        titleLabel?.stringValue = title
        detailLabel?.stringValue = detail
        dot?.layer?.backgroundColor = color.cgColor
        spinner?.isHidden = !processing
        processing ? spinner?.startAnimation(nil) : spinner?.stopAnimation(nil)
        stopButton?.isHidden = !canStop
        declineButton?.isHidden = true
        stopButton?.title = "Stop"
    }

    private func build() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 76),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let container = NSVisualEffectView(frame: panel.contentView!.bounds)
        container.material = .hudWindow
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 18
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        container.layer?.masksToBounds = true
        panel.contentView = container

        let dot = NSView(frame: NSRect(x: 18, y: 31, width: 10, height: 10))
        dot.wantsLayer = true; dot.layer?.cornerRadius = 5
        container.addSubview(dot)

        let title = NSTextField(labelWithString: "Recording meeting")
        title.frame = NSRect(x: 40, y: 39, width: 245, height: 20)
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.textColor = .labelColor
        container.addSubview(title)

        let detail = NSTextField(labelWithString: "Google Meet")
        detail.frame = NSRect(x: 40, y: 17, width: 270, height: 18)
        detail.font = .systemFont(ofSize: 11.5, weight: .regular)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        container.addSubview(detail)

        let spinner = NSProgressIndicator(frame: NSRect(x: 17, y: 27, width: 16, height: 16))
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isHidden = true
        container.addSubview(spinner)

        let stop = NSButton(frame: NSRect(x: 306, y: 22, width: 72, height: 32))
        stop.title = "Stop"; stop.bezelStyle = .rounded; stop.controlSize = .small
        stop.target = self; stop.action = #selector(stopPressed)
        container.addSubview(stop)

        let decline = NSButton(frame: NSRect(x: 384, y: 25, width: 24, height: 26))
        decline.title = "×"; decline.isBordered = false; decline.font = .systemFont(ofSize: 18, weight: .medium)
        decline.contentTintColor = .secondaryLabelColor
        decline.target = self; decline.action = #selector(declinePressed); decline.isHidden = true
        container.addSubview(decline)

        self.panel = panel; self.dot = dot; titleLabel = title; detailLabel = detail
        stopButton = stop; declineButton = decline; self.spinner = spinner
    }

    private func startCountdown() {
        guard let panel, let container = panel.contentView else { return }
        countdownLayer?.removeFromSuperlayer()
        let ring = CAShapeLayer()
        ring.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 18, height: 18), transform: nil)
        ring.frame = CGRect(x: 283, y: 29, width: 18, height: 18)
        ring.fillColor = NSColor.clear.cgColor; ring.strokeColor = NSColor.systemGreen.cgColor
        ring.lineWidth = 2; ring.strokeEnd = 1
        container.layer?.addSublayer(ring); countdownLayer = ring
        let animation = CABasicAnimation(keyPath: "strokeEnd")
        animation.fromValue = 1; animation.toValue = 0; animation.duration = 5
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        ring.add(animation, forKey: "countdown"); ring.strokeEnd = 0
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: frame.maxX - panel.frame.width - 22,
                                     y: frame.maxY - panel.frame.height - 22))
    }

    @objc private func stopPressed() {
        if stopButton?.title == "Record" { generation += 1; panel?.orderOut(nil); onAcceptRecording?() }
        else { onStop?() }
    }


    @objc private func declinePressed() {
        generation += 1
        countdownLayer?.removeAllAnimations()
        panel?.orderOut(nil)
        onDeclineRecording?()
    }
}
