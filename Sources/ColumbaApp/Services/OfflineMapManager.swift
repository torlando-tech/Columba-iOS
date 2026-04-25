//
//  OfflineMapManager.swift
//  ColumbaApp
//
//  Service wrapping MapLibre's native offline API (MLNOfflineStorage).
//  Manages download, deletion, and tracking of offline map regions.
//

#if os(iOS)
import Foundation
import MapLibre
import CoreLocation
import os.log

/// Download status for an offline map region.
enum OfflineDownloadStatus: String, Codable {
    case pending
    case downloading
    case complete
    case error
}

/// Metadata for a downloaded offline map region.
struct OfflineMapRegion: Codable, Identifiable {
    let id: String
    var name: String
    let centerLatitude: Double
    let centerLongitude: Double
    let radiusKm: Double
    let minZoom: Int
    let maxZoom: Int
    var status: OfflineDownloadStatus
    var tileCount: Int
    var sizeBytes: Int64
    var downloadProgress: Float
    var createdAt: TimeInterval
    var completedAt: TimeInterval?
    var isDefault: Bool

    var center: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: centerLatitude, longitude: centerLongitude)
    }

    var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: sizeBytes)
    }
}

/// Manages offline map tile downloads via MapLibre's native offline API.
@available(iOS 17.0, *)
@Observable @MainActor
final class OfflineMapManager {
    // MARK: - State

    var regions: [OfflineMapRegion] = []
    var totalSize: Int64 { regions.reduce(0) { $0 + $1.sizeBytes } }

    // MARK: - Private

    private let storageKey = "com.columba.offlineMapRegions"
    private let styleURL = URL(string: "https://tiles.openfreemap.org/styles/liberty")!
    private let logger = Logger(subsystem: "network.columba.Columba", category: "OfflineMapManager")
    private nonisolated(unsafe) var observers: [NSObjectProtocol] = []

    // MARK: - Init

    init() {
        loadRegions()
        setupObservers()
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Public API

    /// Download a new offline map region.
    func downloadRegion(
        name: String,
        center: CLLocationCoordinate2D,
        radiusKm: Double,
        minZoom: Int,
        maxZoom: Int
    ) {
        let regionId = UUID().uuidString
        let bounds = boundingBox(center: center, radiusKm: radiusKm)

        // Create MLN offline region
        let offlineRegion = MLNTilePyramidOfflineRegion(
            styleURL: styleURL,
            bounds: bounds,
            fromZoomLevel: Double(minZoom),
            toZoomLevel: Double(maxZoom)
        )

        // Encode region ID as context for matching later
        let context = regionId.data(using: .utf8)!

        // Create metadata
        let region = OfflineMapRegion(
            id: regionId,
            name: name,
            centerLatitude: center.latitude,
            centerLongitude: center.longitude,
            radiusKm: radiusKm,
            minZoom: minZoom,
            maxZoom: maxZoom,
            status: .pending,
            tileCount: 0,
            sizeBytes: 0,
            downloadProgress: 0,
            createdAt: Date().timeIntervalSince1970,
            completedAt: nil,
            isDefault: regions.isEmpty
        )

        regions.append(region)
        saveRegions()

        // Start download
        MLNOfflineStorage.shared.addPack(for: offlineRegion, withContext: context) { [weak self] pack, error in
            Task { @MainActor in
                if let error = error {
                    self?.logger.error("Failed to start download: \(error)")
                    if let idx = self?.regions.firstIndex(where: { $0.id == regionId }) {
                        self?.regions[idx].status = .error
                        self?.saveRegions()
                    }
                    return
                }
                if let pack = pack {
                    pack.resume()
                    if let idx = self?.regions.firstIndex(where: { $0.id == regionId }) {
                        self?.regions[idx].status = .downloading
                        self?.saveRegions()
                    }
                }
            }
        }

        logger.info("Started download: \(name) (\(radiusKm)km, zoom \(minZoom)-\(maxZoom))")
    }

    /// Delete an offline map region.
    func deleteRegion(id: String) {
        guard let idx = regions.firstIndex(where: { $0.id == id }) else { return }
        let region = regions[idx]

        // Find and remove the MLN pack
        MLNOfflineStorage.shared.packs?.forEach { pack in
            if let context = String(data: pack.context, encoding: .utf8), context == id {
                MLNOfflineStorage.shared.removePack(pack) { [weak self] error in
                    if let error = error {
                        self?.logger.warning("Failed to remove pack: \(error)")
                    }
                }
            }
        }

        regions.remove(at: idx)

        // If we deleted the default, make the first remaining one default
        if region.isDefault, let firstIdx = regions.indices.first {
            regions[firstIdx].isDefault = true
        }

        saveRegions()
        logger.info("Deleted region: \(region.name)")
    }

    /// Toggle default region.
    func setDefaultRegion(id: String) {
        for idx in regions.indices {
            regions[idx].isDefault = (regions[idx].id == id)
        }
        saveRegions()
    }

    /// Estimate tile count and download size for a proposed region.
    func estimateTileCount(
        center: CLLocationCoordinate2D,
        radiusKm: Double,
        minZoom: Int,
        maxZoom: Int
    ) -> (tiles: Int, sizeEstimate: String) {
        // Rough estimate: each zoom level has 4^z tiles globally
        // For a given area, approximate the number of tiles
        let bounds = boundingBox(center: center, radiusKm: radiusKm)
        var totalTiles = 0

        for z in minZoom...maxZoom {
            let scale = Double(1 << z) // 2^z
            let latRange = bounds.ne.latitude - bounds.sw.latitude
            let lonRange = bounds.ne.longitude - bounds.sw.longitude

            // Tiles per degree at zoom z (approximately)
            let tilesPerDegLat = scale / 180.0
            let tilesPerDegLon = scale / 360.0

            let tilesLat = max(1, Int(latRange * tilesPerDegLat))
            let tilesLon = max(1, Int(lonRange * tilesPerDegLon))
            totalTiles += tilesLat * tilesLon
        }

        // Average tile size ~20KB for vector tiles
        let estimatedBytes = Int64(totalTiles) * 20_000
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        let sizeStr = formatter.string(fromByteCount: estimatedBytes)

        return (tiles: totalTiles, sizeEstimate: sizeStr)
    }

    // MARK: - Persistence

    func loadRegions() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            regions = []
            return
        }
        regions = (try? JSONDecoder().decode([OfflineMapRegion].self, from: data)) ?? []
    }

    private func saveRegions() {
        guard let data = try? JSONEncoder().encode(regions) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    // MARK: - Observers

    private func setupObservers() {
        let progressObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.MLNOfflinePackProgressChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleProgressChange(notification)
        }
        observers.append(progressObserver)

        let errorObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.MLNOfflinePackError,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handlePackError(notification)
        }
        observers.append(errorObserver)
    }

    private func handleProgressChange(_ notification: Notification) {
        guard let pack = notification.object as? MLNOfflinePack,
              let regionId = String(data: pack.context, encoding: .utf8),
              let idx = regions.firstIndex(where: { $0.id == regionId }) else { return }

        let progress = pack.progress
        let completed = progress.countOfResourcesCompleted
        let expected = max(progress.countOfResourcesExpected, 1)
        let fraction = Float(completed) / Float(expected)

        regions[idx].downloadProgress = fraction
        regions[idx].tileCount = Int(completed)
        regions[idx].sizeBytes = Int64(progress.countOfBytesCompleted)

        if progress.countOfResourcesCompleted >= progress.countOfResourcesExpected {
            regions[idx].status = .complete
            regions[idx].completedAt = Date().timeIntervalSince1970
            logger.info("Download complete: \(self.regions[idx].name)")
        } else {
            regions[idx].status = .downloading
        }

        saveRegions()
    }

    private func handlePackError(_ notification: Notification) {
        guard let pack = notification.object as? MLNOfflinePack,
              let regionId = String(data: pack.context, encoding: .utf8),
              let idx = regions.firstIndex(where: { $0.id == regionId }) else { return }

        regions[idx].status = .error
        saveRegions()

        if let error = notification.userInfo?[MLNOfflinePackUserInfoKey.error] as? Error {
            logger.error("Pack error for \(self.regions[idx].name): \(error)")
        }
    }

    // MARK: - Helpers

    /// Calculate bounding box from center + radius.
    private func boundingBox(center: CLLocationCoordinate2D, radiusKm: Double) -> MLNCoordinateBounds {
        // Approximate: 1 degree latitude ~111 km
        let latDelta = radiusKm / 111.0
        // 1 degree longitude varies with latitude
        let lonDelta = radiusKm / (111.0 * cos(center.latitude * .pi / 180.0))

        let sw = CLLocationCoordinate2D(
            latitude: center.latitude - latDelta,
            longitude: center.longitude - lonDelta
        )
        let ne = CLLocationCoordinate2D(
            latitude: center.latitude + latDelta,
            longitude: center.longitude + lonDelta
        )

        return MLNCoordinateBounds(sw: sw, ne: ne)
    }
}
#endif
