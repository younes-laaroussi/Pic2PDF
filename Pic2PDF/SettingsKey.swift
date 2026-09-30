//
//  SettingsKey.swift
//  Pic2PDF
//

import Foundation

/// UserDefaults keys for app settings, with their defaults.
enum SettingsKey {
    static let keepDiagnostics = "keepDiagnostics"
    static let latexAutoFix = "latexAutoFix"
    static let latexModelRepair = "latexModelRepair"
    static let imageMaxDimension = "imageMaxDimension"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            keepDiagnostics: true,
            latexAutoFix: true,
            latexModelRepair: true,
            imageMaxDimension: 768,
        ])
    }
}
