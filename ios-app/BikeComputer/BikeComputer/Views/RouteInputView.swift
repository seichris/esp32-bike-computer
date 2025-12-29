//
//  RouteInputView.swift
//  BikeComputer
//
//  Route input and destination search view
//

import SwiftUI
import MapKit
import Combine
import CoreLocation

// MARK: - Address Search Completer

class AddressSearchCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var suggestions: [MKLocalSearchCompletion] = []
    
    private let completer = MKLocalSearchCompleter()
    
    override init() {
        super.init()
        completer.delegate = self
        // Include both addresses and points of interest for street-level searches
        completer.resultTypes = [.address, .pointOfInterest, .query]
    }
    
    func search(query: String) {
        completer.queryFragment = query
    }
    
    /// Update search region to prioritize results near user's location
    func updateRegion(_ region: MKCoordinateRegion) {
        completer.region = region
    }
    
    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        suggestions = completer.results
    }
    
    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        print("Address search error: \(error.localizedDescription)")
    }
}

// MARK: - Route Input View

struct RouteInputView: View {
    @Environment(\.dismiss) var dismiss
    
    @Binding var sourceAddress: String
    @Binding var destinationAddress: String
    let currentAddress: String
    let currentLocation: CLLocation?  // User's exact GPS location for region-biased search
    
    var onStartNavigation: (String, String, MKDirectionsTransportType, Bool) -> Void
    
    @StateObject private var destinationCompleter = AddressSearchCompleter()
    @FocusState private var isDestinationFieldFocused: Bool
    
    @State private var hasSelectedDestination = false
    @State private var isSelectingFromSuggestion = false
    @State private var isTestMode = false
    @State private var selectedTransportType: MKDirectionsTransportType = {
        if #available(iOS 18.0, *) {
            return .cycling
        } else {
            return .walking  // Fall back to walking for pre-iOS 18
        }
    }()
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Destination Search Field (always visible)
                VStack(spacing: 16) {
                    HStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                        
                        TextField("Search for a destination", text: $destinationAddress)
                            .textContentType(.fullStreetAddress)
                            .focused($isDestinationFieldFocused)
                            .onChange(of: destinationAddress) { newValue in
                                // Skip processing if we're programmatically selecting from suggestions
                                if isSelectingFromSuggestion {
                                    isSelectingFromSuggestion = false
                                    return
                                }
                                
                                destinationCompleter.search(query: newValue)
                                // Reset selection state when user starts typing again
                                if hasSelectedDestination {
                                    hasSelectedDestination = false
                                }
                            }
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(12)
                    
                    // From field (only shown after destination is selected)
                    if hasSelectedDestination {
                        HStack(spacing: 12) {
                            Image(systemName: "location.fill")
                                .foregroundColor(.blue)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Your Location")
                                    .foregroundColor(.primary)
                                    .font(.body)
                                if !currentAddress.contains("Current Location") && !currentAddress.contains("Getting") {
                                    Text(currentAddress)
                                        .foregroundColor(.secondary)
                                        .font(.caption)
                                }
                            }
                            
                            Spacer()
                        }
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(12)
                    }
                }
                .padding()
                
                // Transport Type Selection (only shown after destination is selected)
                if hasSelectedDestination {
                    HStack(spacing: 12) {
                        if #available(iOS 18.0, *) {
                            TransportButton(
                                icon: "bicycle",
                                label: "Bike",
                                isSelected: selectedTransportType == .cycling,
                                action: { selectedTransportType = .cycling }
                            )
                        }
                        
                        TransportButton(
                            icon: "car.fill",
                            label: "Drive",
                            isSelected: selectedTransportType == .automobile,
                            action: { selectedTransportType = .automobile }
                        )
                        
                        TransportButton(
                            icon: "figure.walk",
                            label: "Walk",
                            isSelected: selectedTransportType == .walking,
                            action: { selectedTransportType = .walking }
                        )
                    }
                    .padding(.horizontal)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    
                    // Test Mode Toggle
                    Toggle(isOn: $isTestMode) {
                        HStack {
                            Image(systemName: "testtube.2")
                                .foregroundColor(.orange)
                            Text("Test Mode")
                                .foregroundColor(.primary)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .tint(.orange)
                }
                
                // Suggestions (shown while typing destination)
                if !hasSelectedDestination && !destinationCompleter.suggestions.isEmpty {
                    suggestionsList(for: destinationCompleter.suggestions)
                } else {
                    Spacer()
                }
                
                // Go button (only shown after destination is selected)
                if hasSelectedDestination {
                    Button(action: {
                        onStartNavigation(currentAddress, destinationAddress, selectedTransportType, isTestMode)
                        dismiss()
                    }) {
                        Text(isTestMode ? "Go (Test)" : "Go")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(isTestMode ? Color.orange : Color.blue)
                            .cornerRadius(12)
                    }
                    .padding()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: {
                        dismiss()
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.title2)
                    }
                }
            }
            .onAppear {
                // Auto-focus destination field when view appears
                isDestinationFieldFocused = true
                
                // Set search region based on user's current location for better results
                if let location = currentLocation {
                    let region = MKCoordinateRegion(
                        center: location.coordinate,
                        latitudinalMeters: 50000,  // ~50km radius for search relevance
                        longitudinalMeters: 50000
                    )
                    destinationCompleter.updateRegion(region)
                }
            }
            .onDisappear {
                // Reset state when dismissed
                hasSelectedDestination = false
                destinationAddress = ""
            }
        }
    }
    
    private func suggestionsList(for suggestions: [MKLocalSearchCompletion]) -> some View {
        List(suggestions, id: \.self) { suggestion in
            Button(action: {
                let fullAddress = "\(suggestion.title), \(suggestion.subtitle)"
                isSelectingFromSuggestion = true
                destinationAddress = fullAddress
                hasSelectedDestination = true
                isDestinationFieldFocused = false
            }) {
                HStack(spacing: 12) {
                    Image(systemName: "mappin.circle.fill")
                        .foregroundColor(.secondary)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text(suggestion.title)
                            .font(.body)
                        Text(suggestion.subtitle)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                }
            }
        }
        .listStyle(.plain)
    }
}

// MARK: - Transport Button Component

struct TransportButton: View {
    let icon: String
    let label: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 24))
                Text(label)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? Color.blue : Color(.systemGray6))
            )
            .foregroundColor(isSelected ? .white : .primary)
        }
    }
}

