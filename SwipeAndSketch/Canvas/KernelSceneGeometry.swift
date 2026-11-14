import SceneKit
import simd
import UIKit

/// SceneKit form of a kernel solid. With `perFace`, each B-rep face becomes its own geometry
/// element, so `elementFaces` maps a SceneKit hit's `geometryIndex` back to the B-rep face (tests
/// check the mapping and draw `edgeLines`). The canvas picks with its own ray cast, so it draws each
/// solid as one element: one draw call instead of one per face, which ran to thousands on every
/// frame for imported, threaded, and lettered parts (November 8, 2026).
struct KernelSceneGeometry {
    var faces: SCNGeometry
    /// `elementFaces[geometryIndex]` is the B-rep face index (faces with no triangles are skipped).
    var elementFaces: [Int]

    init(_ mesh: KernelMesh, faceMaterial: SCNMaterial, perFace: Bool = true) {
        let vertices = Self.source(mesh.positions, .vertex)
        let normals = Self.source(mesh.normals, .normal)
        var elements: [SCNGeometryElement] = []
        elementFaces = []
        if perFace {
            for (face, range) in mesh.faces.enumerated() where !range.isEmpty {
                elements.append(SCNGeometryElement(indices: Array(mesh.indices[range]), primitiveType: .triangles))
                elementFaces.append(face)
            }
        } else if !mesh.indices.isEmpty {
            elements = [SCNGeometryElement(indices: mesh.indices, primitiveType: .triangles)]
        }
        faces = SCNGeometry(sources: [vertices, normals], elements: elements)
        faces.materials = [faceMaterial]
    }

    /// A vertex or normal source straight from the mesh's floats (16-byte SIMD3 stride), one copy
    /// instead of first mapping every point to an SCNVector3.
    static func source(_ vectors: [SIMD3<Float>], _ semantic: SCNGeometrySource.Semantic) -> SCNGeometrySource {
        let data = vectors.withUnsafeBytes { Data($0) }
        return SCNGeometrySource(data: data, semantic: semantic, vectorCount: vectors.count, usesFloatComponents: true,
                                 componentsPerVector: 3, bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
                                 dataStride: MemoryLayout<SIMD3<Float>>.stride)
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
