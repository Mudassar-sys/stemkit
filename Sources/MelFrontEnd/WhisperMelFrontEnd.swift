import Accelerate
import Foundation

/// Parameters of the reference extractor. The defaults are those of transformers'
/// `WhisperFeatureExtractor`: 80 mel bins, 16 kHz, hop 160, 30 second chunks, n_fft 400.
public struct WhisperFeatureConfiguration: Sendable, Equatable {
    /// Number of mel bins (`feature_size`).
    public var featureSize = 80
    /// Expected sample rate in Hz (`sampling_rate`).
    public var samplingRate = 16_000
    /// Hop between frames in samples (`hop_length`).
    public var hopLength = 160
    /// Chunk length in seconds (`chunk_length`).
    public var chunkLength = 30
    /// DFT length and window length (`n_fft`).
    public var fftLength = 400

    /// The reference defaults.
    public init() {}

    /// Samples per chunk: input is zero padded or truncated to this length (0 when the product
    /// does not fit an `Int` or a value is negative).
    public var samplesPerChunk: Int {
        let (product, overflow) = max(chunkLength, 0).multipliedReportingOverflow(by: max(samplingRate, 0))
        return overflow ? 0 : product
    }
    /// Frames in the output, `samplesPerChunk / hopLength`.
    public var framesPerChunk: Int { samplesPerChunk / max(hopLength, 1) }
}

/// Reproduces the numpy path of `WhisperFeatureExtractor` (transformers 5.18.0) step by step:
///
/// 1. pad with zeros or truncate to 30 seconds;
/// 2. reflect pad by n_fft / 2 on both sides (`center=True, pad_mode="reflect"`);
/// 3. frames of 400 samples every 160, times a periodic Hann window (`np.hanning(401)[:-1]`),
///    in double precision;
/// 4. one-sided DFT of length 400 (exact, see `DirectDFT`), stored as complex64 like the
///    reference's `np.empty(..., dtype=np.complex64)` buffer;
/// 5. power: `abs(z) ** 2` in double;
/// 6. Slaney-scale, Slaney-normalised mel filters from 0 to 8000 Hz, `max(1e-10, .)`, log10,
///    cast to float32;
/// 7. drop the last frame, clamp to (max - 8), then `(x + 4) / 4`, in float32.
public struct WhisperMelFrontEnd: Sendable {
    /// The parameters in use.
    public let configuration: WhisperFeatureConfiguration
    let window: [Double]
    let dft: DirectDFT
    /// Mel filters, row-major `bins x featureSize` like the reference's `mel_filters`.
    let melFilters: [Double]

    /// Builds the window, DFT tables and mel filters. Out-of-range parameters are clamped so
    /// memory stays bounded: mel bins to 1...512, the sample rate to 1...192000, the chunk to
    /// 1...60 seconds, the transform length to an even value in 2...4096, and the hop raised so
    /// that a chunk has at most 10,000 frames.
    public init(configuration: WhisperFeatureConfiguration = WhisperFeatureConfiguration()) {
        var config = configuration
        config.featureSize = min(max(config.featureSize, 1), 512)
        config.samplingRate = min(max(config.samplingRate, 1), 192_000)
        config.chunkLength = min(max(config.chunkLength, 1), 60)
        let fft = min(max(config.fftLength, 2), 4096)
        config.fftLength = fft + fft % 2
        // At most 10,000 frames per chunk (the default has 3,000), so the frame, spectrum and
        // mel buffers stay bounded whatever the other parameters are. The hop is raised if
        // needed; it is not capped at the transform length, which would undo this bound.
        let minimumHop = (config.samplesPerChunk + 9_999) / 10_000
        config.hopLength = max(config.hopLength, max(minimumHop, 1))
        self.configuration = config
        let n = config.fftLength
        // Periodic Hann: np.hanning(n + 1)[:-1]. numpy evaluates hanning(M) as
        // 0.5 + 0.5 cos(pi k / (M - 1)) for k = 1 - M, 3 - M, ..., M - 1. The same expression is
        // used here (M - 1 = n, k = 2m - n), so the only remaining difference is the platform's
        // cos; the mel output on CI is exact.
        window = (0 ..< n).map { m in 0.5 + 0.5 * cos(Double.pi * Double(2 * m - n) / Double(n)) }
        dft = DirectDFT(count: n)
        melFilters = MelFilterBank.slaney(
            bins: n / 2 + 1, mels: config.featureSize, sampleRate: config.samplingRate,
            minFrequency: 0, maxFrequency: 8000)
    }

    /// Log-mel features for one chunk, row-major `[mel][frame]`
    /// (`featureSize * framesPerChunk` values), as the reference's `input_features[0]`.
    public func features(_ samples: [Float]) -> [Float] {
        let config = configuration
        let n = dft.count
        let hop = config.hopLength
        let chunk = config.samplesPerChunk
        let half = n / 2
        guard chunk + 2 * half >= n, chunk > half else { return [] }

        // 1 and 2: pad or truncate, then reflect pad. Values stay float32 until here.
        var padded = [Double](repeating: 0, count: chunk + 2 * half)
        let used = min(samples.count, chunk)
        for i in 0 ..< used {
            padded[half + i] = Double(samples[i])
        }
        do {
            for i in 0 ..< half {
                padded[i] = padded[2 * half - i]  // x[half - i]
                padded[half + chunk + i] = padded[half + chunk - 2 - i]  // x[chunk - 2 - i]
            }
        }

        // 3: windowed frames.
        let frameCount = 1 + (padded.count - n) / hop
        var frames = [Double](repeating: 0, count: frameCount * n)
        for t in 0 ..< frameCount {
            let start = t * hop
            for i in 0 ..< n {
                frames[t * n + i] = padded[start + i] * window[i]
            }
        }

        // 4 and 5: DFT, complex64 storage, power in double.
        let (real, imaginary) = dft.transform(frames: frames, rows: frameCount)
        let bins = dft.bins
        var power = [Double](repeating: 0, count: frameCount * bins)
        for i in 0 ..< power.count {
            let re = Double(Float(real[i]))
            let im = Double(Float(imaginary[i]))
            let magnitude = hypot(re, im)
            power[i] = magnitude * magnitude
        }

        // 6: mel energies (frames x mels) = power (frames x bins) * filters (bins x mels).
        let mels = config.featureSize
        var energies = [Double](repeating: 0, count: frameCount * mels)
        DirectDFT.multiply(power, melFilters, into: &energies, m: frameCount, n: mels, p: bins)

        // numpy's maximum and max propagate NaN (from a non-finite sample or an infinite spectrum
        // value), so one NaN energy in the frames the reference keeps makes its whole output NaN;
        // mirror that. The last frame is dropped before the reference takes its maximum.
        if energies[0 ..< (frameCount - 1) * mels].contains(where: { $0.isNaN }) {
            return [Float](repeating: .nan, count: mels * (frameCount - 1))
        }

        // 6 and 7: log10 in double, float32, drop the last frame, transpose to [mel][frame].
        let outFrames = frameCount - 1
        var logMel = [Float](repeating: 0, count: mels * outFrames)
        var peak = -Float.infinity
        for t in 0 ..< outFrames {
            for m in 0 ..< mels {
                let value = Float(log10(max(1e-10, energies[t * mels + m])))
                logMel[m * outFrames + t] = value
                peak = max(peak, value)
            }
        }
        let floor = peak - 8.0
        for i in 0 ..< logMel.count {
            logMel[i] = (max(logMel[i], floor) + 4.0) / 4.0
        }
        return logMel
    }
}

/// The mel filter bank of transformers' `audio_utils.mel_filter_bank` with
/// `norm="slaney", mel_scale="slaney"`, in double precision.
public enum MelFilterBank {
    static let minLogHertz = 1000.0
    static let minLogMel = 15.0

    /// Slaney mel scale: linear below 1 kHz, logarithmic above.
    public static func hertzToMel(_ hertz: Double) -> Double {
        if hertz >= minLogHertz {
            let logstep = 27.0 / log(6.4)
            return minLogMel + log(hertz / minLogHertz) * logstep
        }
        return 3.0 * hertz / 200.0
    }

    /// Inverse of `hertzToMel`.
    public static func melToHertz(_ mel: Double) -> Double {
        if mel >= minLogMel {
            let logstep = log(6.4) / 27.0
            return minLogHertz * exp(logstep * (mel - minLogMel))
        }
        return 200.0 * mel / 3.0
    }

    /// `numpy.linspace(start, stop, count)`: start + i * step, with the last value set to stop.
    static func linspace(_ start: Double, _ stop: Double, _ count: Int) -> [Double] {
        guard count > 1 else { return count == 1 ? [start] : [] }
        let step = (stop - start) / Double(count - 1)
        var out = (0 ..< count).map { Double($0) * step + start }
        out[count - 1] = stop
        return out
    }

    /// Triangular filters with Slaney area normalisation, row-major `bins x mels`.
    public static func slaney(bins: Int, mels: Int, sampleRate: Int, minFrequency: Double, maxFrequency: Double) -> [Double] {
        guard bins >= 2, mels >= 1 else { return [] }
        let fftFrequencies = linspace(0, Double(sampleRate / 2), bins)
        let melPoints = linspace(hertzToMel(minFrequency), hertzToMel(maxFrequency), mels + 2)
        let filterFrequencies = melPoints.map(melToHertz)
        var difference = [Double](repeating: 0, count: mels + 1)
        for j in 0 ..< mels + 1 {
            difference[j] = filterFrequencies[j + 1] - filterFrequencies[j]
        }
        var filters = [Double](repeating: 0, count: bins * mels)
        for i in 0 ..< bins {
            for j in 0 ..< mels {
                let down = -(filterFrequencies[j] - fftFrequencies[i]) / difference[j]
                let up = (filterFrequencies[j + 2] - fftFrequencies[i]) / difference[j + 1]
                let enorm = 2.0 / (filterFrequencies[j + 2] - filterFrequencies[j])
                filters[i * mels + j] = max(0.0, min(down, up)) * enorm
            }
        }
        return filters
    }
}
