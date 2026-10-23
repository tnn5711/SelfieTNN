import AVKit
import SwiftUI

struct GalleryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var photos = PhotoStore.list()
    @State private var selected: URL?
    @State private var toast: String?

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 2)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if photos.isEmpty {
                    Text("Nothing here yet").foregroundStyle(.secondary).padding(.top, 80)
                }
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(photos, id: \.self) { url in
                        Button { selected = url } label: {
                            Color.clear.aspectRatio(1, contentMode: .fit)
                                .overlay(AsyncThumb(url: url))
                                .overlay(alignment: .bottomLeading) {
                                    if PhotoStore.isVideo(url) {
                                        Image(systemName: "video.fill").font(.caption).padding(4)
                                    }
                                }
                                .clipped()
                        }
                    }
                }
            }
            .navigationTitle("Library")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $selected) { url in
                DetailView(url: url,
                           onSaveToPhotos: {
                               PhotoStore.saveToPhotos(url) { toast = $0 ? "Saved to Photos" : "Photos access denied" }
                           },
                           onDelete: {
                               PhotoStore.delete(url)
                               photos = PhotoStore.list()
                               selected = nil
                           })
            }
            .overlay(alignment: .bottom) {
                if let toast {
                    Text(toast).padding().background(.ultraThinMaterial, in: Capsule())
                        .task { try? await Task.sleep(for: .seconds(1.5)); self.toast = nil }
                }
            }
        }
    }
}

extension URL: @retroactive Identifiable { public var id: String { absoluteString } }

private struct AsyncThumb: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color.gray.opacity(0.3)
            }
        }
        .task {
            let u = url
            image = await Task.detached(priority: .utility) { () -> UIImage? in
                if PhotoStore.isVideo(u) {
                    let gen = AVAssetImageGenerator(asset: AVURLAsset(url: u))
                    gen.appliesPreferredTrackTransform = true
                    gen.maximumSize = CGSize(width: 300, height: 300)
                    return (try? gen.copyCGImage(at: .zero, actualTime: nil)).map { UIImage(cgImage: $0) }
                }
                return UIImage(contentsOfFile: u.path)
            }.value
        }
    }
}

private struct DetailView: View {
    let url: URL
    let onSaveToPhotos: () -> Void
    let onDelete: () -> Void
    @State private var confirmDelete = false
    @State private var player: AVPlayer?

    var body: some View {
        NavigationStack {
            Group {
                if PhotoStore.isVideo(url) {
                    VideoPlayer(player: player)
                        .onAppear { player = AVPlayer(url: url) }
                        .onDisappear { player?.pause() }
                } else if let img = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: img).resizable().scaledToFit()
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Save to Photos", systemImage: "square.and.arrow.down", action: onSaveToPhotos)
                    Spacer()
                    ShareLink(item: url)
                    Spacer()
                    Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
                }
            }
            .confirmationDialog("Delete this item?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive, action: onDelete)
            }
        }
    }
}
