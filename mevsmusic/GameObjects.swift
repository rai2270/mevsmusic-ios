import SceneKit
import SceneKit.ModelIO

enum GameAssetError: Error {
    case missingAsset(String)
}

enum GameAssets {

    static func loadOBJ(named name: String) throws -> SCNNode {
        guard let url = Bundle.main.url(forResource: name, withExtension: "obj") else {
            throw GameAssetError.missingAsset("\(name).obj")
        }
        let scene = SCNScene(mdlAsset: MDLAsset(url: url))
        let container = SCNNode()
        for child in scene.rootNode.childNodes {
            container.addChildNode(child)
        }
        return container
    }

    // Rajawali's SimpleMaterial: unlit texture.
    static func unlitMaterial(imageNamed imageName: String) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIImage(named: imageName)
        return material
    }
}

// objship.java port: the player ship model, its three weapon rings, movement
// integration and world clamps. Coordinates are the Android renderer's collision
// space (its display space was x-mirrored from this), so the yaw sign flips and
// movement is simply the ship's local velocity rotated by its heading.
final class Ship {

    static let spawnPosition = simd_float3(0,
                                           -GameRenderer.roomSize / 2 + 7,
                                           GameRenderer.roomSize / 2 - 12)
    private static let maxSpeedZ: Float = -12              // MAX_SPEED_Z
    private static let xzLimit = GameRenderer.worldLimit - GameRenderer.roomEdge * 5
    private static let yMin = -GameRenderer.worldLimit     // GAME_WORLD_Y_SPACE
    private static let yMax: Float = -50 - GameRenderer.roomEdge
    private static let ringCount = 3

    let node: SCNNode
    let rings: [SCNNode]

    // DisplayObject.vVel: x steers yaw (degrees per frame), y is the climb input.
    var velocity = simd_float2()
    // Last frame's displacement (mDirection); bullets fire along it.
    private(set) var direction = simd_float3()
    private(set) var zDirection: Float = 0
    private var yawDegrees: Float = 0
    private var ringRotations = [Int](repeating: 0, count: Ship.ringCount)
    private let ringIntervals = [1, 2, 3]
    private let materials: [SCNMaterial]

    init() throws {
        node = try GameAssets.loadOBJ(named: "ship_obj")
        node.simdPosition = Self.spawnPosition

        rings = try (0..<Self.ringCount).map { _ in
            let ring = try GameAssets.loadOBJ(named: "ring005")
            ring.simdScale = simd_float3(repeating: 0.02)
            ring.simdPosition = GameRenderer.inactivePosition
            ring.enumerateHierarchy { child, _ in
                child.castsShadow = false
                for material in child.geometry?.materials ?? [] {
                    // Energy rings: emissive so they feed the HDR bloom pass.
                    material.lightingModel = .physicallyBased
                    material.metalness.contents = 0.9
                    material.roughness.contents = 0.25
                    material.emission.contents = UIColor(red: 0.5, green: 0.9, blue: 1, alpha: 1)
                    material.emission.intensity = 1.6
                }
            }
            return ring
        }

        var collected: [SCNMaterial] = []
        node.enumerateHierarchy { child, _ in
            collected.append(contentsOf: child.geometry?.materials ?? [])
        }
        materials = collected
        // The MTL's plain colors, upgraded to metal under image-based lighting.
        materials.forEach {
            $0.lightingModel = .physicallyBased
            $0.metalness.contents = 0.85
            $0.roughness.contents = 0.35
        }
    }

    // setPosition(fTimeLapsed, ringIsON, shieldIsON) port.
    func update(deltaTime: Float, isRingOn: Bool) {
        let previousZ = node.simdPosition.z

        yawDegrees -= velocity.x   // display-space rotY += vVel.x, mirrored here
        let yaw = yawDegrees * .pi / 180
        node.eulerAngles = SCNVector3(0, yaw, 0)

        if isRingOn {
            for i in rings.indices {
                ringRotations[i] += ringIntervals[i] * ringIntervals[0]
                var angles = rings[i].eulerAngles
                angles.x = Float(ringRotations[i] % 360) * .pi / 180
                ringRotations[i] += ringIntervals[i] * ringIntervals[0]
                angles.y = Float(ringRotations[i] % 360) * .pi / 180
                rings[i].eulerAngles = angles
            }
        } else {
            rings.forEach { $0.simdPosition = GameRenderer.inactivePosition }
        }

        // mDirection: forward speed plus climb, rotated into the heading.
        let local = simd_float3(0, -velocity.y * 15, Self.maxSpeedZ)
        let heading = simd_float3(local.x * cos(yaw) + local.z * sin(yaw),
                                  local.y,
                                  -local.x * sin(yaw) + local.z * cos(yaw))
        direction = heading * deltaTime
        node.simdPosition += direction

        var p = node.simdPosition
        p.x = min(max(p.x, -Self.xzLimit), Self.xzLimit)
        p.y = min(max(p.y, Self.yMin), Self.yMax)
        p.z = min(max(p.z, -Self.xzLimit), Self.xzLimit)
        node.simdPosition = p

        if isRingOn {
            rings.forEach { $0.simdPosition = p }
        }

        zDirection = node.simdPosition.z - previousZ
    }

    // Wireframe flash while the ship is hit (drawing mode GL_LINES on Android).
    func setFlash(_ flashing: Bool) {
        materials.forEach { $0.fillMode = flashing ? .lines : .fill }
    }
}

// objspectrum.java port: one music spectrum bar growing upward from the floor.
final class SpectrumBar {

    static let size: Float = 2.5          // SPECTRUM_BIN_SIZE
    static let yFactor: Float = 5         // SPECTRUM_BIN_SIZE_Y_FACTOR
    private static let spacing = size * 1.35

    let node: SCNNode
    let basePosition: simd_float3
    private let material: SCNMaterial

    init(index: Int, imageNamed imageName: String) {
        // Android display x mirrored into collision space.
        let x = Float(index) * Self.spacing - Float(GameLogic.spectrumBinCount) / 2 * Self.spacing
        basePosition = simd_float3(x, -GameRenderer.roomSize / 2 + 0.5, 0)

        // Per-bar material: the emission tracks this bar's level, so peaking
        // bars glow into the HDR bloom pass.
        material = GameAssets.unlitMaterial(imageNamed: imageName)
        material.emission.contents = material.diffuse.contents
        material.emission.intensity = 0

        let size = CGFloat(Self.size)
        let box = SCNBox(width: size, height: size, length: size, chamferRadius: 0)
        box.materials = [material]
        node = SCNNode(geometry: box)
        node.simdPosition = basePosition
        node.simdScale = simd_float3(1, 0.2, 1)
    }

    func setValue(_ value: Float) {
        let yScale = value * Self.yFactor
        node.simdScale = simd_float3(1, yScale, 1)
        node.simdPosition = simd_float3(basePosition.x,
                                        basePosition.y + Self.size * yScale / 2,
                                        basePosition.z)
        material.emission.intensity = CGFloat(value) * 0.75   // 0...1.5, blooms at the peak
    }
}
