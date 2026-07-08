//
//  FirmwareUpdateManager.swift
//  BikeComputer
//
//  iPhone-driven firmware OTA over the shared device transfer channel.
//

import Combine
import CryptoKit
import Foundation

enum FirmwareUpdateError: LocalizedError, Equatable {
    case deviceNotReady
    case transferCommandNotSent
    case missingTransferSession
    case missingFirmwareTarget
    case invalidManifest
    case updateNotAvailable
    case unsupportedUpdaterProtocol
    case targetMismatch
    case downgradeNotAllowed
    case downloadSizeMismatch
    case downloadHashMismatch
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .deviceNotReady:
            return "Device is not ready"
        case .transferCommandNotSent:
            return "Could not send transfer command"
        case .missingTransferSession:
            return "Device did not report a firmware transfer session"
        case .missingFirmwareTarget:
            return "Device firmware target is unknown"
        case .invalidManifest:
            return "Firmware manifest is invalid"
        case .updateNotAvailable:
            return "No newer firmware is available"
        case .unsupportedUpdaterProtocol:
            return "Firmware update requires a newer app"
        case .targetMismatch:
            return "Firmware target does not match this device"
        case .downgradeNotAllowed:
            return "Firmware downgrade is disabled"
        case .downloadSizeMismatch:
            return "Downloaded firmware size does not match the manifest"
        case .downloadHashMismatch:
            return "Downloaded firmware hash does not match the manifest"
        case .serverError(let message):
            return message
        }
    }
}

struct FirmwareReleaseManifest: Codable, Equatable {
    let schemaVersion: Int
    let target: String
    let version: String
    let build: Int
    let gitSha: String?
    let size: Int
    let sha256: String
    let url: URL
    let minUpdaterProtocol: Int
    let signature: String?

    var isSupportedByApp: Bool {
        schemaVersion == 1 && minUpdaterProtocol <= 1
    }
}

struct FirmwareDeviceStatus: Decodable, Equatable {
    let status: String
    let target: String
    let runningVersion: String
    let runningBuild: Int
    let runningPartition: String
    let inactivePartition: String
    let otaState: String
    let maxImageBytes: Int
    let receivedBytes: Int
    let totalBytes: Int
    let sha256: String?
    let lastError: FirmwareStatusError?
}

struct FirmwareStatusError: Codable, Equatable {
    let code: String
    let message: String
}

@MainActor
final class FirmwareUpdateManager: ObservableObject {
    @Published var manifestBaseURLString: String {
        didSet { defaults.set(manifestBaseURLString, forKey: Defaults.manifestBaseURLKey) }
    }
    @Published var allowDeveloperDowngrade: Bool {
        didSet { defaults.set(allowDeveloperDowngrade, forKey: Defaults.allowDowngradeKey) }
    }
    @Published private(set) var latestManifest: FirmwareReleaseManifest?
    @Published private(set) var deviceStatus: FirmwareDeviceStatus?
    @Published private(set) var downloadProgress: Double = 0
    @Published private(set) var uploadProgress: Double = 0
    @Published private(set) var statusMessage: String = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var isBusy = false

    private enum Defaults {
        static let manifestBaseURLKey = "firmware.manifestBaseURL"
        static let allowDowngradeKey = "firmware.allowDeveloperDowngrade"
        static let defaultManifestBaseURL = "https://seichris.github.io/open-bike-computer/firmware"
    }

    private let defaults: UserDefaults
    private let session: URLSession
    private let deviceTransferManager = DeviceTransferManager()

    init(defaults: UserDefaults = .standard, session: URLSession = .shared) {
        self.defaults = defaults
        self.session = session
        self.manifestBaseURLString = defaults.string(forKey: Defaults.manifestBaseURLKey) ?? Defaults.defaultManifestBaseURL
        self.allowDeveloperDowngrade = defaults.bool(forKey: Defaults.allowDowngradeKey)
    }

    func checkForUpdate(bleManager: BLEManager) {
        Task {
            await runBusy {
                let manifest = try await self.fetchLatestManifest(bleManager: bleManager)
                self.latestManifest = manifest
                self.statusMessage = self.isUpdateAllowed(manifest, bleManager: bleManager) ? "firmware update available" : "firmware is current"
            }
        }
    }

    func installLatest(bleManager: BLEManager) {
        Task {
            await runBusy {
                let manifest: FirmwareReleaseManifest
                if let latestManifest = self.latestManifest {
                    manifest = latestManifest
                } else {
                    manifest = try await self.fetchLatestManifest(bleManager: bleManager)
                }
                try self.validateInstall(manifest, bleManager: bleManager)
                self.latestManifest = manifest
                self.statusMessage = "downloading firmware"
                self.downloadProgress = 0
                self.uploadProgress = 0
                let image = try await self.downloadFirmware(manifest: manifest)
                self.downloadProgress = 1
                try self.verify(image: image, manifest: manifest)

                var finalized = false
                let transferSession = try await self.deviceTransferManager.enterFirmwareTransfer(
                    bleManager: bleManager
                ) { message in
                    self.statusMessage = message
                }
                defer {
                    if !finalized {
                        self.deviceTransferManager.exitFirmwareTransfer(bleManager: bleManager)
                    }
                }

                let client = FirmwareUpdateDeviceClient(
                    baseURL: transferSession.baseURL,
                    sessionToken: transferSession.sessionToken ?? "",
                    session: self.session
                )
                self.statusMessage = "preparing device update"
                self.deviceStatus = try await client.begin(manifest: manifest,
                                                           allowDowngrade: self.allowDeveloperDowngrade)
                self.statusMessage = "uploading firmware"
                self.uploadProgress = 0
                self.deviceStatus = try await client.upload(image: image) { progress in
                    self.uploadProgress = progress
                }
                self.statusMessage = "finalizing firmware"
                self.deviceStatus = try await client.finalize()
                finalized = true
                self.statusMessage = "device rebooting"
            }
        }
    }

    func refreshDeviceFirmwareStatus(bleManager: BLEManager) {
        bleManager.requestDeviceTransferStatus()
    }

    private func fetchLatestManifest(bleManager: BLEManager) async throws -> FirmwareReleaseManifest {
        if bleManager.firmwareTarget.isEmpty {
            bleManager.requestDeviceTransferStatus()
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        guard !bleManager.firmwareTarget.isEmpty else {
            throw FirmwareUpdateError.missingFirmwareTarget
        }
        guard let baseURL = URL(string: manifestBaseURLString) else {
            throw FirmwareUpdateError.invalidManifest
        }
        let manifestURL = baseURL
            .appendingPathComponent(bleManager.firmwareTarget)
            .appendingPathComponent("manifest.json")
        let (data, response) = try await session.data(from: manifestURL)
        try Self.validateHTTP(response)
        let manifest = try JSONDecoder().decode(FirmwareReleaseManifest.self, from: data)
        guard manifest.isSupportedByApp else {
            throw FirmwareUpdateError.unsupportedUpdaterProtocol
        }
        guard manifest.target == bleManager.firmwareTarget else {
            throw FirmwareUpdateError.targetMismatch
        }
        return manifest
    }

    private func validateInstall(_ manifest: FirmwareReleaseManifest, bleManager: BLEManager) throws {
        guard manifest.target == bleManager.firmwareTarget else {
            throw FirmwareUpdateError.targetMismatch
        }
        if manifest.build <= bleManager.firmwareBuild && !allowDeveloperDowngrade {
            throw FirmwareUpdateError.updateNotAvailable
        }
    }

    func isUpdateAllowed(_ manifest: FirmwareReleaseManifest, bleManager: BLEManager) -> Bool {
        manifest.target == bleManager.firmwareTarget &&
        (manifest.build > bleManager.firmwareBuild || allowDeveloperDowngrade)
    }

    private func downloadFirmware(manifest: FirmwareReleaseManifest) async throws -> Data {
        let (data, response) = try await session.data(from: manifest.url)
        try Self.validateHTTP(response)
        return data
    }

    private func verify(image: Data, manifest: FirmwareReleaseManifest) throws {
        guard image.count == manifest.size else {
            throw FirmwareUpdateError.downloadSizeMismatch
        }
        guard Self.sha256Hex(image) == manifest.sha256.lowercased() else {
            throw FirmwareUpdateError.downloadHashMismatch
        }
    }

    private func runBusy(_ operation: @MainActor @escaping () async throws -> Void) async {
        isBusy = true
        errorMessage = nil
        do {
            try await operation()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isBusy = false
    }

    private static func validateHTTP(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw FirmwareUpdateError.serverError("Firmware server request failed")
        }
    }

    nonisolated static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct FirmwareUpdateDeviceClient {
    let baseURL: URL
    let sessionToken: String
    var session: URLSession = .shared

    func begin(manifest: FirmwareReleaseManifest,
               allowDowngrade: Bool) async throws -> FirmwareDeviceStatus {
        let body: [String: Any] = [
            "version": manifest.version,
            "build": manifest.build,
            "target": manifest.target,
            "size": manifest.size,
            "sha256": manifest.sha256,
            "manifestSignature": manifest.signature ?? "",
            "releaseUrl": manifest.url.absoluteString,
            "allowDowngrade": allowDowngrade
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        return try await request(path: "firmware-update/begin",
                                 method: "POST",
                                 body: data,
                                 contentType: "application/json")
    }

    @MainActor
    func upload(image: Data,
                progress: @escaping @MainActor (Double) -> Void) async throws -> FirmwareDeviceStatus {
        progress(0)
        let status: FirmwareDeviceStatus = try await request(path: "firmware-update/image",
                                                             method: "PUT",
                                                             body: image,
                                                             contentType: "application/octet-stream")
        progress(1)
        return status
    }

    func finalize() async throws -> FirmwareDeviceStatus {
        try await request(path: "firmware-update/finalize",
                          method: "POST",
                          body: Data(),
                          contentType: "application/json")
    }

    private func request<T: Decodable>(path: String,
                                       method: String,
                                       body: Data?,
                                       contentType: String? = nil) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 60
        request.setValue(sessionToken, forHTTPHeaderField: "X-BikeComputer-Transfer-Token")
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.upload(for: request, from: body ?? Data())
        guard let http = response as? HTTPURLResponse else {
            throw FirmwareUpdateError.serverError("Device did not return HTTP")
        }
        guard (200..<300).contains(http.statusCode) else {
            if let message = Self.errorMessage(from: data) {
                throw FirmwareUpdateError.serverError(message)
            }
            throw FirmwareUpdateError.serverError("Device firmware request failed")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func errorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any] else {
            return nil
        }
        let code = error["code"] as? String ?? "error"
        let message = error["message"] as? String ?? ""
        return message.isEmpty ? code : "\(code): \(message)"
    }
}
