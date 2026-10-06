import Accelerate
import CryptoKit
import Foundation
import Testing
@testable import MelFrontEnd

/// Fixture access for the reference features written by reference/make_mel_fixtures.py.
enum MelFixtures {
    struct Clip: Sendable {
        let name: String
        let input: String
        let features: String
        let inputSHA256: String
        let featuresSHA256: String
        let shape: [Int]
    }

    static func root() throws -> URL {
        try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
    }

    static func manifest() throws -> (versions: [String: String], clips: [Clip]) {
        let data = try Data(contentsOf: try root().appendingPathComponent("manifest.json"))
        let top = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let versions = try #require(top["versions"] as? [String: String])
        let items = try #require(top["clips"] as? [[String: Any]])
        let clips = try items.map { item in
            Clip(
                name: try #require(item["name"] as? String),
                input: try #require(item["input"] as? String),
                features: try #require(item["features"] as? String),
                inputSHA256: try #require(item["input_sha256"] as? String),
                featuresSHA256: try #require(item["features_sha256"] as? String),
                shape: try #require(item["shape"] as? [Int])
            )
        }
        return (versions, clips)
    }

    /// 16-bit little-endian samples converted to float32 by dividing by 32768 (exact).
    static func samples(_ clip: Clip) throws -> [Float] {
        let data = try Data(contentsOf: try root().appendingPathComponent(clip.input))
        #expect(sha256(data) == clip.inputSHA256, "\(clip.input) does not match its manifest digest")
        let bytes = [UInt8](data)
        var out = [Float](repeating: 0, count: bytes.count / 2)
        for i in 0 ..< out.count {
            let value = Int16(bitPattern: UInt16(bytes[2 * i]) | UInt16(bytes[2 * i + 1]) << 8)
            out[i] = Float(value) / 32768.0
        }
        return out
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func features(_ clip: Clip) throws -> [Float] {
        let data = try Data(contentsOf: try root().appendingPathComponent(clip.features))
        #expect(sha256(data) == clip.featuresSHA256, "\(clip.features) does not match its manifest digest")
        let bytes = [UInt8](data)
        var out = [Float](repeating: 0, count: bytes.count / 4)
        for i in 0 ..< out.count {
            let bits = UInt32(bytes[4 * i]) | UInt32(bytes[4 * i + 1]) << 8 | UInt32(bytes[4 * i + 2]) << 16 | UInt32(bytes[4 * i + 3]) << 24
            out[i] = Float(bitPattern: bits)
        }
        return out
    }
}

@Suite("Direct DFT")
struct DirectDFTTests {
    @Test("Accelerate's DFT setup rejects length 400 and accepts a documented length")
    func acceleratePrecondition() {
        let rejected = try? vDSP.DiscreteFourierTransform(
            previous: nil, count: 400, direction: .forward, transformType: .complexComplex, ofType: Float.self)
        #expect(rejected == nil)
        let accepted = try? vDSP.DiscreteFourierTransform(
            previous: nil, count: 320, direction: .forward, transformType: .complexComplex, ofType: Float.self)
        #expect(accepted != nil)
    }

    @Test("Matrix DFT equals the naive O(N^2) DFT on random frames")
    func matchesNaive() {
        let n = 400
        let dft = DirectDFT(count: n)
        var state: UInt64 = 0x1234_5678
        func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53) * 2 - 1
        }
        let rows = 8
        let frames = (0 ..< rows * n).map { _ in next() }
        let (real, imaginary) = dft.transform(frames: frames, rows: rows)
        var maxError = 0.0
        for r in 0 ..< rows {
            let (re, im) = DirectDFT.naive(Array(frames[r * n ..< (r + 1) * n]))
            for k in 0 ..< dft.bins {
                maxError = max(maxError, abs(re[k] - real[r * dft.bins + k]), abs(im[k] - imaginary[r * dft.bins + k]))
            }
        }
        print("DFT max_abs_error_vs_naive=\(maxError)")
        // Values are sums of 400 terms of magnitude below 1; double rounding stays far below 1e-9.
        #expect(maxError < 1e-9)
    }

    @Test("Known transforms: impulse, constant and a cosine on a bin")
    func knownTransforms() {
        let n = 400
        let dft = DirectDFT(count: n)
        var impulse = [Double](repeating: 0, count: n)
        impulse[0] = 1
        let a = dft.transform(frames: impulse, rows: 1)
        #expect(a.real.allSatisfy { abs($0 - 1) < 1e-12 })
        #expect(a.imaginary.allSatisfy { abs($0) < 1e-12 })
        let constant = dft.transform(frames: [Double](repeating: 1, count: n), rows: 1)
        #expect(abs(constant.real[0] - Double(n)) < 1e-9)
        #expect(constant.real.dropFirst().allSatisfy { abs($0) < 1e-9 })
        let k0 = 37
        let cosine = (0 ..< n).map { cos(2 * Double.pi * Double((k0 * $0) % n) / Double(n)) }
        let c = dft.transform(frames: cosine, rows: 1)
        for k in 0 ..< dft.bins {
            #expect(abs(c.real[k] - (k == k0 ? Double(n) / 2 : 0)) < 1e-9)
        }
    }
}

@Suite("Whisper log-mel parity")
struct MelParityTests {
    /// Pass threshold for every element: 1e-6. Reason: the reference and this port evaluate the
    /// same double precision pipeline and round to float32 at the same three points (the
    /// complex64 spectrum, the log10 output, the final add and divide). The double results
    /// agree to about 1e-13 relative, so the only differences possible are values that sit on a
    /// float32 rounding boundary and round the other way. A flip of a float32 log10 value below
    /// 16 in magnitude (one ulp at most 2^-20) moves its output by at most 2^-20 / 4 = 2.4e-7;
    /// a flip in the complex64 spectrum moves it by about 1.3e-8; the final float32 step can
    /// add one output ulp, 1.2e-7 for outputs in [1, 2). 1e-6 covers these with margin.
    ///
    /// Mean threshold: 2e-7. Most elements of a padded chunk sit on the clamp floor
    /// (peak - 8), so a single flip of the peak value moves all of them by up to about 1.2e-7
    /// at once; the mean bound allows that one event and not a systematic error.
    static let maxThreshold: Float = 1e-6
    static let meanThreshold: Double = 2e-7

    @Test("Every reference clip matches element by element")
    func parity() throws {
        let (versions, clips) = try MelFixtures.manifest()
        #expect(clips.count == 6)
        print("MEL reference transformers=\(versions["transformers"] ?? "?") numpy=\(versions["numpy"] ?? "?")")
        #expect(versions["transformers"] == "5.18.0")
        #expect(versions["numpy"] == "2.5.3")
        let frontEnd = WhisperMelFrontEnd()
        for clip in clips {
            #expect(clip.shape == [80, 3000])
            let expected = try MelFixtures.features(clip)
            let actual = frontEnd.features(try MelFixtures.samples(clip))
            #expect(actual.count == expected.count)
            guard actual.count == expected.count else { continue }
            var maxError: Float = 0
            var sum = 0.0
            var exact = 0
            for i in 0 ..< actual.count {
                let e = abs(actual[i] - expected[i])
                maxError = max(maxError, e)
                sum += Double(e)
                if e == 0 { exact += 1 }
            }
            let mean = sum / Double(actual.count)
            print("MEL clip=\(clip.name) max_abs_error=\(maxError) mean_abs_error=\(mean) exact=\(exact)/\(actual.count)")
            #expect(maxError <= Self.maxThreshold, "\(clip.name)")
            #expect(mean <= Self.meanThreshold, "\(clip.name)")
        }
    }

    @Test("Mel filters: 201 x 80, no empty filter, and the Slaney mel scale round trips")
    func filterBank() {
        let filters = MelFilterBank.slaney(bins: 201, mels: 80, sampleRate: 16_000, minFrequency: 0, maxFrequency: 8000)
        #expect(filters.count == 201 * 80)
        for j in 0 ..< 80 {
            var peak = 0.0
            for i in 0 ..< 201 { peak = max(peak, filters[i * 80 + j]) }
            #expect(peak > 0, "filter \(j)")
        }
        #expect(abs(MelFilterBank.melToHertz(MelFilterBank.hertzToMel(4321)) - 4321) < 1e-9)
    }

    @Test("Benchmark: frames per second on this machine (reported, not gated)")
    func benchmark() {
        let frontEnd = WhisperMelFrontEnd()
        let input = (0 ..< 16_000 * 30).map { Float(sin(Double($0) * 0.01)) * 0.5 }
        _ = frontEnd.features(input)  // warm up
        let runs = 5
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for _ in 0 ..< runs { _ = frontEnd.features(input) }
        }
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
        let frames = Double(runs * frontEnd.configuration.framesPerChunk)
        print("BENCHMARK mel_frames_per_second=\(Int(frames / seconds)) chunks_per_second=\(String(format: "%.2f", Double(runs) / seconds))")
        #expect(seconds > 0)
    }
}
