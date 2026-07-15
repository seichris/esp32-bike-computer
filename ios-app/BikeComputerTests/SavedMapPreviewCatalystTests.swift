import Foundation
import UIKit

private func fail(_ message: String) -> Never {
    fputs("FAIL: \(message)\n", stderr)
    Foundation.exit(1)
}

private func appendUInt16LE(_ value: UInt16, to data: inout Data) {
    data.append(UInt8(value & 0xff))
    data.append(UInt8(value >> 8))
}

private func appendUInt32LE(_ value: UInt32, to data: inout Data) {
    data.append(UInt8(value & 0xff))
    data.append(UInt8((value >> 8) & 0xff))
    data.append(UInt8((value >> 16) & 0xff))
    data.append(UInt8((value >> 24) & 0xff))
}

private func crc32(_ data: Data) -> UInt32 {
    var crc = UInt32.max
    for byte in data {
        var value = (crc ^ UInt32(byte)) & 0xff
        for _ in 0..<8 {
            value = value & 1 == 1
                ? (value >> 1) ^ 0xedb8_8320
                : value >> 1
        }
        crc = (crc >> 8) ^ value
    }
    return crc ^ UInt32.max
}

private func storedZip(entries: [(String, Data)]) -> Data {
    var zip = Data()
    for (path, body) in entries {
        let name = Data(path.utf8)
        appendUInt32LE(0x0403_4B50, to: &zip)
        appendUInt16LE(20, to: &zip)
        appendUInt16LE(0, to: &zip)
        appendUInt16LE(0, to: &zip)
        appendUInt16LE(0, to: &zip)
        appendUInt16LE(0, to: &zip)
        appendUInt32LE(crc32(body), to: &zip)
        appendUInt32LE(UInt32(body.count), to: &zip)
        appendUInt32LE(UInt32(body.count), to: &zip)
        appendUInt16LE(UInt16(name.count), to: &zip)
        appendUInt16LE(0, to: &zip)
        zip.append(name)
        zip.append(body)
    }
    return zip
}

private func hasVisiblePixel(_ image: UIImage) -> Bool {
    guard let source = image.cgImage else { return false }
    let width = source.width
    let height = source.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    return pixels.withUnsafeMutableBytes { bytes in
        guard let context = CGContext(
            data: bytes.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return false
        }
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        return stride(from: 3, to: bytes.count, by: 4).contains { bytes[$0] > 0 }
    }
}

@main
struct SavedMapPreviewCatalystTests {
    @MainActor
    static func main() async {
        let suite = "saved-map-preview-catalyst-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fail("test defaults should create")
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("saved-map-preview-catalyst-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(
                at: cacheDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            fail("test cache should create: \(error)")
        }
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }

        let mapID = "custom-map-4dc48b9bcb"
        let packURL = cacheDirectory.appendingPathComponent("\(mapID).zip")
        let manifest: Data
        do {
            manifest = try JSONSerialization.data(withJSONObject: [
                "schemaVersion": 1,
                "mapId": mapID,
                "displayName": mapID,
                "bounds": [120.90, 30.70, 121.95, 31.55],
                "source": ["name": "Shanghai and Suzhou"],
            ])
            try storedZip(entries: [
                ("manifest.json", manifest),
                ("VECTMAP/\(mapID)/+0000+0000/1.fmb", Data("map-block".utf8)),
            ]).write(to: packURL)
        } catch {
            fail("preview-less test pack should write: \(error)")
        }
        defaults.set(
            [packURL.lastPathComponent: mapID],
            forKey: "offlineMap.packDisplayNames"
        )

        let manager = OfflineMapManager(defaults: defaults, cacheDirectory: cacheDirectory)
        guard manager.displayName(forCachedPack: packURL) == "Shanghai and Suzhou" else {
            fail("source.name should repair the generated saved-map title")
        }

        manager.loadPreviewIfNeeded(forCachedPack: packURL)
        let deadline = Date().addingTimeInterval(3)
        while manager.previewImage(forCachedPack: packURL) == nil && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        guard let image = manager.previewImage(forCachedPack: packURL) else {
            fail("bounds fallback should publish a preview through OfflineMapManager")
        }
        guard image.size == CGSize(width: 160, height: 96) else {
            fail("bounds fallback should publish the expected 160x96 image")
        }
        guard hasVisiblePixel(image) else {
            fail("bounds fallback should contain visible rendered pixels")
        }

        print("SavedMapPreviewCatalystTests passed")
    }
}
