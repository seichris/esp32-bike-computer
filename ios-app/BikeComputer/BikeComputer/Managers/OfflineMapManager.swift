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
    @Published private(set) var isBusy = false
    @Published private(set) var statusMessage = ""
    @Published private(set) var errorMessage: String?

    private static let serverURLKey = "offlineMap.serverURL"
    private static let apiTokenKey = "offlineMap.apiToken"
    private static let centerLatitudeKey = "offlineMap.centerLatitude"
    private static let centerLongitudeKey = "offlineMap.centerLongitude"
    private static let sideLengthKey = "offlineMap.sideLengthKm"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.serverURLString = defaults.string(forKey: Self.serverURLKey) ?? ""
        self.apiToken = defaults.string(forKey: Self.apiTokenKey) ?? ""
        self.centerLatitude = defaults.string(forKey: Self.centerLatitudeKey) ?? "35.16755"
        self.centerLongitude = defaults.string(forKey: Self.centerLongitudeKey) ?? "136.89451"
        self.sideLengthKm = defaults.string(forKey: Self.sideLengthKey) ?? "25"
    }

    func createCustomCutoutJob() {
        Task {
            await runBusy {
                let client = try self.makeClient()
                let request = try self.makeCustomBBoxRequest()
                self.currentJob = try await client.createJob(request)
                self.downloadURL = nil
                self.statusMessage = self.currentJob?.status ?? ""
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
