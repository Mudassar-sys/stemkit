import Accelerate
import Foundation

/// An exact real-input DFT of any length, computed as a matrix product with Accelerate.
///
/// Accelerate's FFT and DFT routines accept lengths of the form f * 2^n with f in
/// {1, 3, 5, 9, 15}; 400 = 25 * 16 is not one of them, and zero padding to a supported
/// length would change the frequency grid and therefore the result. This type evaluates
/// the DFT definition directly, X[k] = sum_n x[n] * exp(-2 pi i k n / N) for
/// k = 0 ... N/2, in double precision. The cosine and sine tables are built once with the
/// angle reduced exactly in integers ((k * n) mod N), and each block of frames is
/// transformed with two `vDSP_mmulD` products.
public struct DirectDFT: Sendable {
    /// Transform length N.
    public let count: Int
    /// Output bins, N / 2 + 1 (the one-sided spectrum, as `numpy.fft.rfft` returns).
    public let bins: Int
    /// cos(2 pi k n / N), row-major with N rows and `bins` columns.
    let cosine: [Double]
    /// -sin(2 pi k n / N), row-major with N rows and `bins` columns.
    let negativeSine: [Double]

    /// Builds the tables for length `count` (at least 1).
    public init(count: Int) {
        let n = max(count, 1)
        self.count = n
        bins = n / 2 + 1
        var cosine = [Double](repeating: 0, count: n * bins)
        var negativeSine = [Double](repeating: 0, count: n * bins)
        for row in 0 ..< n {
            for k in 0 ..< bins {
                let reduced = (row * k) % n
                let angle = 2.0 * Double.pi * Double(reduced) / Double(n)
                cosine[row * bins + k] = cos(angle)
                negativeSine[row * bins + k] = -sin(angle)
            }
        }
        self.cosine = cosine
        self.negativeSine = negativeSine
    }

    /// Transforms `rows` frames stored row-major (`rows * count` values). Returns the real
    /// and imaginary parts, each row-major with `rows * bins` values.
    public func transform(frames: [Double], rows: Int) -> (real: [Double], imaginary: [Double]) {
        guard rows > 0, frames.count == rows * count else { return ([], []) }
        var real = [Double](repeating: 0, count: rows * bins)
        var imaginary = [Double](repeating: 0, count: rows * bins)
        Self.multiply(frames, cosine, into: &real, m: rows, n: bins, p: count)
        Self.multiply(frames, negativeSine, into: &imaginary, m: rows, n: bins, p: count)
        return (real, imaginary)
    }

    /// C (m x n) = A (m x p) * B (p x n), all row-major, with `vDSP_mmulD`.
    static func multiply(_ a: [Double], _ b: [Double], into c: inout [Double], m: Int, n: Int, p: Int) {
        guard a.count == m * p, b.count == p * n, c.count == m * n, m > 0, n > 0, p > 0 else { return }
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                c.withUnsafeMutableBufferPointer { pc in
                    guard let baseA = pa.baseAddress, let baseB = pb.baseAddress, let baseC = pc.baseAddress else { return }
                    vDSP_mmulD(baseA, 1, baseB, 1, baseC, 1, vDSP_Length(m), vDSP_Length(n), vDSP_Length(p))
                }
            }
        }
    }

    /// The textbook O(N^2) evaluation for one frame, used by the tests as the oracle.
    /// The angle is reduced exactly in integers, and the sum runs over n in order.
    public static func naive(_ x: [Double]) -> (real: [Double], imaginary: [Double]) {
        let n = x.count
        guard n > 0 else { return ([], []) }
        let bins = n / 2 + 1
        var real = [Double](repeating: 0, count: bins)
        var imaginary = [Double](repeating: 0, count: bins)
        for k in 0 ..< bins {
            var re = 0.0
            var im = 0.0
            for i in 0 ..< n {
                let angle = 2.0 * Double.pi * Double((i * k) % n) / Double(n)
                re += x[i] * cos(angle)
                im -= x[i] * sin(angle)
            }
            real[k] = re
            imaginary[k] = im
        }
        return (real, imaginary)
    }
}
