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
- `BeautyFilter.swift` – Vision face detection + Core Image pipeline; takes a `CIImage`, so it can be reused per video frame.
- `CameraManager.swift` – AVCapture session, live preview frames, photo capture, save to Photos.
- `ContentView.swift` – UI.

## Video later
Add an `AVCaptureAudioDataOutput` + `AVAssetWriter`, and append the filtered frames produced in `captureOutput`.
