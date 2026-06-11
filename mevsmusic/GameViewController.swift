//
//  GameViewController.swift
//  mevsmusic
//

import UIKit
import SceneKit

class GameViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()

        guard let sceneView = self.view as? SCNView else { return }

        // Placeholder scene proving the 3D pipeline; the port replaces this with the game scene.
        let scene = SCNScene()
        scene.background.contents = UIColor(red: 0.05, green: 0.1, blue: 0.4, alpha: 1)

        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.position = SCNVector3(0, 0, 10)
        scene.rootNode.addChildNode(cameraNode)

        let lightNode = SCNNode()
        lightNode.light = SCNLight()
        lightNode.light?.type = .directional
        lightNode.eulerAngles = SCNVector3(-0.5, 0.3, 0)
        scene.rootNode.addChildNode(lightNode)

        let box = SCNNode(geometry: SCNBox(width: 2, height: 2, length: 2, chamferRadius: 0.1))
        box.runAction(.repeatForever(.rotateBy(x: 0, y: 2, z: 0, duration: 2)))
        scene.rootNode.addChildNode(box)

        sceneView.scene = scene
        sceneView.showsStatistics = true
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return .landscape
    }

    override var prefersStatusBarHidden: Bool {
        return true
    }
}
