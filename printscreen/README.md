# PrintScreen

Captura de tela para macOS no estilo do Lightshot: aperte o atalho, escolha a área, marque e copie ou salve.

## Como usar
- **Atalho:** ⇧⌘2 (padrão). Troque em ícone da barra de menus › Atalho…
- **Abrir o app tira o print:** abrir o PrintScreen pelo Finder, Spotlight ou por uma tecla que "abre aplicativo"
  já captura, esteja ele fechado ou aberto.
- **Tecla de print do teclado (Logitech MX Keys e outros):** essas teclas especiais não aparecem na janela do atalho.
  No Logi Options+, ponha na tecla **Atalho de teclado ⇧⌘2** ou **Abrir aplicativo › PrintScreen**.
- **Escolher a área:** arraste. Depois dá para mover a área e puxar as alças para mudar o tamanho. O tamanho em pixels aparece em cima.
- **Marcar:** lápis, linha, seta, quadrado, círculo e texto, com a cor que quiser (paleta ou "Mais cores…").
  Segurando Shift, linha e seta ficam em ângulos de 45° e quadrado e círculo saem perfeitos.
- **Desfocar:** a gota borra a área que você arrastar, para esconder senhas, nomes e números. A espessura
  define a intensidade.
- **Espessura:** na barra lateral, entre a bolinha grande e a pequena. Com uma ferramenta escolhida, a roda do mouse
  também muda: para cima engrossa, para baixo afina (no texto, muda o tamanho da letra). Fica lembrada para as próximas.
- **Desfazer / refazer:** ⌘Z e ⇧⌘Z, ou os botões da barra.
- **Nova captura:** botão ⊞ da barra (⌘N) fecha esta e fotografa a tela de novo, como ela está agora.
- **Terminar:** copiar (⌘C) ou salvar em PNG (⌘S). Esc cancela.

Funciona em todas as telas conectadas e captura na resolução real (Retina).

## Gravar vídeo
- **Começar:** ícone da barra de menus › Gravar vídeo… e arraste a área (Enter grava a tela inteira).
  Ou, numa captura normal, escolha a área e clique em ⏺ (⌘R).
- **Parar:** botão ■ do cronômetro, ícone da barra de menus ou o mesmo atalho da captura (⇧⌘2).
- **Arquivo:** MP4 em HEVC (H.265), no máximo Full HD (1080p), 30 fps. Quadros só são gravados quando a tela muda,
  então um minuto costuma ficar entre 1 e 5 MB. O cursor aparece; o som não é gravado.
- **Onde fica:** Filmes › PrintScreen. Ao parar, o vídeo é copiado (dá para colar no WhatsApp, Slack ou e-mail)
  e aparece selecionado no Finder.
- O contorno da área e o cronômetro não aparecem no vídeo. As marcações da captura também não entram.

## Permissão
Na primeira captura o macOS pede **Gravação de Tela**: Ajustes do Sistema › Privacidade e Segurança ›
Gravação de Tela e Áudio do Sistema › ative o PrintScreen.

Se o macOS continuar pedindo com o PrintScreen já ativado, a autorização é de uma versão anterior do app
(acontece a cada atualização enquanto ele não for assinado com o certificado "Limpo Dev"). No aviso do
PrintScreen, clique em **Refazer autorização**, ative de novo e escolha Sair e Reabrir.

## Instalar / atualizar
```bash
./build-app.sh
```
Requer Mac com Apple Silicon (M1 ou mais novo), macOS 14+ e as Command Line Tools (`xcode-select --install`).
