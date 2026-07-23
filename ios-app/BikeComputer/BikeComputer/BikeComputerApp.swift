//
//  BikeComputerApp.swift
//  BikeComputer
//
//  Main iOS App Entry Point
//

import SwiftUI

@main
struct BikeComputerApp: App {
    
    // Ensure app continues running in background for navigation
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            ContentView(
                workoutMirrorManager: appDelegate.workoutMirrorManager,
                coordinator: appDelegate.coordinator
            )
        }
    }
}

// MARK: - App Delegate for Background Tasks

@MainActor
class AppDelegate: NSObject, UIApplicationDelegate {
    let workoutMirrorManager = WorkoutMirrorManager()
    let locationManager = CurrentLocationManager()
    lazy var coordinator = BikeComputerCoordinator(
        destinationStore: SavedDestinationStore(),
        workoutMetricsStore: workoutMirrorManager.store,
        locationManager: locationManager
    )

    override init() {
        super.init()
        locationManager.bindWorkoutMetricsStore(
            workoutMirrorManager.store
        )
    }
    
    func application(_ application: UIApplication, 
                    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        
        // Configure for background location updates
        print("BikeComputer app launched")
        _ = coordinator
        workoutMirrorManager.installMirroringHandler()
        
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        coordinator.applicationDidBecomeActive()
    }
    
    func applicationDidEnterBackground(_ application: UIApplication) {
        coordinator.setViewingMap(false)
        print("App entered background - navigation continues")
    }
    
    func applicationWillEnterForeground(_ application: UIApplication) {
        print("App entering foreground")
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == BackgroundMapUploadCoordinator.sessionIdentifier else {
            completionHandler()
            return
        }
        BackgroundMapUploadCoordinator.shared.handleEvents(
            completionHandler: completionHandler
        )
    }
}
