//
//  AppModels.swift
//  BikeComputer
//
//  Data models for app state
//

import Foundation
import CoreLocation
import MapKit
import Combine

/// Route calculation state
struct RouteCalculationState {
    var isCalculating: Bool = false
    var status: String = ""
}

/// Alert state
struct AlertState {
    var isShowing: Bool = false
    var message: String = ""
}

/// Navigation icon IDs shared with the ESP32 firmware.
enum NavigationIconID {
    static let straight = 1
    static let left = 2
    static let right = 3
    static let uTurn = 4
}

enum RouteEndpoint {
    case currentLocation
    case mapItem(MKMapItem)
    case query(String)
}

/// A destination that can be shown again in recents or favorites.
struct SavedDestination: Codable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let latitude: CLLocationDegrees?
    let longitude: CLLocationDegrees?

    init(
        id: UUID = UUID(),
        name: String,
        coordinate: CLLocationCoordinate2D? = nil
    ) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.latitude = coordinate?.latitude
        self.longitude = coordinate?.longitude
    }

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        return CLLocationCoordinate2DIsValid(coordinate) ? coordinate : nil
    }

    var routeEndpoint: RouteEndpoint {
        guard let coordinate else { return .query(name) }

        let item: MKMapItem
        if #available(iOS 26.0, macOS 26.0, *) {
            item = MKMapItem(
                location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude),
                address: nil
            )
        } else {
            item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        }
        item.name = name
        return .mapItem(item)
    }

    fileprivate func matches(_ other: SavedDestination) -> Bool {
        if name.caseInsensitiveCompare(other.name) == .orderedSame {
            return true
        }

        guard let coordinate, let otherCoordinate = other.coordinate else { return false }
        return abs(coordinate.latitude - otherCoordinate.latitude) < 0.00001 &&
            abs(coordinate.longitude - otherCoordinate.longitude) < 0.00001
    }
}

/// UserDefaults-backed destination history shared by map pins and address search.
@MainActor
final class SavedDestinationStore: ObservableObject {
    @Published private(set) var favoriteDestinations: [SavedDestination]
    @Published private(set) var recentDestinations: [SavedDestination]

    private static let favoritesKey = "routeInput.favoriteDestinations"
    private static let recentsKey = "routeInput.recentDestinations"
    private static let legacyRecentsKey = "routeInput.recentDestinationSearches"

    private let defaults: UserDefaults
    private let recentLimit: Int
    private let encoder = JSONEncoder()

    init(defaults: UserDefaults = .standard, recentLimit: Int = 5) {
        self.defaults = defaults
        self.recentLimit = max(recentLimit, 1)

        favoriteDestinations = Self.loadDestinations(forKey: Self.favoritesKey, from: defaults)

        if let storedRecents = Self.loadDestinationData(forKey: Self.recentsKey, from: defaults) {
            recentDestinations = Array(storedRecents.prefix(self.recentLimit))
        } else {
            recentDestinations = Array(
                (defaults.stringArray(forKey: Self.legacyRecentsKey) ?? [])
                    .map { SavedDestination(name: $0) }
                    .filter { !$0.name.isEmpty }
                    .prefix(self.recentLimit)
            )
        }

        persist()
    }

    var nonFavoriteRecentDestinations: [SavedDestination] {
        recentDestinations.filter { destination in
            !favoriteDestinations.contains { $0.matches(destination) }
        }
    }

    func addRecent(_ destination: SavedDestination) {
        guard let destination = cleaned(destination) else { return }

        recentDestinations.removeAll { $0.matches(destination) }
        recentDestinations.insert(destination, at: 0)
        recentDestinations = Array(recentDestinations.prefix(recentLimit))
        persist()
    }

    func isFavorite(_ destination: SavedDestination) -> Bool {
        favoriteDestinations.contains { $0.matches(destination) }
    }

    @discardableResult
    func toggleFavorite(_ destination: SavedDestination) -> Bool {
        guard let destination = cleaned(destination) else { return false }

        if let index = favoriteDestinations.firstIndex(where: { $0.matches(destination) }) {
            favoriteDestinations.remove(at: index)
            persist()
            return false
        }

        favoriteDestinations.insert(destination, at: 0)
        persist()
        return true
    }

    private func cleaned(_ destination: SavedDestination) -> SavedDestination? {
        let name = destination.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return SavedDestination(id: destination.id, name: name, coordinate: destination.coordinate)
    }

    private func persist() {
        if let data = try? encoder.encode(favoriteDestinations) {
            defaults.set(data, forKey: Self.favoritesKey)
        }
        if let data = try? encoder.encode(recentDestinations) {
            defaults.set(data, forKey: Self.recentsKey)
        }

        // Keep the previous string-only key current so app downgrades retain useful history.
        defaults.set(recentDestinations.map(\.name), forKey: Self.legacyRecentsKey)
    }

    private static func loadDestinations(forKey key: String, from defaults: UserDefaults) -> [SavedDestination] {
        loadDestinationData(forKey: key, from: defaults) ?? []
    }

    private static func loadDestinationData(forKey key: String, from defaults: UserDefaults) -> [SavedDestination]? {
        guard let data = defaults.data(forKey: key),
              let destinations = try? JSONDecoder().decode([SavedDestination].self, from: data) else {
            return nil
        }
        return destinations.filter { !$0.name.isEmpty }
    }
}
