//
//  OfflineMapPlatform.swift
//  BikeComputer
//
//  Backend models for offline map cut-outs.
//

import CoreLocation
import Foundation

struct OfflineMapBounds: Codable, Equatable {
    let minLon: Double
    let minLat: Double
    let maxLon: Double
    let maxLat: Double

    init(minLon: Double, minLat: Double, maxLon: Double, maxLat: Double) {
        self.minLon = minLon
        self.minLat = minLat
        self.maxLon = maxLon
        self.maxLat = maxLat
    }

    init(center: CLLocationCoordinate2D, sideLengthKm: Double) {
        let halfSideKm = max(sideLengthKm, 0.1) / 2
        let latDelta = halfSideKm / 111.32
        let lonScale = max(cos(center.latitude * .pi / 180), 0.01)
        let lonDelta = halfSideKm / (111.32 * lonScale)
        self.init(
            minLon: max(center.longitude - lonDelta, -180),
            minLat: max(center.latitude - latDelta, -85.05112878),
            maxLon: min(center.longitude + lonDelta, 180),
            maxLat: min(center.latitude + latDelta, 85.05112878)
        )
    }

    var apiArray: [Double] {
        [minLon, minLat, maxLon, maxLat]
    }
}

struct OfflineMapJobRequest: Encodable, Equatable {
    let mode: String
    let bbox: [Double]?
    let geometry: GeoJSONGeometry?
    let route: GeoJSONGeometry?
    let corridorWidthM: Double?

    static func customBBox(_ bounds: OfflineMapBounds) -> OfflineMapJobRequest {
        OfflineMapJobRequest(
            mode: "custom_bbox",
            bbox: bounds.apiArray,
            geometry: nil,
            route: nil,
            corridorWidthM: nil
        )
    }

    static func customPolygon(ring: [CLLocationCoordinate2D]) -> OfflineMapJobRequest {
        OfflineMapJobRequest(
            mode: "custom_polygon",
            bbox: nil,
            geometry: GeoJSONGeometry.polygon(ring: ring),
            route: nil,
            corridorWidthM: nil
        )
    }

    static func routeCorridor(route: [CLLocationCoordinate2D], widthMeters: Double) -> OfflineMapJobRequest {
        OfflineMapJobRequest(
            mode: "route_corridor",
            bbox: nil,
            geometry: nil,
            route: GeoJSONGeometry.lineString(route),
            corridorWidthM: widthMeters
        )
    }
}

struct GeoJSONGeometry: Codable, Equatable {
    let type: String
    let coordinates: GeoJSONCoordinates

    static func polygon(ring: [CLLocationCoordinate2D]) -> GeoJSONGeometry {
        var closed = ring
        if let first = ring.first, let last = ring.last,
           first.latitude != last.latitude || first.longitude != last.longitude {
            closed.append(first)
        }
        return GeoJSONGeometry(
            type: "Polygon",
            coordinates: .polygon([closed.map { [$0.longitude, $0.latitude] }])
        )
    }

    static func lineString(_ points: [CLLocationCoordinate2D]) -> GeoJSONGeometry {
        GeoJSONGeometry(
            type: "LineString",
            coordinates: .lineString(points.map { [$0.longitude, $0.latitude] })
        )
    }
}

enum GeoJSONCoordinates: Codable, Equatable {
    case lineString([[Double]])
    case polygon([[[Double]]])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let polygon = try? container.decode([[[Double]]].self) {
            self = .polygon(polygon)
            return
        }
        self = .lineString(try container.decode([[Double]].self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .lineString(let points):
            try container.encode(points)
        case .polygon(let rings):
            try container.encode(rings)
        }
    }
}

struct OfflineMapJob: Decodable, Equatable {
    let jobId: String
    let status: String
    let error: String?
    let mapId: String?
    let packPath: String?
    let geometry: OfflineMapJobGeometry?
    let sourceRegion: OfflineMapSourceRegion?

    var isTerminal: Bool {
        ["ready", "failed", "expired", "cancelled"].contains(status)
    }
}

struct OfflineMapJobGeometry: Decodable, Equatable {
    let mode: String
    let bounds: [Double]
    let areaKm2: Double
    let vertexCount: Int
    let routePointCount: Int
}

struct OfflineMapSourceRegion: Decodable, Equatable {
    let id: String
    let name: String
    let provider: String
}

struct OfflineMapDownloadURL: Decodable, Equatable {
    let mapId: String
    let url: String
    let expiresAt: Int
    let expiresInSeconds: Int
}

enum OfflineMapPlatformError: LocalizedError {
    case invalidBaseURL
    case missingMapId
    case invalidResponse
    case serverStatus(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Invalid map server URL"
        case .missingMapId:
            return "Map pack is not ready"
        case .invalidResponse:
            return "Map server returned an invalid response"
        case .serverStatus(let status, let body):
            return "Map server returned \(status): \(body)"
        }
    }
}

struct OfflineMapPlatformClient {
    let baseURL: URL
    let apiToken: String?
    var session: URLSession = .shared

    init(baseURL: URL, apiToken: String? = nil) {
        self.baseURL = baseURL
        self.apiToken = apiToken?.isEmpty == true ? nil : apiToken
    }

    func createJob(_ jobRequest: OfflineMapJobRequest) async throws -> OfflineMapJob {
        try await send(path: "/v1/map-jobs", method: "POST", body: jobRequest)
    }

    func job(id: String) async throws -> OfflineMapJob {
        try await send(path: "/v1/map-jobs/\(id)", method: "GET", body: Optional<Data>.none)
    }

    func downloadURL(mapId: String) async throws -> URL {
        let response: OfflineMapDownloadURL = try await send(
            path: "/v1/map-packs/\(mapId)/download-url",
            method: "POST",
            body: Optional<Data>.none
        )
        return try absoluteURL(for: response.url, baseURL: baseURL)
    }

    static func makeCreateJobURLRequest(
        baseURL: URL,
        apiToken: String?,
        jobRequest: OfflineMapJobRequest
    ) throws -> URLRequest {
        var request = URLRequest(url: try endpointURL(baseURL: baseURL, path: "/v1/map-jobs"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let apiToken, !apiToken.isEmpty {
            request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder.offlineMap.encode(jobRequest)
        return request
    }

    private func send<Body: Encodable, Response: Decodable>(
        path: String,
        method: String,
        body: Body?
    ) async throws -> Response {
        var request = URLRequest(url: try Self.endpointURL(baseURL: baseURL, path: path))
        request.httpMethod = method
        if let apiToken {
            request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder.offlineMap.encode(body)
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OfflineMapPlatformError.invalidResponse
        }
        guard 200..<300 ~= http.statusCode else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw OfflineMapPlatformError.serverStatus(http.statusCode, bodyText)
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private static func endpointURL(baseURL: URL, path: String) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw OfflineMapPlatformError.invalidBaseURL
        }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpointPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [basePath, endpointPath].filter { !$0.isEmpty }.joined(separator: "/")
        guard let url = components.url else {
            throw OfflineMapPlatformError.invalidBaseURL
        }
        return url
    }

    private func absoluteURL(for value: String, baseURL: URL) throws -> URL {
        if let absolute = URL(string: value), absolute.scheme != nil {
            return absolute
        }
        guard let url = URL(string: value, relativeTo: baseURL)?.absoluteURL else {
            throw OfflineMapPlatformError.invalidResponse
        }
        return url
    }
}

extension JSONEncoder {
    static var offlineMap: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
