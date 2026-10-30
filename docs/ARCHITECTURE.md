# Arquitetura

Visão técnica de como o DualFrame captura, recorta e grava vários formatos a partir de um único sensor.

## Camadas

| Camada | Arquivos | Responsabilidade |
|---|---|---|
| Interface | `Views/` | SwiftUI: câmera, prévias, controles manuais, ajustes, galeria |
| Estado | `CameraModel.swift` | `@MainActor`; configurações, leituras do dispositivo, gravação, foto |
| Captura | `CaptureEngine.swift` | `AVCaptureSession` / `AVCaptureMultiCamSession`, formatos, saídas, foto, rajada, longa exposição |
| Imagem | `FrameRenderer.swift`, `PhotoFusion.swift`, `SelfieOverlay.swift` | Core Image: recorte, escala, composição, empilhamento |
| Gravação | `TakeWriter.swift` | Um `AVAssetWriter` por formato, áudio compartilhado |
| Geometria | `CropMath.swift` | Recortes, tamanhos de saída e orientação |

## Filas

- **Main:** só interface. Valores rápidos (medidor de áudio, histograma, leituras de ISO e zoom) ficam em objetos observáveis separados (`LiveMeters`, `DeviceReadouts`), para que só os elementos que os mostram sejam redesenhados.
- **`sessionQueue`:** configuração da sessão e do dispositivo (`lockForConfiguration`).
- **`outputQueue`:** recebe cada quadro e áudio; alimenta gravadores, prévias, rajada e empilhamento.
- **`photoQueue`:** codificação de fotos (HEIC/DNG) fora do caminho dos quadros.

## Do sensor ao arquivo

1. **Formato do sensor:** o app escolhe o maior formato **4:3** que atinge o fps pedido, com preferência pela faixa dinâmica (HLG / Apple Log) e pela estabilização conforme a prioridade escolhida (`pickFormat`).
2. **Buffer na orientação do sensor:** a câmera traseira entrega o buffer deitado (ângulo 0). Segurando o celular em pé, o "vertical da cena" corresponde ao eixo X do buffer.
3. **Recorte:** `CropMath.region` calcula o maior retângulo centralizado com o aspecto do formato (9:16, 16:9 ou 4:3), no espaço do buffer.
4. **Renderização:** `FrameRenderer` recorta e reduz com Core Image (Lanczos abaixo de 0,8×) para um buffer de um pool. Os valores codificados passam sem conversão de cor, o que é exato para SDR, HLG e Log.
5. **Gravação:** cada `AVAssetWriterInput` recebe a transformação de rotação, então o arquivo abre em pé sem rotacionar pixels. O 4:3 em resolução nativa vai direto (passthrough).
6. **Áudio:** as mesmas amostras AAC vão para todos os arquivos; a sessão de cada gravador começa no primeiro quadro de vídeo.

## Prévias

- Um único `VTPixelTransferSession` (escalonador de hardware) reduz o quadro do sensor pela metade ou a um quarto por quadro.
- Cada formato é recortado dessa base e desenhado no tamanho em pixels da maior janela que o mostra, num `CIContext` de 8 bits e prioridade baixa.
- O resultado vai para `AVSampleBufferDisplayLayer` (várias janelas podem mostrar o mesmo formato).
- Limite de 30 fps; com pressão térmica alta cai para 15 ou 10 fps e zebra/peaking pausam.

## Frente + trás

- A sessão é trocada por uma `AVCaptureMultiCamSession`, com entradas e conexões manuais (porta → saída). A troca cria saídas novas, porque reaproveitar saídas de uma sessão configurada derruba o app.
- O formato traseiro é o maior que, junto com a selfie, mantém `hardwareCost ≤ 1`.
- O último quadro da selfie é composto (`OverlayCompositor`) dentro do recorte vertical, tanto na prévia quanto no arquivo. Nesse modo os pixels são girados antes de codificar, para que a janela fique exatamente onde foi posicionada.

## Foto

- **Apple:** `AVCapturePhotoOutput` (qualidade equilibrada), HEIC por formato recortado do quadro processado; DNG Bayer opcional.
- **Fusão HDR / Super-res:** rajada de quadros de vídeo copiados do pool, alinhados com `VNTranslationalImageRegistrationRequest`, somados num `CIImageAccumulator` em meia precisão e normalizados (alfa forçado a 1). A super-resolução reamostra cada quadro numa grade 1,5× antes de somar.
- **Longa exposição:** quadros de até 1 s de exposição somados (média) ou combinados pelo mais claro (rastros), em buffers de meia precisão.

## Calor e energia

- Reação ao `systemPressureState` da câmera, como recomenda a Apple: menos trabalho na prévia e, em estado crítico, 24 fps (nunca durante uma gravação).
- Prévias pausadas quando Ajustes ou Galeria cobrem a câmera.
- Microfone desligado fora do modo vídeo; foto em `.balanced`.
