# PrintScreen — instruções para o Claude Code

App de captura de tela para macOS no estilo do Lightshot (prnt.sc), em AppKit, Swift Package.
Responder sempre em português (PT-BR), direto ao ponto.

## Fluxo de atualização
1. Ao mudar o app, **suba a versão** em `VERSION` (semver: correção = patch, recurso = minor).
2. Rode `./build-app.sh` — compila, encerra o PrintScreen aberto e **substitui** `/Applications/PrintScreen.app`.
   Assina com o certificado "Limpo Dev" (o mesmo do Limpo) para o macOS manter a Gravação de Tela entre versões.
3. Se o build falhar, leia o erro, corrija e rode de novo até passar.
4. Commit e push no repositório (`github.com/pablobaptistadev/clean-MAC`, pasta `printscreen/`).
5. **Release só com `--latest=false` e tag `printscreen-v<versão>`**: o atualizador do Limpo lê a última Release
   do repositório; uma Release do PrintScreen marcada como "latest" faria o Limpo parar de achar as dele.

## Regras de código
- Mesma regra do Limpo: **não usar `@State`, `@Bindable` nem outras macros do SwiftUI** (as Command Line Tools não têm o plugin). A interface é AppKit.
- Visual: cores do sistema da Apple em modo escuro; barras em vidro escuro (`NSVisualEffectView` .hudWindow), ícones SF Symbols brancos, ferramenta ativa em azul do sistema.
- Captura com ScreenCaptureKit (`SCScreenshotManager`), uma janela de seleção por tela, na resolução real (Retina).
- Atalho global pelo Carbon (`RegisterEventHotKey`): não precisa de permissão de Acessibilidade.

## Estrutura
- `PrintScreenApp.swift` — entrada, ícone e menu na barra de menus.
- `HotKey.swift` — atalho global e o formato salvo (`Shortcut`).
- `ScreenCapture.swift` — captura das telas e pedido de permissão de Gravação de Tela.
- `CaptureOverlay.swift` — seletor (mover/redimensionar), marcações (`Mark`: lápis, seta, quadrado, círculo, texto), cor, copiar e salvar PNG.
- `SettingsWindow.swift` — janela para gravar o atalho.

## Fase 1 (feito)
Atalho configurável · seletor de área com tamanho em pixels · seta, lápis, quadrado, círculo, texto, cor · copiar · salvar PNG.
