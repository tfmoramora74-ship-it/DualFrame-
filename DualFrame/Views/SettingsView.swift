import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: CameraModel
    /// Not observed here: only the small row below redraws when readouts change.
    let readouts: DeviceReadouts
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                        overlayTile("Grade", icon: "number", isOn: $model.config.showGrid)
                        overlayTile("Mira", icon: "plus", isOn: $model.config.showCrosshair)
                        overlayTile("Nível", icon: "level", isOn: $model.config.showLevel)
                        overlayTile("Histograma", icon: "chart.bar.fill", isOn: $model.config.showHistogram)
                        overlayTile("Zebra", icon: "line.diagonal", isOn: $model.config.zebra)
                        overlayTile("Peaking", icon: "scope", isOn: $model.config.focusPeaking)
                    }
                    .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                } header: {
                    Text("Sobreposições")
                } footer: {
                    Text("Nunca são gravadas nos seus takes. Zebra listra o que vai estourar; peaking colore o que está em foco.")
                }

                Section("Gravação") {
                    toggle("Salvar em Fotos", "Cada gravação também é copiada para o app Fotos.",
                           isOn: $model.config.saveToPhotos)
                    picker("Estabilização", "O app escolhe o formato do sensor que suporta o modo pedido. Cinemática e Máxima seguram mais, com um leve atraso na prévia.",
                           selection: $model.config.stabilization, options: StabilizationChoice.allCases) { $0.label }
                    picker("Cor do vídeo", rangeSubtitle,
                           selection: $model.config.dynamicRange, options: DynamicRange.allCases) { $0.label }
                    picker("Codec", "HEVC é o melhor equilíbrio entre qualidade e tamanho.",
                           selection: $model.config.codec, options: VideoCodecChoice.allCases) { $0.label }
                    picker("Qualidade", "Taxa de bits do vídeo.",
                           selection: $model.config.quality, options: BitrateQuality.allCases) { $0.label }
                    toggle("Borda vermelha ao gravar", "Contorno vermelho na prévia enquanto grava.",
                           isOn: $model.config.recordingBorder)
                    toggle("Medidor de nível de áudio", "Medidor discreto durante a gravação; fica vermelho quando satura.",
                           isOn: $model.config.audioMeter)
                    toggle("Espelhar câmera frontal", "Salva o vídeo da câmera frontal espelhado, como na prévia.",
                           isOn: $model.config.mirrorFront)
                    toggle("Girar com o celular",
                           "A tela gira e os arquivos seguem o jeito que você segura. Desligado: tudo fica sempre em pé.",
                           isOn: $model.config.followDeviceRotation)
                    picker("Temporizador", "Atraso antes de fotografar ou começar a gravar. Toque no disparador para cancelar.",
                           selection: $model.config.timerSeconds, options: [0, 3, 5, 10]) { $0 == 0 ? "Desligado" : "\($0) s" }
                    toggle("Manter os controles manuais", "Mantém ISO, obturador, balanço de branco e foco ao trocar de lente.",
                           isOn: $model.config.keepManualControls)
                }

                Section {
                    picker("Lente", "As lentes físicas liberam todos os controles manuais.",
                           selection: $model.config.lens, options: LensChoice.allCases) { $0.label }
                    Picker(selection: $model.config.formatOverride) {
                        Text("Automático").tag(String?.none)
                        ForEach(model.state.formats) { format in
                            Text(format.label).tag(String?.some(format.id))
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Formato do sensor")
                            Text(model.state.activeFormat.map { "Agora: \($0.width)×\($0.height)" } ?? "")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .pickerStyle(.navigationLink)
                } header: {
                    Text("Câmera")
                } footer: {
                    Text("Todos os formatos saem do mesmo quadro 4:3 do sensor, perfeitamente sincronizados.")
                }

                Section("Sobre") {
                    LabeledContent("Câmera ativa", value: model.state.device?.localizedName ?? "—")
                    LabeledContent("Estabilização pedida", value: model.state.stabilizationRequested)
                    ActiveStabilizationRow(readouts: readouts)
                    LabeledContent("Versão", value: appVersion)
                    toggle("Diagnóstico de desempenho",
                           "Mostra na prévia os quadros por segundo reais, o tempo de processamento e quadros perdidos.",
                           isOn: $model.config.showDiagnostics)
                    ForEach(model.state.notes, id: \.self) { note in
                        Label(note, systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Ajustes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Concluído") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .tint(.accentTeal)
        .preferredColorScheme(.dark)
        .presentationDragIndicator(.visible)
    }

    private var rangeSubtitle: String {
        switch model.config.dynamicRange {
        case .sdr: return "SDR: arquivos menores, prontos para postar."
        case .hdr: return "HDR HLG 10-bit: mais alcance de luz, arquivos maiores."
        case .log: return model.state.appleLogAvailable
            ? "Apple Log 10-bit: imagem plana para colorir na edição."
            : "Apple Log só existe no iPhone 15 Pro ou mais novo; aqui grava HLG 10-bit, o perfil mais plano disponível."
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    private func overlayTile(_ title: String, icon: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 18, weight: .medium))
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(isOn.wrappedValue ? Color.accentTeal : Color.white)
            .frame(maxWidth: .infinity, minHeight: 70)
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isOn.wrappedValue ? Color.accentTeal : Color.white.opacity(0.15), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func toggle(_ title: String, _ subtitle: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .tint(.green)
    }

    private func picker<T: Hashable>(_ title: String, _ subtitle: String, selection: Binding<T>, options: [T],
                                     label: @escaping (T) -> String) -> some View {
        Picker(selection: selection) {
            ForEach(options, id: \.self) { Text(label($0)).tag($0) }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .pickerStyle(.menu)
    }
}

private struct ActiveStabilizationRow: View {
    @ObservedObject var readouts: DeviceReadouts

    var body: some View {
        LabeledContent("Estabilização ativa agora", value: readouts.activeStabilization)
    }
}
