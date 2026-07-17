import SwiftUI

@main
struct BikeComputerWatchApp: App {
    var body: some Scene {
        WindowGroup {
            WatchWorkoutPlaceholderView()
        }
    }
}

private struct WatchWorkoutPlaceholderView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "bicycle")
                .font(.title2)
            Text("BikeComputer")
                .font(.headline)
            Text("Workout setup is ready")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}
