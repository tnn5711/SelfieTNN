import SwiftUI

struct PreviewView: UIViewRepresentable {
    let image: CGImage?

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .black
        v.layer.contentsGravity = .resizeAspectFill
        v.layer.masksToBounds = true
        return v
    }

    func updateUIView(_ view: UIView, context: Context) {
        view.layer.contents = image
    }
}

struct ContentView: View {
    @StateObject private var camera = CameraManager()
    @State private var showGallery = false
    @State private var showSettings = false
    @State private var videoMode = false

    private var isRecording: Bool { camera.recordingStartedAt != nil }

    var body: some View {
        ZStack {
            PreviewView(image: camera.previewImage).ignoresSafeArea()

            if !camera.authorized {
                Text("Camera access is required.\nEnable it in Settings.")
                    .multilineTextAlignment(.center).foregroundStyle(.white)
            }

            VStack {
                HStack {
                    Button { showGallery = true } label: {
                        Image(systemName: "photo.on.rectangle")
                            .font(.title2).padding(12).background(.ultraThinMaterial, in: Circle())
                    }
                    Spacer()
                    if let start = camera.recordingStartedAt {
                        TimelineView(.periodic(from: start, by: 1)) { ctx in
                            let s = Int(ctx.date.timeIntervalSince(start))
                            Label(String(format: "%d:%02d", s / 60, s % 60), systemImage: "record.circle")
                                .foregroundStyle(.red).padding(8)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                    }
                    Spacer()
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                            .font(.title2).padding(12).background(.ultraThinMaterial, in: Circle())
                    }
                    .disabled(isRecording)
                    Button { camera.flip() } label: {
                        Image(systemName: "arrow.triangle.2.circlepath.camera")
                            .font(.title2).padding(12).background(.ultraThinMaterial, in: Circle())
                    }
                    .disabled(isRecording)
                }.padding()
                Spacer()
                controls
            }

            if camera.lastSaved {
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .padding().background(.ultraThinMaterial, in: Capsule())
            }
        }
        .tint(.white)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showGallery) { GalleryView() }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
        .alert("Error", isPresented: Binding(get: { camera.errorMessage != nil },
                                             set: { _ in camera.errorMessage = nil })) {
            Button("OK", role: .cancel) {}
        } message: { Text(camera.errorMessage ?? "") }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            Toggle("Beautify", isOn: $camera.settings.enabled).padding(.horizontal)
            if camera.settings.enabled {
                slider("Smooth", $camera.settings.smoothing)
                slider("Bright", $camera.settings.brightness)
                slider("Warm", $camera.settings.warmth)
            }
            Picker("Mode", selection: $videoMode) {
                Text("Photo").tag(false)
                Text("Video").tag(true)
            }
            .pickerStyle(.segmented).padding(.horizontal)
            .disabled(isRecording)
            Button {
                if !videoMode { camera.capture() }
                else if isRecording { camera.stopRecording() }
                else { camera.startRecording() }
            } label: {
                Circle().strokeBorder(.white, lineWidth: 4).frame(width: 72, height: 72)
                    .overlay(
                        Group {
                            if videoMode && isRecording {
                                RoundedRectangle(cornerRadius: 6).fill(.red).padding(22)
                            } else {
                                Circle().fill(videoMode ? Color.red : Color.white).padding(7)
                            }
                        }
                    )
            }
        }
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding()
    }

    private func slider(_ title: String, _ value: Binding<Double>) -> some View {
        HStack {
            Text(title).font(.caption).frame(width: 52, alignment: .leading)
            Slider(value: value, in: 0...1)
        }.padding(.horizontal)
    }
}
