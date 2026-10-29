import AVKit
import SwiftUI

struct GalleryView: View {
    @ObservedObject var store: TakeStore
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 2)]

    var body: some View {
        NavigationStack {
            Group {
                if store.takes.isEmpty {
                    ContentUnavailableView("Nenhuma gravação ainda", systemImage: "video",
                                           description: Text("Suas fotos e vídeos aparecem aqui."))
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(store.takes) { take in
                                NavigationLink(value: take) {
                                    TakeCell(take: take)
                                }
                                .contextMenu {
                                    ShareLink(items: take.files) { Label("Compartilhar", systemImage: "square.and.arrow.up") }
                                    Button(role: .destructive) { store.delete(take) } label: {
                                        Label("Apagar", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Gravações")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Take.self) { take in
                TakeDetailView(take: take, store: store)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Fechar")
                }
            }
            .onAppear { store.reload() }
        }
        .tint(.accentTeal)
        .preferredColorScheme(.dark)
    }
}

private struct TakeCell: View {
    let take: Take
    @State private var thumbnail: UIImage?

    var body: some View {
        Color.gray.opacity(0.2)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFill()
                }
            }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 3) {
                    Image(systemName: take.isPhoto ? "photo" : "video.fill")
                    Text(take.files.map { TakeStore.label(for: $0) }.joined(separator: "·"))
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .padding(4)
                .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 4))
                .padding(4)
            }
            .task {
                if let first = take.files.first { thumbnail = await Thumbnailer.image(for: first) }
            }
    }
}

struct TakeDetailView: View {
    let take: Take
    @ObservedObject var store: TakeStore
    @Environment(\.dismiss) private var dismiss
    @State private var selection: URL?
    @State private var player = AVPlayer()
    @State private var image: UIImage?
    @State private var details = ""
    @State private var message: String?
    @State private var confirmDelete = false

    var body: some View {
        VStack(spacing: 12) {
            if take.files.count > 1 {
                Picker("Formato", selection: $selection) {
                    ForEach(take.files, id: \.self) { url in
                        Text(TakeStore.label(for: url)).tag(URL?.some(url))
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
            }

            Group {
                if let selection, TakeStore.isPhoto(selection) {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFit()
                    } else {
                        ProgressView()
                    }
                } else {
                    VideoPlayer(player: player)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Text(details)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                ShareLink(items: take.files) {
                    Label("Compartilhar", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    PhotoSaver.save(take.files) { text in
                        Task { @MainActor in message = text }
                    }
                } label: {
                    Label("Salvar no Fotos", systemImage: "photo.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Apagar")
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .navigationTitle(take.date.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if selection == nil { selection = take.files.first }
        }
        .onDisappear { player.pause() }
        .task(id: selection) {
            guard let selection else { return }
            if TakeStore.isPhoto(selection) {
                player.pause()
                image = UIImage(contentsOfFile: selection.path)
            } else {
                player.replaceCurrentItem(with: AVPlayerItem(url: selection))
            }
            details = await Thumbnailer.details(for: selection)
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        }
        .confirmationDialog("Apagar este take e todos os arquivos?", isPresented: $confirmDelete,
                            titleVisibility: .visible) {
            Button("Apagar", role: .destructive) {
                player.pause()
                store.delete(take)
                dismiss()
            }
        }
    }
}
