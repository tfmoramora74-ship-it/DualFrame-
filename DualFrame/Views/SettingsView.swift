import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: CameraModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(OutputKind.allCases) { kind in
                        Toggle(kind.label, isOn: Binding(
                            get: { model.config.outputs.contains(kind) },
                            set: { on in
                                var outputs = model.config.outputs.filter { $0 != kind }
                                if on { outputs.append(kind) }
                                model.config.outputs = OutputKind.allCases.filter(outputs.contains)
                            }))
                    }
                } header: {
                    Text("Arquivos por gravação")
                } footer: {
                    Text("Todos saem do mesmo quadro do sensor, perfeitamente sincronizados. \"Sensor 4:3\" grava a imagem inteira, sem corte.")
                }

                Section("Vídeo") {
                    Picker("Resolução", selection: $model.config.resolution) {
                        ForEach(OutputResolution.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Quadros por segundo", selection: $model.config.fps) {
                        ForEach([24, 25, 30, 48, 50, 60], id: \.self) { Text("\($0) fps").tag($0) }
                    }
                    Toggle("HDR (HLG 10-bit)", isOn: $model.config.hdr)
                    Picker("Codec", selection: $model.config.codec) {
                        ForEach(VideoCodecChoice.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Qualidade (bitrate)", selection: $model.config.quality) {
                        ForEach(BitrateQuality.allCases) { Text($0.label).tag($0) }
                    }
                    .disabled(model.config.codec == .prores)
                    Picker("Estabilização", selection: $model.config.stabilization) {
                        ForEach(StabilizationChoice.allCases) { Text($0.label).tag($0) }
                    }
                }

                Section {
                    Picker("Lente", selection: $model.config.lens) {
                        ForEach(LensChoice.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Formato do sensor", selection: $model.config.formatOverride) {
                        Text("Automático").tag(String?.none)
                        ForEach(model.state.formats) { format in
                            Text(format.label).tag(String?.some(format.id))
                        }
                    }
                    .pickerStyle(.navigationLink)
                } header: {
                    Text("Câmera")
                } footer: {
                    Text("Lentes físicas liberam foco e balanço de branco manuais completos. A automática troca de lente sozinha conforme o zoom.")
                }

                Section("Sobreposições (não aparecem no vídeo)") {
                    Toggle("Guias dos cortes", isOn: $model.config.showGuides)
                    Toggle("Grade (terços)", isOn: $model.config.showGrid)
                    Toggle("Mira", isOn: $model.config.showCrosshair)
                    Toggle("Nível do horizonte", isOn: $model.config.showLevel)
                    Toggle("Histograma", isOn: $model.config.showHistogram)
                }

                Section("Armazenamento") {
                    Toggle("Copiar para o app Fotos", isOn: $model.config.saveToPhotos)
                    Text("As gravações também ficam no app Arquivos › No Meu iPhone › DualFrame › Takes.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Agora") {
                    LabeledContent("Câmera", value: model.state.device?.localizedName ?? "—")
                    LabeledContent("Formato", value: model.state.activeFormat?.label ?? "—")
                    LabeledContent("FPS", value: "\(Int(model.state.fps))")
                    LabeledContent("HDR", value: model.state.hdrActive ? "Ativo" : "Desligado")
                    LabeledContent("Estabilização", value: model.state.stabilizationActive)
                    ForEach(model.state.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Ajustes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Concluído") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
