import AVFoundation
import Accelerate

// Plays a bundled MP3 through AVAudioEngine and serves BASS-style FFT snapshots:
// a tap on the player keeps the latest 1024 mono samples, and fftMagnitudes()
// Hann-windows them into 512 magnitude bins, mirroring the Android renderer's
// BASS_ChannelGetData(..., BASS_DATA_FFT1024) that GameLogic was calibrated against.
final class AudioEngine {

    enum Failure: Error {
        case fileNotFound(String)
    }

    private static let fftSize = 1024
    private static let binCount = fftSize / 2
    // BASS-equivalent normalization, calibrated empirically against GameLogic's
    // chord-release rules over both demo tracks: 1/256 yields ~3.4 releases/s
    // with the spectrum bars still dancing (22-29% of updates have a pegged bar),
    // matching the busy Android game. Smaller values starve the game of enemies.
    private static let magnitudeScale: Float = 1.0 / 256

    let sampleRate: Int

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let file: AVAudioFile
    private let dft: vDSP.DiscreteFourierTransform<Float>
    private let hannWindow: [Float]

    private let lock = NSLock()
    private var latestSamples = [Float](repeating: 0, count: AudioEngine.fftSize)
    private var isFinished = false

    init(fileNamed name: String) throws {
        guard let url = Bundle.main.url(forResource: name, withExtension: "mp3") else {
            throw Failure.fileNotFound(name)
        }
        dft = try vDSP.DiscreteFourierTransform(count: Self.fftSize, direction: .forward,
                                                transformType: .complexReal, ofType: Float.self)
        file = try AVAudioFile(forReading: url)
        sampleRate = Int(file.processingFormat.sampleRate)
        hannWindow = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized,
                                 count: Self.fftSize, isHalfWindow: false)

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
        player.installTap(onBus: 0, bufferSize: AVAudioFrameCount(Self.fftSize), format: nil) { [weak self] buffer, _ in
            self?.capture(buffer)
        }
    }

    // MARK: - Playback

    func play() throws {
        try AVAudioSession.sharedInstance().setCategory(.playback)
        try AVAudioSession.sharedInstance().setActive(true)
        try engine.start()
        player.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.lock.withLock { self.isFinished = true }
        }
        player.play()
    }

    func pause() {
        player.pause()
        engine.pause()
    }

    func resume() {
        if !engine.isRunning {
            try? engine.start()
        }
        player.play()
    }

    func stop() {
        player.stop()
        engine.stop()
    }

    var hasFinishedPlaying: Bool {
        lock.withLock { isFinished }
    }

    // MARK: - Spectrum

    // Magnitudes of the latest 1024 played samples as 512 bins, BASS-scaled;
    // feed straight into GameLogic.updateSpectrum(fft:deltaTime:).
    func fftMagnitudes() -> [Float] {
        let windowed = vDSP.multiply(lock.withLock { latestSamples }, hannWindow)

        var inputReal = [Float](repeating: 0, count: Self.binCount)
        var inputImaginary = [Float](repeating: 0, count: Self.binCount)
        for i in inputReal.indices {  // even/odd split expected by the real-to-complex DFT
            inputReal[i] = windowed[2 * i]
            inputImaginary[i] = windowed[2 * i + 1]
        }

        var outputReal = [Float](repeating: 0, count: Self.binCount)
        var outputImaginary = [Float](repeating: 0, count: Self.binCount)
        dft.transform(inputReal: inputReal, inputImaginary: inputImaginary,
                      outputReal: &outputReal, outputImaginary: &outputImaginary)

        outputImaginary[0] = 0  // drop the packed Nyquist term; bin 0 is pure DC
        return vDSP.multiply(Self.magnitudeScale, vDSP.hypot(outputReal, outputImaginary))
    }

    private func capture(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        // Mix channels down to mono, as BASS does for its combined FFT.
        let channelCount = Int(buffer.format.channelCount)
        var mono = [Float](repeating: 0, count: frameCount)
        for channel in 0..<channelCount {
            vDSP.add(mono, UnsafeBufferPointer(start: channelData[channel], count: frameCount), result: &mono)
        }
        if channelCount > 1 {
            vDSP.divide(mono, Float(channelCount), result: &mono)
        }

        lock.withLock {
            if frameCount >= Self.fftSize {
                latestSamples = Array(mono.suffix(Self.fftSize))
            } else {
                latestSamples.removeFirst(frameCount)
                latestSamples.append(contentsOf: mono)
            }
        }
    }
}
