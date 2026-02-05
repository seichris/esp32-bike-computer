# BikeComputer iOS App

iOS companion application for the [IceNav-v3 ESP32 Bike Computer](../IceNav-v3). This app handles route planning and transmits navigation data via Bluetooth Low Energy (BLE).

## 🛠 Testing with a Real iPhone

To test the app on a physical device and share it with others, follow these steps:

### 1. Enable Developer Mode
On the testing iPhone:
1. Go to **Settings > Privacy & Security**.
2. Scroll to the bottom and tap **Developer Mode**.
3. Toggle the switch **On**.
4. Restart the iPhone when prompted.
5. After restart, tap "Turn On" in the system alert.

### 2. Trust the Developer App
1. Connect the iPhone to your Mac via USB.
2. Open the project in Xcode.
3. Select your iPhone as the run target.
4. Click the **Run** (Play) button.
5. Once installed, go to **Settings > General > VPN & Device Management**.
6. Tap your developer account email and select **Trust**.
