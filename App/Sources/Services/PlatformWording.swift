import Foundation

/// The device the app runs on, for texts like "Keys stay in this \(Device.name)'s Keychain".
enum Device {
    static let name: String = {
        #if targetEnvironment(macCatalyst)
        return "Mac"
        #else
        // The model identifier ("iPad14,3", "iPhone17,1") — readable off the main actor, unlike UIDevice.
        var model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? ""
        if model.isEmpty {
            var size = 0; sysctlbyname("hw.machine", nil, &size, nil, 0)
            var buf = [CChar](repeating: 0, count: max(size, 1)); sysctlbyname("hw.machine", &buf, &size, nil, 0)
            model = String(cString: buf)
        }
        return model.hasPrefix("iPad") ? "iPad" : "iPhone"
        #endif
    }()
}
