import SwiftUI

// HAo Music: no upstream setup quiz — the NetEase upstream is built in,
// so the gate is a straight pass-through to the app.
struct UpstreamGate<Content: View>: View {
    let content: () -> Content

    var body: some View {
        content()
    }
}
