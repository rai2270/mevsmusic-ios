import SceneKit
import SceneKit.ModelIO

// FlyingRenderer.java port: owns the SceneKit scene and the frame loop. All game
// rules live in GameLogic; this class feeds it inputs (time, FFT data, collisions)
// and applies its outputs to the scene. The world uses the Android renderer's
// collision space — its display space was x-mirrored from this one, and collision
// space is the self-consistent frame where chords chase the ship, bullets fly
// along its heading and the camera trails behind it.
final class GameRenderer: NSObject, SCNSceneRendererDelegate {

    static let roomSize: Float = 200
    static let roomHalf = roomSize / 2
    static let roomEdge: Float = 1
    static let worldLimit = roomHalf - roomEdge              // GAME_WORLD_X/Y/Z_SPACE
    static let inactivePosition = simd_float3(repeating: roomSize * 1.5)
    static let spectrumTop = SpectrumBar.size * SpectrumBar.yFactor * GameLogic.spectrumMaxValue

    private static let chordsPerGroup = 40
    private static let groupCount = 3
    private static let bulletCount = chordsPerGroup * groupCount
    private static let collisionDistance: Float = 2.0

    let scene = SCNScene()
    let cameraNode = SCNNode()

    private let logic: GameLogic
    private let audio: AudioEngine
    private weak var events: GameEvents?

    private let ship: Ship
    private let bars: [SpectrumBar]
    private let bullets = BulletParticles(count: GameRenderer.bulletCount)
    private let chordGroups: [ChordParticles]
    private let bonuses: [BonusParticles]
    private let bonusPositions: [simd_float3]

    private var cameraYaw: Float = 0
    private var lastTime: TimeInterval?
    private var shipFlashApplied = false
    private var gameOverSceneCleaned = false
    private var shakeTime: Float = 0
    private var shakeClock: Float = 0
    private var wasShipHit = false

    // Input written from the main thread, consumed on the render thread.
    private let inputLock = NSLock()
    private var pendingFireCount = 0
    private var joystickVelocity = simd_float2()
    private var useJoystickVelocity = false
    private let useAccelerometer: Bool
    private var accelerometerStart: simd_float3?
    private var accelerometerVelocity: simd_float2?

    init(logic: GameLogic, audio: AudioEngine, events: GameEvents, useAccelerometer: Bool = false) {
        self.logic = logic
        self.audio = audio
        self.events = events
        self.useAccelerometer = useAccelerometer

        ship = Ship()

        bars = (0..<GameLogic.spectrumBinCount).map { SpectrumBar(index: $0) }

        chordGroups = [("chord_cyan.png", UIColor(red: 0.2, green: 0.85, blue: 1, alpha: 1)),
                       ("chord_magenta.png", UIColor(red: 1, green: 0.25, blue: 0.85, alpha: 1)),
                       ("chord_amber.png", UIColor(red: 1, green: 0.7, blue: 0.2, alpha: 1))].map {
            ChordParticles(count: Self.chordsPerGroup, imageNamed: $0.0, burstColor: $0.1)
        }
        // Indexed by GameLogic.BonusSlot.rawValue (the original's bonusTextures order).
        bonuses = ["bonus_rings.png", "bonus_1k.png", "bonus_5k.png", "bonus_40k.png", "bonus_ship.png", "bonus_25k.png"]
            .map { BonusParticles(imageNamed: $0) }

        // Pickup spots above selected bars; slot 5 mixes bin 7's x with bin 5's y/z,
        // exactly as in the original.
        let base = bars.map(\.basePosition)
        let zOffset = Self.spectrumTop / 5
        let edge = Self.roomEdge
        bonusPositions = [
            simd_float3(base[0].x, base[0].y + edge, base[0].z - zOffset),
            simd_float3(base[12].x, base[12].y + edge, base[12].z + zOffset),
            simd_float3(base[5].x, base[5].y + edge, base[5].z - zOffset),
            simd_float3(base[10].x, base[10].y + edge, base[10].z - zOffset),
            simd_float3(base[2].x, base[2].y + edge, base[2].z + zOffset),
            simd_float3(base[7].x, base[5].y + edge, base[5].z + zOffset),
        ]

        super.init()

        let root = scene.rootNode
        installArena(in: root)
        bars.forEach { root.addChildNode($0.node) }
        root.addChildNode(ship.node)
        ship.rings.forEach(root.addChildNode)
        root.addChildNode(bullets.containerNode)
        chordGroups.forEach { root.addChildNode($0.containerNode) }
        bonuses.forEach { root.addChildNode($0.containerNode) }

        // The two directional lights objship adds; only the ship and rings are lit
        // (room, bars and sprites are unlit).
        for direction in [simd_float3(0.1, 1, 0.1), simd_float3(-0.1, -0.1, -0.1)] {
            let light = SCNLight()
            light.type = .directional
            light.intensity = 2000
            let lightNode = SCNNode()
            lightNode.light = light
            lightNode.simdOrientation = simd_quatf(from: simd_float3(0, 0, -1),
                                                   to: simd_normalize(direction))
            root.addChildNode(lightNode)
        }

        // ChaseCamera(offset (0, 0.6, 3), slerp 0.05) port.
        let camera = SCNCamera()
        camera.fieldOfView = 45
        camera.zFar = 2000
        configureModernCamera(camera)
        cameraNode.camera = camera
        root.addChildNode(cameraNode)

        installLightingEnvironment()
        installSunlight(in: root)
        installFloorEffects(in: root)
        installEngineExhaust()
        chordGroups.forEach { group in
            group.onExplode = { [weak self] position, color in
                self?.spawnBurst(at: position, color: color)
            }
        }

        // Atmospheric depth: the arena edges recede into the night.
        scene.fogColor = UIColor(red: 0.02, green: 0.02, blue: 0.07, alpha: 1)
        scene.fogStartDistance = 45
        scene.fogEndDistance = 340
        scene.fogDensityExponent = 1.5

        updateChaseCamera(deltaTime: 0)
    }

    // MARK: - Modern rendering (feature/high_quality)
    // Everything below is presentation only: positions, timings and collisions
    // are untouched, so gameplay stays identical to the faithful port.

    private func configureModernCamera(_ camera: SCNCamera) {
        camera.wantsHDR = true
        camera.wantsExposureAdaptation = false   // stable music lighting, no pumping
        camera.bloomThreshold = 1.0              // only emissive surfaces bloom
        camera.bloomIntensity = 0.85
        camera.bloomBlurRadius = 12
        camera.motionBlurIntensity = 0.35
        camera.vignettingPower = 0.7
        camera.vignettingIntensity = 0.5
        camera.grainIntensity = 0.05             // subtle cinematic grain
        camera.grainIsColored = false
        camera.saturation = 1.1
        camera.contrast = 1.05
    }

    // The night arena: neon grid floor, city-skyline walls, starfield above.
    // Same 200x50x200 play volume as the original room, restyled.
    private func installArena(in root: SCNNode) {
        func panel(_ plane: SCNPlane, image: String, emission: CGFloat) -> SCNNode {
            let material = GameAssets.unlitMaterial(imageNamed: image, emission: emission)
            plane.materials = [material]
            let node = SCNNode(geometry: plane)
            node.castsShadow = false
            return node
        }

        let floor = panel(SCNPlane(width: CGFloat(Self.roomSize), height: CGFloat(Self.roomSize)),
                          image: "floor_grid.png", emission: 0.8)
        if let material = floor.geometry?.firstMaterial {
            material.diffuse.wrapS = .repeat
            material.diffuse.wrapT = .repeat
            material.diffuse.contentsTransform = SCNMatrix4MakeScale(4, 4, 1)
            material.emission.wrapS = .repeat
            material.emission.wrapT = .repeat
            material.emission.contentsTransform = material.diffuse.contentsTransform
        }
        floor.eulerAngles.x = -.pi / 2
        floor.simdPosition = simd_float3(0, -Self.roomHalf, 0)
        root.addChildNode(floor)

        let ceiling = panel(SCNPlane(width: CGFloat(Self.roomSize), height: CGFloat(Self.roomSize)),
                            image: "ceiling_stars.png", emission: 0.45)
        ceiling.eulerAngles.x = .pi / 2
        ceiling.simdPosition = simd_float3(0, -50, 0)
        root.addChildNode(ceiling)

        // Four skyline walls closing the 50-unit-tall play band, facing inward.
        let wallHeight: CGFloat = 50
        let placements: [(simd_float3, Float)] = [
            (simd_float3(0, -75, -Self.roomHalf), 0),
            (simd_float3(0, -75, Self.roomHalf), .pi),
            (simd_float3(-Self.roomHalf, -75, 0), .pi / 2),
            (simd_float3(Self.roomHalf, -75, 0), -.pi / 2),
        ]
        for (position, yaw) in placements {
            let wall = panel(SCNPlane(width: CGFloat(Self.roomSize), height: wallHeight),
                             image: "wall_skyline.png", emission: 0.4)
            if let material = wall.geometry?.firstMaterial {
                // Tile the skyline so buildings stay believable up close.
                material.diffuse.wrapS = .repeat
                material.diffuse.contentsTransform = SCNMatrix4MakeScale(3, 1, 1)
                material.emission.wrapS = .repeat
                material.emission.contentsTransform = material.diffuse.contentsTransform
            }
            wall.simdPosition = position
            wall.eulerAngles.y = yaw
            root.addChildNode(wall)
        }
    }

    // Procedural sky cube as image-based lighting for the PBR ship and rings.
    private func installLightingEnvironment() {
        let sky = MDLSkyCubeTexture(name: nil,
                                    channelEncoding: .uInt8,
                                    textureDimensions: vector_int2(128, 128),
                                    turbidity: 0.28,
                                    sunElevation: 0.65,
                                    upperAtmosphereScattering: 0.2,
                                    groundAlbedo: 0.6)
        scene.lightingEnvironment.contents = sky.imageFromTexture()?.takeUnretainedValue()
        scene.lightingEnvironment.intensity = 1.2
    }

    // Key light with soft shadows; the ship and the dancing bars cast onto the floor.
    private func installSunlight(in root: SCNNode) {
        let sun = SCNLight()
        sun.type = .directional
        sun.intensity = 700
        sun.castsShadow = true
        sun.shadowMapSize = CGSize(width: 2048, height: 2048)
        sun.shadowSampleCount = 16
        sun.shadowRadius = 8
        sun.shadowColor = UIColor(white: 0, alpha: 0.55)
        let node = SCNNode()
        node.light = sun
        node.eulerAngles = SCNVector3(-Float.pi / 3, Float.pi / 7, 0)
        root.addChildNode(node)
    }

    // A shadow catcher and subtle real-time reflections over the room's floor art.
    private func installFloorEffects(in root: SCNNode) {
        let catcherPlane = SCNPlane(width: CGFloat(Self.roomSize), height: CGFloat(Self.roomSize))
        let catcherMaterial = SCNMaterial()
        catcherMaterial.lightingModel = .shadowOnly
        catcherPlane.materials = [catcherMaterial]
        let catcher = SCNNode(geometry: catcherPlane)
        catcher.eulerAngles.x = -.pi / 2
        catcher.simdPosition = simd_float3(0, -Self.roomSize / 2 + 0.05, 0)
        catcher.castsShadow = false
        root.addChildNode(catcher)

        let floor = SCNFloor()
        floor.reflectivity = 0.25
        floor.reflectionFalloffEnd = 50
        let floorMaterial = SCNMaterial()
        floorMaterial.lightingModel = .constant
        floorMaterial.diffuse.contents = UIColor(white: 0, alpha: 0.02)
        floorMaterial.writesToDepthBuffer = false
        floor.materials = [floorMaterial]
        let floorNode = SCNNode(geometry: floor)
        floorNode.simdPosition = simd_float3(0, -Self.roomSize / 2 + 0.02, 0)
        floorNode.castsShadow = false
        root.addChildNode(floorNode)
    }

    // Additive engine trails behind each engine (world-space, so they streak).
    private func installEngineExhaust() {
        for side: Float in [-1, 1] {
            let exhaust = SCNParticleSystem()
            exhaust.emitterShape = SCNSphere(radius: 0.03)
            exhaust.birthRate = 60
            exhaust.particleLifeSpan = 0.22
            exhaust.particleLifeSpanVariation = 0.06
            exhaust.particleVelocity = 10
            exhaust.particleVelocityVariation = 2.5
            exhaust.emittingDirection = SCNVector3(0, 0, 1)   // ship-local backward
            exhaust.spreadingAngle = 5
            exhaust.particleSize = 0.20
            exhaust.particleSizeVariation = 0.08
            exhaust.particleImage = UIImage(named: "flare.png")
            exhaust.particleColor = UIColor(red: 0.35, green: 0.7, blue: 1, alpha: 0.55)
            exhaust.blendMode = .additive
            exhaust.isLightingEnabled = false
            let mount = SCNNode()
            mount.position = SCNVector3(side * 0.17, 0, 0.5)
            mount.addParticleSystem(exhaust)
            ship.node.addChildNode(mount)
        }
    }

    // One-shot additive spark burst (chord explosions, pickups, the ship's demise).
    private func spawnBurst(at position: simd_float3, color: UIColor,
                            count: CGFloat = 130, speed: CGFloat = 9, size: CGFloat = 0.3) {
        let burst = SCNParticleSystem()
        burst.loops = false
        burst.emissionDuration = 0.05
        burst.birthRate = count / 0.05
        burst.particleLifeSpan = 0.5
        burst.particleLifeSpanVariation = 0.2
        burst.particleVelocity = speed
        burst.particleVelocityVariation = speed * 0.6
        burst.emitterShape = SCNSphere(radius: 0.1)
        burst.birthDirection = .random
        burst.particleSize = size
        burst.particleSizeVariation = size * 0.5
        burst.particleImage = UIImage(named: "flare.png")
        burst.particleColor = color
        burst.blendMode = .additive
        burst.isLightingEnabled = false
        let node = SCNNode()
        node.simdPosition = position
        node.addParticleSystem(burst)
        scene.rootNode.addChildNode(node)
        node.runAction(.sequence([.wait(duration: 1.2), .removeFromParentNode()]))
    }

    // Resets frame timing (after the app returns to the foreground).
    func resetClock() {
        lastTime = nil
    }

    // MARK: - Input (main thread)

    func setJoystick(_ velocity: simd_float2) {
        inputLock.withLock {
            joystickVelocity = velocity
            useJoystickVelocity = true
        }
    }

    func releaseJoystick() {
        inputLock.withLock { useJoystickVelocity = false }
    }

    // setTouch() in the original: queue one shot for the next frame.
    func fireOnce() {
        inputLock.withLock { pendingFireCount += 1 }
    }

    // setTouch(float) in the original: tap-to-autofire.
    func autoFire(duration: Float) {
        logic.autoFire(duration: duration)
    }

    // setAccelerometerValues port: the first reading is the neutral posture,
    // later readings steer relative to it (vVel = ((x*2, y) - start) * 0.02).
    func setAccelerometerValues(x: Float, y: Float, z: Float) {
        guard logic.state == .running else { return }
        if accelerometerStart == nil {
            accelerometerStart = simd_float3(x, y, z)
        }
        guard useAccelerometer, let start = accelerometerStart else { return }
        inputLock.withLock {
            guard !useJoystickVelocity else { return }
            accelerometerVelocity = simd_float2((x * 2 - start.x) * 0.02, (y - start.y) * 0.02)
        }
    }

    // MARK: - Frame loop (render thread)

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        let deltaTime = Float(lastTime.map { time - $0 } ?? 0)
        lastTime = time

        if logic.state == .paused {
            exitGame()
            return
        }
        if logic.state == .finished {
            handleGameOver(deltaTime)
            updateChaseCamera(deltaTime: deltaTime)
            return
        }

        logic.tick(deltaTime: deltaTime)
        updateDisplayList(deltaTime)
        checkShipHitBonus()
        checkBulletHitChords()
        checkChordHitShip()
        logic.publishStatus(deltaTime: deltaTime)

        if logic.songCheckDue(deltaTime: deltaTime), audio.hasFinishedPlaying {
            logic.songEnded()
        }
        updateChaseCamera(deltaTime: deltaTime)
    }

    private func updateDisplayList(_ deltaTime: Float) {
        let (joystick, usingJoystick, accelerometer, fires) = inputLock.withLock {
            defer { pendingFireCount = 0 }
            return (joystickVelocity, useJoystickVelocity, accelerometerVelocity, pendingFireCount)
        }

        if usingJoystick {
            ship.velocity.x = joystick.x * 2
            ship.velocity.y = joystick.y
        } else if useAccelerometer {
            if let accelerometer {
                ship.velocity = accelerometer
            }
        } else {
            ship.velocity *= 0.95
        }

        if logic.state == .running {
            ship.update(deltaTime: deltaTime, isRingOn: logic.isRingOn)
            applyShipFlash(logic.isShipHit && logic.isShipFlashOn)
            if logic.isShipHit && !wasShipHit {
                shakeTime = 0.45   // camera impact kick, presentation only
            }
            wasShipHit = logic.isShipHit
        }

        for _ in 0..<fires { fire() }
        if logic.consumeAutoFire() { fire() }

        updateSpectrum(deltaTime)
        applySpectrumToBars()

        if let slot = logic.consumePendingBonusSlot() {
            bonuses[slot.rawValue].spawn(at: bonusPositions[logic.bonusLocation(of: slot)])
        }

        bullets.update(deltaTime: deltaTime)
        chordGroups.forEach { $0.update(deltaTime: deltaTime) }
        bonuses.forEach { $0.update(deltaTime: deltaTime) }
    }

    private func applyShipFlash(_ flash: Bool) {
        guard flash != shipFlashApplied else { return }
        shipFlashApplied = flash
        ship.setFlash(flash)
    }

    private func applySpectrumToBars() {
        guard logic.isSpectrumReady else { return }
        for sp in GameLogic.spectrumSkipCount..<GameLogic.spectrumSize {
            bars[sp - GameLogic.spectrumSkipCount].setValue(logic.spectrumValues[sp])
        }
    }

    private func updateSpectrum(_ deltaTime: Float) {
        guard logic.spectrumUpdateDue(deltaTime: deltaTime) else { return }
        logic.updateSpectrum(fft: audio.fftMagnitudes(), deltaTime: deltaTime)
        for bin in 0..<GameLogic.spectrumBinCount where logic.consumeChordRelease(bin: bin) {
            spawnChord(bin: bin)
        }
    }

    private func spawnChord(bin: Int) {
        let group = logic.rollChordGroup()
        guard group >= 0 else { return }

        let spawn = bars[bin].basePosition + simd_float3(0, Self.spectrumTop, 0)
        // Try the rolled chord type first, then the others in rotation.
        for j in 0..<Self.groupCount {
            if chordGroups[(group + j) % Self.groupCount]
                .spawn(at: spawn, toward: ship.node.simdPosition) {
                return
            }
        }
    }

    // MARK: - Collisions

    private func withinManhattanDistance(_ a: simd_float3, _ b: simd_float3, _ distance: Float) -> Bool {
        let d = simd_abs(a - b)
        return d.x <= distance && d.y <= distance && d.z <= distance
    }

    private func checkShipHitBonus() {
        let shipPosition = ship.node.simdPosition
        for (slotIndex, bonus) in bonuses.enumerated() {
            guard let slot = GameLogic.BonusSlot(rawValue: slotIndex) else { continue }
            for i in bonus.nodes.indices where bonus.isAlive[i] {
                if withinManhattanDistance(bonus.positions[i], shipPosition, Self.collisionDistance) {
                    spawnBurst(at: bonus.positions[i],
                               color: UIColor(red: 1, green: 0.9, blue: 0.5, alpha: 1),
                               count: 80, speed: 6, size: 0.25)
                    logic.bonusCollected(slot)
                    bonus.deactivate(i)
                }
            }
        }
    }

    private func checkBulletHitChords() {
        for bi in bullets.nodes.indices where bullets.isAlive[bi] {
            let bulletPosition = bullets.positions[bi]
            var bulletHit = false

            chordSearch: for i in 0..<Self.chordsPerGroup {
                for chords in chordGroups where chords.states[i] == .alive && chords.isAlive[i] {
                    if withinManhattanDistance(bulletPosition, chords.positions[i], Self.collisionDistance) {
                        chords.explode(i)
                        bulletHit = true
                        logic.bulletHitChord()
                        break chordSearch
                    }
                }
            }

            if bulletHit {
                bullets.deactivate(bi)
            }
        }
    }

    private func checkChordHitShip() {
        let shipPosition = ship.node.simdPosition
        for i in 0..<Self.chordsPerGroup {
            for chords in chordGroups where chords.states[i] == .alive && chords.isAlive[i] {
                if withinManhattanDistance(shipPosition, chords.positions[i], Self.collisionDistance) {
                    chords.explode(i)
                    logic.chordHitShip()
                }
            }
        }
    }

    // MARK: - Firing

    private func fire() {
        guard logic.state == .running else { return }

        if logic.isRingOn {
            // Ring weapon: a fast shot at every chord ahead of the ship's z motion.
            let shipPosition = ship.node.simdPosition
            for i in 0..<Self.chordsPerGroup {
                for chords in chordGroups where chords.states[i] == .alive && chords.isAlive[i] {
                    let dz = chords.positions[i].z - shipPosition.z
                    let firesStraight = (ship.zDirection < 0 && dz < 0) || (ship.zDirection > 0 && dz > 0)
                    if firesStraight {
                        let direction = simd_normalize(chords.positions[i] - shipPosition)
                        bullets.fire(direction: direction, from: shipPosition, veryFast: true)
                    }
                }
            }
        } else {
            // Single shot along the ship's horizontal heading.
            var direction = ship.direction
            direction.y = 0
            bullets.fire(direction: simd_normalize(direction),
                         from: ship.node.simdPosition,
                         veryFast: false)
        }
    }

    // MARK: - Chase camera

    private func updateChaseCamera(deltaTime: Float) {
        let yaw = ship.node.eulerAngles.y
        var offset = simd_float3(3 * sin(yaw), 0.6, 3 * cos(yaw))   // (0, 0.6, 3) rotated by yaw
        // Decaying impact shake when the ship is hit.
        shakeClock += deltaTime
        if shakeTime > 0 {
            shakeTime = max(0, shakeTime - deltaTime)
            let amplitude = shakeTime * shakeTime * 0.9
            offset += simd_float3(sin(shakeClock * 47) * amplitude,
                                  sin(shakeClock * 61) * amplitude, 0)
        }
        cameraNode.simdPosition = ship.node.simdPosition + offset
        cameraYaw += 0.05 * (yaw - cameraYaw)
        cameraNode.eulerAngles = SCNVector3(0, cameraYaw, 0)
    }

    // MARK: - Game over

    private func handleGameOver(_ deltaTime: Float) {
        if !gameOverSceneCleaned {
            gameOverSceneCleaned = true
            spawnBurst(at: ship.node.simdPosition,
                       color: UIColor(red: 0.5, green: 0.85, blue: 1, alpha: 1),
                       count: 320, speed: 14, size: 0.4)
            ship.node.removeFromParentNode()
            ship.rings.forEach { $0.removeFromParentNode() }
            bullets.containerNode.removeFromParentNode()
            bonuses.forEach { $0.containerNode.removeFromParentNode() }
        }

        // The spectrum keeps dancing behind the game-over screen.
        updateSpectrum(deltaTime)
        applySpectrumToBars()
        chordGroups.forEach { $0.update(deltaTime: deltaTime) }

        logic.tickGameOver(deltaTime: deltaTime)

        if logic.consumeExitRequest() {
            exitGame()
        }
    }

    private func exitGame() {
        audio.stop()
        events?.gameOverTime()
    }
}
