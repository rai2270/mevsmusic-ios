import SceneKit

// CPU-driven billboard sprites porting the Rajawali GL_POINTS particle systems
// (mvm/particle/*ParticleSystem.java). Each particle is a camera-facing textured
// plane; the game loop drives positions and sprite-sheet frames every frame.
// Plane sizes approximate the original point sprites (2400/800 px with ~1/distance
// attenuation on a ~1080 px, 45° FOV viewport ≈ 1.8/0.6 world units).
class SpriteParticles {

    let containerNode = SCNNode()
    let nodes: [SCNNode]
    private(set) var isAlive: [Bool]
    var positions: [simd_float3]

    private let tileRows: Int

    init(count: Int, imageNamed imageName: String, size: CGFloat, tileRows: Int = 1,
         blendMode: SCNBlendMode = .alpha, emissionIntensity: CGFloat = 0) {
        self.tileRows = tileRows
        isAlive = [Bool](repeating: false, count: count)
        positions = [simd_float3](repeating: GameRenderer.inactivePosition, count: count)
        nodes = (0..<count).map { _ in
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = UIImage(named: imageName)
            material.diffuse.mipFilter = .linear    // trilinear: no shimmer at distance
            material.isDoubleSided = true
            material.writesToDepthBuffer = false
            material.blendMode = blendMode
            if emissionIntensity > 0 {
                // Same image as emission so the sprite feeds the HDR bloom pass.
                material.emission.contents = material.diffuse.contents
                material.emission.intensity = emissionIntensity
            }
            if tileRows > 1 {
                let scale = 1 / Float(tileRows)
                material.diffuse.contentsTransform = SCNMatrix4MakeScale(scale, scale, 1)
                material.emission.contentsTransform = material.diffuse.contentsTransform
            }
            let plane = SCNPlane(width: size, height: size)
            plane.materials = [material]
            let node = SCNNode(geometry: plane)
            node.constraints = [SCNBillboardConstraint()]
            node.simdPosition = GameRenderer.inactivePosition
            node.castsShadow = false
            return node
        }
        containerNode.castsShadow = false
        nodes.forEach(containerNode.addChildNode)
    }

    // Selects one tile of the row-major sprite sheet, like the ANIMATED shader path
    // in GameParticleMaterial.
    func setTile(_ index: Int, frame: Int) {
        guard tileRows > 1, let material = nodes[index].geometry?.firstMaterial else { return }
        let scale = 1 / Float(tileRows)
        let translation = SCNMatrix4MakeTranslation(Float(frame % tileRows) * scale,
                                                    Float(frame / tileRows) * scale, 0)
        material.diffuse.contentsTransform = SCNMatrix4Mult(SCNMatrix4MakeScale(scale, scale, 1), translation)
        material.emission.contentsTransform = material.diffuse.contentsTransform
    }

    func deactivate(_ index: Int) {
        isAlive[index] = false
        positions[index] = GameRenderer.inactivePosition
        nodes[index].simdPosition = GameRenderer.inactivePosition
    }

    func nextAvailable() -> Int? {
        guard let index = isAlive.firstIndex(of: false) else { return nil }
        isAlive[index] = true
        return index
    }

    func applyPositions() {
        for i in nodes.indices where isAlive[i] {
            nodes[i].simdPosition = positions[i]
        }
    }
}

// BulletParticleSystem.java port: straight-flying shots that die at the room walls.
final class BulletParticles: SpriteParticles {

    private static let speed: Float = 100          // BULLET_SPEED
    private static let fastSpeed: Float = 250      // BULLET_SPEED_VERY_FAST (ring weapon)

    private var velocities: [simd_float3]
    private var speeds: [Float]

    init(count: Int) {
        velocities = [simd_float3](repeating: .zero, count: count)
        speeds = [Float](repeating: Self.speed, count: count)
        super.init(count: count, imageNamed: "flare.png", size: 0.6,
                   blendMode: .add, emissionIntensity: 1.8)
    }

    func fire(direction: simd_float3, from position: simd_float3, veryFast: Bool) {
        guard let index = nextAvailable() else { return }
        positions[index] = position
        velocities[index] = direction
        if veryFast {
            speeds[index] = Self.fastSpeed
        }
    }

    func update(deltaTime: Float) {
        for i in nodes.indices where isAlive[i] {
            positions[i] += velocities[i] * (deltaTime * speeds[i])
            let p = positions[i]
            if abs(p.x) >= GameRenderer.roomHalf ||
               abs(p.y) >= GameRenderer.roomHalf ||
               abs(p.z) >= GameRenderer.roomHalf {
                deactivate(i)
            }
        }
        applyPositions()
    }

    override func deactivate(_ index: Int) {
        speeds[index] = Self.speed
        super.deactivate(index)
    }
}

// ChordParticleSystem.java port: the chord enemies. Sprite-sheet animation runs
// born (8 frames) -> alive (40, looping) -> explode (16) at 0.05 s per frame;
// alive chords fly toward their spawn target and bounce off the world walls.
final class ChordParticles: SpriteParticles {

    enum State {
        case inactive, born, alive, explode
    }

    private static let bornFrameCount = 8
    private static let aliveFrameCount = 40
    private static let explodeFrameCount = 16
    private static let frameInterval: Float = 2.0 / Float(aliveFrameCount)  // ONE_ROTATE_TAKES / frames
    private static let speedRange: ClosedRange<Float> = 5.0...11.0
    // Chords roam the lower band of the room.
    private static let xzLimit = GameRenderer.worldLimit
    private static let yMax: Float = -50 - GameRenderer.roomEdge

    private(set) var states: [State]
    // Presentation hook: the renderer spawns a spark burst here on every explosion.
    var onExplode: ((simd_float3, UIColor) -> Void)?
    private let burstColor: UIColor
    private var velocities: [simd_float3]
    private var speeds: [Float]
    private var frames: [Int]
    private var bornFrames: [Int]
    private var aliveFrames: [Int]
    private var explodeFrames: [Int]
    private var frameTimer = ChordParticles.frameInterval

    init(count: Int, imageNamed imageName: String, burstColor: UIColor) {
        self.burstColor = burstColor
        states = [State](repeating: .inactive, count: count)
        velocities = [simd_float3](repeating: .zero, count: count)
        speeds = (0..<count).map { _ in .random(in: Self.speedRange) }
        frames = [Int](repeating: 0, count: count)
        bornFrames = [Int](repeating: 0, count: count)
        aliveFrames = (0..<count).map { _ in Int.random(in: 0..<Self.aliveFrameCount) }
        explodeFrames = [Int](repeating: 0, count: count)
        super.init(count: count, imageNamed: imageName, size: 1.8, tileRows: 8,
                   emissionIntensity: 0.9)
    }

    func spawn(at position: simd_float3, toward shipPosition: simd_float3) -> Bool {
        guard let index = nextAvailable() else { return false }
        states[index] = .born
        positions[index] = position
        velocities[index] = simd_normalize(shipPosition - position)
        return true
    }

    // setInactivePosition in the original: starts the explosion animation; the
    // particle frees itself when it finishes.
    func explode(_ index: Int) {
        states[index] = .explode
        onExplode?(positions[index], burstColor)
    }

    func update(deltaTime: Float) {
        let frameTicked = advanceFrames(deltaTime)
        for i in nodes.indices where isAlive[i] {
            positions[i] += velocities[i] * (deltaTime * speeds[i])

            // Bounce off the walls.
            if positions[i].x > Self.xzLimit { positions[i].x = Self.xzLimit; velocities[i].x *= -1 }
            else if positions[i].x < -Self.xzLimit { positions[i].x = -Self.xzLimit; velocities[i].x *= -1 }
            if positions[i].y > Self.yMax { positions[i].y = Self.yMax; velocities[i].y *= -1 }
            else if positions[i].y < -Self.xzLimit { positions[i].y = -Self.xzLimit; velocities[i].y *= -1 }
            if positions[i].z > Self.xzLimit { positions[i].z = Self.xzLimit; velocities[i].z *= -1 }
            else if positions[i].z < -Self.xzLimit { positions[i].z = -Self.xzLimit; velocities[i].z *= -1 }

            if frameTicked {
                setTile(i, frame: frames[i])
            }
        }
        applyPositions()
    }

    // Ports the original's post-increment state machine exactly.
    private func advanceFrames(_ deltaTime: Float) -> Bool {
        frameTimer -= deltaTime
        guard frameTimer <= 0 else { return false }
        frameTimer = Self.frameInterval

        for i in nodes.indices where isAlive[i] {
            if states[i] == .born {
                let previous = bornFrames[i]
                bornFrames[i] += 1
                if previous >= Self.bornFrameCount {
                    states[i] = .alive
                    bornFrames[i] = 0
                } else {
                    frames[i] = max(bornFrames[i] - 1, 0)
                    continue
                }
            }
            if states[i] == .alive {
                let previous = aliveFrames[i]
                aliveFrames[i] += 1
                if previous >= Self.aliveFrameCount {
                    aliveFrames[i] = 0
                    frames[i] = Self.bornFrameCount
                } else {
                    frames[i] = Self.bornFrameCount + aliveFrames[i] - 1
                }
                continue
            }
            if states[i] == .explode {
                let previous = explodeFrames[i]
                explodeFrames[i] += 1
                if previous >= Self.explodeFrameCount {
                    deactivate(i)
                    states[i] = .inactive
                    bornFrames[i] = 0
                    aliveFrames[i] = Int.random(in: 0..<Self.aliveFrameCount)
                    explodeFrames[i] = 0
                    frames[i] = 0
                } else {
                    frames[i] = Self.bornFrameCount + Self.aliveFrameCount + explodeFrames[i] - 1
                }
            }
        }
        return true
    }
}

// BonusParticleSystem.java port: a stationary pickup looping its 8x8 sprite sheet
// every two seconds. The renderer holds one instance per bonus slot.
final class BonusParticles: SpriteParticles {

    private static let totalFrames = 64
    private static let frameInterval: Float = 2.0 / Float(totalFrames)

    private var frames: [Int]
    private var frameTimer = BonusParticles.frameInterval

    init(imageNamed imageName: String) {
        frames = [Int.random(in: 0..<Self.totalFrames)]
        super.init(count: 1, imageNamed: imageName, size: 1.8, tileRows: 8,
                   emissionIntensity: 0.9)
    }

    func spawn(at position: simd_float3) {
        guard let index = nextAvailable() else { return }
        positions[index] = position
    }

    func update(deltaTime: Float) {
        frameTimer -= deltaTime
        if frameTimer <= 0 {
            frameTimer = Self.frameInterval
            for i in nodes.indices {
                let previous = frames[i]
                frames[i] += 1
                if previous >= Self.totalFrames {
                    frames[i] = 0
                }
                setTile(i, frame: frames[i])
            }
        }
        applyPositions()
    }
}
