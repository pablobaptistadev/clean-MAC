# PrintScreen

Captura de tela para macOS no estilo do Lightshot: aperte o atalho, escolha a área, marque e copie ou salve.

## Como usar
- **Atalho:** ⇧⌘2 (padrão). Troque em ícone da barra de menus › Ajustes…
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
- **Mexer no que já desenhou:** clique numa marcação (a mãozinha aparece em cima dela) e arraste para mover.
  As alças azuis mudam o tamanho; no texto, os cantos aumentam ou diminuem a letra. Clique duplo no texto edita.
  Com ela selecionada, a cor, a espessura e a roda do mouse mudam só ela; Delete apaga e as setas do teclado
  empurram (Shift: de 10 em 10). Esc tira a seleção.
- **Desfazer / refazer:** ⌘Z e ⇧⌘Z, ou os botões da barra. Volta também o que foi movido, redimensionado ou apagado.
- **Compartilhar:** botão ⬆︎ da barra de baixo › **Criar nota no Notas** ou **Enviar por e-mail** (abre o Mail com a
  imagem anexada).

## Ajustes (ícone da barra de menus › Ajustes…)
- **Ferramenta já escolhida:** a captura já abre com ela (ex.: Seta) — é só arrastar a área e desenhar.
- **Começar com a última área escolhida:** ao apertar o atalho, a área da última captura já vem marcada; dá para
  copiar na hora (⌘C), desenhar ou ajustar. Clicar fora dela escolhe outra.

## Palco (várias capturas juntas, em camadas)
- Na captura, o botão ⊞ da barra lateral manda a área (com as marcações) para o **palco** e já abre a escolha da
  próxima captura. Escolha a área e clique em **Adicionar ao palco** (Enter). Esc volta para o palco.
- No palco: clique numa imagem para selecionar, arraste para mover e puxe os cantos para mudar o tamanho (mantém a
  proporção). Setas, textos, desfoque e as outras ferramentas funcionam igual, por cima das imagens.
- **Tamanho do palco:** puxe as alças da borda, digite largura × altura em pixels ou use **Ajustar ao conteúdo**.
  Onde não tem imagem, o PNG sai transparente.
- **Camadas:** ⌘] traz a selecionada para a frente, ⌘[ leva para trás. **Adicionar captura** põe mais uma.
- Copiar, salvar e compartilhar ficam no canto de cima; fechar sem salvar pede confirmação.
- **Terminar:** copiar (⌘C) ou salvar em PNG (⌘S); um aviso confirma ("Copiado", "Imagem salva"). Esc cancela.

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
