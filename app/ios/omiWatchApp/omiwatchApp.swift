import SwiftUI
import WatchKit

@main
struct omiwatch_Watch_AppApp: App {
    @StateObject private var viewModel = WatchAudioRecorderViewModel()

    var body: some Scene {
        WindowGroup {
            WatchRecorderView(viewModel: viewModel)
        }
        .onAppear {
            // Register Quick Action handler
            QuickActionHandler.shared
            // Set the shared reference so Quick Action can access the ViewModel
            WatchAudioRecorderViewModel.shared = viewModel
        }
    }
}

// MARK: - Quick Action Handler

/// Handles the Quick Action button on the Apple Watch.
/// When the user presses the Quick Action button, the app opens and
/// immediately starts recording.
class QuickActionHandler: NSObject, WKApplicationDelegate {
    static let shared = QuickActionHandler()

    private override init() {
        super.init()
        WKApplication.shared().delegate = self
    }

    func applicationDidBecomeActive(_ application: WKApplication) {
        print("QuickAction: App became active")
    }

    func applicationDidOpen(_ application: WKApplication, with options: [WKOpenOptionsKey: Any]) {
        print("QuickAction: App opened with options: \(options)")
        // If opened via Quick Action, start recording immediately
        if let wasOpenedByUser = options[WKOpenOptionsKey.wasOpenedByUser] as? Bool, wasOpenedByUser {
            print("QuickAction: Starting recording via Quick Action")
            WatchAudioRecorderViewModel.shared?.startRecording()
        }
    }
}

// MARK: - Shared ViewModel Reference

extension WatchAudioRecorderViewModel {
    static var shared: WatchAudioRecorderViewModel?
}
