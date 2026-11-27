import Foundation

/// Radix-2 complex FFT with precomputed twiddles and a Hann window, for magnitude spectra.
public final class FFT {
    public let size: Int
    let log2n: Int
    let cosTable: [Double]
    let sinTable: [Double]
    let bitReverse: [Int]
    public let window: [Double]

    public init(size: Int) {
        precondition(size > 1 && size & (size - 1) == 0, "FFT size must be a power of two")
        self.size = size
        var l = 0
        while (1 << l) < size { l += 1 }
        log2n = l
        var c = [Double](repeating: 0, count: size / 2)
        var s = [Double](repeating: 0, count: size / 2)
        for i in 0 ..< size / 2 {
            let a = -2.0 * Double.pi * Double(i) / Double(size)
            c[i] = cos(a)
            s[i] = sin(a)
        }
        cosTable = c
        sinTable = s
        var rev = [Int](repeating: 0, count: size)
        for i in 0 ..< size {
            var x = i
            var r = 0
            for _ in 0 ..< l {
                r = (r << 1) | (x & 1)
                x >>= 1
            }
            rev[i] = r
        }
        bitReverse = rev
        window = (0 ..< size).map { 0.5 - 0.5 * cos(2.0 * Double.pi * Double($0) / Double(size)) }
    }

    /// Magnitude spectrum (size/2 + 1 bins) of a windowed real frame.
    public func magnitudes(_ frame: UnsafeBufferPointer<Float>, offset: Int, into out: inout [Double]) {
        var re = [Double](repeating: 0, count: size)
        var im = [Double](repeating: 0, count: size)
        for i in 0 ..< size {
            let j = offset + i
            let sample = j >= 0 && j < frame.count ? Double(frame[j]) : 0
            re[bitReverse[i]] = sample * window[i]
        }
        var half = 1
        while half < size {
            let step = size / (half * 2)
            var start = 0
            while start < size {
                for k in 0 ..< half {
                    let w = k * step
                    let wr = cosTable[w]
                    let wi = sinTable[w]
                    let a = start + k
                    let b = a + half
                    let tr = re[b] * wr - im[b] * wi
                    let ti = re[b] * wi + im[b] * wr
                    re[b] = re[a] - tr
                    im[b] = im[a] - ti
                    re[a] += tr
                    im[a] += ti
                }
                start += half * 2
            }
            half *= 2
        }
        let bins = size / 2 + 1
        if out.count != bins { out = [Double](repeating: 0, count: bins) }
        for i in 0 ..< bins { out[i] = (re[i] * re[i] + im[i] * im[i]).squareRoot() }
    }
}
