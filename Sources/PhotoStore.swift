import Photos
import UIKit

/// Private, app-only storage in Application Support (not visible in Files, USB, or backups).
enum PhotoStore {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var dir = base.appendingPathComponent("Selfies", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? dir.setResourceValues(values)
        }
        return dir
    }

    static func isVideo(_ url: URL) -> Bool { url.pathExtension == "mov" }

    static func list() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { ["jpg", "mov"].contains($0.pathExtension) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Moves a finished recording from temp storage into the private folder.
    static func addVideo(from temp: URL) -> URL? {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss_SSS"
        let url = directory.appendingPathComponent("video_\(f.string(from: Date())).mov")
        do {
            try FileManager.default.moveItem(at: temp, to: url)
            try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete],
                                                   ofItemAtPath: url.path)
            return url
        } catch { return nil }
    }

    static func add(_ image: UIImage) -> URL? {
        guard let data = image.jpegData(compressionQuality: 0.95) else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss_SSS"
        let url = directory.appendingPathComponent("selfie_\(f.string(from: Date())).jpg")
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            return url
        } catch { return nil }
    }

    static func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Explicit, user-initiated copy to Photos (add-only permission).
    static func saveToPhotos(_ url: URL, completion: @escaping (Bool) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                if isVideo(url) {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                } else {
                    PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
                }
            }) { ok, _ in
                DispatchQueue.main.async { completion(ok) }
            }
        }
    }
}
