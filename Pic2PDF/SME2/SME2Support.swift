//
//  SME2Support.swift
//  Pic2PDF
//
//  Single source of truth for Arm SME2 acceleration: whether the CPU supports it,
//  whether the user wants it, the XNNPACK gate, and what XNNPACK actually chose.
//

import Foundation

// C shim in xnn_sme2.c (no bridging header, so bind the symbols directly).
@_silgen_name("pic2pdf_cpu_has_sme2") private func c_cpu_has_sme2() -> Int32
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

    /// True if the CPU reports FEAT_SME2 (A18 / M4 and later), unless a debug override forces it off.
    /// Read once per process, like XNNPACK's own decision.
    static let isSupported: Bool = {
        if isForcedOff {
            NSLog("[SME2] Forcing unsupported (debug override)")
            return false
        }
        return c_cpu_has_sme2() == 1
    }()

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
        NSLog("[SME2] supported=\(isSupported) enabled=\(sme2Enabled) -> requesting \(mode.displayName)")
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
}
