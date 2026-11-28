import CatalogCore
import Darwin
import SwiftUI
import UIKit

private struct DiagnosticsKey: EnvironmentKey {
    static let defaultValue: DiagnosticStore? = nil
}

extension EnvironmentValues {
    var diagnostics: DiagnosticStore? {
        get { self[DiagnosticsKey.self] }
        set { self[DiagnosticsKey.self] = newValue }
    }
}

@main
struct CatalogApp: App {
    @Environment(\.scenePhase) private var scenePhase
    private let diagnostics: DiagnosticStore?

    init() {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        diagnostics = applicationSupport.map {
            DiagnosticStore(directory: $0.appending(path: "CatalogDiagnostics/v1"), metadata: Self.metadata)
        }
    }

    var body: some Scene {
        WindowGroup {
            CatalogView()
                .environment(\.diagnostics, diagnostics)
                .task { _ = await diagnostics?.flush() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background || phase == .active {
                        Task { _ = await diagnostics?.flush() }
                    }
                }
        }
    }

    private static var metadata: DiagnosticMetadata {
        let bundle = Bundle.main
        var machine = utsname()
        uname(&machine)
        let capacity = MemoryLayout.size(ofValue: machine.machine)
        let identifier = withUnsafePointer(to: &machine.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
        }
        #if targetEnvironment(simulator)
        let device = "Simulator " + (ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? identifier)
        #else
        let device = identifier
        #endif
        return DiagnosticMetadata(
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            revision: bundle.object(forInfoDictionaryKey: "CatalogSourceRevision") as? String ?? "unknown",
            operatingSystem: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            device: device
        )
    }
}
