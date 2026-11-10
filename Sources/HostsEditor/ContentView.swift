import SwiftUI

/// App state shared between AppKit and SwiftUI. An ObservableObject passed in from AppKit:
/// SwiftUI macros (@State, @Observable) need full Xcode, this also builds with Command Line Tools.
@MainActor
final class AppModel: ObservableObject {
    @Published var counter = 0
}

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles").font(.system(size: 40)).foregroundStyle(.tint)
            Text(L("Hello from HostsEditor")).font(.title2.weight(.semibold))
            Text(String(format: L("Clicked %d times"), model.counter)).foregroundStyle(.secondary)
            Button(L("Click me")) { model.counter += 1 }
                .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .frame(minWidth: 360, minHeight: 240)
    }
}
