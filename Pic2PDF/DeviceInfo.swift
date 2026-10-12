//
//  DeviceInfo.swift
//  Pic2PDF
//
//  Device model and OS name for diagnostics, including when the iPad app runs on a Mac.
//

import UIKit

enum DeviceInfo {
    /// "iOS", "iPadOS" or "macOS" (the iPad app running on an Apple silicon Mac).
    static var osName: String {
        ProcessInfo.processInfo.isiOSAppOnMac ? "macOS" : UIDevice.current.systemName
    }

    /// Hardware model identifier, e.g. "iPhone17,2" or "Mac16,13" (UIDevice.model only says "iPhone").
    static func modelIdentifier() -> String {
        // In the simulator uname reports the Mac's architecture; the simulated model is in the environment.
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated + " (Simulator)"
        }
        // On a Mac, uname doesn't name the model; hw.model does.
        if ProcessInfo.processInfo.isiOSAppOnMac, let model = sysctlString("hw.model") {
            return model
        }
        var systemInfo = utsname()
        uname(&systemInfo)
        let identifier = withUnsafeBytes(of: &systemInfo.machine) { buffer in
            String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return identifier.isEmpty ? UIDevice.current.model : identifier
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
