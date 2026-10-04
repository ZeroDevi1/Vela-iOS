import Foundation
import VelaNetwork
#if canImport(UIKit)
import UIKit
#endif

public enum DeviceIdentity {
    private static let deviceIDAccount = "device-id"

    /// 生成或读取稳定的设备 id。存 Keychain 而不是 UserDefaults，重装应用后仍保持同一设备身份，避免服务器堆积重复设备。
    @MainActor
    public static func current(keychain: KeychainStore = KeychainStore(service: "app.vela.device")) -> ClientIdentity {
        let deviceID: String
        if let stored = try? keychain.string(for: deviceIDAccount), !stored.isEmpty {
            deviceID = stored
        } else {
            deviceID = UUID().uuidString
            try? keychain.set(deviceID, for: deviceIDAccount)
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        return ClientIdentity(deviceName: deviceName, deviceID: deviceID, version: version)
    }

    @MainActor
    private static var deviceName: String {
        #if os(macOS)
        Host.current().localizedName ?? "Mac"
        #else
        UIDevice.current.model
        #endif
    }
}
