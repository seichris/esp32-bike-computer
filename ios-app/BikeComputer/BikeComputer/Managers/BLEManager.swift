//
//  BLEManager.swift
//  BikeComputer
//
//  BLE Manager for connecting to ESP32 Bike Computer
//  Service UUID: 1819 (Navigation Service)
//

import Foundation
import Combine
import CoreBluetooth

class BLEManager: NSObject, ObservableObject {
    private static let navigationProtocolMaxBytes = 96
    
    // MARK: - Published Properties
    @Published var isScanning: Bool = false
    @Published var isConnected: Bool = false
    @Published var isGPSReady: Bool = false // Ready to send GPS data
    @Published var isRouteReady: Bool = false // Ready to send Route data
    @Published var supportsDeviceSettings: Bool = false
    @Published var peripheralName: String = ""
    @Published var signalStrength: Int = 0
    
    // MARK: - Map Settings (persisted for UI display)
    @Published var minPolygonSize: Double = 0
    @Published var detailLevel: Int = 2
    @Published var routeLineWidth: Double = 4
    @Published var displayRotation: Int = 0 
    @Published var mapRotationMode: Int = 0 // 0=North Up, 1=Course Up  // 0-3: 0°, 90°, 180°, 270°
    @Published var zoomLevel: Int = 2 // 0-4: 0=super-zoom, 1=closest, 4=farthest
    
    // Feature Visibility
    @Published var showBuildings: Bool = true
    @Published var showNature: Bool = true
    @Published var showMinorRoads: Bool = true
    
    // MARK: - BLE UUIDs (matching ESP32)
    private let serviceUUID = CBUUID(string: "1819")           // Navigation Service
    private let characteristicUUID = CBUUID(string: "2A6E")    // Navigation Data Characteristic
    
    // MARK: - Private Properties
    private var centralManager: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var navigationCharacteristic: CBCharacteristic?
    private var pendingNavigationWrites: [Data] = []
    private let maxQueuedNavigationWrites = 16
    
    private var autoReconnect: Bool = true
    private var lastConnectedPeripheralIdentifier: UUID?
    
    // MARK: - Reconnection with Exponential Backoff (Optimization #14)
    private var reconnectAttempts: Int = 0
    private var maxReconnectAttempts: Int = 10
    private var baseReconnectDelay: TimeInterval = 1.0 // Start with 1 second
    private var maxReconnectDelay: TimeInterval = 60.0 // Cap at 60 seconds
    private var reconnectTimer: Timer?
    
    // MARK: - UserDefaults Keys
    private enum SettingsKeys {
        static let minPolygonSize = "mapSettings.minPolygonSize"
        static let detailLevel = "mapSettings.detailLevel"
        static let routeLineWidth = "mapSettings.routeLineWidth"
        static let displayRotation = "mapSettings.displayRotation"
        static let showBuildings = "mapSettings.showBuildings"
        static let showNature = "mapSettings.showNature"
        static let showMinorRoads = "mapSettings.showMinorRoads"
    }
    
    // MARK: - Initialization
    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
        loadSettings()
    }
    
    private func loadSettings() {
        let defaults = UserDefaults.standard
        minPolygonSize = defaults.double(forKey: SettingsKeys.minPolygonSize)
        detailLevel = defaults.object(forKey: SettingsKeys.detailLevel) as? Int ?? 2
        routeLineWidth = defaults.object(forKey: SettingsKeys.routeLineWidth) as? Double ?? 4.0
        displayRotation = defaults.object(forKey: SettingsKeys.displayRotation) as? Int ?? 0
        showBuildings = defaults.object(forKey: SettingsKeys.showBuildings) as? Bool ?? true
        showNature = defaults.object(forKey: SettingsKeys.showNature) as? Bool ?? true
        showMinorRoads = defaults.object(forKey: SettingsKeys.showMinorRoads) as? Bool ?? true
    }
    
    func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(minPolygonSize, forKey: SettingsKeys.minPolygonSize)
        defaults.set(detailLevel, forKey: SettingsKeys.detailLevel)
        defaults.set(routeLineWidth, forKey: SettingsKeys.routeLineWidth)
        defaults.set(displayRotation, forKey: SettingsKeys.displayRotation)
        defaults.set(showBuildings, forKey: SettingsKeys.showBuildings)
        defaults.set(showNature, forKey: SettingsKeys.showNature)
        defaults.set(showMinorRoads, forKey: SettingsKeys.showMinorRoads)
    }
    
    // MARK: - Public Methods
    
    /// Start scanning for bike computer peripheral
    func startScanning() {
        guard centralManager.state == .poweredOn else {
            print("Bluetooth not powered on")
            return
        }
        
        print("Starting BLE scan for service UUID: \(serviceUUID)")
        isScanning = true
        
        // Scan for devices advertising the navigation service
        centralManager.scanForPeripherals(
            withServices: [serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }
    
    /// Stop scanning
    func stopScanning() {
        centralManager.stopScan()
        isScanning = false
        print("BLE scan stopped")
    }
    
    /// Disconnect from current peripheral
    func disconnect() {
        guard let peripheral = connectedPeripheral else { return }
        
        autoReconnect = false
        centralManager.cancelPeripheralConnection(peripheral)
        print("Disconnecting from peripheral")
    }
    
    /// Send navigation data to ESP32
    func sendNavigationData(_ data: String) {
        guard let peripheral = connectedPeripheral,
              let characteristic = navigationCharacteristic,
              isConnected else {
            print("Cannot send: not connected or characteristic not found")
            return
        }
        
        let maxLength = min(peripheral.maximumWriteValueLength(for: .withoutResponse), Self.navigationProtocolMaxBytes)
        guard let dataToSend = navigationPacketData(from: data, maxLength: maxLength) else {
            print("Failed to encode data")
            return
        }
        
        enqueueNavigationWrite(dataToSend, for: characteristic, on: peripheral)
        print("Queued navigation packet: \(dataToSend.count) bytes")
    }
    
    /// Send route geometry data to ESP32 (binary format)
    func sendRouteGeometry(_ data: Data) {
        print("Route geometry BLE characteristic is not supported by the current ESP32 firmware; skipped \(data.count) bytes")
    }
    
    /// Send GPS position to ESP32
    /// Format: [Lat:4][Lon:4][Heading:2] = 10 bytes
    /// GPS coordinates are sent as-is (WGS-84) but with a calibration nudge for map alignment
    func sendGPSPosition(lat: Double, lon: Double, heading: Double = 0) {
        print("GPS BLE characteristic is not supported by the current ESP32 firmware; skipped lat=\(lat), lon=\(lon), heading=\(heading)")
    }
    
    /// Send a setting to ESP32 (runtime map configuration)
    /// Format: [settingId:1][value:4] = 5 bytes
    /// Setting IDs: 1=minPolygonSize (0-50), 2=detailLevel (0-2), 3=routeLineWidth (2-8)
    func sendSetting(id: UInt8, value: Int32) {
        saveSettings()
        print("Settings BLE characteristic is not supported by the current ESP32 firmware; saved local setting id=\(id), value=\(value)")
    }
    
    /// Send feature visibility bitmask
    func sendVisibilityMask() {
        var mask: Int32 = 0
        if showBuildings { mask |= (1 << 0) }
        if showNature { mask |= (1 << 1) }
        if showMinorRoads { mask |= (1 << 2) }
        // Bits 3-31 are unused for now (0)
        
        sendSetting(id: 8, value: mask)
    }
    
    /// Attempt to reconnect to last known peripheral
    func reconnectToLastDevice() {
        guard let uuid = lastConnectedPeripheralIdentifier else {
            print("No last connected device")
            startScanning()
            return
        }
        
        let peripherals = centralManager.retrievePeripherals(withIdentifiers: [uuid])
        
        if let peripheral = peripherals.first {
            print("Attempting to reconnect to last device: \(peripheral.name ?? "Unknown")")
            connectToPeripheral(peripheral)
        } else {
            print("Last device not found, starting scan")
            startScanning()
        }
    }
    
    // MARK: - Private Methods
    
    private func connectToPeripheral(_ peripheral: CBPeripheral) {
        connectedPeripheral = peripheral
        peripheral.delegate = self
        centralManager.connect(peripheral, options: nil)
        print("Connecting to: \(peripheral.name ?? "Unknown")")
    }

    private func navigationPacketData(from packet: String, maxLength: Int) -> Data? {
        guard maxLength > 0 else { return nil }

        if let data = packet.data(using: .utf8), data.count <= maxLength {
            return data
        }

        let parts = packet.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }

        let prefix = "\(parts[0])|\(parts[1])|"
        guard let prefixData = prefix.data(using: .utf8), prefixData.count < maxLength else {
            return nil
        }

        var instruction = String(parts[2])
        while let data = "\(prefix)\(instruction)".data(using: .utf8), data.count > maxLength {
            guard !instruction.isEmpty else { return nil }
            instruction.removeLast()
        }

        return "\(prefix)\(instruction)".data(using: .utf8)
    }

    private func enqueueNavigationWrite(_ data: Data, for characteristic: CBCharacteristic, on peripheral: CBPeripheral) {
        pendingNavigationWrites.append(data)
        if pendingNavigationWrites.count > maxQueuedNavigationWrites {
            pendingNavigationWrites.removeFirst(pendingNavigationWrites.count - maxQueuedNavigationWrites)
        }

        flushPendingNavigationWrites(for: characteristic, on: peripheral)
    }

    private func flushPendingNavigationWrites(for characteristic: CBCharacteristic, on peripheral: CBPeripheral) {
        while !pendingNavigationWrites.isEmpty && peripheral.canSendWriteWithoutResponse {
            let data = pendingNavigationWrites.removeFirst()
            peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
            print("Sent navigation packet: \(data.count) bytes")
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEManager: CBCentralManagerDelegate {
    
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            print("Bluetooth powered on")
            // Attempt to reconnect to last device, or start scanning
            if let uuid = lastConnectedPeripheralIdentifier {
                reconnectToLastDevice()
            } else {
                startScanning()
            }
            
        case .poweredOff:
            print("Bluetooth powered off")
            isConnected = false
            isScanning = false
            
        case .resetting:
            print("Bluetooth resetting")
            
        case .unauthorized:
            print("Bluetooth unauthorized")
            
        case .unsupported:
            print("Bluetooth unsupported")
            
        case .unknown:
            print("Bluetooth unknown state")
            
        @unknown default:
            print("Bluetooth unknown state")
        }
    }
    
    func centralManager(_ central: CBCentralManager, 
                       didDiscover peripheral: CBPeripheral, 
                       advertisementData: [String : Any], 
                       rssi RSSI: NSNumber) {
        
        print("Discovered: \(peripheral.name ?? "Unknown") (RSSI: \(RSSI))")
        
        // Auto-connect to first discovered device with our service
        // (In production, you might want to show a list and let user choose)
        stopScanning()
        connectToPeripheral(peripheral)
        
        // Store signal strength
        signalStrength = RSSI.intValue
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("Connected to: \(peripheral.name ?? "Unknown")")
        
        isConnected = true
        peripheralName = peripheral.name ?? "BikeComputer"
        lastConnectedPeripheralIdentifier = peripheral.identifier
        
        // Reset reconnection state on successful connection (Optimization #14)
        resetReconnectionState()
        
        // Discover services
        peripheral.discoverServices([serviceUUID])
    }
    
    func centralManager(_ central: CBCentralManager, 
                       didDisconnectPeripheral peripheral: CBPeripheral, 
                       error: Error?) {
        print("Disconnected from: \(peripheral.name ?? "Unknown")")
        
        if let error = error {
            print("Disconnect error: \(error.localizedDescription)")
        }
        
        isConnected = false
        isGPSReady = false
        isRouteReady = false
        supportsDeviceSettings = false
        connectedPeripheral = nil
        navigationCharacteristic = nil
        pendingNavigationWrites.removeAll()
        
        // Auto-reconnect if enabled with exponential backoff
        if autoReconnect {
            scheduleReconnectWithBackoff()
        }
    }
    
    // MARK: - Exponential Backoff Reconnection (Optimization #14)
    
    private func scheduleReconnectWithBackoff() {
        reconnectTimer?.invalidate()
        
        guard reconnectAttempts < maxReconnectAttempts else {
            print("❌ Max reconnection attempts reached (\(maxReconnectAttempts))")
            reconnectAttempts = 0
            return
        }
        
        // Calculate delay with exponential backoff: base * 2^attempts
        let delay = min(baseReconnectDelay * pow(2.0, Double(reconnectAttempts)), maxReconnectDelay)
        reconnectAttempts += 1
        
        print("🔄 Reconnection attempt \(reconnectAttempts)/\(maxReconnectAttempts) in \(String(format: "%.1f", delay))s...")
        
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.reconnectToLastDevice()
        }
    }
    
    private func resetReconnectionState() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        reconnectAttempts = 0
    }
    
    func centralManager(_ central: CBCentralManager, 
                       didFailToConnect peripheral: CBPeripheral, 
                       error: Error?) {
        print("Failed to connect to: \(peripheral.name ?? "Unknown")")
        
        if let error = error {
            print("Connection error: \(error.localizedDescription)")
        }
        
        // Retry after delay
        if autoReconnect {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.startScanning()
            }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BLEManager: CBPeripheralDelegate {
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            print("Error discovering services: \(error.localizedDescription)")
            return
        }
        
        guard let services = peripheral.services else { return }
        
        for service in services {
            print("Discovered service: \(service.uuid)")
            
            if service.uuid == serviceUUID {
                // Discover characteristics for navigation service
                peripheral.discoverCharacteristics([characteristicUUID], for: service)
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, 
                   didDiscoverCharacteristicsFor service: CBService, 
                   error: Error?) {
        if let error = error {
            print("Error discovering characteristics: \(error.localizedDescription)")
            return
        }
        
        guard let characteristics = service.characteristics else { return }
        
        for characteristic in characteristics {
            print("Discovered characteristic: \(characteristic.uuid)")
            
            if characteristic.uuid == characteristicUUID {
                guard characteristic.properties.contains(.writeWithoutResponse) else {
                    print("Navigation characteristic does not support write without response")
                    continue
                }

                navigationCharacteristic = characteristic
                print("Navigation characteristic ready!")
                
                // Optional: Enable notifications if ESP32 sends updates
                if characteristic.properties.contains(.notify) {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            }
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard let characteristic = navigationCharacteristic else { return }
        flushPendingNavigationWrites(for: characteristic, on: peripheral)
    }
    
    func peripheral(_ peripheral: CBPeripheral, 
                   didWriteValueFor characteristic: CBCharacteristic, 
                   error: Error?) {
        if let error = error {
            print("Error writing characteristic: \(error.localizedDescription)")
            return
        }
        
        // Write successful (if using .withResponse type)
        // print("Write successful")
    }
    
    func peripheral(_ peripheral: CBPeripheral, 
                   didUpdateValueFor characteristic: CBCharacteristic, 
                   error: Error?) {
        if let error = error {
            print("Error reading characteristic: \(error.localizedDescription)")
            return
        }
        
        // Handle notifications from ESP32 (if implemented)
        guard let data = characteristic.value else { return }
        
        if let string = String(data: data, encoding: .utf8) {
            print("Received from ESP32: \(string)")
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, 
                   didReadRSSI RSSI: NSNumber, 
                   error: Error?) {
        if error == nil {
            signalStrength = RSSI.intValue
        }
    }
}

// MARK: - Helper Extension

extension BLEManager {
    
    /// Read RSSI periodically to monitor connection strength
    func startMonitoringRSSI() {
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self, let peripheral = self.connectedPeripheral, self.isConnected else {
                return
            }
            peripheral.readRSSI()
        }
    }
}
