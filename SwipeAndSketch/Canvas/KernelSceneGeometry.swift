import SceneKit
import simd
import UIKit

/// SceneKit form of a kernel solid. Each B-rep face becomes its own geometry element, so
/// `elementFaces` maps a SceneKit hit's `geometryIndex` back to the B-rep face. (The canvas picks
/// with its own ray cast and draws borders as tubes; tests check the mapping and draw `edgeLines`.)
struct KernelSceneGeometry {
    var faces: SCNGeometry
    /// `elementFaces[geometryIndex]` is the B-rep face index (faces with no triangles are skipped).
    var elementFaces: [Int]

    init(_ mesh: KernelMesh, faceMaterial: SCNMaterial) {
        let vertices = SCNGeometrySource(vertices: mesh.positions.map { SCNVector3($0) })
        let normals = SCNGeometrySource(normals: mesh.normals.map { SCNVector3($0) })
        var elements: [SCNGeometryElement] = []
        elementFaces = []
        for (face, range) in mesh.faces.enumerated() where !range.isEmpty {
            elements.append(SCNGeometryElement(indices: Array(mesh.indices[range]), primitiveType: .triangles))
            elementFaces.append(face)
        }
        faces = SCNGeometry(sources: [vertices, normals], elements: elements)
        faces.materials = [faceMaterial]
    }

    /// Line segments along visible B-rep edges (seams and degenerate edges omitted).
    static func edgeLines(_ mesh: KernelMesh, material: SCNMaterial) -> SCNGeometry {
        var points: [SCNVector3] = []
        var segments: [UInt32] = []
        for edge in mesh.edges where edge.isBoundary && edge.points.count > 1 {
            let first = UInt32(points.count)
            points += edge.points.map { SCNVector3($0) }
            for i in 0..<UInt32(edge.points.count - 1) { segments += [first + i, first + i + 1] }
        }
        let edges = SCNGeometry(sources: [SCNGeometrySource(vertices: points)],
                                elements: [SCNGeometryElement(indices: segments, primitiveType: .line)])
        edges.materials = [material]
        return edges
    }

    /// B-rep face index for a hit on `faces`.
    func face(for hit: SCNHitTestResult) -> Int? {
        elementFaces.indices.contains(hit.geometryIndex) ? elementFaces[hit.geometryIndex] : nil
    }
}
