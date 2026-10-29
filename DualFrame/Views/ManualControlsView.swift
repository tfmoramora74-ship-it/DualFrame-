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
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ManualControl.allCases) { control in
                        chip(control)
                    }
                    Button {
                        model.resetAll()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 34, height: 34)
                            .background(.white.opacity(0.12), in: Circle())
                    }
                }
                .padding(.horizontal, 12)
            }
        }
        .foregroundStyle(.white)
        .animation(.easeOut(duration: 0.18), value: selected)
    }

    private func chip(_ control: ManualControl) -> some View {
        let isOn = selected == control
        let manual: Bool = {
            switch control {
            case .iso, .shutter: return model.manualExposure
            case .whiteBalance: return model.manualWB
            case .focus: return model.manualFocus
            case .exposureBias: return abs(model.exposureBias) > 0.05
            case .zoom: return false
            }
        }()
        return Button {
            selected = isOn ? nil : control
        } label: {
            VStack(spacing: 1) {
                Text(control.title)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(manual ? Color.cyan : Color.white.opacity(0.6))
                Text(value(control))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
            }
            .frame(minWidth: 54, minHeight: 34)
            .padding(.horizontal, 4)
            .background(isOn ? Color.cyan.opacity(0.3) : Color.white.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func value(_ control: ManualControl) -> String {
        switch control {
        case .iso: return "\(Int(model.iso))"
        case .shutter: return formatShutter(model.shutter)
        case .whiteBalance: return "\(Int(model.temperature / 100) * 100)K"
        case .focus: return String(format: "%.2f", model.lensPosition)
        case .exposureBias: return String(format: "%+.1f", model.exposureBias)
        case .zoom: return String(format: "%.1f×", model.zoomDisplay)
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
                        enabled: model.supportsManualExposure,
                        isAuto: !model.manualExposure,
                        onChange: { model.setISO(Float($0)) },
                        onAuto: { model.setExposureAuto() })
        case .shutter:
            SliderPanel(title: "Obturador \(formatShutter(model.shutter))",
                        value: model.shutter,
                        range: model.shutterRange,
                        logarithmic: true,
                        enabled: model.supportsManualExposure,
                        isAuto: !model.manualExposure,
                        onChange: { model.setShutter($0) },
                        onAuto: { model.setExposureAuto() })
        case .whiteBalance:
            SliderPanel(title: "Balanço de branco \(Int(model.temperature))K",
                        value: Double(model.temperature),
                        range: 2000...10000,
                        logarithmic: false,
                        enabled: model.supportsManualWB,
                        isAuto: !model.manualWB,
                        onChange: { model.setWhiteBalance(temperature: Float($0), tint: 0) },
                        onAuto: { model.setWhiteBalanceAuto() })
        case .focus:
            SliderPanel(title: "Foco \(String(format: "%.2f", model.lensPosition))  (0 = perto · 1 = infinito)",
                        value: Double(model.lensPosition),
                        range: 0...1,
                        logarithmic: false,
                        enabled: model.supportsManualFocus,
                        isAuto: !model.manualFocus,
                        onChange: { model.setFocus(Float($0)) },
                        onAuto: { model.setFocusAuto() })
        case .exposureBias:
            SliderPanel(title: "Compensação \(String(format: "%+.1f", model.exposureBias)) EV",
                        value: Double(model.exposureBias),
                        range: Double(max(-4, model.biasRange.lowerBound))...Double(min(4, model.biasRange.upperBound)),
                        logarithmic: false,
                        enabled: true,
                        isAuto: abs(model.exposureBias) < 0.05,
                        onChange: { model.setExposureBias(Float(($0 * 10).rounded() / 10)) },
                        onAuto: { model.setExposureBias(0) })
        case .zoom:
            SliderPanel(title: "Zoom \(String(format: "%.1f×", model.zoomDisplay))",
                        value: Double(model.zoomDisplay),
                        range: Double(model.zoomRange.lowerBound)...Double(model.zoomRange.upperBound),
                        logarithmic: true,
                        enabled: true,
                        isAuto: false,
                        onChange: { model.setZoom(display: CGFloat($0), animated: false) },
                        onAuto: { model.setZoom(display: 1, animated: true) })
        }
    }
}

private struct SliderPanel: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let logarithmic: Bool
    let enabled: Bool
    let isAuto: Bool
    let onChange: (Double) -> Void
    let onAuto: () -> Void

    @State private var dragging: Double?

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text(enabled ? title : "\(title) — não suportado por esta lente")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer()
                Button(isAuto ? "AUTO" : "Auto") { onAuto() }
                    .font(.system(size: 11, weight: .bold))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(isAuto ? Color.cyan : Color.white.opacity(0.15), in: Capsule())
                    .foregroundStyle(isAuto ? Color.black : Color.white)
            }
            Slider(value: Binding(get: { dragging ?? toSlider(value) },
                                  set: { newValue in
                                      dragging = newValue
                                      onChange(fromSlider(newValue))
                                  }),
                   in: 0...1,
                   onEditingChanged: { editing in if !editing { dragging = nil } })
                .tint(.cyan)
                .disabled(!enabled)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
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
