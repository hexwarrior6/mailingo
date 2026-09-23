import SwiftUI

@main
struct MailingoApp: App {
    var body: some Scene {
        WindowGroup("Mailingo · S0 探针") {
            ProbeLogView()
                .frame(minWidth: 760, minHeight: 520)
        }
        .windowResizability(.contentMinSize)
    }
}
