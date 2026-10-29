# Limpo — instruções para o Claude Code

App nativo macOS (SwiftUI, Swift Package) que usa o **Mole CLI** (`mo`, github.com/tw93/Mole) como motor.
Responder sempre em português (PT-BR), direto ao ponto.

## Fluxo de atualização (obrigatório)
1. Ao mudar qualquer coisa no app, **suba a versão** em `VERSION` (semver: correção = patch, recurso = minor).
2. Rode `./build-app.sh` — compila, encerra o Limpo aberto e **substitui** `/Applications/Limpo.app`.
   Ele assina com o certificado "Limpo Dev" do Acesso às Chaves para o macOS manter as permissões entre versões; se avisar que o certificado não existe, conte ao usuário.
   Nunca deixe cópias do app em outras pastas (`build/`, Downloads etc.).
3. Se o build falhar, leia o erro, corrija e rode de novo até passar.
4. Para gerar instalador: `./build-app.sh --dmg` (ou `./make-dmg.sh`) → `~/Downloads/Limpo-<versão>.dmg`.
5. No fim, confirme a versão instalada: `defaults read /Applications/Limpo.app/Contents/Info CFBundleShortVersionString`.
6. Com a versão nova instalada, **commite e dê push** no GitHub (`github.com/pablobaptistadev/clean-MAC`, branch `main`):
   `git add -A && git commit -m "Limpo <versão>: <resumo da mudança>" && git push`.
   O `.gitignore` já deixa de fora `.build/`, `.app` e `.dmg`. Se o push falhar, avise e não force (`--force`).
7. **Publique a Release** com o `.dmg` (é dela que o app dos clientes se atualiza):
   `gh release create v<versão> ~/Downloads/Limpo-<versão>.dmg --repo pablobaptistadev/clean-MAC --target main --title "Limpo <versão>" --notes "<novidades em PT-BR>"`.
   A tag tem que ser `v` + o conteúdo de `VERSION` e o `.dmg` tem que conter o `Limpo.app` dessa mesma versão — o app recusa a atualização se não bater.

## Regras de código
- **Não usar `@State`, `@Bindable` nem outras macros do SwiftUI**: as Command Line Tools do macOS 27 não trazem o plugin `SwiftUIMacros` e o build quebra. Estado fica nos models `@Observable` (Observation funciona) e bindings são feitos com `Binding(get:set:)`.
- Visual: layout do BuhoCleaner — barra lateral escura com as seções (`Sidebar`), área principal cinza-escuro, telas iniciais com título + "Analisar" e ícone grande apagado na borda, anel de progresso, caixas de marcar quadradas (`TriCheckBox`), botões em pílula azul (`PillButtonStyle`) e barra inferior com "Selecionado | Total". Cores do sistema da Apple (iOS/macOS modo escuro: fundos #161618/#1C1C1E/#2C2C2E, azul #0A84FF), **nada em vermelho** (alertas e erros em laranja). Cores só em `Theme`; dados com cor (`Palette`).
- Limpeza: a Lixeira aparece sempre como primeira categoria quando tem itens. O que o usuário desmarca vira proteção temporária (`Whitelist.protectTemporarily`) só durante o `mo clean`.
- Tudo que o app apaga vai para a Lixeira, salvo opção explícita.
- Comandos do Mole que exigem terminal real (seleção do `mo slim`, `mo touchid enable/disable`, tarefas com sudo) abrem no Terminal via `SettingsModel.runInTerminal`.
- Mapa de recursos do Mole ↔ app: `FEATURES.md`.

## Estrutura
- `Sources/Limpo/` — uma feature por arquivo (`CleanFeature`, `OptimizeFeature`, `AnalyzeFeature`, `UninstallFeature`, `SlimFeature`, `StatusFeature`, `ProcessesFeature`, `MenuBar`, `HistorySettingsFeature`…)
- `MoleCLI.swift` — execução do `mo` (normal, streaming e PTY)
- `UpdateFeature.swift` — atualização automática: lê a última Release do GitHub, baixa o `.dmg`, troca o app e reabre.
  Para testar com uma versão falsa: `defaults write br.com.pablobaptista.limpo updateFeedURL <url de um JSON no formato da API>` (apague com `defaults delete … updateFeedURL`).
- `Resources/AppIcon.png` — ícone (convertido para .icns no build)
