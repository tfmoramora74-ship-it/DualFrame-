import AVKit
import SwiftUI

/// Google Photos–style library: day sections, a pinch-resizable square grid, filters,
/// multi-select, and a full-screen pager.
struct GalleryView: View {
    @ObservedObject var store: TakeStore
    @Environment(\.dismiss) private var dismiss

    enum Filter: String, CaseIterable, Identifiable {
        case all, photos, videos, raw
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return "Tudo"
            case .photos: return "Fotos"
            case .videos: return "Vídeos"
            case .raw: return "RAW"
            }
        }
    }

    @State private var filter: Filter = .all
    @State private var columns = 3
    @State private var pinchBase = 3
    @State private var selecting = false
    @State private var selection = Set<String>()
    @State private var viewer: ViewerItem?
    @State private var confirmDelete = false
    @State private var message: String?

    struct ViewerItem: Identifiable {
        let id: String
    }

    private var filtered: [Take] {
        store.takes.filter { take in
            switch filter {
            case .all: return true
            case .photos: return take.isPhoto
            case .videos: return !take.isPhoto
            case .raw: return take.files.contains { $0.pathExtension.lowercased() == "dng" }
            }
        }
    }

    private var sections: [(day: Date, takes: [Take])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filtered) { calendar.startOfDay(for: $0.date) }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Color.black.ignoresSafeArea()
                if store.takes.isEmpty {
                    ContentUnavailableView("Nenhuma gravação ainda", systemImage: "photo.on.rectangle.angled",
                                           description: Text("Suas fotos e vídeos aparecem aqui."))
                } else {
                    grid
                }
                if selecting { selectionBar }
            }
            .navigationTitle(selecting ? "\(selection.count) selecionado(s)" : "Galeria")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Fechar")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(selecting ? "Cancelar" : "Selecionar") {
                        selecting.toggle()
                        selection.removeAll()
                    }
                    .disabled(store.takes.isEmpty)
                }
            }
            .onAppear { store.reload() }
            .fullScreenCover(item: $viewer) { item in
                MediaPager(store: store, takes: filtered, startID: item.id)
            }
            .confirmationDialog("Apagar \(selection.count) item(ns) e todos os seus arquivos?",
                                isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Apagar", role: .destructive) {
                    for take in store.takes where selection.contains(take.id) { store.delete(take) }
                    selection.removeAll()
                    selecting = false
                }
            }
            .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK") { message = nil }
            }
        }
        .tint(.accentTeal)
        .preferredColorScheme(.dark)
    }

    private var grid: some View {
        ScrollView {
            filterChips
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                ForEach(sections, id: \.day) { section in
                    Text(dayTitle(section.day))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.top, 18)
                        .padding(.bottom, 8)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: columns), spacing: 2) {
                        ForEach(section.takes) { take in
                            GridCell(take: take, selecting: selecting, selected: selection.contains(take.id))
                                .onTapGesture { tapped(take) }
                                .onLongPressGesture(minimumDuration: 0.35) {
                                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                    selecting = true
                                    selection.insert(take.id)
                                }
                        }
                    }
                }
            }
            .padding(.bottom, selecting ? 90 : 20)
        }
        .simultaneousGesture(
            MagnificationGesture()
                .onChanged { scale in
                    let target = Int((Double(pinchBase) / Double(scale)).rounded())
                    let clamped = min(6, max(2, target))
                    if clamped != columns { withAnimation(.spring(duration: 0.3)) { columns = clamped } }
                }
                .onEnded { _ in pinchBase = columns }
        )
    }

    private var filterChips: some View {
        HStack(spacing: 8) {
            ForEach(Filter.allCases) { item in
                let on = filter == item
                Button { withAnimation(.snappy) { filter = item } } label: {
                    Text(item.label)
                        .font(.system(size: 14, weight: .medium))
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .foregroundStyle(on ? Color.black : Color.white)
                        .background(on ? Color.accentTeal : Color.white.opacity(0.1), in: Capsule())
                }
            }
            Spacer()
        }
    }

    private var selectionBar: some View {
        let chosen = store.takes.filter { selection.contains($0.id) }
        let files = chosen.flatMap(\.files)
        return HStack(spacing: 28) {
            ShareLink(items: files) {
                VStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.up")
                    Text("Compartilhar").font(.system(size: 11))
                }
            }
            Button {
                PhotoSaver.save(files) { text in Task { @MainActor in message = text } }
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "photo.badge.plus")
                    Text("Salvar no Fotos").font(.system(size: 11))
                }
            }
            Button(role: .destructive) { confirmDelete = true } label: {
                VStack(spacing: 4) {
                    Image(systemName: "trash")
                    Text("Apagar").font(.system(size: 11))
                }
            }
        }
        .font(.system(size: 20))
        .disabled(selection.isEmpty)
        .padding(.horizontal, 28).padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.bottom, 14)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func tapped(_ take: Take) {
        if selecting {
            if selection.contains(take.id) { selection.remove(take.id) } else { selection.insert(take.id) }
        } else {
            viewer = ViewerItem(id: take.id)
        }
    }

    private func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Hoje" }
        if calendar.isDateInYesterday(day) { return "Ontem" }
        let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: Date())
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "pt_BR")
        formatter.dateFormat = sameYear ? "EEE, d 'de' MMM" : "d 'de' MMM 'de' yyyy"
        return formatter.string(from: day).capitalized
    }
}

private struct GridCell: View {
    let take: Take
    let selecting: Bool
    let selected: Bool
    @State private var thumbnail: UIImage?
    @State private var duration: String?

    var body: some View {
        Color.white.opacity(0.06)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFill()
                }
            }
            .clipped()
            .overlay(alignment: .topTrailing) {
                if let duration {
                    HStack(spacing: 3) {
                        Text(duration)
                        Image(systemName: "play.fill").font(.system(size: 8))
                    }
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
                    .padding(6)
                }
            }
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 4) {
                    if take.files.count > 1 {
                        Label("\(take.files.filter { $0.pathExtension.lowercased() != "dng" }.count)",
                              systemImage: "square.on.square")
                    }
                    if take.files.contains(where: { $0.pathExtension.lowercased() == "dng" }) {
                        Text("RAW").fontWeight(.heavy)
                    }
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(radius: 2)
                .padding(6)
            }
            .overlay {
                if selecting {
                    ZStack(alignment: .topLeading) {
                        Color.black.opacity(selected ? 0.25 : 0)
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 22))
                            .foregroundStyle(selected ? Color.accentTeal : Color.white)
                            .background(selected ? Circle().fill(Color.white).padding(3) : nil)
                            .padding(6)
                    }
                }
            }
            .scaleEffect(selecting && selected ? 0.9 : 1)
            .animation(.spring(duration: 0.2), value: selected)
            .contentShape(Rectangle())
            .task {
                guard let first = take.files.first else { return }
                thumbnail = await Thumbnailer.image(for: first)
                if !take.isPhoto, let seconds = try? await AVURLAsset(url: first).load(.duration).seconds,
                   seconds.isFinite {
                    duration = formatDuration(seconds)
                }
            }
    }
}

/// Full-screen viewer: swipe between items, pinch to zoom, tap to hide the chrome.
private struct MediaPager: View {
    @ObservedObject var store: TakeStore
    let takes: [Take]
    @Environment(\.dismiss) private var dismiss
    @State private var currentID: String
    @State private var chromeVisible = true
    @State private var message: String?
    @State private var confirmDelete = false
    @State private var showInfo = false
    @State private var fileForTake: [String: URL] = [:]

    init(store: TakeStore, takes: [Take], startID: String) {
        self.store = store
        self.takes = takes
        _currentID = State(initialValue: startID)
    }

    private var current: Take? { takes.first { $0.id == currentID } }
    private func file(for take: Take) -> URL? { fileForTake[take.id] ?? take.files.first }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TabView(selection: $currentID) {
                ForEach(takes) { take in
                    MediaPage(url: file(for: take), active: take.id == currentID) {
                        withAnimation(.easeOut(duration: 0.2)) { chromeVisible.toggle() }
                    }
                    .tag(take.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            if chromeVisible, let take = current {
                VStack(spacing: 0) {
                    topBar(take)
                    Spacer()
                    bottomBar(take)
                }
                .transition(.opacity)
            }
        }
        .statusBarHidden(!chromeVisible)
        .preferredColorScheme(.dark)
        .tint(.accentTeal)
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        }
        .confirmationDialog("Apagar este item e todos os seus arquivos?", isPresented: $confirmDelete,
                            titleVisibility: .visible) {
            Button("Apagar", role: .destructive) {
                guard let take = current else { return }
                let index = takes.firstIndex(of: take) ?? 0
                store.delete(take)
                let remaining = takes.filter { $0.id != take.id }
                if remaining.isEmpty {
                    dismiss()
                } else {
                    currentID = remaining[min(index, remaining.count - 1)].id
                }
            }
        }
        .sheet(isPresented: $showInfo) {
            if let take = current { InfoSheet(take: take) }
        }
    }

    private func topBar(_ take: Take) -> some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left").font(.system(size: 18, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Voltar")
            VStack(alignment: .leading, spacing: 1) {
                Text(take.date.formatted(date: .abbreviated, time: .omitted)).font(.system(size: 15, weight: .semibold))
                Text(take.date.formatted(date: .omitted, time: .shortened)).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { showInfo = true } label: {
                Image(systemName: "info.circle").font(.system(size: 18)).frame(width: 44, height: 44)
            }
            .accessibilityLabel("Informações")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .background(LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea())
    }

    private func bottomBar(_ take: Take) -> some View {
        VStack(spacing: 14) {
            if take.files.count > 1 {
                HStack(spacing: 6) {
                    ForEach(take.files, id: \.self) { url in
                        let on = file(for: take) == url
                        Button { fileForTake[take.id] = url } label: {
                            Text(TakeStore.label(for: url))
                                .font(.system(size: 13, weight: .semibold))
                                .padding(.horizontal, 14).padding(.vertical, 7)
                                .foregroundStyle(on ? Color.black : Color.white)
                                .background(on ? Color.accentTeal : Color.white.opacity(0.15), in: Capsule())
                        }
                    }
                }
            }
            HStack {
                ShareLink(items: [file(for: take)].compactMap { $0 }) {
                    barIcon("square.and.arrow.up", "Compartilhar")
                }
                Spacer()
                Button {
                    PhotoSaver.save(take.files) { text in Task { @MainActor in message = text } }
                } label: { barIcon("photo.badge.plus", "Salvar no Fotos") }
                Spacer()
                ShareLink(items: take.files) { barIcon("square.stack", "Enviar todos") }
                Spacer()
                Button(role: .destructive) { confirmDelete = true } label: { barIcon("trash", "Apagar") }
            }
            .padding(.horizontal, 28)
        }
        .foregroundStyle(.white)
        .padding(.top, 20)
        .padding(.bottom, 8)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea())
    }

    private func barIcon(_ name: String, _ label: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: name).font(.system(size: 20))
            Text(label).font(.system(size: 10))
        }
    }
}

/// One page of the pager: a zoomable photo, or a zoomable video with its own player.
private struct MediaPage: View {
    let url: URL?
    let active: Bool
    let onTap: () -> Void
    @State private var image: UIImage?
    @State private var player = AVPlayer()

    var body: some View {
        Group {
            if let url, TakeStore.isPhoto(url) {
                if let image {
                    ZoomableMedia(content: .image(image), onTap: onTap)
                } else {
                    ProgressView()
                }
            } else {
                VStack(spacing: 6) {
                    ZoomableMedia(content: .video(player), onTap: onTap)
                    PlayerControls(player: player).padding(.bottom, 110)
                }
            }
        }
        .task(id: url) {
            guard let url else { return }
            if TakeStore.isPhoto(url) {
                player.pause()
                image = nil
                image = await Task.detached(priority: .userInitiated) { UIImage(contentsOfFile: url.path) }.value
            } else {
                player.replaceCurrentItem(with: AVPlayerItem(url: url))
            }
        }
        .onChange(of: active) { _, isActive in
            if !isActive { player.pause() }
        }
        .onDisappear { player.pause() }
    }
}

private struct InfoSheet: View {
    let take: Take
    @State private var details: [URL: String] = [:]

    var body: some View {
        NavigationStack {
            List {
                Section("Arquivos") {
                    ForEach(take.files, id: \.self) { url in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(TakeStore.label(for: url)) · \(url.lastPathComponent)")
                                .font(.system(size: 14, weight: .medium))
                            Text(details[url] ?? "…").font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                            Text(size(of: url)).font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    LabeledContent("Data", value: take.date.formatted(date: .long, time: .standard))
                    LabeledContent("Total", value: ByteCountFormatter.string(fromByteCount: take.bytes, countStyle: .file))
                }
            }
            .navigationTitle("Informações")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .task {
            for url in take.files { details[url] = await Thumbnailer.details(for: url) }
        }
    }

    private func size(of url: URL) -> String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
