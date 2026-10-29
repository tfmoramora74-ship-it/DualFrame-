# Engenharia reversa — ContentCam 2.7 → base do nosso app

Alvo: `com.JimmyYip.ContentCam` 2.7 (build 1), Swift/SwiftUI, iOS 18+, arm64, SDK iOS 26.
Binário já descriptografado (decrypt.day). Ferramentas: REA (inventário/strings) + Ghidra 12.1.4 headless
(decompilação completa, 7.286 funções, símbolos removidos — identificação feita pelas strings de log).

## 1. Pipeline de captura (o coração do app)

```
AVCaptureSession (ou AVCaptureMultiCamSession em "Lente dupla")
  └─ AVCaptureDeviceInput (câmera traseira, formato 4:3)
  └─ AVCaptureVideoDataOutput  (420v, fallback 420f)  ──► sampleBuffer
  └─ AVCaptureAudioDataOutput                           ──► sampleBuffer
                     │
          PixelBufferCropper ×2  (um para 9:16, um para 16:9)
             - anexa kCVImageBufferCleanApertureKey (retângulo de recorte) ao buffer de origem
             - VTPixelTransferSessionTransferImage → buffer de um CVPixelBufferPool pré-aquecido
                     │
              DualWriter
             - 2× AVAssetWriter (.mov / AVFileTypeQuickTimeMovie)
             - mesmo áudio AAC enviado aos dois (sincronia garantida pelo mesmo PTS)
             - startSession(atSourceTime:) no PTS do 1º frame de vídeo
             - preenche buracos de áudio com silêncio; descarta 1 frame se o writer atrasar
```

Achados confirmados no código decompilado:

| Item | Valor no ContentCam |
|---|---|
| Codec | HEVC (`AVVideoCodecTypeHEVC`) |
| Perfil | `HEVC_Main10_AutoLevel` com HDR ligado, senão `HEVC_Main_AutoLevel` |
| Keyframe | `AVVideoMaxKeyFrameIntervalKey = 30` |
| Bitrate | `AVVideoAverageBitRateKey` por saída (calculado por resolução) |
| Cor | `AVVideoColorPropertiesKey` (BT.709 SDR / BT.2020 HLG em HDR) |
| Formato do sensor | só formatos **4:3**; largura ≥ 1920 (HD) ou ≥ 3840 (4K); prefere os que suportam estabilização |
| Tempo real | `expectsMediaDataInRealTime = true` |
| Arquivos | `<take>_Portrait.mov`, `<take>_Landscape.mov`, `_Back.mov` (frente/trás), `_Landscape.heic` (foto) |

Matemática do recorte (buffer 4:3 deitado, L×A, ex.: 4032×3024):
- **16:9 horizontal**: largura total, altura = L × 9/16 → 4032×2268 → escalado p/ 3840×2160 (4K) ou 1920×1080 (HD)
- **9:16 vertical**: altura total vira o lado longo, largura = A × 9/16 → 1701×3024 → rotacionado 90° e escalado p/ 2160×3840 ou 1080×1920
- Constante `0.5625` (9/16) aparece em todas as rotinas de layout/recorte.

## 2. Modos

| Modo | Como funciona |
|---|---|
| Lente única | 1 captura 4:3 → 2 recortes (o modo principal) |
| Lente dupla | `AVCaptureMultiCamSession`: wide → um formato, ultra-wide → o outro; checa `hardwareCost ≤ 0.95`; sem 4K/60fps (limite da Apple) |
| Frente/Trás | MultiCam traseira + frontal (frontal sempre vertical) |
| Timelapse | `TimelapseFrameSelector` + `TimelapsePTSRewriter` (30×, gravado a 30fps) |
| Pausa | `PausePTSRewriter` remove o trecho pausado reescrevendo PTS |
| Foto | `AVCapturePhotoOutput` + `PhotoCropper` → HEIC vertical + horizontal |

## 3. Demais recursos encontrados
Estabilização (standard/cinematic/cinematic extended, rebaixada automaticamente se não aguentar), HDR 10-bit,
controles manuais (EV, ISO, obturador, balanço de branco, foco, trava AE/AF por toque), zoom com dial
(.5 / 1 / 2 / 3), sobreposições (grade, mira, nível via CoreMotion), medidor de áudio, teleprompter,
contagem regressiva (com flash da lanterna), tons de gravação, monitor térmico, projetos/cenas (SwiftData),
revisão lado a lado com corte, salvar em Fotos, recuperação de arquivos não finalizados.
Bloqueios Premium: StoreKit (`PremiumStore`, `PaywallView`) — **no nosso app não existirá paywall**.

## 4. Nosso app (nome provisório: **DualFrame**) — o que muda

Código 100% nosso, mesma ideia. Melhorias sobre o original:
1. **Tudo liberado**: 4K, 60fps, lente dupla, timelapse, manual, projetos ilimitados.
2. **Sensor completo sem recorte** ("open gate"): terceira saída opcional 4:3 nativa do sensor.
3. Escolha de saídas por gravação: Vertical / Horizontal / 4:3 completo (qualquer combinação).
4. Codec selecionável: HEVC ou H.264, bitrate configurável; ProRes 422 quando o aparelho suportar.
5. Painel manual completo sempre visível (ISO, obturador em frações 1/x, WB em Kelvin, foco manual, EV).
6. Ferramentas pro: nível, grade (terços), mira, histograma, zebra, peaking de foco, medidor de áudio.
7. Botões de volume como disparador de gravação.

Build: projeto Swift + GitHub Actions (`macos-latest`, `CODE_SIGNING_ALLOWED=NO`) → `.ipa` sem assinatura,
re-assinado pelo LiveContainer no iPhone — mesmo pipeline do RecurringExpenseTracker.
