//
//  OfflineMapServiceConfig.swift
//  BikeComputer
//
//  Production offline map service configuration.
//

import Foundation

enum OfflineMapServiceConfig {
    static let productionServerURLString = "http://rhi0maej6bwo33hn0im6h4lf.178.18.245.246.sslip.io"
    static let apiTokenInfoPlistKey = "OfflineMapAPIToken"

    static var apiToken: String {
        let value = Bundle.main.object(forInfoDictionaryKey: apiTokenInfoPlistKey) as? String ?? ""
        return value.hasPrefix("$(") ? "" : value
    }
}
