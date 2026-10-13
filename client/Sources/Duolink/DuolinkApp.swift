import SwiftUI

@main
struct DuolinkApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            // Two paths merged into one while the tunnel runs.
            Image(systemName: model.isOn ? "arrow.triangle.merge" : "arrow.triangle.branch")
        }
        .menuBarExtraStyle(.window)
    }
}
