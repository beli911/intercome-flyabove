import SwiftUI

@main
struct FlyAboveIntercomApp: App {
    @StateObject private var viewModel = IntercomViewModel(
        transport: PreviewIntercomTransport(),
        audioSession: AudioSessionController()
    )

    var body: some Scene {
        WindowGroup {
            RootView(viewModel: viewModel)
        }
    }
}
