import SwiftUI

#if canImport(ScreenCaptureKit)

@available(iOS 27.0, *)
struct NativeCaptureSection: View {
    @ObservedObject private var controller = ScreenCaptureController.shared

    var body: some View {
        VStack(spacing: 8) {
            Button {
                if controller.isRunning {
                    controller.stop()
                } else {
                    controller.start()
                }
            } label: {
                Text(controller.isRunning ? "Stop native capture" : "Native capture (2796x1290)")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(controller.isRunning ? Color.red : Color.blue)
                    .foregroundColor(.white)
                    .clipShape(Capsule())
            }

            Toggle(isOn: $controller.flip180) {
                Text("Flip 180°")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.9))
            }
            .toggleStyle(.switch)
            .frame(maxWidth: 200)

            Picker("FPS", selection: $controller.fps) {
                Text("30").tag(30)
                Text("60").tag(60)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 160)

            Text(controller.status)
                .font(.caption2)
                .foregroundColor(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
    }
}

#endif
