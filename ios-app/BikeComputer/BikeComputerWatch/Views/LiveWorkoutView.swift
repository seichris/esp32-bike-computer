import SwiftUI

struct LiveWorkoutView: View {
    @ObservedObject var manager: WatchWorkoutManager
    @State private var showsEndOptions = false

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                stateHeader

                if let finishError = manager.finishRequestError {
                    VStack(spacing: 5) {
                        Label(
                            finishErrorMessage(finishError),
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)

                        if finishError == .reconciliationFailed
                            || finishError == .saveFailed
                            || finishError == .identityMetadataFailed {
                            Button(manager.isDiscarding ? "Retry Recovery" : "Retry Save") {
                                manager.retryFinalization()
                            }
                            .font(.caption2)
                        }
                    }
                }

                Text(WorkoutValueFormatter.duration(manager.snapshot.elapsedTime?.value))
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .accessibilityLabel("Elapsed time")

                LazyVGrid(columns: columns, spacing: 8) {
                    metric(
                        title: "Heart",
                        value: WorkoutValueFormatter.heartRate(
                            manager.snapshot.currentHeartRate?.value
                        ),
                        unit: "BPM",
                        icon: "heart.fill",
                        color: .red
                    )
                    metric(
                        title: "Distance",
                        value: WorkoutValueFormatter.distance(
                            manager.snapshot.cyclingDistance?.value
                        ),
                        unit: WorkoutValueFormatter.distanceUnit(
                            manager.snapshot.cyclingDistance?.value
                        ),
                        icon: "point.topleft.down.to.point.bottomright.curvepath",
                        color: .green
                    )
                    metric(
                        title: "Speed",
                        value: WorkoutValueFormatter.speed(
                            manager.snapshot.currentSpeed?.value
                        ),
                        unit: "KM/H",
                        icon: "speedometer",
                        color: .cyan
                    )
                    metric(
                        title: "Energy",
                        value: WorkoutValueFormatter.energy(
                            manager.snapshot.activeEnergy?.value
                        ),
                        unit: "KCAL",
                        icon: "flame.fill",
                        color: .orange
                    )
                    metric(
                        title: "Power",
                        value: WorkoutValueFormatter.whole(
                            manager.snapshot.cyclingPower?.value
                        ),
                        unit: "W",
                        icon: "bolt.fill",
                        color: .yellow
                    )
                    metric(
                        title: "Cadence",
                        value: WorkoutValueFormatter.whole(
                            manager.snapshot.cyclingCadence?.value
                        ),
                        unit: "RPM",
                        icon: "arrow.triangle.2.circlepath",
                        color: .mint
                    )
                }

                HStack(spacing: 8) {
                    Button {
                        if manager.state == .paused {
                            manager.resume()
                        } else {
                            manager.pause()
                        }
                    } label: {
                        Image(systemName: manager.state == .paused ? "play.fill" : "pause.fill")
                    }
                    .tint(manager.state == .paused ? .green : .orange)
                    .disabled(![.running, .paused].contains(manager.state))
                    .accessibilityLabel(manager.state == .paused ? "Resume ride" : "Pause ride")

                    Button(role: .destructive) {
                        showsEndOptions = true
                    } label: {
                        Image(systemName: "stop.fill")
                    }
                    .disabled(manager.state == .ending)
                    .accessibilityLabel("End ride")
                }
            }
            .padding(.horizontal, 6)
        }
        .confirmationDialog("Finish this ride?", isPresented: $showsEndOptions) {
            Button("End and Save") {
                manager.endAndSave()
            }
            Button("Discard Workout", role: .destructive) {
                manager.discard()
            }
            Button("Keep Riding", role: .cancel) {}
        } message: {
            Text("Saving creates one workout in Health. Discarding saves nothing.")
        }
    }

    private var stateHeader: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(stateColor)
                .frame(width: 7, height: 7)
            Text(stateLabel)
                .font(.caption.weight(.semibold))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Workout \(stateLabel)")
    }

    private func metric(
        title: String,
        value: String,
        unit: String,
        icon: String,
        color: Color
    ) -> some View {
        VStack(spacing: 2) {
            Label(title, systemImage: icon)
                .font(.caption2)
                .foregroundStyle(color)
                .lineLimit(1)
            Text(value)
                .font(.system(.body, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(unit)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(value) \(unit)")
    }

    private var columns: [GridItem] {
        [GridItem(.flexible()), GridItem(.flexible())]
    }

    private var stateLabel: String {
        switch manager.state {
        case .starting: "STARTING"
        case .running: "LIVE"
        case .paused: "PAUSED"
        case .ending: manager.isDiscarding ? "DISCARDING" : "SAVING"
        case .idle, .ended, .failed: "WORKOUT"
        }
    }

    private var stateColor: Color {
        switch manager.state {
        case .paused: .orange
        case .ending: .blue
        case .starting: .yellow
        case .running: .green
        case .idle, .ended, .failed: .secondary
        }
    }

    private func finishErrorMessage(
        _ error: WatchWorkoutFinishRequestError
    ) -> String {
        switch error {
        case .persistenceFailed:
            "Couldn’t end the ride. It’s still active—try again."
        case .saveFailed:
            "Couldn’t save the ride yet. Retry safely."
        case .reconciliationFailed:
            "Couldn’t verify whether this ride was saved. Retry safely."
        case .identityMetadataFailed:
            "Couldn’t finish the ride safely yet. Retry recovery."
        }
    }
}
