//
//  SME2Support.swift
//  Pic2PDF
//
//  Single source of truth for Arm SME2 acceleration: whether the CPU supports it,
//  whether the user wants it, the XNNPACK gate, and what XNNPACK actually chose.
//

import Foundation

// C shim in xnn_sme2.c (no bridging header, so bind the symbols directly).
@_silgen_name("pic2pdf_sme2_availability") private func c_sme2_availability() -> Int32
@_silgen_name("pic2pdf_xnn_set_sme2") private func c_xnn_set_sme2(_ enabled: Int32)
@_silgen_name("pic2pdf_xnn_sme2_active") private func c_xnn_sme2_active() -> Int32

enum SME2Support {
    enum Mode: String, Codable {
        case sme2
        case neon

        var displayName: String {
            switch self {
            case .sme2: return "SME2"
            case .neon: return "NEON"
            }
        }
    }

    // MARK: - Keys

    /// User preference, default true. Bound to the Settings toggle.
    static let enabledKey = "sme2Enabled"
    /// Debug-only override (honoured in DEBUG builds) to test the unsupported-device path.
    static let debugForceNoSME2Key = "debugForceNoSME2"
    /// Launch environment override (set from Xcode or devicectl) to test the unsupported-device path.
    static let forceNoSME2EnvironmentKey = "PIC2PDF_FORCE_NO_SME2"

    // MARK: - Support and preference

    enum Availability {
        /// The CPU has SME2 and the OS lets apps use it.
        case available
        /// The CPU has no SME2 (older than A18 / M4).
        case noHardware
        /// The CPU has SME2 but the OS traps SME instructions in apps (some iOS versions on A18 / A19).
        case blockedByOS
    }

    /// Whether this device can run SME2, read once per process like XNNPACK's own decision.
    /// A debug override can force `.noHardware`.
    static let availability: Availability = {
        if isForcedOff {
            NSLog("[SME2] Forcing unsupported (debug override)")
            return .noHardware
        }
        switch c_sme2_availability() {
        case 1: return .available
        case 2: return .blockedByOS
        default: return .noHardware
        }
    }()

    static var isSupported: Bool { availability == .available }

    /// "Yes", "No" or "Blocked by iOS", for the Analytics and benchmark screens.
    static var availabilityDescription: String {
        switch availability {
        case .available: return "Yes"
        case .noHardware: return "No"
        case .blockedByOS: return "Blocked by \(DeviceInfo.osName)"
        }
    }

    private static var isForcedOff: Bool {
        if ProcessInfo.processInfo.environment[forceNoSME2EnvironmentKey] == "1" {
            return true
        }
        #if DEBUG
        if UserDefaults.standard.bool(forKey: debugForceNoSME2Key) {
            return true
        }
        #endif
        return false
    }

    /// Registers `sme2Enabled = true` so a missing value means "on", not "off".
    private static let defaultsRegistered: Void = {
        UserDefaults.standard.register(defaults: [enabledKey: true])
    }()

    /// The user's preference (default true). Has no effect on devices without SME2.
    static var sme2Enabled: Bool {
        _ = defaultsRegistered
        return UserDefaults.standard.bool(forKey: enabledKey)
    }

    /// The mode the current preference asks for.
    static var requestedMode: Mode {
        return isSupported && sme2Enabled ? .sme2 : .neon
    }

    // MARK: - XNNPACK gate

    private static var isConfigured = false

    /// The mode passed to XNNPACK at launch. XNNPACK locks it on first init,
    /// so this is what the process runs with until it restarts.
    static private(set) var requestedModeAtLaunch: Mode = .neon

    /// What XNNPACK actually chose, read after the first model load. nil until then (or if unknown).
    static private(set) var activeMode: Mode?

    /// Sets XNNPACK's SME2 gate. Must run before any model is loaded; only the first call does anything.
    static func configureBeforeModelLoad() {
        guard !isConfigured else { return }
        isConfigured = true

        let mode = requestedMode
        requestedModeAtLaunch = mode
        c_xnn_set_sme2(mode == .sme2 ? 1 : 0)
        NSLog("[SME2] availability=\(availability) enabled=\(sme2Enabled) -> requesting \(mode.displayName)")
    }

    /// Reads what XNNPACK decided. Call only after a model has loaded (this initializes XNNPACK).
    static func recordActiveModeAfterLoad() {
        switch c_xnn_sme2_active() {
        case 1: activeMode = .sme2
        case 0: activeMode = .neon
        default: activeMode = nil
        }

        if let active = activeMode {
            if active != requestedModeAtLaunch {
                NSLog("[SME2] WARNING: requested \(requestedModeAtLaunch.displayName) but XNNPACK is using \(active.displayName)")
            } else {
                NSLog("[SME2] XNNPACK is using \(active.displayName)")
            }
        } else {
            NSLog("[SME2] Could not read XNNPACK's hardware config")
        }
    }

    /// True when the Settings toggle asks for a different mode than the one this process runs with.
    static var needsRestart: Bool {
        guard isConfigured else { return false }
        return requestedMode != requestedModeAtLaunch
    }

    // MARK: - What the UI shows

    /// The mode the model is running on, and why it differs from what Settings asks for.
    struct Status: Equatable {
        let mode: Mode
        /// "SME2 not available", "SME2 off in Settings" or "restart to use …"; nil when the model runs on SME2 as set.
        let note: String?

        /// One line for the Generate screen, e.g. "On-device · NEON · SME2 not available".
        var summary: String {
            ["On-device", mode.displayName, note].compactMap { $0 }.joined(separator: " · ")
        }
    }

    /// Settings and the Generate screen both show this, so they always agree.
    /// The mode is what XNNPACK actually chose, not the toggle. nil until a model has loaded.
    static var status: Status? {
        guard let active = activeMode else { return nil }
        if needsRestart {
            return Status(mode: active, note: "restart to use \(requestedMode.displayName)")
        }
        if active == .sme2 {
            return Status(mode: .sme2, note: nil)
        }
        // NEON: either SME2 was asked for and isn't available, or it's switched off.
        if availability == .available && requestedModeAtLaunch == .neon {
            return Status(mode: .neon, note: "SME2 off in Settings")
        }
        return Status(mode: .neon, note: "SME2 not available")
    }
}
