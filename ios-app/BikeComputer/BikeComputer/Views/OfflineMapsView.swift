//
//  OfflineMapsView.swift
//  BikeComputer
//
//  Offline map platform controls.
//

import SwiftUI

struct OfflineMapsView: View {
    @EnvironmentObject private var bleManager: BLEManager
    @StateObject private var manager = OfflineMapManager()

    var body: some View {
        Form {
            Section(header: Text("Map Server")) {
                OfflineMapValueRow(title: "Service", value: manager.serverURLString)
                Button {
                    manager.serverURLString = OfflineMapServiceConfig.productionServerURLString
                } label: {
                    Label("Use Production Server", systemImage: "checkmark.seal")
                }
            }

            Section(header: Text("Custom Cut-Out")) {
                TextField("Latitude", text: $manager.centerLatitude)
                    .keyboardType(.numbersAndPunctuation)
                TextField("Longitude", text: $manager.centerLongitude)
                    .keyboardType(.numbersAndPunctuation)
                TextField("Side length km", text: $manager.sideLengthKm)
                    .keyboardType(.decimalPad)

                Button(action: manager.createCustomCutoutJob) {
                    Label("Create Map Job", systemImage: "map")
                }
                .disabled(manager.isBusy || manager.serverURLString.isEmpty)
            }

            if let job = manager.currentJob {
                Section(header: Text("Current Job")) {
                    OfflineMapValueRow(title: "Status", value: job.status)
                    OfflineMapValueRow(title: "Job ID", value: job.jobId)
                    if let mapId = job.mapId {
                        OfflineMapValueRow(title: "Map ID", value: mapId)
                    }
                    if let region = job.sourceRegion {
                        OfflineMapValueRow(title: "Source", value: region.name)
                    }
                    if let area = job.geometry?.areaKm2 {
                        OfflineMapValueRow(title: "Area", value: "\(Int(area.rounded())) km²")
                    }
                    if let error = job.error {
                        Text(error)
                            .foregroundColor(.red)
                    }

                    Button(action: manager.refreshJob) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(manager.isBusy)

                    Button(action: manager.fetchDownloadURL) {
                        Label("Get Download URL", systemImage: "arrow.down.circle")
                    }
                    .disabled(manager.isBusy || job.mapId == nil)
                }
            }

            if let downloadURL = manager.downloadURL {
                Section(header: Text("Download")) {
                    Text(downloadURL.absoluteString)
                        .font(.caption)
                        .textSelection(.enabled)

                    Button(action: manager.downloadPack) {
                        Label("Download Pack", systemImage: "square.and.arrow.down")
                    }
                    .disabled(manager.isBusy)
                }
            }

            Section(header: Text("Device Transfer")) {
                OfflineMapValueRow(
                    title: "BLE",
                    value: bleManager.isNavigationReady ? "Ready" : "Not Ready"
                )
                OfflineMapValueRow(
                    title: "Transfer",
                    value: bleManager.mapTransferStatusDescription
                )
                if let localURL = manager.downloadedPackURL {
                    OfflineMapValueRow(title: "Pack", value: localURL.lastPathComponent)
                }

                Button(action: { bleManager.requestMapTransferMode(enabled: true) }) {
                    Label("Enable Transfer Mode", systemImage: "wifi")
                }
                .disabled(!bleManager.isNavigationReady)

                Button(action: { manager.transferDownloadedPack(bleManager: bleManager) }) {
                    Label("Upload to Device", systemImage: "sdcard")
                }
                .disabled(manager.isBusy || !bleManager.isNavigationReady || manager.downloadedPackURL == nil)

                if manager.transferProgress > 0 && manager.transferProgress < 1 {
                    ProgressView(value: manager.transferProgress)
                }
            }

            if manager.isBusy {
                Section {
                    ProgressView()
                }
            }

            if let error = manager.errorMessage {
                Section {
                    Text(error)
                        .foregroundColor(.red)
                }
            }
        }
        .navigationTitle("Offline Maps")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct OfflineMapValueRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

#Preview {
    NavigationView {
        OfflineMapsView()
            .environmentObject(BLEManager())
    }
}
