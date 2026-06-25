import AppKit
import QuartzCore

// A row of bars driven by live voice. Listening mode is loudness-driven and symmetric
// (every bar rises as you speak, centre tallest, with per-band spectral character);
// processing mode is a gentle travelling shimmer. Smoothed every frame via a display link.
final class VoiceBarsView: NSView {
    enum Mode { case listening, processing }

    private let barCount: Int
    private let center: Int
    private let bandCount: Int
    private var barLayers: [CALayer] = []

    private var displayed: [CGFloat]
    private var rawRMS: Float = 0
    private var rawBands: [Float]
    private var bandPeak: [CGFloat]
    private var smoothedLoud: CGFloat = 0
    private var idlePhase: CGFloat = 0
    private var phase: CGFloat = 0

    private var mode: Mode = .listening
    private var link: CADisplayLink?

    private let barWidth: CGFloat = 4
    private let barGap: CGFloat = 5
    private let minBarHeight: CGFloat = 3

    init(barCount: Int) {
        self.barCount = barCount
        self.center = barCount / 2
        self.bandCount = barCount / 2 + 1
        self.displayed = Array(repeating: 0, count: barCount)
        self.rawBands = Array(repeating: 0, count: barCount / 2 + 1)
        self.bandPeak = Array(repeating: 0.0001, count: barCount / 2 + 1)
        super.init(frame: .zero)
        wantsLayer = true
        for _ in 0..<barCount {
            let bar = CALayer()
            bar.backgroundColor = NSColor.white.cgColor
            bar.cornerRadius = barWidth / 2
            layer?.addSublayer(bar)
            barLayers.append(bar)
        }
    }
    required init?(coder: NSCoder) { fatalError("not supported") }

    var requiredBandCount: Int { bandCount }

    func update(rms: Float, bands: [Float]) {
        rawRMS = rms
        for i in 0..<min(bands.count, bandCount) { rawBands[i] = bands[i] }
    }

    func start(mode: Mode) {
        self.mode = mode
        if mode == .listening {
            smoothedLoud = 0
            for i in 0..<bandCount { bandPeak[i] = 0.0001; rawBands[i] = 0 }
        }
        guard link == nil else { return }
        let link = displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
        rawRMS = 0
        for i in 0..<barCount { displayed[i] = 0 }
        for i in 0..<bandCount { rawBands[i] = 0 }
        layoutBars()
    }

    @objc private func tick() {
        switch mode {
        case .listening: tickListening()
        case .processing: tickProcessing()
        }
        layoutBars()
    }

    private func tickListening() {
        let db = 20 * log10(max(Double(rawRMS), 1e-7))
        let loud = CGFloat(min(max((db + 60) / 42, 0), 1))           // ~-60dB..-18dB → 0..1
        let attack: CGFloat = loud > smoothedLoud ? 0.5 : 0.16        // snappy rise, smooth fall
        smoothedLoud += (loud - smoothedLoud) * attack

        idlePhase += 0.05
        for i in 0..<barCount {
            let bi = abs(i - center)
            let raw = CGFloat(rawBands[bi])
            bandPeak[bi] = max(raw, bandPeak[bi] * 0.95)
            let norm = min(raw / max(bandPeak[bi], 1e-6), 1)
            let envelope = 1 - 0.4 * CGFloat(bi) / CGFloat(max(center, 1))
            var target = smoothedLoud * envelope * (0.4 + 0.6 * norm)
            if smoothedLoud < 0.06 {                                  // gentle breathing when quiet
                target = max(target, 0.05 * (sin(idlePhase + CGFloat(i) * 0.55) + 1) / 2)
            }
            let a: CGFloat = target > displayed[i] ? 0.55 : 0.18
            displayed[i] += (target - displayed[i]) * a
        }
    }

    private func tickProcessing() {
        phase += 0.16
        for i in 0..<barCount {
            let s = (sin(phase + CGFloat(i) * 0.7) + 1) / 2
            let target = 0.2 + 0.4 * s
            displayed[i] += (target - displayed[i]) * 0.25
        }
    }

    private func layoutBars() {
        guard bounds.width > 0 else { return }
        let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barGap
        let startX = (bounds.width - totalWidth) / 2
        let maxHeight = bounds.height - 12
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for i in 0..<barCount {
            let h = minBarHeight + max(0, displayed[i]) * max(0, maxHeight - minBarHeight)
            let x = startX + CGFloat(i) * (barWidth + barGap)
            let y = (bounds.height - h) / 2
            barLayers[i].frame = CGRect(x: x, y: y, width: barWidth, height: h)
        }
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        layoutBars()
    }
}

// Floating pill near the bottom of the screen that hosts the voice bars.
final class OverlayController {
    enum State { case listening, processing }

    private var panel: NSPanel?
    private var bars: VoiceBarsView?

    func show(_ state: State) {
        if panel == nil { build() }
        guard let panel, let bars else { return }
        bars.start(mode: state == .listening ? .listening : .processing)
        position(panel)
        panel.orderFrontRegardless()
    }

    func setLevels(rms: Float, bands: [Float]) {
        bars?.update(rms: rms, bands: bands)
    }

    func hide() {
        bars?.stop()
        panel?.orderOut(nil)
    }

    private func build() {
        let width: CGFloat = 132, height: CGFloat = 40
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let container = NSView(frame: panel.contentView!.bounds)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 0.09, alpha: 0.92).cgColor
        container.layer?.cornerRadius = height / 2
        container.layer?.masksToBounds = true
        panel.contentView = container

        let bars = VoiceBarsView(barCount: Config.barCount)
        bars.frame = container.bounds
        bars.autoresizingMask = [.width, .height]
        container.addSubview(bars)

        self.panel = panel
        self.bars = bars
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 80))
    }
}
