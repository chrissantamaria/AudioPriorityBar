import Foundation

class BluetoothBatteryService {
    private var cachedBatteryInfo: [String: AirPodsBatteryInfo] = [:]

    /// Reads battery info from system_profiler and returns it keyed by normalized Bluetooth MAC address (hyphen-separated, uppercase).
    func refreshBatteryInfo() -> [String: AirPodsBatteryInfo] {
        var result: [String: AirPodsBatteryInfo] = [:]

        if let plistResult = readFromBluetoothPlist() {
            result = plistResult
        }

        if result.isEmpty {
            result = readFromSystemProfiler()
        }

        cachedBatteryInfo = result
        return result
    }

    /// Try the legacy DeviceCache plist approach (older macOS versions).
    private func readFromBluetoothPlist() -> [String: AirPodsBatteryInfo]? {
        guard let deviceCache = CFPreferencesCopyAppValue(
            "DeviceCache" as CFString,
            "com.apple.Bluetooth" as CFString
        ) as? [String: [String: Any]] else {
            return nil
        }

        var result: [String: AirPodsBatteryInfo] = [:]

        for (address, properties) in deviceCache {
            let left = properties["BatteryPercentLeft"] as? Int
            let right = properties["BatteryPercentRight"] as? Int
            let case_ = properties["BatteryPercentCase"] as? Int

            guard left != nil || right != nil || case_ != nil else { continue }

            let normalized = Self.normalizeAddress(address)
            result[normalized] = AirPodsBatteryInfo(left: left, right: right, case_: case_)
        }

        return result.isEmpty ? nil : result
    }

    /// Uses `system_profiler SPBluetoothDataType -json` to get battery levels for connected devices.
    private func readFromSystemProfiler() -> [String: AirPodsBatteryInfo] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return [:]
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let btArray = json["SPBluetoothDataType"] as? [[String: Any]] else {
            return [:]
        }

        var result: [String: AirPodsBatteryInfo] = [:]

        for entry in btArray {
            if let connected = entry["device_connected"] as? [[String: Any]] {
                for deviceDict in connected {
                    for (_, props) in deviceDict {
                        guard let properties = props as? [String: Any] else { continue }
                        guard let address = properties["device_address"] as? String else { continue }

                        let left = Self.parseBatteryPercent(properties["device_batteryLevelLeft"])
                        let right = Self.parseBatteryPercent(properties["device_batteryLevelRight"])
                        let case_ = Self.parseBatteryPercent(properties["device_batteryLevelCase"])
                        let single = Self.parseBatteryPercent(properties["device_batteryLevel"])

                        guard left != nil || right != nil || case_ != nil || single != nil else { continue }

                        let normalized = Self.normalizeAddress(address)
                        result[normalized] = AirPodsBatteryInfo(
                            left: left ?? single,
                            right: right ?? single,
                            case_: case_
                        )
                    }
                }
            }
        }

        return result
    }

    /// Parses a battery percentage string like "97%" into an Int.
    private static func parseBatteryPercent(_ value: Any?) -> Int? {
        if let intVal = value as? Int { return intVal }
        guard let str = value as? String else { return nil }
        let digits = str.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
        return Int(digits)
    }

    /// Normalizes a MAC address to uppercase, hyphen-separated format (matching CoreAudio UIDs).
    static func normalizeAddress(_ address: String) -> String {
        address
            .replacingOccurrences(of: ":", with: "-")
            .uppercased()
    }

    /// Extracts the Bluetooth MAC address from a CoreAudio device UID.
    /// CoreAudio Bluetooth UIDs look like `30-82-16-B2-48-AF:output`.
    func extractBluetoothAddress(fromDeviceUID uid: String) -> String? {
        let parts = uid.split(separator: ":")
        guard let addressPart = parts.first else { return nil }
        let address = String(addressPart).uppercased()

        let macPattern = #"^[0-9A-F]{2}(-[0-9A-F]{2}){5}$"#
        guard address.range(of: macPattern, options: .regularExpression) != nil else {
            return nil
        }

        return address
    }

    /// Returns battery info for a given CoreAudio device UID.
    func batteryInfo(forDeviceUID uid: String) -> AirPodsBatteryInfo? {
        guard let address = extractBluetoothAddress(fromDeviceUID: uid) else {
            return nil
        }
        return cachedBatteryInfo[address]
    }
}
