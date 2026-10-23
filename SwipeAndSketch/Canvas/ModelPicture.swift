import SceneKit
import simd
import UIKit

/// A model drawn on its own, off the canvas: the project's picture for the document browser, and
/// the template gallery's cards and live preview (October 21, 2026). Solids are shaded gray with
/// dark borders, as on the canvas, from the standard 3D angle and framed to fit; with no solid, the
/// sketches are purple lines.
enum ModelPicture {
    /// One solid ready to draw: its faces (with their material) and its border lines.
    struct Part: @unchecked Sendable {
        var faces: SCNGeometry
        var borders: [[SIMD3<Float>]]
        var corners: [SIMD3<Float>]
    }

    /// The visible solids of `workspace` that build. Kernel work: call it off the main thread.
    static func parts(of workspace: Workspace) -> [Part] {
        workspace.visible.bodies.compactMap { body in
            guard let solid = try? SolidKernel.solid(for: body), let mesh = try? solid.tessellateForDisplay() else { return nil }
            let (r, g, b) = (body.color ?? .gray).rgb
            let material = SCNMaterial()
            material.diffuse.contents = UIColor(red: r, green: g, blue: b, alpha: 1)
            material.lightingModel = .lambert
            material.isDoubleSided = true
            let bounds = solid.bounds
            var corners: [SIMD3<Float>] = []
            for x in [bounds.min.x, bounds.max.x] { for y in [bounds.min.y, bounds.max.y] { for z in [bounds.min.z, bounds.max.z] {
                corners.append(SIMD3(Float(x), Float(y), Float(z)))
            } } }
            return Part(faces: KernelSceneGeometry(mesh, faceMaterial: material).faces,
                        borders: mesh.edges.filter(\.isBoundary).map(\.points), corners: corners)
        }
    }

    /// The standard 3D view direction (the canvas's default angle).
    static let orientation = ViewOrientation(direction: SIMD3(cos(.pi / 5) * cos(-.pi / 3), cos(.pi / 5) * sin(-.pi / 3), sin(.pi / 5)),
                                             up: SIMD3(0, 0, 1))

    /// A scene of `parts` (or, with none, `sketchLines`) and an orthographic camera framing them,
    /// with border lines `pixels` wide. Nil when there is nothing to draw.
    @MainActor static func scene(parts: [Part], sketchLines: [[SIMD3<Float>]] = [], pixels: Double) -> (scene: SCNScene, camera: SCNNode, center: SIMD3<Float>)? {
        let points = parts.flatMap(\.corners) + sketchLines.flatMap { $0 }
        guard let first = points.first else { return nil }
        let low = points.reduce(first) { simd_min($0, $1) }, high = points.reduce(first) { simd_max($0, $1) }
        let center = (low + high) / 2
        var halfWidth = 0.0, halfHeight = 0.0
        for point in points {
            let offset = SIMD3<Double>(point - center)
            halfWidth = max(halfWidth, abs(simd_dot(offset, orientation.right)))
            halfHeight = max(halfHeight, abs(simd_dot(offset, orientation.up)))
        }
        let height = max(1, max(halfWidth, halfHeight) * 2 * 1.15)

        let scene = SCNScene()
        scene.background.contents = UIColor(named: "ss-canvas") ?? UIColor(white: 0.94, alpha: 1)
        let edgeGray = UIColor(white: 0.09, alpha: 1)
        for part in parts {
            let node = SCNNode(geometry: part.faces)
            let segments = part.borders.flatMap { border in zip(border, border.dropFirst()).map { ($0, $1) } }
            node.addChildNode(stroke(segments, color: edgeGray, pixels: pixels))
            scene.rootNode.addChildNode(node)
        }
        let sketchSegments = sketchLines.flatMap { line in zip(line, line.dropFirst()).map { ($0, $1) } }
        if !sketchSegments.isEmpty {
            scene.rootNode.addChildNode(stroke(sketchSegments, color: UIColor(named: "ss-violet") ?? .purple, pixels: pixels))
        }
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 350
        scene.rootNode.addChildNode(ambient)
        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 650
        key.position = SCNVector3(4, 2, 8)
        key.look(at: SCNVector3Zero, up: SCNVector3(0, 0, 1), localFront: SCNVector3(0, 0, -1))
        scene.rootNode.addChildNode(key)
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.usesOrthographicProjection = true
        camera.camera?.orthographicScale = height / 2
        camera.camera?.zNear = 0.1
        camera.camera?.zFar = 200_000
        camera.simdPosition = center + SIMD3<Float>(orientation.direction) * 50_000
        camera.simdOrientation = orientation.rotation
        scene.rootNode.addChildNode(camera)
        return (scene, camera, center)
    }

    /// A square picture `side` pixels across.
    @MainActor static func image(parts: [Part], sketchLines: [[SIMD3<Float>]] = [], side: CGFloat) -> UIImage? {
        // Lines about 3 pixels wide whatever the model's size, so they survive the browser's shrinking.
        guard let drawn = scene(parts: parts, sketchLines: sketchLines, pixels: 1.5) else { return nil }
        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = drawn.scene
        renderer.pointOfView = drawn.camera
        return renderer.snapshot(atTime: 0, with: CGSize(width: side, height: side), antialiasingMode: .multisampling4X)
    }

    /// Tubes along `segments`, widened to `pixels` by the canvas's stroke shader whatever the zoom.
    @MainActor private static func stroke(_ segments: [(SIMD3<Float>, SIMD3<Float>)], color: UIColor, pixels: Double) -> SCNNode {
        let geometry = CanvasController.strokeGeometry(segments)
        let material = SCNMaterial()
        material.diffuse.contents = color.withAlphaComponent(1)
        material.lightingModel = .constant
        material.isDoubleSided = true
        material.shaderModifiers = [.geometry: CanvasController.strokeShader]
        material.setValue(NSNumber(value: Float(pixels)), forKey: "strokePixels")
        geometry.materials = [material]
        return SCNNode(geometry: geometry)
    }
}
