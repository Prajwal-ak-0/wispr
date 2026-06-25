import Accelerate
import Foundation

// Turns a window of audio samples into a handful of frequency-band magnitudes,
// used to drive the live voice visualizer. Levels are raw (not normalized);
// the visualizer applies auto-gain and smoothing.
final class SpectrumAnalyzer {
    private let size: Int
    private let halfSize: Int
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private var window: [Float]
    private var windowed: [Float]
    private var realp: [Float]
    private var imagp: [Float]
    private var magnitudes: [Float]

    init?(size: Int = 1024) {
        guard size >= 2, (size & (size - 1)) == 0 else { return nil } // power of two
        self.size = size
        self.halfSize = size / 2
        self.log2n = vDSP_Length(log2(Double(size)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        self.fftSetup = setup
        self.window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
        self.windowed = [Float](repeating: 0, count: size)
        self.realp = [Float](repeating: 0, count: halfSize)
        self.imagp = [Float](repeating: 0, count: halfSize)
        self.magnitudes = [Float](repeating: 0, count: halfSize)
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    func analyze(_ samples: UnsafePointer<Float>, count: Int, bandCount: Int) -> [Float] {
        let n = min(count, size)
        if n < size {
            for i in n..<size { windowed[i] = 0 }
        }
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(n))

        var bands = [Float](repeating: 0, count: bandCount)
        realp.withUnsafeMutableBufferPointer { rp in
            imagp.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfSize) { cp in
                        vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(halfSize))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(halfSize))

                // Log-spaced bands across the voice-relevant range.
                let minBin = 2
                for b in 0..<bandCount {
                    let lo = logBin(b, of: bandCount, minBin: minBin, maxBin: halfSize)
                    let hi = max(lo + 1, logBin(b + 1, of: bandCount, minBin: minBin, maxBin: halfSize))
                    var sum: Float = 0
                    var c = 0
                    var i = lo
                    while i < hi && i < halfSize { sum += magnitudes[i]; c += 1; i += 1 }
                    bands[b] = c > 0 ? sqrtf(sum / Float(c)) : 0
                }
            }
        }
        return bands
    }

    private func logBin(_ index: Int, of bandCount: Int, minBin: Int, maxBin: Int) -> Int {
        let t = Double(index) / Double(bandCount)
        let value = Double(minBin) * pow(Double(maxBin) / Double(minBin), t)
        return min(maxBin, max(minBin, Int(value.rounded())))
    }
}
