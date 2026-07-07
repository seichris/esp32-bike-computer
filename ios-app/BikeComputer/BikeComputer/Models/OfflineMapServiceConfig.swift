//
//  OfflineMapServiceConfig.swift
//  BikeComputer
//
//  Production offline map service configuration.
//

import Foundation

enum OfflineMapServiceConfig {
    nonisolated static let productionServerURLString = "https://maps.8o.vc"
    nonisolated static let apiTokenInfoPlistKey = "OfflineMapAPIToken"

    nonisolated static var apiToken: String {
        let value = Bundle.main.object(forInfoDictionaryKey: apiTokenInfoPlistKey) as? String ?? ""
        return value.hasPrefix("$(") ? "" : value
    }
}
