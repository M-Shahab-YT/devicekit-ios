import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            BroadcastStarterView()
            Text("Press to Start Broadcasting")
                .font(.footnote)
                .foregroundColor(.white.opacity(0.8))

            #if canImport(ScreenCaptureKit)
            if #available(iOS 27.0, *) {
                Divider()
                    .background(Color.white.opacity(0.3))
                    .padding(.horizontal, 40)
                NativeCaptureSection()
            }
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}
