import SwiftData
import SwiftUI

@main
struct StillwaterRowApp: App {
    @State private var link = BluetoothLink()
    @State private var health = HealthStore()
    @State private var game = RowGame()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(link)
                .environment(health)
                .environment(game)
                .preferredColorScheme(.dark)
                .statusBarHidden(game.phase != .home)
                .persistentSystemOverlays(game.phase == .home ? .automatic : .hidden)
        }
        .modelContainer(for: RowSession.self)
    }
}
