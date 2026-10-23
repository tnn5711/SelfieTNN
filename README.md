# SelfieTNN

SwiftUI selfie app with live beautify (face-masked skin smoothing, brightness, warmth).

## Build (on a Mac)
```
brew install xcodegen
cd SelfieTNN
xcodegen generate
open SelfieTNN.xcodeproj
```
Set your signing team, run on a real device (camera required, iOS 17+).

## Structure
- `BeautyFilter.swift` – Vision face landmarks + Core Image pipeline; takes a `CIImage`, shared by preview, photos and video.
- `CameraManager.swift` – AVCapture session, live preview frames, photo capture, recording control.
- `VideoRecorder.swift` – AVAssetWriter that encodes beautified frames and mic audio to `.mov`.
- `PhotoStore.swift` – private on-device storage for photos and videos, save to Photos, delete.
- `ContentView.swift` / `GalleryView.swift` – UI.
