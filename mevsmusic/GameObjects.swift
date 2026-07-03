import SceneKit

// All art is procedural since 1.2: textures come from tools/generate_assets.swift
// and the models below are composed from SceneKit geometry with PBR materials.
enum GameAssets {

    // Rajawali's SimpleMaterial: unlit texture.
    static func unlitMaterial(imageNamed imageName: String, emission: CGFloat = 0) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIImage(named: imageName)
        if emission > 0 {
            material.emission.contents = material.diffuse.contents
            material.emission.intensity = emission
        }
        return material
    }

    static func hullMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = UIColor(red: 0.55, green: 0.60, blue: 0.68, alpha: 1)
        material.metalness.contents = 0.9
        material.roughness.contents = 0.3
        return material
    }

    static func accentMaterial(color: UIColor, intensity: CGFloat) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = UIColor.black
        material.metalness.contents = 0.5
        material.roughness.contents = 0.4
        material.emission.contents = color
        material.emission.intensity = intensity
        return material
    }
}

// The player fighter, built in the Android ship's footprint (~1.0 long, ~1.0 span,
// nose toward -z) so the chase camera and 2.0-unit collision box feel identical.
private enum ShipFactory {

    static let accentCyan = UIColor(red: 0.3, green: 0.9, blue: 1, alpha: 1)

    static func make() -> SCNNode {
        let ship = SCNNode()
        let hull = GameAssets.hullMaterial()
        let dark = SCNMaterial()
        dark.lightingModel = .physicallyBased
        dark.diffuse.contents = UIColor(white: 0.13, alpha: 1)
        dark.metalness.contents = 0.8
        dark.roughness.contents = 0.45

        // Fuselage: a flattened capsule running nose to tail.
        let fuselage = SCNNode(geometry: SCNCapsule(capRadius: 0.10, height: 0.85))
        fuselage.geometry?.materials = [hull]
        fuselage.eulerAngles.x = .pi / 2
        fuselage.scale = SCNVector3(1, 1, 0.62)       // local z is world y after the rotation
        fuselage.position = SCNVector3(0, 0.02, 0.02)
        ship.addChildNode(fuselage)

        let nose = SCNNode(geometry: SCNCone(topRadius: 0.004, bottomRadius: 0.085, height: 0.34))
        nose.geometry?.materials = [hull]
        nose.eulerAngles.x = -.pi / 2
        nose.scale = SCNVector3(1, 1, 0.62)
        nose.position = SCNVector3(0, 0.02, -0.52)
        ship.addChildNode(nose)

        // Cockpit canopy: dark glass with a faint inner glow.
        let glass = SCNMaterial()
        glass.lightingModel = .physicallyBased
        glass.diffuse.contents = UIColor(red: 0.02, green: 0.06, blue: 0.10, alpha: 1)
        glass.metalness.contents = 0.4
        glass.roughness.contents = 0.08
        glass.emission.contents = accentCyan
        glass.emission.intensity = 0.15
        let canopy = SCNNode(geometry: SCNSphere(radius: 0.075))
        canopy.geometry?.materials = [glass]
        canopy.scale = SCNVector3(1, 0.6, 1.7)
        canopy.position = SCNVector3(0, 0.10, -0.16)
        ship.addChildNode(canopy)

        // One swept delta plate forms both wings.
        let wingPath = UIBezierPath()
        wingPath.move(to: CGPoint(x: 0, y: 0.18))
        wingPath.addLine(to: CGPoint(x: 0.50, y: -0.30))
        wingPath.addLine(to: CGPoint(x: 0.42, y: -0.40))
        wingPath.addLine(to: CGPoint(x: 0, y: -0.30))
        wingPath.addLine(to: CGPoint(x: -0.42, y: -0.40))
        wingPath.addLine(to: CGPoint(x: -0.50, y: -0.30))
        wingPath.close()
        let wingShape = SCNShape(path: wingPath, extrusionDepth: 0.028)
        wingShape.chamferRadius = 0.006
        wingShape.materials = [hull]
        let wings = SCNNode(geometry: wingShape)
        wings.eulerAngles.x = -.pi / 2                // path y becomes world -z
        ship.addChildNode(wings)

        // Tail fin sweeping back and up.
        let finPath = UIBezierPath()
        finPath.move(to: CGPoint(x: 0, y: 0.03))
        finPath.addLine(to: CGPoint(x: 0.16, y: 0.24))
        finPath.addLine(to: CGPoint(x: 0.22, y: 0.22))
        finPath.addLine(to: CGPoint(x: 0.13, y: 0.03))
        finPath.close()
        let finShape = SCNShape(path: finPath, extrusionDepth: 0.02)
        finShape.chamferRadius = 0.004
        finShape.materials = [hull]
        let fin = SCNNode(geometry: finShape)
        fin.eulerAngles.y = -.pi / 2                  // path x becomes world +z
        fin.position = SCNVector3(0, 0.05, 0.12)
        ship.addChildNode(fin)

        // Twin engines with hot exhaust discs (they feed the bloom pass).
        for side: Float in [-1, 1] {
            let engine = SCNNode(geometry: SCNCylinder(radius: 0.055, height: 0.26))
            engine.geometry?.materials = [dark]
            engine.eulerAngles.x = .pi / 2
            engine.position = SCNVector3(side * 0.17, 0, 0.30)
            ship.addChildNode(engine)

            let exhaust = SCNNode(geometry: SCNCylinder(radius: 0.042, height: 0.015))
            exhaust.geometry?.materials = [GameAssets.accentMaterial(color: accentCyan, intensity: 2.6)]
            exhaust.eulerAngles.x = .pi / 2
            exhaust.position = SCNVector3(side * 0.17, 0, 0.44)
            ship.addChildNode(exhaust)

            let navLight = SCNNode(geometry: SCNSphere(radius: 0.018))
            navLight.geometry?.materials = [GameAssets.accentMaterial(color: accentCyan, intensity: 2.0)]
            navLight.position = SCNVector3(side * 0.46, 0.01, 0.32)
            ship.addChildNode(navLight)
        }

        // Dorsal light strip along the spine.
        let strip = SCNNode(geometry: SCNBox(width: 0.02, height: 0.006, length: 0.55, chamferRadius: 0.002))
        strip.geometry?.materials = [GameAssets.accentMaterial(color: accentCyan, intensity: 1.6)]
        strip.position = SCNVector3(0, 0.125, 0)
        ship.addChildNode(strip)
        return ship
    }

    static func makeRing() -> SCNNode {
        let torus = SCNTorus(ringRadius: 0.62, pipeRadius: 0.03)
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.metalness.contents = 0.9
        material.roughness.contents = 0.25
        material.emission.contents = UIColor(red: 0.5, green: 0.9, blue: 1, alpha: 1)
        material.emission.intensity = 1.8
        torus.materials = [material]
        let ring = SCNNode(geometry: torus)
        ring.castsShadow = false
        return ring
    }
}

// objship.java port: the player ship, its three weapon rings, movement
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

    init() {
        node = ShipFactory.make()
        node.simdPosition = Self.spawnPosition

        rings = (0..<Self.ringCount).map { _ in
            let ring = ShipFactory.makeRing()
            ring.simdPosition = GameRenderer.inactivePosition
            return ring
        }

        var collected: [SCNMaterial] = []
        node.enumerateHierarchy { child, _ in
            collected.append(contentsOf: child.geometry?.materials ?? [])
        }
        materials = collected
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
// Each bar has its own neon hue sweeping cyan -> magenta across the rack.
final class SpectrumBar {

    static let size: Float = 2.5          // SPECTRUM_BIN_SIZE
    static let yFactor: Float = 5         // SPECTRUM_BIN_SIZE_Y_FACTOR
    private static let spacing = size * 1.35

    let node: SCNNode
    let basePosition: simd_float3
    private let material: SCNMaterial

    init(index: Int) {
        // Android display x mirrored into collision space.
        let x = Float(index) * Self.spacing - Float(GameLogic.spectrumBinCount) / 2 * Self.spacing
        basePosition = simd_float3(x, -GameRenderer.roomSize / 2 + 0.5, 0)

        // The white gradient texture is tinted per bar; emission tracks this bar's
        // level so peaking bars glow into the HDR bloom pass.
        let hue = 0.5 + 0.37 * CGFloat(index) / CGFloat(GameLogic.spectrumBinCount - 1)
        material = GameAssets.unlitMaterial(imageNamed: "bar_gradient.png")
        material.multiply.contents = UIColor(hue: hue, saturation: 0.85, brightness: 1, alpha: 1)
        material.emission.contents = material.diffuse.contents
        material.emission.intensity = 0

        let size = CGFloat(Self.size)
        let box = SCNBox(width: size, height: size, length: size, chamferRadius: 0.12)
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
        material.emission.intensity = CGFloat(value) * 0.9   // blooms at the peak
    }
}
