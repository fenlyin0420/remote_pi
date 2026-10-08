#!/usr/bin/env bash
set -euo pipefail

# Cria 4 panes (App, Relay, Extension, Site) à direita do pane atual,
# empilhados verticalmente, cada um já rodando
# `cmux claude-teams --model sonnet --dangerously-skip-permissions` no cwd do
# subprojeto.
#
# Por que `cmux claude-teams` em vez de `claude` puro:
#   - O wrapper `claude-teams` injeta automaticamente os hooks Claude Code
#     (SessionStart/UserPromptSubmit/Stop/...) que o cmux precisa pra emitir
#     eventos `agent.hook.*`. Sem o wrapper, nenhum hook dispara e o
#     orquestrador não consegue escutar via `cmux events` quando o worker
#     termina seu turn — fica refém de o humano dizer "feito".
#   - Todas as flags do `claude` (--model, --dangerously-skip-permissions,
#     --resume) são passadas transparentemente.
#
# Por que --dangerously-skip-permissions:
#   - Agentes operam dentro do seu próprio cwd (regra de orquestração)
#   - Sem a flag, cada Edit/Bash/Write pediria confirmação no pane do agente,
#     quebrando o fluxo orquestrado (orquestrador não vê o prompt pra responder)
#   - Aceitável porque cada subprojeto tem seu próprio CLAUDE.md restringindo
#     escopo (cwd-only, sem commits, etc)
#
# Modelo: Orquestrador roda em Opus; agentes de subprojeto rodam em Sonnet
# (mais barato e suficiente pra tarefas mecânicas).
#
# Uso:
#   scripts/cmux-bootstrap-agents.sh           # nova sessão claude em cada pane
#   scripts/cmux-bootstrap-agents.sh --resume  # claude --resume (picker)
#
# Pré-requisitos:
#   - cmux no PATH
#   - rodar de dentro de um terminal cmux do workspace alvo
#     (CMUX_WORKSPACE_ID; cai pra `cmux identify` se não estiver setado)
#
# Idempotência:
#   - Se TODOS os 4 panes já existem (por título "App"/"Relay"/"Extension"/
#     "Site" no workspace), o script não faz nada e sai 0.
#   - Se NENHUM existe, cria os 4.
#   - Se algum existe e outros não, aborta com erro (estado misto — feche
#     manualmente os existentes ou complete o jogo a mão).

usage() {
  awk '
    /^# Cria/ { on = 1 }
    on {
      if (!/^#/) exit
      sub(/^# /, "")
      sub(/^#$/, "")
      print
    }
  ' "$0"
}

resume_flag=""
for arg in "$@"; do
  case "$arg" in
    --resume|-r) resume_flag="--resume" ;;
    -h|--help)   usage; exit 0 ;;
    *)           echo "argumento desconhecido: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

command -v cmux >/dev/null || { echo "erro: cmux não encontrado no PATH" >&2; exit 1; }

# `cmux tree` sempre usa short refs (workspace:N). $CMUX_WORKSPACE_ID pode ser
# UUID. Sempre derive o short ref via `cmux identify` pra casar com o tree.
WS_REF=$(cmux identify 2>/dev/null \
  | awk -F'"' '/"workspace_ref"/ {print $4; exit}')
[ -n "$WS_REF" ] || { echo "erro: workspace cmux não identificado" >&2; exit 1; }

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

# nome|subdir — ordem é top→bottom no layout final
agents=(
  "App|app"
  "Relay|relay"
  "Extension|pi-remote"
  "Site|site"
)

panes_now() {
  cmux list-panes 2>/dev/null | grep -oE 'pane:[0-9]+' | sort -u
}

new_pane_id() {
  # cria pane na direção $1, retorna o ID novo via diff de list-panes
  local dir="$1" before after new
  before=$(panes_now)
  cmux new-pane --direction "$dir" --focus true >/dev/null
  for _ in 1 2 3 4 5; do
    after=$(panes_now)
    new=$(comm -13 <(echo "$before") <(echo "$after") | head -1)
    [ -n "$new" ] && { echo "$new"; return 0; }
    sleep 0.2
  done
  echo "falhou criar pane (--direction $dir)" >&2
  return 1
}

first_surface_of() {
  cmux list-pane-surfaces --pane "$1" 2>/dev/null \
    | grep -oE 'surface:[0-9]+' | head -1
}

# extrai títulos de surfaces do workspace alvo a partir de `cmux tree`
existing_surface_titles() {
  cmux tree 2>/dev/null | awk -v target="$WS_REF" '
    /workspace workspace:/ {
      in_ws = 0
      for (i = 1; i <= NF; i++) if ($i == target) in_ws = 1
      next
    }
    in_ws && /surface surface:/ {
      if (match($0, /"[^"]+"/)) {
        s = substr($0, RSTART + 1, RLENGTH - 2)
        print s
      }
    }
  '
}

existing=$(existing_surface_titles)
present=()
missing=()
for entry in "${agents[@]}"; do
  name=${entry%%|*}
  if grep -Fxq "$name" <<<"$existing"; then
    present+=("$name")
  else
    missing+=("$name")
  fi
done

if [ "${#missing[@]}" -eq 0 ]; then
  echo "todos os 4 panes já existem (${present[*]}) — nada a fazer."
  exit 0
fi
if [ "${#present[@]}" -ne 0 ]; then
  echo "erro: estado misto — existem [${present[*]}], faltam [${missing[*]}]." >&2
  echo "feche os existentes (cmux close-surface --surface surface:NN) e rode de novo," >&2
  echo "ou crie os faltantes manualmente." >&2
  exit 3
fi

direction="right"
created=0
for entry in "${agents[@]}"; do
  name=${entry%%|*}
  cwd="$REPO_ROOT/${entry##*|}"

  if [ ! -d "$cwd" ]; then
    echo "aviso: $cwd não existe — pulando $name" >&2
    direction="down"
    continue
  fi

  pane=$(new_pane_id "$direction") || { direction="down"; continue; }
  surface=$(first_surface_of "$pane")
  if [ -z "$surface" ]; then
    echo "aviso: $pane sem surface visível — pulando $name" >&2
    direction="down"
    continue
  fi

  cmux rename-tab --surface "$surface" "$name" >/dev/null

  cmd="cd '$cwd' && clear && cmux claude-teams --model sonnet --dangerously-skip-permissions"
  [ -n "$resume_flag" ] && cmd="$cmd $resume_flag"
  cmux send --surface "$surface" "${cmd}\n" >/dev/null

  printf "  ok  %-10s pane=%s surface=%s cwd=%s\n" "$name" "$pane" "$surface" "$cwd"
  created=$((created + 1))
  direction="down"
done

echo "pronto. $created agentes despachados${resume_flag:+ (modo --resume)}."
