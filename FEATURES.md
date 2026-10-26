# Mapa: Mole CLI → Limpo

Levantado do código do repositório tw93/Mole (dispatcher `mole`, `bin/*.sh`, `lib/core/help.sh`, `cmd/analyze`, `cmd/status`).

| Comando / opção do Mole | No Limpo | Como |
|---|---|---|
| `mo clean` | Limpar › Sistema | prévia com `--dry-run`, depois roda |
| `mo clean --dry-run` (gera `~/.config/mole/clean-list.txt`) | Limpar › Sistema › "Ver caminhos" | lista os caminhos de cada seção |
| `mo clean --whitelist` | Botão "Proteger" por caminho + Ajustes › Proteções da limpeza | grava `~/.config/mole/whitelist` (já com os padrões do Mole) |
| `mo clean --external PATH` | Limpar › Disco externo | prévia + limpeza + ejetar |
| `mo purge` / `--paths` / `--include-empty` / `--yes` | Limpar › Projetos + Ajustes › Pastas de projetos | varredura nativa com as mesmas pastas e alvos; vai para o Lixo |
| `mo installer` | Limpar › Instaladores | varredura nativa nos mesmos locais; vai para o Lixo |
| `mo optimize` / `--dry-run` | Otimizar | plano + execução com saída ao vivo |
| `mo optimize --whitelist` | Ajustes › Tarefas da otimização | liga/desliga as 19 tarefas (`whitelist_optimize`) |
| `mo analyze` (visão geral + "espaço oculto") | Analisar › Explorador | começa na visão geral; navega por pasta; menu Discos |
| `mo analyze --json PATH` | Analisar › Explorador | drill-down, mover para o Lixo, mostrar no Finder |
| Arquivos grandes do `analyze` | Analisar › Arquivos grandes | por categoria |
| `mo uninstall --list` / `NAME…` / `--dry-run` | Apps › Desinstalar | plano antes, confirmação no app |
| `mo uninstall --with-data` | Apps › "Incluir dados pessoais" | |
| `mo uninstall --permanent` | Apps › "Apagar sem passar pelo Lixo" | |
| `mo slim` / `--dry-run` | Apps › Reduzir (Intel) | lista no app; escolha no Terminal (o Mole só seleciona em terminal) |
| `mo status --watch --interval` | Status + Monitor da barra | um processo contínuo em vez de consultas |
| `mo status` CPU, GPU, memória, disco, I/O, rede, proxy, térmico, ventoinha, sensores, bateria, Bluetooth, Lixo, zumbis | Status + Monitor | cards coloridos |
| `--proc-cpu-threshold` / `--proc-cpu-window` / `--proc-cpu-alerts` | Ajustes › Monitor e alertas | banner no Status + notificação do macOS |
| Lista de processos | Status › Processos + Monitor da barra | todos via `ps`, agrupados por app (helpers somados, grupo expansível), memória pelo phys_footprint (o mesmo valor do Monitor de Atividade; processos de root usam o RSS), ordenável por memória/CPU/nome/PID; encerrar (confere se fechou, oferece forçar e pede a senha de administrador para processos do sistema), copiar PID, por que está rodando |
| `mo history --json --limit` | Histórico | totais, execuções, itens removidos, abrir logs |
| `MO_NO_OPLOG=1` | Ajustes › Registrar histórico | |
| `mo touchid status/enable/disable` | Ajustes › Touch ID para sudo | status no app, mudança no Terminal (precisa de senha) |
| `mo update` / `--force` / `--nightly` | Ajustes › Atualizar + menu da barra | |
| `mo completion` | Ajustes › Autocompletar no Terminal | |
| `mo remove` / `--dry-run` | Ajustes › Remover o Mole | |
| `mo --version` | Ajustes | |
| `--debug` | não exposto | só polui a saída que o app lê |
| `mo touchid` interativo, seleção do `mo slim` | Terminal | o Mole exige terminal real |

Fora do Mole: atualização do próprio Limpo pelas Releases do GitHub (Ajustes, aviso na janela, menu da barra).

Fora do CLI (não dá para fazer só com o Mole): controle de ventoinha.
