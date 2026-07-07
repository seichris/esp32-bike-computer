//
//  OfflineMapServiceConfig.swift
//  BikeComputer
//
//  Production offline map service configuration.
//

import Foundation

enum OfflineMapServiceConfig {
    static let productionServerURLString = "https://maps.8o.vc"
    static let apiTokenInfoPlistKey = "OfflineMapAPIToken"

    static var apiToken: String {
        let value = Bundle.main.object(forInfoDictionaryKey: apiTokenInfoPlistKey) as? String ?? ""
        return value.hasPrefix("$(") ? "" : value
    }
}
