//
//  OfflineMapManager.swift
//  BikeComputer
//
//  Coordinates offline map platform requests from the settings UI.
//

import CoreLocation
import Combine
import Foundation

private enum OfflineMapDefaults {
    nonisolated static let serverURLKey = "offlineMap.serverURL"
    nonisolated static let apiTokenKey = "offlineMap.apiToken"
    nonisolated static let centerLatitudeKey = "offlineMap.centerLatitude"
    nonisolated static let centerLongitudeKey = "offlineMap.centerLongitude"
    nonisolated static let sideLengthKey = "offlineMap.sideLengthKm"
    nonisolated static let legacyServerURLs = [
        "http://rhi0maej6bwo33hn0im6h4lf.178.18.245.246.sslip.io"
    ]
}

@MainActor
final class OfflineMapManager: ObservableObject {
    @Published var serverURLString: String {
        didSet { defaults.set(serverURLString, forKey: OfflineMapDefaults.serverURLKey) }
    }
    @Published var apiToken: String {
        didSet { defaults.set(apiToken, forKey: OfflineMapDefaults.apiTokenKey) }
    }
    @Published var centerLatitude: String {
        didSet { defaults.set(centerLatitude, forKey: OfflineMapDefaults.centerLatitudeKey) }
    }
    @Published var centerLongitude: String {
        didSet { defaults.set(centerLongitude, forKey: OfflineMapDefaults.centerLongitudeKey) }
    }
    @Published var sideLengthKm: String {
        didSet { defaults.set(sideLengthKm, forKey: OfflineMapDefaults.sideLengthKey) }
    }
    @Published private(set) var currentJob: OfflineMapJob?
    @Published private(set) var downloadURL: URL?
    @Published private(set) var downloadedPackURL: URL?
    @Published private(set) var cachedPackURLs: [URL] = []
    @Published private(set) var downloadProgress: Double = 0
    @Published private(set) var downloadByteProgress: OfflineMapByteProgress?
    @Published private(set) var transferProgress: Double = 0
    @Published private(set) var isBusy = false
    @Published private(set) var isMapAreaSelectionActive = false
    @Published private(set) var selectedMapBounds: OfflineMapBounds?
    @Published private(set) var statusMessage = ""
    @Published private(set) var errorMessage: String?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.serverURLString = Self.resolvedServerURL(defaults: defaults)
        self.apiToken = Self.resolvedAPIToken(defaults: defaults)
        self.centerLatitude = defaults.string(forKey: OfflineMapDefaults.centerLatitudeKey) ?? "35.16755"
        self.centerLongitude = defaults.string(forKey: OfflineMapDefaults.centerLongitudeKey) ?? "136.89451"
        self.sideLengthKm = defaults.string(forKey: OfflineMapDefaults.sideLengthKey) ?? "25"
        defaults.set(serverURLString, forKey: OfflineMapDefaults.serverURLKey)
        defaults.set(apiToken, forKey: OfflineMapDefaults.apiTokenKey)
        refreshCachedPacks()
    }

    func createCustomCutoutJob() {
        do {
            try createJobAndDownload(request: makeCustomBBoxRequest())
        } catch {
            errorMessage = diagnosticMessage(for: error)
        }
    }

    func beginMapAreaSelection() {
        errorMessage = nil
        selectedMapBounds = nil
        isMapAreaSelectionActive = true
    }

    func cancelMapAreaSelection() {
        isMapAreaSelectionActive = false
    }

    func updateMapAreaSelection(bounds: OfflineMapBounds) {
        selectedMapBounds = bounds
    }

    func createJobFromSelectedMapArea() {
        guard let selectedMapBounds else {
            errorMessage = OfflineMapPlatformError.invalidResponse.localizedDescription
            return
        }
        isMapAreaSelectionActive = false
        createJobAndDownload(request: .customBBox(selectedMapBounds))
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
                self.downloadProgress = 0
                self.downloadByteProgress = nil
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
                    self.downloadProgress = 0
                    self.downloadByteProgress = nil
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

    private func createJobAndDownload(request: OfflineMapJobRequest) {
        Task {
            await runBusy {
                let client = try self.makeClient()
                self.currentJob = nil
                self.downloadURL = nil
                self.downloadedPackURL = nil
                self.downloadProgress = 0
                self.downloadByteProgress = nil
                self.transferProgress = 0
                self.statusMessage = "creating map job"

                self.currentJob = try await client.createJob(request)
                self.statusMessage = self.currentJob?.status ?? ""
                try await self.waitForReadyMap(client: client)
                try await self.downloadReadyPack(client: client)
            }
        }
    }

    private func makeClient() throws -> OfflineMapPlatformClient {
        guard let url = URL(string: serverURLString), url.scheme != nil else {
            throw OfflineMapPlatformError.invalidBaseURL
        }
        return OfflineMapPlatformClient(baseURL: url, apiToken: apiToken)
    }

    nonisolated static func resolvedServerURL(defaults: UserDefaults) -> String {
        let stored = defaults.string(forKey: OfflineMapDefaults.serverURLKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if stored.isEmpty || OfflineMapDefaults.legacyServerURLs.contains(stored) {
            return OfflineMapServiceConfig.productionServerURLString
        }
        return stored
    }

    nonisolated static func resolvedAPIToken(defaults: UserDefaults) -> String {
        let bundled = OfflineMapServiceConfig.apiToken
        let stored = defaults.string(forKey: OfflineMapDefaults.apiTokenKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
        downloadProgress = 0
        downloadByteProgress = nil
        let temporaryURL = try await OfflineMapPackDownloader.download(from: url) { [weak self] progress in
            self?.downloadProgress = progress
        } onByteProgress: { [weak self] byteProgress in
            self?.downloadByteProgress = byteProgress
        }
        let destination = try cachedPackURL(mapId: mapId)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        downloadedPackURL = destination
        refreshCachedPacks()
        downloadProgress = 1
        downloadByteProgress = nil
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
        let directory = try cachedPackDirectory()
        return directory.appendingPathComponent("\(mapId).zip")
    }

    private func cachedPackDirectory() throws -> URL {
        let directory = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("OfflineMapPacks", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func refreshCachedPacks() {
        do {
            let directory = try cachedPackDirectory()
            cachedPackURLs = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            .filter { $0.pathExtension.lowercased() == "zip" }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhsDate > rhsDate
            }
        } catch {
            cachedPackURLs = []
        }
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
            errorMessage = diagnosticMessage(for: error)
        }
    }

    private func diagnosticMessage(for error: Error) -> String {
        let nsError = error as NSError
        var parts = [error.localizedDescription]
        if nsError.domain != NSCocoaErrorDomain || nsError.code != 0 {
            parts.append("\(nsError.domain) \(nsError.code)")
        }
        if let failingURL = nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL {
            parts.append(failingURL.absoluteString)
        }
        return parts.joined(separator: "\n")
    }
}

struct OfflineMapByteProgress: Equatable {
    let completedBytes: Int64
    let totalBytes: Int64
}

private final class OfflineMapPackDownloader: NSObject, URLSessionDownloadDelegate {
    private let onProgress: @MainActor @Sendable (Double) -> Void
    private let onByteProgress: @MainActor @Sendable (OfflineMapByteProgress) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?

    private init(
        onProgress: @escaping @MainActor @Sendable (Double) -> Void,
        onByteProgress: @escaping @MainActor @Sendable (OfflineMapByteProgress) -> Void
    ) {
        self.onProgress = onProgress
        self.onByteProgress = onByteProgress
    }

    static func download(
        from url: URL,
        onProgress: @escaping @MainActor @Sendable (Double) -> Void,
        onByteProgress: @escaping @MainActor @Sendable (OfflineMapByteProgress) -> Void
    ) async throws -> URL {
        let downloader = OfflineMapPackDownloader(onProgress: onProgress, onByteProgress: onByteProgress)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                downloader.continuation = continuation
                let configuration = URLSessionConfiguration.default
                configuration.timeoutIntervalForRequest = 120
                configuration.timeoutIntervalForResource = 60 * 60
                configuration.waitsForConnectivity = true
                let session = URLSession(configuration: configuration, delegate: downloader, delegateQueue: nil)
                downloader.session = session
                session.downloadTask(with: url).resume()
            }
        } onCancel: {
            downloader.session?.invalidateAndCancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = min(max(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 0), 1)
        let byteProgress = OfflineMapByteProgress(
            completedBytes: totalBytesWritten,
            totalBytes: totalBytesExpectedToWrite
        )
        Task { @MainActor [onProgress, onByteProgress] in
            onProgress(progress)
            onByteProgress(byteProgress)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            let temporaryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("zip")
            try FileManager.default.moveItem(at: location, to: temporaryURL)
            continuation?.resume(returning: temporaryURL)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
        session.finishTasksAndInvalidate()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error, continuation != nil {
            continuation?.resume(throwing: error)
            continuation = nil
        }
        session.finishTasksAndInvalidate()
    }
}
