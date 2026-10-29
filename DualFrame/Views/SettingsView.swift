import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: CameraModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 10) {
                        overlayTile("Grade", icon: "number", isOn: $model.config.showGrid)
                        overlayTile("Mira", icon: "plus", isOn: $model.config.showCrosshair)
                        overlayTile("Nível", icon: "level", isOn: $model.config.showLevel)
                        overlayTile("Histograma", icon: "chart.bar.fill", isOn: $model.config.showHistogram)
                    }
                    .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                } header: {
                    Text("Sobreposições")
                } footer: {
                    Text("As sobreposições nunca são gravadas nos seus takes.")
                }

                Section("Gravação") {
                    toggle("Salvar em Fotos", "Cada gravação também é copiada para o app Fotos.",
                           isOn: $model.config.saveToPhotos)
                    picker("Estabilização", "Reduz a tremida ao filmar na mão. Padrão é a mais fluida na prévia.",
                           selection: $model.config.stabilization, options: StabilizationChoice.allCases) { $0.label }
                    toggle("Vídeo HDR", model.config.hdr ? "Grava em HLG 10-bit. Arquivos maiores."
                                                         : "Grava em SDR. Arquivos menores, mais fáceis de editar.",
                           isOn: $model.config.hdr)
                    picker("Codec", "HEVC é o melhor equilíbrio entre qualidade e tamanho.",
                           selection: $model.config.codec, options: VideoCodecChoice.allCases) { $0.label }
                    picker("Qualidade", "Taxa de bits do vídeo.",
                           selection: $model.config.quality, options: BitrateQuality.allCases) { $0.label }
                    toggle("Medidor de nível de áudio", "Medidor discreto durante a gravação; fica vermelho quando satura.",
                           isOn: $model.config.audioMeter)
                    toggle("Espelhar câmera frontal", "Salva o vídeo da câmera frontal espelhado, como na prévia.",
                           isOn: $model.config.mirrorFront)
                    toggle("Seguir a rotação do celular",
                           "Desligado: o celular é tratado sempre como em pé. Ligado: gravar deitado também sai na orientação certa.",
                           isOn: $model.config.followDeviceRotation)
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
                    LabeledContent("Estabilização ativa", value: model.state.stabilizationActive)
                    LabeledContent("Versão", value: appVersion)
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
