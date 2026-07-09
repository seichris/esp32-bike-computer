//
//  BikeComputerCoordinator.swift
//  BikeComputer
//
//  Central coordinator managing all app subsystems
//  Implements coordinator pattern to eliminate circular dependencies
//

import Foundation
import SwiftUI
import MapKit
import Combine
import CoreLocation

/// Main coordinator for the Bike Computer app
/// Manages BLE, Navigation, Location, and HealthKit subsystems
class BikeComputerCoordinator: ObservableObject {

    // MARK: - Private Managers (Implementation Details)

    let bleManager = BLEManager()  // Accessible for settings view
    let firmwareUpdateManager = FirmwareUpdateManager()
    private let navEngine = NavigationEngine()
    private let locationManager = CurrentLocationManager()
    private let healthKitManager = HealthKitManager()

    // MARK: - Published State (UI Observable)

    // BLE Connection
    @Published var isConnected: Bool = false
    @Published var peripheralName: String = ""
    @Published var hardwareLabel: String = ""
    @Published var signalStrength: Int = 0

    // Navigation
    @Published var isNavigating: Bool = false
    @Published var currentInstruction: String = "Ready to Navigate"
    @Published var distanceToManeuver: Int = 0
    @Published var currentIconID: Int = NavigationIconID.straight
    @Published var currentRoute: MKRoute?
    @Published var currentFallbackRoutePolyline: MKPolyline?
    @Published var isSimulationMode: Bool = false
    @Published var simulatedPosition: CLLocationCoordinate2D?
    @Published var routeRemainingDistance: CLLocationDistance?
    @Published var routeRemainingTime: TimeInterval?
    @Published var expectedArrivalDate: Date?

    // Workout
    @Published var isWorkoutActive: Bool = false
    @Published var isHealthKitAuthorized: Bool = false
    @Published var isHealthKitAvailable: Bool = false
    @Published var workoutElapsedTime: TimeInterval = 0
    @Published var currentSpeedKmh: Double = 0
    @Published var distanceKm: Double = 0
    @Published var heartRate: Int?
    @Published var formattedElapsedTime: String = "00:00"

    // Location
    @Published var currentLocation: CLLocation?
    @Published var currentAddress: String = "Current Location"
    @Published var locationAuthorizationStatus: CLAuthorizationStatus = .notDetermined

    // Route Calculation
    @Published var routeCalculation = RouteCalculationState()

    // Alerts
    @Published var alert = AlertState()

    // UI State
    @Published var selectedView: Int = 0  // 0 = map, 1 = navigation+workout

    // MARK: - Private State

    private var cancellables = Set<AnyCancellable>()
    private var ongoingSourceSearch: MKLocalSearch?
    private var ongoingDestinationSearch: MKLocalSearch?
    private var ongoingDirections: MKDirections?
    private var transportType: MKDirectionsTransportType = RouteTransportTypes.cycling

    // MARK: - Initialization

    init() {
        setupManagerBindings()
        setupManagers()
    }

    // MARK: - Setup

    private func setupManagerBindings() {
        // Bind BLE manager state
        bleManager.$isConnected
            .assign(to: &$isConnected)

        bleManager.$peripheralName
            .assign(to: &$peripheralName)

        bleManager.$hardwareLabel
            .assign(to: &$hardwareLabel)

        bleManager.$signalStrength
            .assign(to: &$signalStrength)

        // Bind navigation engine state
        navEngine.$isNavigating
            .sink { [weak self] navigating in
                guard let self = self else { return }
                self.isNavigating = navigating
                self.locationManager.setNavigating(navigating && !self.navEngine.isSimulationMode)
            }
            .store(in: &cancellables)

        navEngine.$isSimulationMode
            .assign(to: &$isSimulationMode)

        navEngine.$simulatedPosition
            .assign(to: &$simulatedPosition)

        navEngine.$currentInstruction
            .assign(to: &$currentInstruction)

        navEngine.$distanceToManeuver
            .assign(to: &$distanceToManeuver)

        navEngine.$currentIconID
            .assign(to: &$currentIconID)

        navEngine.$routeRemainingDistance
            .assign(to: &$routeRemainingDistance)

        navEngine.$routeRemainingTime
            .assign(to: &$routeRemainingTime)

        navEngine.$expectedArrivalDate
            .assign(to: &$expectedArrivalDate)

        // Bind health kit manager state
        healthKitManager.$isAuthorized
            .assign(to: &$isHealthKitAuthorized)

        healthKitManager.$isHealthKitAvailable
            .assign(to: &$isHealthKitAvailable)

        healthKitManager.$isWorkoutActive
            .sink { [weak self] active in
                self?.isWorkoutActive = active
                self?.locationManager.updateLocationTracking()
            }
            .store(in: &cancellables)

        healthKitManager.$workoutElapsedTime
            .assign(to: &$workoutElapsedTime)

        healthKitManager.$currentSpeed
            .map { $0 * 3.6 }
            .assign(to: &$currentSpeedKmh)

        healthKitManager.$distanceTraveled
            .map { $0 / 1000.0 }
            .assign(to: &$distanceKm)

        healthKitManager.$heartRate
            .map { $0 > 0 ? Int($0) : nil }
            .assign(to: &$heartRate)

        healthKitManager.$workoutElapsedTime
            .map { TimeFormatter.format($0) }
            .assign(to: &$formattedElapsedTime)

        // Bind location manager state
        locationManager.$currentLocation
            .assign(to: &$currentLocation)

        locationManager.$currentLocation
            .compactMap { $0 }
            .sink { [weak self] location in
                self?.navEngine.processExternalLocation(location)
            }
            .store(in: &cancellables)

        bleManager.$isNavigationReady
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in
                guard let self else { return }
                if let location = self.locationManager.currentLocation {
                    self.navEngine.processExternalLocation(location)
                }
                self.requestMapTransferStatusAfterDeviceRefresh()
                self.bleManager.requestDeviceTransferStatus()
                self.scheduleFirmwareUpdateCheckAfterDeviceRefresh()
            }
            .store(in: &cancellables)

        locationManager.$currentLocation
            .compactMap { $0 }
            .combineLatest(bleManager.$isNavigationReady)
            .filter { _, ready in ready }
            .throttle(for: .seconds(8), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _, _ in
                self?.requestMapTransferStatusAfterDeviceRefresh()
            }
            .store(in: &cancellables)

        locationManager.$currentAddress
            .assign(to: &$currentAddress)

        locationManager.$authorizationStatus
            .assign(to: &$locationAuthorizationStatus)

        // Current firmware exposes only the navigation packet characteristic.
    }

    private func setupManagers() {
        // Wire up inter-manager dependencies
        navEngine.setBLEManager(bleManager)
        locationManager.healthKitManager = healthKitManager
        healthKitManager.locationManager = locationManager

        // Start BLE operations
        bleManager.startScanning()

        // Enable location tracking for map view
        locationManager.setViewingMap(true)
    }

    // MARK: - Public API: BLE

    func disconnect() {
        bleManager.disconnect()
    }

    func reconnect() {
        bleManager.reconnect()
    }

    // MARK: - Public API: Navigation

    func startNavigation(from source: RouteEndpoint, to destination: RouteEndpoint, transportType: MKDirectionsTransportType, isTestMode: Bool = false) {
        self.transportType = transportType
        calculateRoute(from: source, to: destination, isTestMode: isTestMode)
    }

    func startNavigation(from source: String, to destination: String, transportType: MKDirectionsTransportType, isTestMode: Bool = false) {
        startNavigation(from: .query(source), to: .query(destination), transportType: transportType, isTestMode: isTestMode)
    }

    func stopNavigation() {
        navEngine.stopNavigation()
        currentRoute = nil
        currentFallbackRoutePolyline = nil
        locationManager.setNavigating(false)
        selectedView = 0
    }

    func handleDestinationSelection(coordinate: CLLocationCoordinate2D, mapLocation: CLLocation?) {
        guard let sourceLocation = currentLocation ?? mapLocation else {
            alert.message = "Unable to determine your current location. Please enable location services."
            alert.isShowing = true
            return
        }

        let routeSourceLocation = CoordinateConverter.mapKitRouteLocation(fromGPSLocation: sourceLocation)
        transportType = RouteTransportTypes.cycling
        routeCalculation.isCalculating = true
        routeCalculation.status = "Resolving route points..."

        resolveCoordinateForRoute(routeSourceLocation.coordinate, fallbackName: "Current Location") { [weak self] source in
            guard let self else { return }
            self.resolveCoordinateForRoute(coordinate, fallbackName: "Selected Location") { [weak self] destination in
                guard let self else { return }
                self.calculateRoute(from: .mapItem(source), to: .mapItem(destination))
            }
        }
    }

    // MARK: - Public API: Workout

    func startWorkout() {
        healthKitManager.startBikeWorkout()
    }

    func endWorkout() {
        healthKitManager.endBikeWorkout()
    }

    // MARK: - Public API: Location

    func setViewingMap(_ viewing: Bool) {
        locationManager.setViewingMap(viewing)
    }

    func requestLocationAuthorization() {
        locationManager.requestWhenInUseAuthorization()
    }

    var isLocationAuthorized: Bool {
        locationAuthorizationStatus == .authorizedAlways ||
            locationAuthorizationStatus == .authorizedWhenInUse
    }

    private func requestMapTransferStatusAfterDeviceRefresh() {
        bleManager.requestMapTransferStatus()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.bleManager.isNavigationReady else { return }
            self.bleManager.requestMapTransferStatus()
        }
    }

    private func scheduleFirmwareUpdateCheckAfterDeviceRefresh() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.runAutomaticFirmwareUpdateCheck(attempt: 0)
        }
    }

    private func runAutomaticFirmwareUpdateCheck(attempt: Int) {
        guard bleManager.isNavigationReady else { return }
        guard isFirmwareMetadataReadyForUpdateCheck else {
            if attempt < 5 {
                bleManager.requestDeviceTransferStatus()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    self?.runAutomaticFirmwareUpdateCheck(attempt: attempt + 1)
                }
            }
            return
        }
        firmwareUpdateManager.checkForUpdateAutomatically(bleManager: bleManager)
    }

    private var isFirmwareMetadataReadyForUpdateCheck: Bool {
        !bleManager.firmwareTarget.isEmpty &&
        !bleManager.firmwareVersion.isEmpty &&
        bleManager.firmwareBuild > 0 &&
        !bleManager.firmwareGitSha.isEmpty
    }

    // MARK: - Public API: UI State

    func updateSelectedView(_ view: Int) {
        selectedView = view
        locationManager.setViewingMap(view == 0)
    }
}

// MARK: - Route Calculation (Private Implementation)

extension BikeComputerCoordinator {

    private func calculateRoute(from source: RouteEndpoint, to destination: RouteEndpoint, isTestMode: Bool = false) {
        print("Starting route calculation")

        // Cancel any ongoing searches
        ongoingSourceSearch?.cancel()
        ongoingDestinationSearch?.cancel()
        ongoingDirections?.cancel()

        routeCalculation.isCalculating = true
        routeCalculation.status = "Searching for locations..."

        resolveEndpoint(source, role: "Starting location") { [weak self] sourceItem in
            guard let self = self, let sourceItem = sourceItem else { return }

            self.routeCalculation.status = "Finding destination..."
            self.resolveEndpoint(destination, role: "Destination") { [weak self] destinationItem in
                guard let self = self, let destinationItem = destinationItem else { return }

                self.routeCalculation.status = "Calculating route..."
                self.requestDirections(from: sourceItem, to: destinationItem, isTestMode: isTestMode)
            }
        }
    }

    private func resolveEndpoint(_ endpoint: RouteEndpoint, role: String, completion: @escaping (MKMapItem?) -> Void) {
        switch endpoint {
        case .currentLocation:
            guard let currentLoc = currentLocation else {
                routeCalculation.status = "Current location unavailable"
                alert.message = "Unable to determine your current location. Please enable location services."
                alert.isShowing = true
                finishRouteCalculationAfterDelay()
                completion(nil)
                return
            }

            let routeLocation = CoordinateConverter.mapKitRouteLocation(fromGPSLocation: currentLoc)
            let item = MKMapItem(placemark: MKPlacemark(coordinate: routeLocation.coordinate))
            item.name = "Current Location"
            print("Using current location: \(routeLocation.coordinate.latitude), \(routeLocation.coordinate.longitude)")
            completion(item)

        case .mapItem(let item):
            print("\(role): \(item.name ?? "Map Item") at \(item.placemark.coordinate.latitude), \(item.placemark.coordinate.longitude)")
            completion(item)

        case .query(let query):
            let searchRequest = MKLocalSearch.Request()
            searchRequest.naturalLanguageQuery = query
            if let currentLocation {
                let routeLocation = CoordinateConverter.mapKitRouteLocation(fromGPSLocation: currentLocation)
                searchRequest.region = MKCoordinateRegion(
                    center: routeLocation.coordinate,
                    latitudinalMeters: 50000,
                    longitudinalMeters: 50000
                )
            }

            let search = MKLocalSearch(request: searchRequest)
            if role == "Starting location" {
                ongoingSourceSearch = search
            } else {
                ongoingDestinationSearch = search
            }

            search.start { [weak self] response, error in
                guard let self = self else { return }

                if role == "Starting location" {
                    self.ongoingSourceSearch = nil
                } else {
                    self.ongoingDestinationSearch = nil
                }

                if let error = error {
                    print("Error searching for \(role): \(error.localizedDescription)")
                    self.routeCalculation.status = "\(role) not found"
                    self.finishRouteCalculationAfterDelay()
                    completion(nil)
                    return
                }

                guard let item = response?.mapItems.first else {
                    print("No results for \(role)")
                    self.routeCalculation.status = "\(role) not found"
                    self.finishRouteCalculationAfterDelay()
                    completion(nil)
                    return
                }

                print("\(role) found: \(item.name ?? "Unknown") at \(item.placemark.coordinate.latitude), \(item.placemark.coordinate.longitude)")
                completion(item)
            }
        }
    }

    private func resolveCoordinateForRoute(
        _ coordinate: CLLocationCoordinate2D,
        fallbackName: String,
        completion: @escaping (MKMapItem) -> Void
    ) {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        CLGeocoder().reverseGeocodeLocation(location) { [weak self] placemarks, error in
            if let placemark = placemarks?.first {
                let item = MKMapItem(placemark: MKPlacemark(placemark: placemark))
                item.name = placemark.name ?? fallbackName
                print("\(fallbackName) resolved by reverse geocode: \(self?.routeAttemptDescription(for: item) ?? fallbackName)")
                completion(item)
                return
            }

            if let error {
                print("Reverse geocode failed for \(fallbackName): \(error.localizedDescription)")
            }

            self?.resolveCoordinateByLocalSearch(
                coordinate,
                fallbackName: fallbackName,
                completion: completion
            )
        }
    }

    private func resolveCoordinateByLocalSearch(
        _ coordinate: CLLocationCoordinate2D,
        fallbackName: String,
        completion: @escaping (MKMapItem) -> Void
    ) {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = fallbackName == "Current Location" ? "road" : "point of interest"
        request.resultTypes = [.address, .pointOfInterest]
        request.region = MKCoordinateRegion(
            center: coordinate,
            latitudinalMeters: 800,
            longitudinalMeters: 800
        )

        MKLocalSearch(request: request).start { [weak self] response, error in
            let targetPoint = MKMapPoint(coordinate)
            let nearest = response?.mapItems
                .filter { CLLocationCoordinate2DIsValid($0.placemark.coordinate) }
                .min {
                    MKMapPoint($0.placemark.coordinate).distance(to: targetPoint) <
                        MKMapPoint($1.placemark.coordinate).distance(to: targetPoint)
                }

            if let nearest {
                print("\(fallbackName) resolved by local search: \(self?.routeAttemptDescription(for: nearest) ?? fallbackName)")
                completion(nearest)
                return
            }

            if let error {
                print("Local search snap failed for \(fallbackName): \(error.localizedDescription)")
            }

            let fallback = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
            fallback.name = fallbackName
            print("\(fallbackName) using raw coordinate fallback: \(self?.routeAttemptDescription(for: fallback) ?? fallbackName)")
            completion(fallback)
        }
    }

    private func finishRouteCalculationAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            self.routeCalculation.isCalculating = false
            self.routeCalculation.status = ""
        }
    }

    private func requestDirections(
        from sourceItem: MKMapItem,
        to destinationItem: MKMapItem,
        isTestMode: Bool,
        fallbackTransportTypes: [MKDirectionsTransportType]? = nil
    ) {
        let requestedTransportType = self.transportType
        let remainingFallbacks = fallbackTransportTypes ?? routeFallbackTransportTypes(after: requestedTransportType)
        let request = MKDirections.Request()
        request.source = sourceItem
        request.destination = destinationItem
        request.transportType = requestedTransportType
        request.requestsAlternateRoutes = false

        let sourceDescription = routeAttemptDescription(for: sourceItem)
        let destinationDescription = routeAttemptDescription(for: destinationItem)
        let transportDescription = routeTransportDescription(requestedTransportType)
        print("Route attempt: \(transportDescription) from \(sourceDescription) to \(destinationDescription)")
        routeCalculation.status = "Calculating \(transportDescription): \(sourceItem.name ?? "Start") -> \(destinationItem.name ?? "Destination")"

        let directions = MKDirections(request: request)
        self.ongoingDirections = directions
        directions.calculate { [weak self] response, error in
            guard let self = self else { return }
            self.ongoingDirections = nil

            if let error = error {
                print("Error calculating route from \(sourceDescription) to \(destinationDescription): \(error.localizedDescription)")
                if let nextTransportType = remainingFallbacks.first {
                    let nextFallbacks = Array(remainingFallbacks.dropFirst())
                    let nextTransportDescription = self.routeTransportDescription(nextTransportType)
                    print("\(transportDescription.capitalized) route unavailable; retrying with \(nextTransportDescription)")
                    self.transportType = nextTransportType
                    self.routeCalculation.status = "\(transportDescription.capitalized) unavailable here; trying \(nextTransportDescription)..."
                    self.requestDirections(
                        from: sourceItem,
                        to: destinationItem,
                        isTestMode: isTestMode,
                        fallbackTransportTypes: nextFallbacks
                    )
                    return
                }

                self.startSimpleFallbackRoute(
                    from: sourceItem,
                    to: destinationItem,
                    isTestMode: isTestMode,
                    reason: error.localizedDescription
                )
                return
            }

            guard let route = response?.routes.first else {
                print("No routes found")
                self.routeCalculation.status = "No route available"
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    self.routeCalculation.isCalculating = false
                    self.routeCalculation.status = ""
                }
                return
            }

            print("Route calculated successfully!")
            print("Distance: \(route.distance)m, ETA: \(route.expectedTravelTime)s")
            print("Steps: \(route.steps.count)")

            self.routeCalculation.status = "Starting navigation..."

            // Store the route for map display
            self.currentRoute = route
            self.currentFallbackRoutePolyline = nil

            // Start navigation from the same source MapKit used to calculate the route.
            self.navEngine.startNavigation(
                with: route,
                isTestMode: isTestMode,
                initialLocation: RouteInitialLocation.location(for: sourceItem.placemark.coordinate)
            )

            // Enable location tracking for navigation
            self.locationManager.setNavigating(!isTestMode)

            // Show navigation+workout view
            self.selectedView = 1

            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.routeCalculation.isCalculating = false
                self.routeCalculation.status = ""
            }
        }
    }

    private func startSimpleFallbackRoute(
        from sourceItem: MKMapItem,
        to destinationItem: MKMapItem,
        isTestMode: Bool,
        reason: String
    ) {
        let source = sourceItem.placemark.coordinate
        let destination = destinationItem.placemark.coordinate
        let coordinates = simpleFallbackCoordinates(from: source, to: destination)
        let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
        let distance = fallbackDistance(for: coordinates)

        print("Using simple fallback route after MapKit directions failed: \(reason)")
        currentRoute = nil
        currentFallbackRoutePolyline = polyline
        routeCalculation.status = "Using simple route fallback..."

        navEngine.startFallbackNavigation(
            polyline: polyline,
            distance: distance,
            isTestMode: isTestMode,
            initialLocation: RouteInitialLocation.location(for: source)
        )

        locationManager.setNavigating(!isTestMode)
        selectedView = 1

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.routeCalculation.isCalculating = false
            self.routeCalculation.status = ""
        }
    }

    private func simpleFallbackCoordinates(
        from source: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D
    ) -> [CLLocationCoordinate2D] {
        if isInTokyoScreenshotArea(source) && isInTokyoScreenshotArea(destination) {
            return tokyoScreenshotFallbackCoordinates(from: source, to: destination)
        }

        return curvedFallbackCoordinates(from: source, to: destination)
    }

    private func isInTokyoScreenshotArea(_ coordinate: CLLocationCoordinate2D) -> Bool {
        coordinate.latitude >= 35.62 &&
            coordinate.latitude <= 35.72 &&
            coordinate.longitude >= 139.65 &&
            coordinate.longitude <= 139.78
    }

    private func tokyoScreenshotFallbackCoordinates(
        from source: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D
    ) -> [CLLocationCoordinate2D] {
        let anchors = [
            CLLocationCoordinate2D(latitude: 35.65950, longitude: 139.70050),
            CLLocationCoordinate2D(latitude: 35.66005, longitude: 139.70170),
            CLLocationCoordinate2D(latitude: 35.66072, longitude: 139.70308),
            CLLocationCoordinate2D(latitude: 35.66142, longitude: 139.70445),
            CLLocationCoordinate2D(latitude: 35.66212, longitude: 139.70586),
            CLLocationCoordinate2D(latitude: 35.66296, longitude: 139.70750),
            CLLocationCoordinate2D(latitude: 35.66356, longitude: 139.70902),
            CLLocationCoordinate2D(latitude: 35.66405, longitude: 139.71035),
            CLLocationCoordinate2D(latitude: 35.66436, longitude: 139.71164)
        ]

        let shiftedAnchors = anchors.map { anchor in
            CLLocationCoordinate2D(
                latitude: source.latitude + (anchor.latitude - anchors[0].latitude),
                longitude: source.longitude + (anchor.longitude - anchors[0].longitude)
            )
        }

        guard let last = shiftedAnchors.last else { return curvedFallbackCoordinates(from: source, to: destination) }
        let deltaLat = destination.latitude - last.latitude
        let deltaLon = destination.longitude - last.longitude
        return shiftedAnchors.enumerated().map { index, point in
            let progress = Double(index) / Double(max(shiftedAnchors.count - 1, 1))
            return CLLocationCoordinate2D(
                latitude: point.latitude + deltaLat * progress,
                longitude: point.longitude + deltaLon * progress
            )
        }
    }

    private func curvedFallbackCoordinates(
        from source: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D
    ) -> [CLLocationCoordinate2D] {
        let steps = 12
        let deltaLat = destination.latitude - source.latitude
        let deltaLon = destination.longitude - source.longitude
        let lateralScale = 0.18

        return (0...steps).map { index in
            let t = Double(index) / Double(steps)
            let ease = t * t * (3 - 2 * t)
            let offset = sin(t * .pi) * lateralScale
            return CLLocationCoordinate2D(
                latitude: source.latitude + deltaLat * ease - deltaLon * offset,
                longitude: source.longitude + deltaLon * ease + deltaLat * offset
            )
        }
    }

    private func fallbackDistance(for coordinates: [CLLocationCoordinate2D]) -> CLLocationDistance {
        guard coordinates.count > 1 else { return 0 }

        return zip(coordinates, coordinates.dropFirst()).reduce(0) { total, segment in
            let start = CLLocation(latitude: segment.0.latitude, longitude: segment.0.longitude)
            let end = CLLocation(latitude: segment.1.latitude, longitude: segment.1.longitude)
            return total + start.distance(from: end)
        }
    }

    private func routeFallbackTransportTypes(after type: MKDirectionsTransportType) -> [MKDirectionsTransportType] {
        if type == RouteTransportTypes.cycling {
            return [.walking, .automobile, .any]
        }

        switch type {
        case .walking:
            return [.automobile, .any]
        case .automobile:
            return [.any]
        default:
            return []
        }
    }

    private func routeAttemptDescription(for item: MKMapItem) -> String {
        let coordinate = item.placemark.coordinate
        let name = item.name ?? item.placemark.name ?? "Unnamed"
        return "\(name) (\(String(format: "%.6f", coordinate.latitude)), \(String(format: "%.6f", coordinate.longitude)))"
    }

    private func routeTransportDescription(_ type: MKDirectionsTransportType) -> String {
        if type == RouteTransportTypes.cycling {
            return "cycling"
        }

        switch type {
        case .automobile:
            return "driving"
        case .walking:
            return "walking"
        default:
            return "transport \(type.rawValue)"
        }
    }
}
