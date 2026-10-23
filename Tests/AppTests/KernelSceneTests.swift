import XCTest
import SceneKit
import simd
@testable import SwipeAndSketch

/// On-device path for the Open CASCADE kernel: OCCT runs inside the iPad app, its solids
/// render through SceneKit, and SceneKit hits map back to B-rep faces.
@MainActor final class KernelSceneTests: XCTestCase {
    func profile(_ shape: SketchShape) throws -> SketchProfile {
        try XCTUnwrap(Geometry.profiles(in: [shape], on: shape.plane).first)
    }

    /// Box → fillet vertical edges → shell open at the top → drill the back wall.
    func enclosure() throws -> KernelSolid {
        let box = try SolidKernel.extrude(profile(.init(kind: .rectangle, plane: .top, start: .init(x: -40, y: -25), end: .init(x: 40, y: 25))), depth: 30)
        let boxEdges = try box.tessellate().edges
        let vertical = boxEdges.indices.filter { index in
            let points = boxEdges[index].points
            return abs(points[0].x - points[points.count - 1].x) < 1e-4 && abs(points[0].y - points[points.count - 1].y) < 1e-4
        }
        let rounded = try SolidKernel.fillet(box, edges: vertical, radius: 5)
        let mesh = try rounded.tessellate()
        let top = try XCTUnwrap(mesh.faces.indices.first { face in
            mesh.indices[mesh.faces[face]].allSatisfy { mesh.normals[Int($0)].z > 0.999 && abs(mesh.positions[Int($0)].z - 30) < 1e-4 }
        })
        let shelled = try SolidKernel.shell(rounded, openFaces: [top], thickness: 2)
        let hole = try SolidKernel.extrude(profile(.init(kind: .circle, plane: .front, start: .init(x: 0, y: 15), end: .init(x: 3, y: 15))), depth: -40)
        return try SolidKernel.boolean(shelled, hole, .subtract)
    }

    func material(_ color: UIColor) -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = color
        material.lightingModel = .lambert
        return material
    }

    /// Screen-point picking through SCNView, the same path the canvas uses for Pencil selection.
    func hits(_ geometry: KernelSceneGeometry, cameraAt eye: SIMD3<Float>, lookingAt target: SIMD3<Float>, up: SIMD3<Float>) -> [SCNHitTestResult] {
        let view = SCNView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let scene = SCNScene()
        scene.rootNode.addChildNode(SCNNode(geometry: geometry.faces))
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.zFar = 2_000
        camera.simdPosition = eye
        camera.simdLook(at: target, up: up, localFront: SIMD3(0, 0, -1))
        scene.rootNode.addChildNode(camera)
        view.scene = scene
        view.pointOfView = camera
        return view.hitTest(CGPoint(x: 200, y: 150), options: [.searchMode: SCNHitTestSearchMode.all.rawValue])
    }

    func testKernelSolidRendersAndPicksBRepFaces() throws {
        let solid = try enclosure()
        XCTAssertTrue(solid.isValidSolid)
        let mesh = try solid.tessellate()
        let scene = KernelSceneGeometry(mesh, faceMaterial: material(.gray))
        XCTAssertEqual(scene.elementFaces.count, mesh.faces.filter { !$0.isEmpty }.count)

        // Looking straight down through the open top: the first face hit is the inside floor at z = 2.
        let down = hits(scene, cameraAt: SIMD3(0, 0, 200), lookingAt: .zero, up: SIMD3(0, 1, 0))
        let floor = try XCTUnwrap(down.first)
        XCTAssertEqual(floor.worldCoordinates.z, 2, accuracy: 1e-2)
        let floorFace = try XCTUnwrap(scene.face(for: floor))
        XCTAssertTrue(mesh.indices[mesh.faces[floorFace]].allSatisfy { mesh.normals[Int($0)].z > 0.999 }, "Hit maps to the upward-facing floor face")

        // Looking from the front at the hole's height: the front wall is solid, the back wall is drilled.
        let through = hits(scene, cameraAt: SIMD3(0, -200, 15), lookingAt: SIMD3(0, 0, 15), up: SIMD3(0, 0, 1))
        let ys = through.map(\.worldCoordinates.y).sorted()
        XCTAssertEqual(ys.first ?? 0, -25, accuracy: 1e-2)
        XCTAssertEqual(ys.count, 1, "Back faces are culled, so only the front wall's outer face is hit")
        XCTAssertFalse(ys.contains { $0 > 20 }, "The ray passes through the hole in the back wall")
        XCTAssertTrue(through.allSatisfy { scene.face(for: $0) != nil })
    }

    func testKernelSolidDrawsOffscreenWithSceneKit() throws {
        let mesh = try enclosure().tessellate()
        let geometry = KernelSceneGeometry(mesh, faceMaterial: material(.gray))
        let scene = SCNScene()
        scene.background.contents = UIColor.white
        let node = SCNNode(geometry: geometry.faces)
        node.addChildNode(SCNNode(geometry: KernelSceneGeometry.edgeLines(mesh, material: material(.black))))
        scene.rootNode.addChildNode(node)
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.zFar = 2_000   // default 100 would clip a solid ~240 mm away
        camera.simdPosition = SIMD3(120, -160, 140)
        camera.simdLook(at: SIMD3(0, 0, 12), up: SIMD3(0, 0, 1), localFront: SIMD3(0, 0, -1))
        scene.rootNode.addChildNode(camera)
        let light = SCNNode()
        light.light = SCNLight()
        light.light?.type = .directional
        camera.addChildNode(light)
        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = scene
        renderer.pointOfView = camera
        let image = renderer.snapshot(atTime: 0, with: CGSize(width: 400, height: 300), antialiasingMode: .multisampling4X)
        let attachment = XCTAttachment(image: image)
        attachment.name = "KernelEnclosure"
        attachment.lifetime = .keepAlways
        add(attachment)
        // The solid covers the image center; the corner stays background white.
        XCTAssertLessThan(brightness(image, at: CGPoint(x: 200, y: 150)), 0.9)
        XCTAssertGreaterThan(brightness(image, at: CGPoint(x: 2, y: 2)), 0.95)
    }

    func testCanvasDrawsCommittedSolidsFromKernelBRep() throws {
        for kind in [ShapeKind.rectangle, .circle] {
            let session = ModelingSession(inMemory: true)
            session.addShape(.init(kind: kind, plane: .front, start: .zero, end: .init(x: 20, y: 12)))
            session.beginExtrusion()
            session.extrusionDepth = -15
            session.confirmExtrusion()
            let controller = CanvasController(session: session)
            controller.loadViewIfNeeded()
            controller.view.frame = CGRect(x: 0, y: 0, width: 1180, height: 820)
            controller.view.layoutIfNeeded()
            controller.refresh()
            let node = try XCTUnwrap(controller.content.childNodes.first { $0.name?.hasPrefix("body|") == true })
            let geometry = try XCTUnwrap(node.geometry)
            XCTAssertFalse(geometry is SCNShape, "Committed \(kind) must not use the SceneKit extrusion fallback")
            XCTAssertEqual(geometry.elements.count, kind == .rectangle ? 6 : 3, "One element per B-rep face")
            XCTAssertNotNil(node.childNode(withName: "body.edges", recursively: false))
            // Zoom rebuilds strokes but reuses the cached B-rep triangulation.
            session.requestCamera(.reset); controller.refresh()
            let rebuilt = try XCTUnwrap(controller.content.childNodes.first { $0.name?.hasPrefix("body|") == true })
            XCTAssertTrue(rebuilt.geometry === geometry)
        }
    }

    /// Run on a physical iPad (Product ▸ Test with the iPad selected) for device timings.
    func testReportsOnDeviceKernelTimings() throws {
        func time<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
            let start = Date()
            let value = try body()
            print(String(format: "[kernel timing] %@: %.1f ms", label, Date().timeIntervalSince(start) * 1000))
            return value
        }
        let solid = try time("enclosure (extrude, fillet, shell, cut)") { try enclosure() }
        let mesh = try time("tessellate") { try solid.tessellate() }
        _ = time("SceneKit geometry") { KernelSceneGeometry(mesh, faceMaterial: material(.gray)) }
        print("[kernel timing] OCCT \(SolidKernel.occtVersion); triangles: \(mesh.triangleCount); faces: \(mesh.faces.count)")
    }

    func brightness(_ image: UIImage, at point: CGPoint) -> CGFloat {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1), format: {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; return format
        }())
        let pixel = renderer.image { _ in image.draw(at: CGPoint(x: -point.x, y: -point.y)) }
        var white: CGFloat = 0
        UIColor(cgColor: pixel.cgImage.flatMap { cg -> CGColor? in
            guard let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return nil }
            return CGColor(red: CGFloat(bytes[0]) / 255, green: CGFloat(bytes[1]) / 255, blue: CGFloat(bytes[2]) / 255, alpha: 1)
        } ?? UIColor.black.cgColor).getWhite(&white, alpha: nil)
        return white
    }
}
