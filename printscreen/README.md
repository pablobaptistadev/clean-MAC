# PrintScreen

Captura de tela para macOS no estilo do Lightshot: aperte o atalho, escolha a área, marque e copie ou salve.

## Como usar
- **Atalho:** ⇧⌘2 (padrão). Troque em ícone da barra de menus › Atalho…
- **Escolher a área:** arraste. Depois dá para mover a área e puxar as alças para mudar o tamanho. O tamanho em pixels aparece em cima.
- **Marcar:** lápis, seta, quadrado, círculo e texto, com a cor que quiser (paleta ou "Mais cores…"). ⌘Z desfaz.
- **Terminar:** copiar (⌘C) ou salvar em PNG (⌘S). Esc cancela.

Funciona em todas as telas conectadas e captura na resolução real (Retina).

## Permissão
Na primeira captura o macOS pede **Gravação de Tela**: Ajustes do Sistema › Privacidade e Segurança ›
Gravação de Tela e Áudio do Sistema › ative o PrintScreen.

## Instalar / atualizar
```bash
./build-app.sh
```
Requer Mac com Apple Silicon (M1 ou mais novo), macOS 14+ e as Command Line Tools (`xcode-select --install`).
