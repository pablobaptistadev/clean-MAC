# Limpo

App nativo (SwiftUI) para macOS com visual grafite, usando o **Mole CLI** (github.com/tw93/Mole) como motor.

## Abas
- **Limpar**
  - *Sistema* — `mo clean --dry-run` / `mo clean`
  - *Projetos* — artefatos de build recriáveis (node_modules, vendor, target, .next, DerivedData…), como o `mo purge`
  - *Instaladores* — .dmg/.pkg/.iso/.xip/.zip esquecidos, como o `mo installer`
- **Otimizar** — `mo optimize --dry-run` / `mo optimize`
- **Analisar**
  - *Explorador* — mapa de disco navegável (`mo analyze --json`)
  - *Arquivos grandes*
- **Apps** — `mo uninstall --list`, plano com `--dry-run` antes de remover
- **Status** — `mo status --json` + lista completa de processos (`ps`) ordenável por memória, CPU, nome e PID; menu de cada processo: Por que está em execução?, Copiar PID, Mostrar no Finder, Encerrar
- **Histórico** (ícone de relógio) — `mo history --json`
- **Ajustes** (ícone de engrenagem) — proteções da limpeza/otimização, pastas de projetos, Touch ID para sudo (`mo touchid`), atualizar o Mole, abrir ao iniciar sessão

## Barra de menus
- Clique: monitor em tempo real (CPU, GPU, memória, disco, rede, ventoinha, Bluetooth, top processos por memória, contadores do histórico, Tela ligada)
- Clique direito: menu com todas as seções, Histórico, Ajustes, Manter tela ligada, Atualizar o Mole

Tudo que é removido pelo app vai para o Lixo.

## Requisitos
- macOS 14+
- Command Line Tools (`xcode-select --install`) ou Xcode
- Mole: `brew install mole`

## Instalar / atualizar
```bash
./build-app.sh
```
Compila, encerra o Limpo aberto e **substitui** o `/Applications/Limpo.app` (sem cópias em outras pastas).
A versão fica no arquivo `VERSION`; o número de build é a data/hora da compilação.

Instalador: `./build-app.sh --dmg` gera `~/Downloads/Limpo-<versão>.dmg`.
