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
    @State private var showAdjust = false
    @State private var videoMode = false
    @AppStorage("timerSeconds") private var timerSeconds = 0
    @State private var countdown: Int?
    @State private var countdownTask: Task<Void, Never>?

    private func cycleTimer() {
        let options = [0, 3, 5, 10]
        let i = options.firstIndex(of: timerSeconds) ?? 0
        timerSeconds = options[(i + 1) % options.count]
    }

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
                            let s = Int((camera.pausedAt ?? ctx.date).timeIntervalSince(start))
                            Label(String(format: "%d:%02d", s / 60, s % 60),
                                  systemImage: camera.pausedAt == nil ? "record.circle" : "pause.circle")
                                .foregroundStyle(camera.pausedAt == nil ? .red : .orange).padding(8)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                    }
                    Spacer()
                    Button { cycleTimer() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: timerSeconds == 0 ? "timer" : "timer.circle.fill")
                            if timerSeconds > 0 { Text("\(timerSeconds)s").font(.footnote.bold()) }
                        }
                        .font(.title2).padding(12).background(.ultraThinMaterial, in: Capsule())
                    }
                    .disabled(isRecording || countdownTask != nil)
                    .accessibilityLabel("Timer")
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

            if let countdown {
                Text("\(countdown)")
                    .font(.system(size: 160, weight: .bold, design: .rounded))
                    .foregroundStyle(.white).shadow(radius: 8)
                    .id(countdown)
                    .transition(.scale.combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.25), value: countdown)
        .tint(.white)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showGallery) { GalleryView() }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .onAppear { camera.start() }
        .onDisappear { cancelCountdown(); camera.stop() }
        .alert("Error", isPresented: Binding(get: { camera.errorMessage != nil },
                                             set: { _ in camera.errorMessage = nil })) {
            Button("OK", role: .cancel) {}
        } message: { Text(camera.errorMessage ?? "") }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            if showAdjust {
                Toggle("Beautify", isOn: $camera.settings.enabled).padding(.horizontal)
                if camera.settings.enabled {
                    slider("Smooth", $camera.settings.smoothing)
                    slider("Bright", $camera.settings.brightness)
                    slider("Warm", $camera.settings.warmth)
                }
            }
            Picker("Mode", selection: $videoMode) {
                Text("Photo").tag(false)
                Text("Video").tag(true)
            }
            .pickerStyle(.segmented).padding(.horizontal)
            .disabled(isRecording || countdownTask != nil)
            HStack(spacing: 36) {
                // Left slot: pause/resume while recording; right slot keeps the shutter centered.
                Group {
                    if videoMode && isRecording {
                        Button {
                            if camera.pausedAt == nil { camera.pauseRecording() } else { camera.resumeRecording() }
                        } label: {
                            Image(systemName: camera.pausedAt == nil ? "pause.fill" : "play.fill")
                                .font(.title2).frame(width: 52, height: 52)
                                .background(.white.opacity(0.2), in: Circle())
                        }
                        .accessibilityLabel(camera.pausedAt == nil ? "Pause" : "Resume")
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 52, height: 52)

                shutterButton

                Button { withAnimation(.easeInOut(duration: 0.2)) { showAdjust.toggle() } } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.title2).frame(width: 52, height: 52)
                        .background(showAdjust ? .white.opacity(0.35) : .white.opacity(0.2), in: Circle())
                }
                .accessibilityLabel(showAdjust ? "Hide adjustments" : "Show adjustments")
            }
        }
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding()
    }

    private var shutterButton: some View {
        Button { shutterTapped() } label: {
            Circle().strokeBorder(.white, lineWidth: 4).frame(width: 72, height: 72)
                .overlay(
                    Group {
                        if countdownTask != nil {
                            Image(systemName: "xmark").font(.title.bold())
                        } else if videoMode && isRecording {
                            RoundedRectangle(cornerRadius: 6).fill(.red).padding(22)
                        } else {
                            Circle().fill(videoMode ? Color.red : Color.white).padding(7)
                        }
                    }
                )
        }
        .accessibilityLabel(videoMode && isRecording ? "Stop" : (videoMode ? "Record" : "Take photo"))
    }

    /// Tap starts the countdown (if a timer is set); tapping during the countdown cancels it.
    private func shutterTapped() {
        if let task = countdownTask {
            task.cancel()
            countdownTask = nil
            countdown = nil
            return
        }
        if videoMode && isRecording { camera.stopRecording(); return }
        guard timerSeconds > 0 else { fireShutter(); return }
        countdownTask = Task { @MainActor in
            for remaining in stride(from: timerSeconds, to: 0, by: -1) {
                countdown = remaining
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            countdown = nil
            countdownTask = nil
            fireShutter()
        }
    }

    private func fireShutter() {
        if videoMode { camera.startRecording() } else { camera.capture() }
    }

    private func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        countdown = nil
    }

    private func slider(_ title: String, _ value: Binding<Double>) -> some View {
        HStack {
            Text(title).font(.caption).frame(width: 52, alignment: .leading)
            Slider(value: value, in: 0...1)
        }.padding(.horizontal)
    }
}
