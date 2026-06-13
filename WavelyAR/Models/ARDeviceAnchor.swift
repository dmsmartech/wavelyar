import Foundation
import ARKit

struct ARDeviceAnchor: Codable, Identifiable {
    let id: String
    let entityId: String
    let anchorIdentifier: UUID
    let mapName: String
    var transform: [Float]
    /// Model entity local scale (x, y, z). Defaults to [1, 1, 1].
    var modelScale: [Float]
    /// Model entity local rotation as quaternion (ix, iy, iz, r). Defaults to identity.
    var modelRotation: [Float]

    init(entityId: String, anchor: ARAnchor, mapName: String) {
        self.id              = UUID().uuidString
        self.entityId        = entityId
        self.anchorIdentifier = anchor.identifier
        self.mapName         = mapName
        self.transform       = anchor.transform.toArray()
        self.modelScale      = [1, 1, 1]
        self.modelRotation   = [0, 0, 0, 1]
    }

    // Custom decoder: gracefully handles old records that lack modelScale / modelRotation.
    enum CodingKeys: String, CodingKey {
        case id, entityId, anchorIdentifier, mapName, transform, modelScale, modelRotation
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id               = try c.decode(String.self,  forKey: .id)
        entityId         = try c.decode(String.self,  forKey: .entityId)
        anchorIdentifier = try c.decode(UUID.self,    forKey: .anchorIdentifier)
        mapName          = try c.decode(String.self,  forKey: .mapName)
        transform        = try c.decode([Float].self, forKey: .transform)
        modelScale       = try c.decodeIfPresent([Float].self, forKey: .modelScale)    ?? [1, 1, 1]
        modelRotation    = try c.decodeIfPresent([Float].self, forKey: .modelRotation) ?? [0, 0, 0, 1]
    }

    // MARK: - Typed accessors

    var modelScaleValue: SIMD3<Float> {
        guard modelScale.count == 3 else { return SIMD3(1, 1, 1) }
        return SIMD3(modelScale[0], modelScale[1], modelScale[2])
    }

    var modelRotationValue: simd_quatf {
        guard modelRotation.count == 4 else { return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1) }
        return simd_quatf(ix: modelRotation[0], iy: modelRotation[1],
                          iz: modelRotation[2], r:  modelRotation[3])
    }
}

// MARK: - simd_float4x4 helpers

extension simd_float4x4 {
    func toArray() -> [Float] {
        [columns.0.x, columns.0.y, columns.0.z, columns.0.w,
         columns.1.x, columns.1.y, columns.1.z, columns.1.w,
         columns.2.x, columns.2.y, columns.2.z, columns.2.w,
         columns.3.x, columns.3.y, columns.3.z, columns.3.w]
    }

    static func fromArray(_ array: [Float]) -> simd_float4x4? {
        guard array.count == 16 else { return nil }
        return simd_float4x4(
            SIMD4(array[0],  array[1],  array[2],  array[3]),
            SIMD4(array[4],  array[5],  array[6],  array[7]),
            SIMD4(array[8],  array[9],  array[10], array[11]),
            SIMD4(array[12], array[13], array[14], array[15])
        )
    }
}

// MARK: - AREnvironmentMap

struct AREnvironmentMap: Codable, Identifiable {
    var id: String
    var name: String
    var deviceAnchors: [ARDeviceAnchor]
    var createdAt: Date
    var worldMapData: Data?

    init(name: String) {
        self.id           = UUID().uuidString
        self.name         = name
        self.deviceAnchors = []
        self.createdAt    = Date()
    }
}
