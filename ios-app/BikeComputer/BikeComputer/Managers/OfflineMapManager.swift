//
//  OfflineMapManager.swift
//  BikeComputer
//
//  Coordinates offline map platform requests from the settings UI.
//

import CoreLocation
import Combine
import Foundation

@MainActor
final class OfflineMapManager: ObservableObject {
    @Published var serverURLString: String {
        didSet { defaults.set(serverURLString, forKey: Self.serverURLKey) }
    }
    @Published var apiToken: String {
        didSet { defaults.set(apiToken, forKey: Self.apiTokenKey) }
    }
    @Published var centerLatitude: String {
        didSet { defaults.set(centerLatitude, forKey: Self.centerLatitudeKey) }
    }
    @Published var centerLongitude: String {
        didSet { defaults.set(centerLongitude, forKey: Self.centerLongitudeKey) }
    }
    @Published var sideLengthKm: String {
        didSet { defaults.set(sideLengthKm, forKey: Self.sideLengthKey) }
    }
    @Published private(set) var currentJob: OfflineMapJob?
    @Published private(set) var downloadURL: URL?
    @Published private(set) var downloadedPackURL: URL?
    @Published private(set) var transferProgress: Double = 0
    @Published private(set) var isBusy = false
    @Published private(set) var statusMessage = ""
    @Published private(set) var errorMessage: String?

    private static let serverURLKey = "offlineMap.serverURL"
    private static let apiTokenKey = "offlineMap.apiToken"
    private static let centerLatitudeKey = "offlineMap.centerLatitude"
    private static let centerLongitudeKey = "offlineMap.centerLongitude"
    private static let sideLengthKey = "offlineMap.sideLengthKm"
    private static let legacyServerURLs = [
        "http://rhi0maej6bwo33hn0im6h4lf.178.18.245.246.sslip.io"
    ]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.serverURLString = Self.resolvedServerURL(defaults: defaults)
        self.apiToken = Self.resolvedAPIToken(defaults: defaults)
        self.centerLatitude = defaults.string(forKey: Self.centerLatitudeKey) ?? "35.16755"
        self.centerLongitude = defaults.string(forKey: Self.centerLongitudeKey) ?? "136.89451"
        self.sideLengthKm = defaults.string(forKey: Self.sideLengthKey) ?? "25"
        defaults.set(serverURLString, forKey: Self.serverURLKey)
        defaults.set(apiToken, forKey: Self.apiTokenKey)
    }

    func createCustomCutoutJob() {
        Task {
            await runBusy {
                let client = try self.makeClient()
                let request = try self.makeCustomBBoxRequest()
                self.currentJob = try await client.createJob(request)
                self.downloadURL = nil
                self.downloadedPackURL = nil
                self.transferProgress = 0
                self.statusMessage = self.currentJob?.status ?? ""
            }
        }
    }

    func installCurrentLocationMap(location: CLLocation, bleManager: BLEManager) {
        centerLatitude = String(format: "%.6f", location.coordinate.latitude)
        centerLongitude = String(format: "%.6f", location.coordinate.longitude)

        Task {
            await runBusy {
                let client = try self.makeClient()
                let request = OfflineMapJobRequest.customBBox(OfflineMapBounds(
                    center: location.coordinate,
                    sideLengthKm: Double(self.sideLengthKm) ?? 25
                ))
                self.currentJob = try await client.createJob(request)
                self.downloadURL = nil
                self.downloadedPackURL = nil
                self.transferProgress = 0
                self.statusMessage = "creating map"

                try await self.waitForReadyMap(client: client)
                try await self.downloadReadyPack(client: client)
                try await self.transferReadyPack(bleManager: bleManager)
            }
        }
    }

    func refreshJob() {
        guard let jobId = currentJob?.jobId else { return }
        Task {
            await runBusy {
                let client = try self.makeClient()
                self.currentJob = try await client.job(id: jobId)
                self.statusMessage = self.currentJob?.status ?? ""
                if self.currentJob?.mapId == nil {
                    self.downloadURL = nil
                    self.downloadedPackURL = nil
                    self.transferProgress = 0
                }
            }
        }
    }

    func fetchDownloadURL() {
        guard let mapId = currentJob?.mapId else {
            errorMessage = OfflineMapPlatformError.missingMapId.localizedDescription
            return
        }
        Task {
            await runBusy {
                let client = try self.makeClient()
                self.downloadURL = try await client.downloadURL(mapId: mapId)
                self.statusMessage = "download ready"
            }
        }
    }

    func downloadPack() {
        Task {
            await runBusy {
                try await self.downloadReadyPack(client: self.makeClient())
            }
        }
    }

    func transferDownloadedPack(bleManager: BLEManager) {
        Task {
            await runBusy {
                try await self.transferReadyPack(bleManager: bleManager)
            }
        }
    }

    func makeCustomBBoxRequest() throws -> OfflineMapJobRequest {
        guard let latitude = Double(centerLatitude),
              let longitude = Double(centerLongitude),
              let sizeKm = Double(sideLengthKm) else {
            throw OfflineMapPlatformError.invalidResponse
        }
        let bounds = OfflineMapBounds(
            center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            sideLengthKm: sizeKm
        )
        return .customBBox(bounds)
    }

    private func makeClient() throws -> OfflineMapPlatformClient {
        guard let url = URL(string: serverURLString), url.scheme != nil else {
            throw OfflineMapPlatformError.invalidBaseURL
        }
        return OfflineMapPlatformClient(baseURL: url, apiToken: apiToken)
    }

    nonisolated static func resolvedServerURL(defaults: UserDefaults) -> String {
        let stored = defaults.string(forKey: serverURLKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if stored.isEmpty || legacyServerURLs.contains(stored) {
            return OfflineMapServiceConfig.productionServerURLString
        }
        return stored
    }

    nonisolated static func resolvedAPIToken(defaults: UserDefaults) -> String {
        let bundled = OfflineMapServiceConfig.apiToken
        let stored = defaults.string(forKey: apiTokenKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if stored.isEmpty, !bundled.isEmpty {
            return bundled
        }
        return stored
    }

    private func readyMapId() throws -> String {
        guard let mapId = currentJob?.mapId else {
            throw OfflineMapPlatformError.missingMapId
        }
        return mapId
    }

    private func waitForReadyMap(client: OfflineMapPlatformClient) async throws {
        guard let jobId = currentJob?.jobId else {
            throw OfflineMapPlatformError.invalidResponse
        }

        for _ in 0..<180 {
            let job = try await client.job(id: jobId)
            currentJob = job
            statusMessage = job.status
            if job.status == "ready", job.mapId != nil {
                return
            }
            if job.isTerminal {
                throw OfflineMapPlatformError.serverStatus(409, job.error ?? "Map job ended with status \(job.status)")
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }

        throw OfflineMapPlatformError.serverStatus(408, "Map job did not finish in time")
    }

    private func downloadReadyPack(client: OfflineMapPlatformClient) async throws {
        let mapId = try readyMapId()
        let url: URL
        if let downloadURL {
            url = downloadURL
        } else {
            url = try await client.downloadURL(mapId: mapId)
            downloadURL = url
        }

        statusMessage = "downloading pack"
        let (temporaryURL, _) = try await URLSession.shared.download(from: url)
        let destination = try cachedPackURL(mapId: mapId)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        downloadedPackURL = destination
        transferProgress = 0
        statusMessage = "pack downloaded"
    }

    private func transferReadyPack(bleManager: BLEManager) async throws {
        guard let packURL = downloadedPackURL else {
            throw OfflineMapPlatformError.missingDownloadURL
        }

        let baseURL = try await enableDeviceTransferMode(bleManager: bleManager)
        defer {
            bleManager.requestMapTransferMode(enabled: false)
        }
        let archive = try await Task.detached(priority: .userInitiated) {
            try OfflineMapPackArchive(url: packURL)
        }.value
        let sessionId = UUID().uuidString.lowercased()
        let client = MapTransferDeviceClient(baseURL: baseURL)
        transferProgress = 0
        statusMessage = "uploading to device"
        try await client.upload(archive: archive, sessionId: sessionId) { completed, total, path in
            self.transferProgress = total == 0 ? 0 : Double(completed) / Double(total)
            self.statusMessage = "uploaded \(completed)/\(total): \(path)"
        }
        statusMessage = "activating map"
        try await client.activate(sessionId: sessionId)
        transferProgress = 1
        statusMessage = "map installed"
        bleManager.requestMapTransferStatus()
    }

    private func cachedPackURL(mapId: String) throws -> URL {
        let directory = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("OfflineMapPacks", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(mapId).zip")
    }

    private func enableDeviceTransferMode(bleManager: BLEManager) async throws -> URL {
        guard bleManager.isNavigationReady else {
            throw OfflineMapPlatformError.missingTransferBaseURL
        }

        bleManager.requestMapTransferMode(enabled: true)
        bleManager.requestMapTransferStatus()
        for attempt in 0..<32 {
            if bleManager.mapTransferModeEnabled, let baseURL = bleManager.mapTransferBaseURL {
                return baseURL
            }
            if attempt % 4 == 3 {
                bleManager.requestMapTransferStatus()
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw OfflineMapPlatformError.missingTransferBaseURL
    }

    private func runBusy(_ operation: @MainActor @escaping () async throws -> Void) async {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await operation()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
