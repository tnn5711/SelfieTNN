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
                    Text("No selfies yet").foregroundStyle(.secondary).padding(.top, 80)
                }
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(photos, id: \.self) { url in
                        Button { selected = url } label: {
                            Color.clear.aspectRatio(1, contentMode: .fit)
                                .overlay(AsyncThumb(url: url))
                                .clipped()
                        }
                    }
                }
            }
            .navigationTitle("Selfies")
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
    var body: some View {
        if let img = UIImage(contentsOfFile: url.path) {
            Image(uiImage: img).resizable().scaledToFill()
        } else {
            Color.gray
        }
    }
}

private struct DetailView: View {
    let url: URL
    let onSaveToPhotos: () -> Void
    let onDelete: () -> Void
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Group {
                if let img = UIImage(contentsOfFile: url.path) {
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
            .confirmationDialog("Delete this selfie?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive, action: onDelete)
            }
        }
    }
}
