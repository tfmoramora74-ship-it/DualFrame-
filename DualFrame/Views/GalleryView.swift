import AVKit
import SwiftUI

struct GalleryView: View {
    @ObservedObject var store: TakeStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if store.takes.isEmpty {
                    ContentUnavailableView("Nenhuma gravação", systemImage: "video",
                                           description: Text("Suas gravações aparecem aqui."))
                } else {
                    List {
                        ForEach(store.takes) { take in
                            NavigationLink(value: take) {
                                TakeRow(take: take)
                            }
                        }
                        .onDelete { indexSet in
                            indexSet.map { store.takes[$0] }.forEach(store.delete)
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
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fechar") { dismiss() }
                }
            }
            .onAppear { store.reload() }
        }
        .preferredColorScheme(.dark)
    }
}

private struct TakeRow: View {
    let take: Take
    @State private var thumbnail: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFill()
                } else {
                    Color.gray.opacity(0.3)
                }
            }
            .frame(width: 54, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text(take.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 15, weight: .semibold))
                Text(take.files.map { TakeStore.label(for: $0) }.joined(separator: " · "))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(ByteCountFormatter.string(fromByteCount: take.bytes, countStyle: .file))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
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
    @State private var details = ""
    @State private var message: String?
    @State private var confirmDelete = false

    var body: some View {
        VStack(spacing: 12) {
            Picker("Arquivo", selection: $selection) {
                ForEach(take.files, id: \.self) { url in
                    Text(TakeStore.label(for: url)).tag(URL?.some(url))
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            VideoPlayer(player: player)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)

            Text(details)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                ShareLink(items: take.files) {
                    Label("Compartilhar tudo", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)

                Button {
                    PhotoSaver.save(take.files) { text in
                        Task { @MainActor in message = text }
                    }
                } label: {
                    Label("Salvar no Fotos", systemImage: "photo.badge.plus")
                }
                .buttonStyle(.bordered)

                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.bordered)
            }
            .padding(.bottom)
        }
        .navigationTitle(take.date.formatted(date: .omitted, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if selection == nil { selection = take.files.first }
        }
        .onDisappear { player.pause() }
        .task(id: selection) {
            guard let selection else { return }
            player.replaceCurrentItem(with: AVPlayerItem(url: selection))
            details = await Thumbnailer.details(for: selection)
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        }
        .confirmationDialog("Apagar esta gravação e todos os arquivos?", isPresented: $confirmDelete,
                            titleVisibility: .visible) {
            Button("Apagar", role: .destructive) {
                player.pause()
                store.delete(take)
                dismiss()
            }
        }
    }
}
