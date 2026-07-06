//
//  OfflineMapsView.swift
//  BikeComputer
//
//  Offline map platform controls.
//

import SwiftUI

struct OfflineMapsView: View {
    @StateObject private var manager = OfflineMapManager()

    var body: some View {
        Form {
            Section(header: Text("Map Server")) {
                TextField("https://maps.example.com", text: $manager.serverURLString)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("API token", text: $manager.apiToken)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
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
    }
}
