import SwiftUI

/// Row of pro-control chips; the selected one opens a slider with an Auto button.
struct ManualControlsView: View {
    @ObservedObject var model: CameraModel
    @Binding var selected: ManualControl?

    var body: some View {
        VStack(spacing: 8) {
            if let selected {
                panel(for: selected)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HStack(spacing: 6) {
                ForEach(ManualControl.allCases) { control in
                    chip(control)
                }
                Button {
                    model.resetManual()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 36, height: 40)
                        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .accessibilityLabel("Voltar tudo para automático")
            }
            .padding(.horizontal, 12)
        }
        .foregroundStyle(.white)
        .animation(.easeOut(duration: 0.18), value: selected)
    }

    private func isManual(_ control: ManualControl) -> Bool {
        switch control {
        case .iso, .shutter: return model.manualExposure
        case .whiteBalance: return model.manualWB
        case .focus: return model.manualFocus
        case .exposureBias: return abs(model.exposureBias) > 0.05
        }
    }

    private func chip(_ control: ManualControl) -> some View {
        let isOn = selected == control
        return Button {
            selected = isOn ? nil : control
        } label: {
            VStack(spacing: 1) {
                Text(isManual(control) ? control.title : "\(control.title) A")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(isManual(control) ? Color.accentTeal : Color.white.opacity(0.55))
                Text(value(control))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(isOn ? Color.accentTeal.opacity(0.3) : Color.black.opacity(0.45),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func value(_ control: ManualControl) -> String {
        switch control {
        case .iso: return "\(Int(model.iso))"
        case .shutter: return formatShutter(model.shutter)
        case .whiteBalance: return "\(Int(model.temperature / 100) * 100)K"
        case .focus: return String(format: "%.2f", model.lensPosition)
        case .exposureBias: return String(format: "%+.1f", model.exposureBias)
        }
    }

    @ViewBuilder
    private func panel(for control: ManualControl) -> some View {
        switch control {
        case .iso:
            SliderPanel(title: "ISO \(Int(model.iso))",
                        value: Double(model.iso),
                        range: Double(model.isoRange.lowerBound)...Double(model.isoRange.upperBound),
                        logarithmic: true,
                        unsupported: model.supportsManualExposure ? nil : "Esta lente não permite ISO manual.",
                        isAuto: !model.manualExposure,
                        onChange: { model.setISO(Float($0)) },
                        onAuto: { model.setExposureAuto() })
        case .shutter:
            SliderPanel(title: "Obturador \(formatShutter(model.shutter))",
                        value: model.shutter,
                        range: model.shutterRange,
                        logarithmic: true,
                        unsupported: model.supportsManualExposure ? nil : "Esta lente não permite obturador manual.",
                        isAuto: !model.manualExposure,
                        onChange: { model.setShutter($0) },
                        onAuto: { model.setExposureAuto() })
        case .whiteBalance:
            SliderPanel(title: "Balanço de branco \(Int(model.temperature))K",
                        value: Double(model.temperature),
                        range: 2500...9000,
                        logarithmic: false,
                        unsupported: model.supportsManualWB ? nil : "Esta lente não permite balanço de branco manual.",
                        isAuto: !model.manualWB,
                        onChange: { model.setWhiteBalance(temperature: Float($0)) },
                        onAuto: { model.setWhiteBalanceAuto() })
        case .focus:
            SliderPanel(title: "Foco \(String(format: "%.2f", model.lensPosition))  ·  perto ← → infinito",
                        value: Double(model.lensPosition),
                        range: 0...1,
                        logarithmic: false,
                        unsupported: model.supportsManualFocus ? nil : "Esta lente não tem foco manual (foco fixo).",
                        isAuto: !model.manualFocus,
                        onChange: { model.setFocus(Float($0)) },
                        onAuto: { model.setFocusAuto() })
        case .exposureBias:
            SliderPanel(title: "Exposição \(String(format: "%+.1f", model.exposureBias)) EV",
                        value: Double(model.exposureBias),
                        range: Double(model.biasRange.lowerBound)...Double(model.biasRange.upperBound),
                        logarithmic: false,
                        unsupported: nil,
                        isAuto: abs(model.exposureBias) < 0.05,
                        onChange: { model.setExposureBias(Float(($0 * 10).rounded() / 10)) },
                        onAuto: { model.setExposureBias(0) })
        }
    }
}

private struct SliderPanel: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let logarithmic: Bool
    let unsupported: String?
    let isAuto: Bool
    let onChange: (Double) -> Void
    let onAuto: () -> Void

    @State private var dragging: Double?

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(unsupported ?? title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(unsupported == nil ? Color.white : Color.orange)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer()
                Button(action: onAuto) {
                    Text("AUTO")
                        .font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(isAuto ? Color.accentTeal : Color.white.opacity(0.15), in: Capsule())
                        .foregroundStyle(isAuto ? Color.black : Color.white)
                }
            }
            Slider(value: Binding(get: { dragging ?? toSlider(value) },
                                  set: { newValue in
                                      dragging = newValue
                                      onChange(fromSlider(newValue))
                                  }),
                   in: 0...1,
                   onEditingChanged: { editing in if !editing { dragging = nil } })
                .tint(.accentTeal)
                .disabled(unsupported != nil)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 12)
    }

    private func toSlider(_ v: Double) -> Double {
        let lo = range.lowerBound, hi = range.upperBound
        guard hi > lo else { return 0 }
        let clamped = min(max(v, lo), hi)
        if logarithmic, lo > 0 { return log(clamped / lo) / log(hi / lo) }
        return (clamped - lo) / (hi - lo)
    }

    private func fromSlider(_ t: Double) -> Double {
        let lo = range.lowerBound, hi = range.upperBound
        if logarithmic, lo > 0 { return lo * pow(hi / lo, t) }
        return lo + (hi - lo) * t
    }
}
