import Foundation
import ARKit
import Combine

@MainActor
final class ARPersistenceService: ObservableObject {
    static let shared = ARPersistenceService()

    @Published var environments: [AREnvironmentMap] = []
    @Published var activeEnvironment: AREnvironmentMap?

    private let fileManager = FileManager.default
    private var documentsURL: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WavelyAR", isDirectory: true)
    }

    init() {
        createDirectoryIfNeeded()
        loadEnvironments()
        if environments.isEmpty {
            let defaultEnv = AREnvironmentMap(name: "Casa")
            environments.append(defaultEnv)
            activeEnvironment = defaultEnv
            saveEnvironments()
        } else {
            activeEnvironment = environments.first
        }
    }

    func createEnvironment(name: String) {
        let env = AREnvironmentMap(name: name)
        environments.append(env)
        activeEnvironment = env
        saveEnvironments()
    }

    func renameEnvironment(_ environment: AREnvironmentMap, to name: String) {
        guard let idx = environments.firstIndex(where: { $0.id == environment.id }) else { return }
        environments[idx].name = name
        if activeEnvironment?.id == environment.id { activeEnvironment = environments[idx] }
        saveEnvironments()
    }

    func deleteEnvironment(_ environment: AREnvironmentMap) {
        environments.removeAll { $0.id == environment.id }
        let mapFile = documentsURL.appendingPathComponent("\(environment.id).arworldmap")
        try? fileManager.removeItem(at: mapFile)
        if activeEnvironment?.id == environment.id { activeEnvironment = environments.first }
        saveEnvironments()
    }

    func saveWorldMap(_ worldMap: ARWorldMap, for environment: AREnvironmentMap) {
        guard let idx = environments.firstIndex(where: { $0.id == environment.id }) else { return }
        do {
            let data = try NSKeyedArchiver.archivedData(withRootObject: worldMap, requiringSecureCoding: true)
            let mapFile = documentsURL.appendingPathComponent("\(environment.id).arworldmap")
            try data.write(to: mapFile)
            environments[idx].worldMapData = nil
            if activeEnvironment?.id == environment.id { activeEnvironment = environments[idx] }
            saveEnvironments()
        } catch {}
    }

    func loadWorldMap(for environment: AREnvironmentMap) -> ARWorldMap? {
        let mapFile = documentsURL.appendingPathComponent("\(environment.id).arworldmap")
        guard let data = try? Data(contentsOf: mapFile),
              let worldMap = try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data) else { return nil }
        return worldMap
    }

    func addAnchor(_ anchor: ARAnchor, entityId: String) {
        guard var env = activeEnvironment,
              let idx = environments.firstIndex(where: { $0.id == env.id }) else { return }
        let mapName = env.name
        let deviceAnchor = ARDeviceAnchor(entityId: entityId, anchor: anchor, mapName: mapName)
        environments[idx].deviceAnchors.append(deviceAnchor)
        env = environments[idx]
        activeEnvironment = env
        saveEnvironments()
    }

    func updateAnchorTransform(entityId: String, transform: simd_float4x4) {
        guard let envIdx = environments.firstIndex(where: { $0.id == activeEnvironment?.id }),
              let ancIdx = environments[envIdx].deviceAnchors.firstIndex(where: { $0.entityId == entityId }) else { return }
        environments[envIdx].deviceAnchors[ancIdx].transform = transform.toArray()
        activeEnvironment = environments[envIdx]
        saveEnvironments()
    }

    /// Persists the model entity's local scale and user-defined rotation.
    /// Called whenever the user finishes a pinch or rotation gesture in edit mode.
    func updateModelAppearance(entityId: String, scale: SIMD3<Float>, rotation: simd_quatf) {
        guard let envIdx = environments.firstIndex(where: { $0.id == activeEnvironment?.id }),
              let ancIdx = environments[envIdx].deviceAnchors.firstIndex(where: { $0.entityId == entityId }) else { return }
        environments[envIdx].deviceAnchors[ancIdx].modelScale    = [scale.x, scale.y, scale.z]
        environments[envIdx].deviceAnchors[ancIdx].modelRotation = [rotation.imag.x, rotation.imag.y,
                                                                     rotation.imag.z, rotation.real]
        activeEnvironment = environments[envIdx]
        saveEnvironments()
    }

    func removeAnchor(entityId: String) {
        guard let idx = environments.firstIndex(where: { $0.id == activeEnvironment?.id }) else { return }
        environments[idx].deviceAnchors.removeAll { $0.entityId == entityId }
        activeEnvironment = environments[idx]
        saveEnvironments()
    }

    func anchors(for environmentId: String? = nil) -> [ARDeviceAnchor] {
        let envId = environmentId ?? activeEnvironment?.id
        return environments.first(where: { $0.id == envId })?.deviceAnchors ?? []
    }

    private func saveEnvironments() {
        let url = documentsURL.appendingPathComponent("environments.json")
        guard let data = try? JSONEncoder().encode(environments) else { return }
        try? data.write(to: url)
    }

    private func loadEnvironments() {
        let url = documentsURL.appendingPathComponent("environments.json")
        guard let data = try? Data(contentsOf: url),
              let loaded = try? JSONDecoder().decode([AREnvironmentMap].self, from: data) else { return }
        environments = loaded
    }

    private func createDirectoryIfNeeded() {
        if !fileManager.fileExists(atPath: documentsURL.path) {
            try? fileManager.createDirectory(at: documentsURL, withIntermediateDirectories: true)
        }
    }
}
