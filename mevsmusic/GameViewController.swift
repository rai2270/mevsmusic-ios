import UIKit
import SceneKit

// FlyingActivity.java port: the UIKit shell around the SceneKit game — HUD,
// joystick + fire input, the staged game-over overlay, lifecycle and audio.
class GameViewController: UIViewController {

    private static let joystickSize: CGFloat = 180          // JOYSTICK_SIZE
    private static let demoTrack = "Sunset"                 // DEMO_TRACK1
    private static let hudAlpha: CGFloat = 0x90 / 255.0
    private static let hudBlue = UIColor(red: 0, green: 0xbf / 255.0, blue: 1, alpha: hudAlpha)
    private static let hudCyan = UIColor(red: 0, green: 1, blue: 1, alpha: hudAlpha)
    private static let gameOverCyan = UIColor(red: 0, green: 1, blue: 1, alpha: 1)
    private static let gameOverGreen = UIColor(red: 0x37 / 255.0, green: 1, blue: 0x37 / 255.0, alpha: 1)

    private var audio: AudioEngine?
    private var logic: GameLogic?
    private var gameRenderer: GameRenderer?

    private let scoreLabel = UILabel()
    private let countdownLabel = UILabel()
    private let shipsRow = UIStackView()
    private var shipIcons: [UIImageView] = []
    private let joystickView = UIImageView(image: UIImage(named: "dpad3.png"))
    private let loadingView = UIImageView(image: UIImage(named: "loading.png"))
    private let gameOverStack = UIStackView()
    private var joystickTouch: UITouch?

    private var savedTitle = ""
    private var savedScore = 0

    private var scnView: SCNView? { view as? SCNView }

    // Text sizes follow the Android screen-width fractions.
    private var screenWidth: CGFloat { max(view.bounds.width, view.bounds.height) }

    override func viewDidLoad() {
        super.viewDidLoad()
        HighScore.load()
        buildHUD()

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(appDidEnterBackground),
                           name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.addObserver(self, selector: #selector(appWillEnterForeground),
                           name: UIApplication.willEnterForegroundNotification, object: nil)

        startGame()
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    // MARK: - Game lifecycle

    private func startGame() {
        guard let scnView else { return }
        showLoader()
        do {
            let audio = try AudioEngine(fileNamed: Self.demoTrack)
            let logic = GameLogic(events: self,
                                  title: "\(Self.demoTrack).mp3",
                                  sampleRate: audio.sampleRate)
            let renderer = try GameRenderer(logic: logic, audio: audio, events: self)
            self.audio = audio
            self.logic = logic
            self.gameRenderer = renderer

            scnView.scene = renderer.scene
            scnView.pointOfView = renderer.cameraNode
            scnView.delegate = renderer
            scnView.backgroundColor = .black
            scnView.preferredFramesPerSecond = 60   // setFrameRate(60)
            scnView.isPlaying = true

            try audio.play()
            hideLoader()
        } catch {
            loadingView.isHidden = true
            countdownLabel.isHidden = false
            countdownLabel.text = " "
            scoreLabel.isHidden = false
            scoreLabel.text = "Failed to start: \(error)"
        }
    }

    // The original finished the activity back to the song menu; with no menu
    // ported yet, a fresh game on the same track starts instead.
    private func restartGame() {
        scnView?.isPlaying = false
        scnView?.delegate = nil
        audio?.stop()
        audio = nil
        logic = nil
        gameRenderer = nil

        gameOverStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        gameOverStack.isHidden = true
        shipsRow.isHidden = true
        scoreLabel.isHidden = true
        scoreLabel.text = nil
        countdownLabel.text = nil

        startGame()
    }

    @objc private func appDidEnterBackground() {
        audio?.pause()
        scnView?.isPlaying = false
    }

    @objc private func appWillEnterForeground() {
        gameRenderer?.resetClock()
        scnView?.isPlaying = true
        audio?.resume()
    }

    // MARK: - HUD

    private func buildHUD() {
        guard let view = scnView else { return }

        countdownLabel.font = boldItalicFont(size: 0.2 * screenWidth)
        countdownLabel.textColor = Self.hudCyan
        countdownLabel.textAlignment = .center

        scoreLabel.font = boldItalicFont(size: 0.05 * screenWidth)
        scoreLabel.textColor = Self.hudBlue
        scoreLabel.textAlignment = .center

        shipIcons = (1...GameLogic.maxShipCount).map {
            UIImageView(image: UIImage(named: "ship_lives\($0).png"))
        }
        shipsRow.axis = .horizontal
        shipIcons.forEach(shipsRow.addArrangedSubview)

        gameOverStack.axis = .vertical
        gameOverStack.alignment = .center
        gameOverStack.spacing = 4

        for subview in [loadingView, joystickView, countdownLabel, scoreLabel, shipsRow, gameOverStack] {
            subview.isHidden = true
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }

        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            loadingView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingView.topAnchor.constraint(equalTo: safe.topAnchor, constant: 20),

            countdownLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            countdownLabel.topAnchor.constraint(equalTo: safe.topAnchor),

            scoreLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            scoreLabel.bottomAnchor.constraint(equalTo: safe.bottomAnchor),

            shipsRow.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -10),
            shipsRow.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -10),

            joystickView.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 20),
            joystickView.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -10),
            joystickView.widthAnchor.constraint(equalToConstant: Self.joystickSize),
            joystickView.heightAnchor.constraint(equalToConstant: Self.joystickSize),

            gameOverStack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            gameOverStack.topAnchor.constraint(equalTo: safe.topAnchor, constant: 10),
        ])
    }

    private func boldItalicFont(size: CGFloat) -> UIFont {
        let bold = UIFont.systemFont(ofSize: size, weight: .bold)
        guard let descriptor = bold.fontDescriptor.withSymbolicTraits([.traitBold, .traitItalic]) else {
            return bold
        }
        return UIFont(descriptor: descriptor, size: size)
    }

    private func makeGameOverLabel(_ text: String, size: CGFloat, color: UIColor) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = boldItalicFont(size: size)
        label.textColor = color
        return label
    }

    private func addTopScoreRow(rank: Int) {
        guard HighScore.scores[rank] != 0 else { return }
        let text = "\(rank + 1).  \(HighScore.viewTrack(at: rank))  \(HighScore.scores[rank])"
        gameOverStack.addArrangedSubview(
            makeGameOverLabel(text, size: 0.03 * screenWidth, color: Self.gameOverGreen))
    }

    // MARK: - Touch input (onTouch port)

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            if joystickView.frame.contains(touch.location(in: view)), joystickTouch == nil {
                joystickTouch = touch
                handleJoystick(touch)
            } else {
                gameRenderer?.autoFire(duration: 30)
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches where touch === joystickTouch {
            handleJoystick(touch)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        endJoystickTouch(in: touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        endJoystickTouch(in: touches)
    }

    private func endJoystickTouch(in touches: Set<UITouch>) {
        for touch in touches where touch === joystickTouch {
            joystickTouch = nil
            gameRenderer?.releaseJoystick()
        }
    }

    private func handleJoystick(_ touch: UITouch) {
        let location = touch.location(in: joystickView)
        let half = Float(Self.joystickSize / 2)
        gameRenderer?.fireOnce()
        gameRenderer?.setJoystick(simd_float2((Float(location.x) - half) / half,
                                              (Float(location.y) - half) / half))
    }
}

// MARK: - GameEvents (callbacks arrive on the render thread)

extension GameViewController: GameEvents {

    nonisolated func showLoader() {
        Task { @MainActor in self.loadingView.isHidden = false }
    }

    nonisolated func hideLoader() {
        Task { @MainActor in
            self.loadingView.isHidden = true
            self.joystickView.isHidden = false
            self.countdownLabel.isHidden = false
        }
    }

    nonisolated func removeCountDown() {
        Task { @MainActor in
            self.countdownLabel.isHidden = true
            self.shipsRow.isHidden = false
            self.scoreLabel.isHidden = false
        }
    }

    nonisolated func onShipUpdate(_ shipCount: Int) {
        Task { @MainActor in
            for (i, icon) in self.shipIcons.enumerated() {
                icon.isHidden = i >= shipCount
            }
        }
    }

    nonisolated func onStatusUpdate(_ status: String, isCountDown: Bool) {
        Task { @MainActor in
            if isCountDown {
                self.countdownLabel.text = status
            } else {
                self.scoreLabel.text = status
            }
        }
    }

    nonisolated func gameOverData(title: String, score: Int) {
        Task { @MainActor in
            self.savedTitle = title
            self.savedScore = score
            HighScore.submit(title: title, score: score)
        }
    }

    nonisolated func gameOverStringTime() {
        Task { @MainActor in
            self.joystickView.isHidden = true
            self.gameOverStack.isHidden = false
            self.gameOverStack.addArrangedSubview(
                self.makeGameOverLabel("GAME OVER", size: 0.07 * self.screenWidth, color: Self.gameOverCyan))
        }
    }

    nonisolated func gameOverTitleTime() {
        Task { @MainActor in
            let size = 0.03 * self.screenWidth
            self.gameOverStack.addArrangedSubview(
                self.makeGameOverLabel("  \(self.savedTitle)", size: size, color: Self.gameOverGreen))
            self.gameOverStack.addArrangedSubview(
                self.makeGameOverLabel("  Score: \(self.savedScore)", size: size, color: Self.gameOverGreen))
        }
    }

    nonisolated func gameOverTop3Time() {
        Task { @MainActor in
            guard HighScore.scores[0] != 0 else { return }
            self.gameOverStack.addArrangedSubview(
                self.makeGameOverLabel("Top 3", size: 0.03 * self.screenWidth, color: Self.gameOverGreen))
        }
    }

    nonisolated func gameOverTop31Time() {
        Task { @MainActor in self.addTopScoreRow(rank: 0) }
    }

    nonisolated func gameOverTop32Time() {
        Task { @MainActor in self.addTopScoreRow(rank: 1) }
    }

    nonisolated func gameOverTop33Time() {
        Task { @MainActor in self.addTopScoreRow(rank: 2) }
    }

    nonisolated func gameOverTime() {
        Task { @MainActor in self.restartGame() }
    }
}
