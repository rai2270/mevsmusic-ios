// Platform-independent game rules ported from the Android reference
// (mvm/game/GameLogic.java): state machine, scoring, lives, bonus slots,
// spectrum smoothing and chord-release decisions, and the game-over sequence.
// No UIKit/SceneKit/AVFoundation imports — the renderer feeds inputs
// (time, FFT data, collisions) and applies outputs (pending spawns, flags).
final class GameLogic {

    enum State {
        case starting, running, paused, finished
    }

    // Bonus slots: index into the renderer's bonus systems via rawValue.
    enum BonusSlot: Int, CaseIterable {
        case weapon, score10, score50, score400, ship, score25

        var score: Int {
            switch self {
            case .weapon, .ship: 0
            case .score10: 1000
            case .score50: 5000
            case .score400: 40_000
            case .score25: 2500
            }
        }
    }

    static let maxShipCount = 5
    static let spectrumSize = 26
    static let spectrumSkipCount = 12
    static let spectrumBinCount = spectrumSize - spectrumSkipCount
    static let spectrumMaxValue: Float = 2.0

    private static let chordValue = 100
    private static let bonusInterval: Float = 2.5
    private static let ringDuration: Float = 30
    private static let shipHitDuration: Float = 6
    private static let shipHitFlashInterval: Float = 0.2
    private static let autoFireInterval: Float = 0.1
    private static let statusInterval: Float = 0.1
    private static let startupDelay: Float = 7
    private static let songCheckInterval: Float = 1
    private static let spectrumScanRange = 16_000
    private static let fftInterval: Float = 0.02
    private static let chordReleaseMinTime: Float = 1
    private static let chordReleaseMaxTime: Float = 5
    // The original computed this with integer division (16000 / 26 = 615); keep it.
    private static let spectrumFrequencyDelta = Float(spectrumScanRange / spectrumSize)
    // Parks an elapsed game-over stage so it never fires again.
    private static let gameOverStageDone: Float = 1000

    private weak var events: GameEvents?
    private let title: String
    // FFT bin index per Hz for 1024-sample FFT data (BASS_DATA_FFT1024 layout).
    private let binsPerHertz: Float

    private(set) var state = State.starting
    private(set) var score = 0
    private(set) var shipCount = 3
    private var startupCountdown = GameLogic.startupDelay

    private(set) var isRingOn = false
    private var ringTimeLeft = GameLogic.ringDuration

    private(set) var isShipHit = false
    private(set) var isShipFlashOn = false
    private var shipHitTimeLeft = GameLogic.shipHitDuration
    private var shipHitFlashTimeLeft = GameLogic.shipHitFlashInterval

    private var autoFireTimeLeft: Float = 0
    private var autoFireCooldown = GameLogic.autoFireInterval
    private var isAutoFirePending = false

    private var bonusCountdown = GameLogic.bonusInterval
    // Location per slot; location 0 doubles as "empty", as in the original.
    private var bonusLocations = [Int](repeating: 0, count: BonusSlot.allCases.count)
    private var pendingBonusSlot: BonusSlot?

    private(set) var spectrumValues = [Float](repeating: 0, count: GameLogic.spectrumSize)
    private(set) var isSpectrumReady = false
    private var chordReleaseCountdowns: [Float]
    private var chordReleasePending = [Bool](repeating: false, count: GameLogic.spectrumBinCount)
    private var fftCountdown = GameLogic.fftInterval

    private var statusCountdown = GameLogic.statusInterval
    private var lastPublishedShipCount = 0
    private var lastPublishedScore = 0
    private var lastDisplayedStatus = ""

    private var songCheckCountdown = GameLogic.songCheckInterval

    private var gameOverStringCountdown: Float = 0.5
    private var gameOverTitleCountdown: Float = 2
    private var gameOverTop3Countdown: Float = 4
    private var gameOverTop31Countdown: Float = 6
    private var gameOverTop32Countdown: Float = 8
    private var gameOverTop33Countdown: Float = 10
    private var gameOverCountdown: Float = 20
    private var isGameOverReported = false
    private var isExitPending = false

    init(events: GameEvents, title: String, sampleRate: Int) {
        self.events = events
        self.title = title
        binsPerHertz = 1024 / Float(sampleRate)
        chordReleaseCountdowns = (0..<Self.spectrumBinCount).map { _ in Self.randomReleaseTime() }
    }

    private static func randomReleaseTime() -> Float {
        .random(in: chordReleaseMinTime...chordReleaseMaxTime)
    }

    // MARK: - Per-frame

    // Advances startup countdown, ring/hit/auto-fire timers and the bonus spawner.
    func tick(deltaTime: Float) {
        if state == .starting {
            startupCountdown -= deltaTime
            if startupCountdown <= 0 {
                state = .running
                events?.removeCountDown()
            }
        }

        if isRingOn {
            ringTimeLeft -= deltaTime
            if ringTimeLeft <= 0 {
                isRingOn = false
                ringTimeLeft = Self.ringDuration
            }
        }

        if state == .running, isShipHit {
            updateShipHit(deltaTime)
        }

        updateAutoFire(deltaTime)

        updateBonus(deltaTime)
    }

    private func updateShipHit(_ deltaTime: Float) {
        shipHitTimeLeft -= deltaTime
        if shipHitTimeLeft <= 0 {
            isShipHit = false
            shipHitTimeLeft = Self.shipHitDuration
        } else {
            shipHitFlashTimeLeft -= deltaTime
            if shipHitFlashTimeLeft <= 0 {
                isShipFlashOn.toggle()
                shipHitFlashTimeLeft = Self.shipHitFlashInterval
            }
        }
    }

    private func updateAutoFire(_ deltaTime: Float) {
        autoFireTimeLeft -= deltaTime
        guard autoFireTimeLeft > 0 else { return }
        autoFireCooldown -= deltaTime
        if autoFireCooldown <= 0 {
            if state == .running {
                isAutoFirePending = true
            }
            autoFireCooldown = Self.autoFireInterval
        }
    }

    private func updateBonus(_ deltaTime: Float) {
        bonusCountdown -= deltaTime
        guard bonusCountdown <= 0 else { return }
        bonusCountdown = Self.bonusInterval

        let location = Int.random(in: 0..<BonusSlot.allCases.count)
        if !bonusLocations.contains(location) {
            insertBonus(at: location)
        }
    }

    private func insertBonus(at location: Int) {
        guard let slot = BonusSlot.allCases.randomElement(),
              bonusLocations[slot.rawValue] == 0 else { return }

        bonusLocations[slot.rawValue] = location

        if slot == .ship, shipCount >= Self.maxShipCount {
            bonusLocations[slot.rawValue] = 0
            return
        }

        pendingBonusSlot = slot
    }

    // Publishes score/ship/countdown updates to the UI at the original cadence.
    func publishStatus(deltaTime: Float) {
        if lastPublishedShipCount != shipCount {
            events?.onShipUpdate(shipCount)
            lastPublishedShipCount = shipCount
        }

        if lastPublishedScore != score {
            displayStatus("  \(score) ", isCountDown: false)
            lastPublishedScore = score
        }

        statusCountdown -= deltaTime
        if statusCountdown <= 0 {
            if state == .starting {
                let seconds = Int(startupCountdown)
                displayStatus(seconds == 0 ? " " : " \(seconds) ", isCountDown: true)
            }
            statusCountdown = Self.statusInterval
        }
    }

    private func displayStatus(_ value: String, isCountDown: Bool) {
        guard value != lastDisplayedStatus, !value.isEmpty else { return }
        events?.onStatusUpdate(value, isCountDown: isCountDown)
        lastDisplayedStatus = value
    }

    // Drives the staged game-over UI sequence; ends with an exit request after 20s.
    func tickGameOver(deltaTime: Float) {
        if !isGameOverReported {
            isGameOverReported = true
            events?.onShipUpdate(shipCount)
            events?.gameOverData(title: title, score: score)
        }

        gameOverCountdown -= deltaTime
        if gameOverCountdown <= 0 {
            gameOverCountdown = Self.gameOverStageDone
            isExitPending = true
            return
        }

        gameOverTop33Countdown -= deltaTime
        if gameOverTop33Countdown <= 0 {
            gameOverTop33Countdown = Self.gameOverStageDone
            events?.gameOverTop33Time()
            return
        }

        gameOverTop32Countdown -= deltaTime
        if gameOverTop32Countdown <= 0 {
            gameOverTop32Countdown = Self.gameOverStageDone
            events?.gameOverTop32Time()
            return
        }

        gameOverTop31Countdown -= deltaTime
        if gameOverTop31Countdown <= 0 {
            gameOverTop31Countdown = Self.gameOverStageDone
            events?.gameOverTop31Time()
            return
        }

        gameOverTop3Countdown -= deltaTime
        if gameOverTop3Countdown <= 0 {
            gameOverTop3Countdown = Self.gameOverStageDone
            events?.gameOverTop3Time()
            return
        }

        gameOverTitleCountdown -= deltaTime
        if gameOverTitleCountdown <= 0 {
            gameOverTitleCountdown = Self.gameOverStageDone
            events?.gameOverTitleTime()
            return
        }

        gameOverStringCountdown -= deltaTime
        if gameOverStringCountdown <= 0 {
            gameOverStringCountdown = Self.gameOverStageDone
            events?.gameOverStringTime()
        }
    }

    // MARK: - Spectrum

    func spectrumUpdateDue(deltaTime: Float) -> Bool {
        fftCountdown -= deltaTime
        guard fftCountdown <= 0 else { return false }
        fftCountdown = Self.fftInterval
        return true
    }

    // Smooths the raw FFT into spectrum bar values and decides which bins
    // release a chord. (onSpectrumData in the original.)
    func updateSpectrum(fft: [Float], deltaTime: Float) {
        for sp in Self.spectrumSkipCount..<Self.spectrumSize {
            let size = amplitude(from: Float(sp) * Self.spectrumFrequencyDelta,
                                 to: Float(sp + 1) * Self.spectrumFrequencyDelta,
                                 in: fft) * 130

            if size > spectrumValues[sp] {
                spectrumValues[sp] = size
            } else {
                spectrumValues[sp] *= 0.85
            }
            spectrumValues[sp] = min(max(spectrumValues[sp], 0), Self.spectrumMaxValue)

            let bin = sp - Self.spectrumSkipCount
            chordReleaseCountdowns[bin] -= deltaTime

            if spectrumValues[sp] == Self.spectrumMaxValue,
               chordReleaseCountdowns[bin] <= 0,
               state == .running {
                chordReleasePending[bin] = true
                chordReleaseCountdowns[bin] = Self.randomReleaseTime()
            }
        }

        isSpectrumReady = true
    }

    private func amplitude(from startFrequency: Float, to endFrequency: Float, in fft: [Float]) -> Float {
        // Nearest bins to the start/end frequencies; clamped so a short FFT
        // buffer can't index out of bounds (the original never bounds-checked).
        let first = Int(binsPerHertz * startFrequency + 0.5)
        let last = min(Int(binsPerHertz * endFrequency + 0.5), fft.count - 1)
        guard first <= last else { return 0 }

        var peak: Float = 0
        for bin in first...last where fft[bin] > peak {
            peak = fft[bin]
        }
        return peak
    }

    func consumeChordRelease(bin: Int) -> Bool {
        guard chordReleasePending[bin] else { return false }
        chordReleasePending[bin] = false
        return true
    }

    // Returns the chord group to try first (0..<groups), or -1 for no spawn:
    // ~25% of release events are skipped on purpose (original tuning).
    func rollChordGroup() -> Int {
        Int.random(in: 0..<4) - 1
    }

    // MARK: - Inputs from the platform layer

    func bulletHitChord() {
        score += Self.chordValue
    }

    func chordHitShip() {
        if !isShipHit {
            shipCount -= 1
        }
        isShipHit = true
        score += Self.chordValue

        if shipCount == 0 {
            state = .finished
        }
    }

    func bonusCollected(_ slot: BonusSlot) {
        switch slot {
        case .weapon:
            isRingOn = true
        case .ship:
            if shipCount < Self.maxShipCount {
                shipCount += 1
            }
        default:
            score += slot.score
        }

        bonusLocations[slot.rawValue] = 0
    }

    func autoFire(duration: Float) {
        autoFireTimeLeft = duration
    }

    func pause() {
        state = .paused
    }

    func songEnded() {
        state = .finished
    }

    func songCheckDue(deltaTime: Float) -> Bool {
        songCheckCountdown -= deltaTime
        guard songCheckCountdown <= 0 else { return false }
        songCheckCountdown = Self.songCheckInterval
        return true
    }

    // MARK: - Consumable outputs

    func consumeAutoFire() -> Bool {
        guard isAutoFirePending else { return false }
        isAutoFirePending = false
        return true
    }

    func consumePendingBonusSlot() -> BonusSlot? {
        defer { pendingBonusSlot = nil }
        return pendingBonusSlot
    }

    func bonusLocation(of slot: BonusSlot) -> Int {
        bonusLocations[slot.rawValue]
    }

    func consumeExitRequest() -> Bool {
        guard isExitPending else { return false }
        isExitPending = false
        return true
    }
}
