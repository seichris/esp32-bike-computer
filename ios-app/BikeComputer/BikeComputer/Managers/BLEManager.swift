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
import CryptoKit
import Security

struct NavigationWriteEndpoint {
    let maximumWriteLength: Int
    let canSend: () -> Bool
    let write: (Data) -> Void
}

enum BLEPairingAuthenticator {
    private static let key = SymmetricKey(data: Data("BikeComputer BLE v1 local pairing key".utf8))

    static func makeNonce() -> String? {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func isValidServerResponse(_ response: String, nonce: String) -> Bool {
        let parts = response.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0] == "SERVER",
              parts[1] == Substring(nonce) else {
            return false
        }

        return constantTimeEquals(String(parts[2]), hmacHex("server|\(nonce)"))
    }

    static func clientProof(nonce: String) -> String {
        hmacHex("client|\(nonce)")
    }

    private static func hmacHex(_ message: String) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
        return code.map { String(format: "%02x", $0) }.joined()
    }

    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }

        var diff: UInt8 = 0
        for index in left.indices {
            diff |= left[index] ^ right[index]
        }
        return diff == 0
    }
}

class BLEManager: NSObject, ObservableObject {
    // MARK: - Published Properties
    @Published var isScanning: Bool = false
    @Published var isConnected: Bool = false
    @Published var isNavigationReady: Bool = false
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
    private let authCharacteristicUUID = CBUUID(string: "9D7B3F30-3F6A-4D1C-9F6D-1FBF0E8B1001")
    
    // MARK: - Private Properties
    private var centralManager: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var navigationCharacteristic: CBCharacteristic?
    private var authCharacteristic: CBCharacteristic?
    private var navigationWriteEndpoint: NavigationWriteEndpoint?
    private var navigationWriteQueue = NavigationWriteQueue(maxCount: 16)
    private var isConnecting: Bool = false
    private var isPairingMode: Bool = false
    private var pendingAuthNonce: String?
    private enum AuthWriteState {
        case idle
        case helloInFlight
        case waitingForServer
        case clientProofPending(Data)
        case clientProofInFlight
        case waitingForOK
    }
    private var authWriteState: AuthWriteState = .idle
    
    private var autoReconnect: Bool = true
    private var lastConnectedPeripheralIdentifier: UUID?
    
    // MARK: - Reconnection with Exponential Backoff (Optimization #14)
    private var reconnectAttempts: Int = 0
    private var maxReconnectAttempts: Int = 10
    private var baseReconnectDelay: TimeInterval = 1.0 // Start with 1 second
    private var maxReconnectDelay: TimeInterval = 60.0 // Cap at 60 seconds
    private var reconnectTimer: Timer?
    private var rssiTimer: Timer?
    
    // MARK: - UserDefaults Keys
    private enum SettingsKeys {
        static let minPolygonSize = "mapSettings.minPolygonSize"
        static let detailLevel = "mapSettings.detailLevel"
        static let routeLineWidth = "mapSettings.routeLineWidth"
        static let displayRotation = "mapSettings.displayRotation"
        static let showBuildings = "mapSettings.showBuildings"
        static let showNature = "mapSettings.showNature"
        static let showMinorRoads = "mapSettings.showMinorRoads"
        static let lastPeripheralIdentifier = "ble.lastPeripheralIdentifier"
    }
    
    // MARK: - Initialization
    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
        loadSettings()
        loadLastPeripheralIdentifier()
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

    private func loadLastPeripheralIdentifier() {
        guard let uuidString = UserDefaults.standard.string(forKey: SettingsKeys.lastPeripheralIdentifier) else { return }
        lastConnectedPeripheralIdentifier = UUID(uuidString: uuidString)
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
        guard !isConnected && !isConnecting else {
            print("Skipping BLE scan: connection already active")
            return
        }
        guard !isScanning else {
            print("Skipping BLE scan: scan already active")
            return
        }
        guard lastConnectedPeripheralIdentifier != nil || isPairingMode else {
            print("Skipping BLE scan: no trusted peripheral saved and pairing mode is not active")
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
        stopMonitoringRSSI()
        centralManager.cancelPeripheralConnection(peripheral)
        print("Disconnecting from peripheral")
    }

    func reconnect() {
        autoReconnect = true
        resetReconnectionState()
        if lastConnectedPeripheralIdentifier == nil {
            beginPairing()
        } else {
            reconnectToLastDevice()
        }
    }
    
    /// Send navigation data to ESP32
    @discardableResult
    func sendNavigationData(_ data: String) -> Bool {
        guard let endpoint = navigationWriteEndpoint,
              isConnected,
              isNavigationReady else {
            print("Cannot send: not connected or characteristic not found")
            return false
        }
        
        let maxLength = min(endpoint.maximumWriteLength, NavigationPacketBuilder.protocolMaxBytes)
        guard let dataToSend = NavigationPacketBuilder.data(from: data, maxLength: maxLength) else {
            print("Failed to encode data")
            return false
        }
        
        enqueueNavigationWrite(dataToSend, endpoint: endpoint)
        print("Queued navigation packet: \(dataToSend.count) bytes")
        return true
    }
    
    /// Persist a local map setting. The current ESP32 firmware exposes navigation data only.
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
        guard centralManager.state == .poweredOn else {
            print("Cannot reconnect: Bluetooth not powered on")
            return
        }
        guard !isConnected && !isConnecting else {
            print("Skipping reconnect: connection already active")
            return
        }

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
        guard !isConnected && !isConnecting else {
            print("Skipping connect: connection already active")
            return
        }

        stopScanning()
        connectedPeripheral = peripheral
        navigationCharacteristic = nil
        authCharacteristic = nil
        navigationWriteEndpoint = nil
        isNavigationReady = false
        pendingAuthNonce = nil
        authWriteState = .idle
        navigationWriteQueue.removeAll()
        peripheral.delegate = self
        isConnecting = true
        centralManager.connect(peripheral, options: nil)
        print("Connecting to: \(peripheral.name ?? "Unknown")")
    }

    private func beginPairing() {
        guard centralManager.state == .poweredOn else {
            print("Cannot pair: Bluetooth not powered on")
            return
        }

        isPairingMode = true
        startScanning()
    }

    private func clearConnectionState() {
        isConnected = false
        isConnecting = false
        supportsDeviceSettings = false
        connectedPeripheral = nil
        navigationCharacteristic = nil
        authCharacteristic = nil
        navigationWriteEndpoint = nil
        isNavigationReady = false
        pendingAuthNonce = nil
        authWriteState = .idle
        navigationWriteQueue.removeAll()
        stopMonitoringRSSI()
    }

    func installNavigationWriteEndpoint(_ endpoint: NavigationWriteEndpoint) {
        navigationWriteEndpoint = endpoint
    }

    private func beginAuthenticationIfReady(for peripheral: CBPeripheral) {
        guard navigationCharacteristic != nil,
              let authCharacteristic,
              pendingAuthNonce == nil,
              case .idle = authWriteState else {
            return
        }

        guard authCharacteristic.properties.contains(.write) else {
            print("Auth characteristic does not support write")
            return
        }

        guard let nonce = BLEPairingAuthenticator.makeNonce() else {
            print("Failed to generate BLE auth nonce")
            return
        }

        let challenge = "HELLO|\(nonce)"
        guard let challengeData = challenge.data(using: .utf8) else { return }
        pendingAuthNonce = nonce
        authWriteState = .helloInFlight
        peripheral.writeValue(challengeData, for: authCharacteristic, type: .withResponse)
        print("Sent BLE auth challenge")
    }

    private func handleAuthResponse(_ data: Data, peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        guard let message = String(data: data, encoding: .utf8) else {
            print("Received non-UTF8 BLE auth response")
            return
        }

        if message == "LOCKED" {
            print("Ignoring initial BLE auth state")
            return
        }

        guard let nonce = pendingAuthNonce else {
            print("Ignoring BLE auth response without a pending challenge")
            return
        }

        if message.hasPrefix("SERVER|") {
            guard BLEPairingAuthenticator.isValidServerResponse(message, nonce: nonce) else {
                print("BLE auth failed: invalid server proof")
                isPairingMode = false
                clearConnectionState()
                centralManager.cancelPeripheralConnection(peripheral)
                return
            }

            let clientProof = BLEPairingAuthenticator.clientProof(nonce: nonce)
            let proofMessage = "CLIENT|\(nonce)|\(clientProof)"
            guard let proofData = proofMessage.data(using: .utf8) else { return }
            sendOrQueueClientProof(proofData, peripheral: peripheral, characteristic: characteristic)
            return
        }

        if message == "OK|\(nonce)" {
            completeAuthentication(for: peripheral)
            return
        }

        print("BLE auth failed: unexpected response")
        isPairingMode = false
        clearConnectionState()
        centralManager.cancelPeripheralConnection(peripheral)
    }

    private func completeAuthentication(for peripheral: CBPeripheral) {
        guard let characteristic = navigationCharacteristic else { return }

        installNavigationWriteEndpoint(NavigationWriteEndpoint(
            maximumWriteLength: peripheral.maximumWriteValueLength(for: .withoutResponse),
            canSend: { [weak peripheral] in
                peripheral?.canSendWriteWithoutResponse == true
            },
            write: { [weak peripheral, weak characteristic] data in
                guard let peripheral, let characteristic else { return }
                peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
            }
        ))

        pendingAuthNonce = nil
        authWriteState = .idle
        isPairingMode = false
        isNavigationReady = true
        lastConnectedPeripheralIdentifier = peripheral.identifier
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: SettingsKeys.lastPeripheralIdentifier)
        print("BLE peripheral authenticated")
    }

    private func sendOrQueueClientProof(_ proofData: Data, peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        switch authWriteState {
        case .helloInFlight:
            authWriteState = .clientProofPending(proofData)
            print("Queued BLE client auth proof until challenge write completes")
        case .waitingForServer:
            authWriteState = .clientProofPending(proofData)
            print("Queued BLE client auth proof")
            DispatchQueue.main.async { [weak self, weak peripheral, weak characteristic] in
                guard let self, let peripheral, let characteristic else { return }
                self.authWriteCompleted(for: peripheral, characteristic: characteristic)
            }
        default:
            print("Ignoring duplicate BLE server auth response")
        }
    }

    private func authWriteCompleted(for peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        switch authWriteState {
        case .helloInFlight:
            authWriteState = .waitingForServer
        case .clientProofPending(let proofData):
            authWriteState = .clientProofInFlight
            peripheral.writeValue(proofData, for: characteristic, type: .withResponse)
            print("Sent queued BLE client auth proof")
        case .clientProofInFlight:
            authWriteState = .waitingForOK
        default:
            break
        }
    }

    private func enqueueNavigationWrite(_ data: Data, endpoint: NavigationWriteEndpoint) {
        if navigationWriteQueue.enqueue(data) {
            print("Navigation write queue full; dropped oldest packet")
        }

        flushPendingNavigationWrites(endpoint: endpoint)
    }

    private func flushPendingNavigationWrites(endpoint: NavigationWriteEndpoint) {
        navigationWriteQueue.flush(canSend: endpoint.canSend) { data in
            endpoint.write(data)
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
            if lastConnectedPeripheralIdentifier != nil {
                reconnectToLastDevice()
            } else {
                print("No trusted BikeComputer peripheral saved; tap reconnect to pair")
            }
            
        case .poweredOff:
            print("Bluetooth powered off")
            isScanning = false
            clearConnectionState()
            resetReconnectionState()
            
        case .resetting:
            print("Bluetooth resetting")
            isScanning = false
            clearConnectionState()
            
        case .unauthorized:
            print("Bluetooth unauthorized")
            isScanning = false
            clearConnectionState()
            resetReconnectionState()
            
        case .unsupported:
            print("Bluetooth unsupported")
            isScanning = false
            clearConnectionState()
            resetReconnectionState()
            
        case .unknown:
            print("Bluetooth unknown state")
            isScanning = false
            clearConnectionState()
            
        @unknown default:
            print("Bluetooth unknown state")
            isScanning = false
            clearConnectionState()
        }
    }
    
    func centralManager(_ central: CBCentralManager, 
                       didDiscover peripheral: CBPeripheral, 
                       advertisementData: [String : Any], 
                       rssi RSSI: NSNumber) {
        
        print("Discovered: \(peripheral.name ?? "Unknown") (RSSI: \(RSSI))")

        if let trustedIdentifier = lastConnectedPeripheralIdentifier,
           peripheral.identifier != trustedIdentifier {
            print("Ignoring untrusted BikeComputer peripheral: \(peripheral.identifier)")
            return
        }

        guard isPairingMode || peripheral.identifier == lastConnectedPeripheralIdentifier else {
            print("Ignoring BikeComputer peripheral outside pairing mode")
            return
        }

        connectToPeripheral(peripheral)
        
        // Store signal strength
        signalStrength = RSSI.intValue
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("Connected to: \(peripheral.name ?? "Unknown")")
        
        isConnecting = false
        isConnected = true
        isNavigationReady = false
        peripheralName = peripheral.name ?? "BikeComputer"
        startMonitoringRSSI()
        
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
        isConnecting = false
        supportsDeviceSettings = false
        connectedPeripheral = nil
        navigationCharacteristic = nil
        authCharacteristic = nil
        isNavigationReady = false
        pendingAuthNonce = nil
        navigationWriteQueue.removeAll()
        stopMonitoringRSSI()
        
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

    private func stopMonitoringRSSI() {
        rssiTimer?.invalidate()
        rssiTimer = nil
    }
    
    func centralManager(_ central: CBCentralManager, 
                       didFailToConnect peripheral: CBPeripheral, 
                       error: Error?) {
        print("Failed to connect to: \(peripheral.name ?? "Unknown")")
        clearConnectionState()
        
        if let error = error {
            print("Connection error: \(error.localizedDescription)")
        }
        
        // Retry after delay
        if autoReconnect {
            scheduleReconnectWithBackoff()
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
                peripheral.discoverCharacteristics([characteristicUUID, authCharacteristicUUID], for: service)
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
                beginAuthenticationIfReady(for: peripheral)
            }

            if characteristic.uuid == authCharacteristicUUID {
                authCharacteristic = characteristic
                if characteristic.properties.contains(.notify) {
                    peripheral.setNotifyValue(true, for: characteristic)
                } else {
                    beginAuthenticationIfReady(for: peripheral)
                }
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                   didUpdateNotificationStateFor characteristic: CBCharacteristic,
                   error: Error?) {
        if let error = error {
            print("Error updating notifications: \(error.localizedDescription)")
            return
        }

        if characteristic.uuid == authCharacteristicUUID {
            beginAuthenticationIfReady(for: peripheral)
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard isNavigationReady, let endpoint = navigationWriteEndpoint else { return }
        flushPendingNavigationWrites(endpoint: endpoint)
    }
    
    func peripheral(_ peripheral: CBPeripheral, 
                   didWriteValueFor characteristic: CBCharacteristic, 
                   error: Error?) {
        if let error = error {
            print("Error writing characteristic: \(error.localizedDescription)")
            if characteristic.uuid == authCharacteristicUUID {
                isPairingMode = false
                clearConnectionState()
                centralManager.cancelPeripheralConnection(peripheral)
            }
            return
        }

        if characteristic.uuid == authCharacteristicUUID {
            authWriteCompleted(for: peripheral, characteristic: characteristic)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, 
                   didUpdateValueFor characteristic: CBCharacteristic, 
                   error: Error?) {
        if let error = error {
            print("Error reading characteristic: \(error.localizedDescription)")
            return
        }
        
        guard let data = characteristic.value else { return }

        if characteristic.uuid == authCharacteristicUUID {
            handleAuthResponse(data, peripheral: peripheral, characteristic: characteristic)
            return
        }
        
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
        rssiTimer?.invalidate()
        rssiTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self, let peripheral = self.connectedPeripheral, self.isConnected else {
                return
            }
            peripheral.readRSSI()
        }
    }
}
