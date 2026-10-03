#!/usr/bin/env bash
# =============================================================================
# uninstall.sh — rimuove service e timer systemd creati da install.sh
#
# NON tocca mai i backup già creati nelle destinazioni.
# Per default non cancella nemmeno config.env e il log: lo chiede.
#
# Uso:
#   bash uninstall.sh                  # interattivo, cerca le unit create da install.sh
#   bash uninstall.sh --name NOME      # specifica il nome delle unit
#   bash uninstall.sh -y               # nessuna domanda (config e log restano)
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UNIT_DIR="/etc/systemd/system"
MARKER="# Managed by autobackup install.sh"
UNIT_NAME=""
ASSUME_YES=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes) ASSUME_YES=true ;;
    --name)   UNIT_NAME="${2:?--name richiede un valore}"; shift ;;
    -h|--help) sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Opzione sconosciuta: $1"; exit 2 ;;
  esac
  shift
done

if [[ -t 1 ]]; then
  BOLD=$'\033[1m'; RESET=$'\033[0m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'
else
  BOLD=""; RESET=""; GREEN=""; YELLOW=""; RED=""
fi
info() { echo "  ${YELLOW}ℹ️  $1${RESET}"; }
ok()   { echo "  ${GREEN}✅ $1${RESET}"; }
warn() { echo "  ${RED}⚠️  $1${RESET}"; }
ask_yn() {
  local prompt="$1" default="$2" answer
  if [[ "$ASSUME_YES" == true ]]; then [[ "$default" == s ]]; return; fi
  read -rp "  ${prompt} (s/n) [${default}]: " answer
  answer="${answer:-$default}"
  [[ "$answer" =~ ^[sSyY] ]]
}

SUDO=""
[[ "$EUID" -ne 0 ]] && SUDO="sudo"

# trova le unit gestite dall'installer che puntano a questa cartella
FOUND=()
if [[ -z "$UNIT_NAME" ]]; then
  for f in "$UNIT_DIR"/*.service; do
    [[ -e "$f" ]] || continue
    if grep -qs "$MARKER" "$f" && grep -qs "$SCRIPT_DIR/backup.sh" "$f"; then
      FOUND+=("$(basename "$f" .service)")
    fi
  done
  if (( ${#FOUND[@]} == 0 )); then
    info "Nessuna unit creata da install.sh trovata in $UNIT_DIR."
    info "Se hai usato un nome diverso o unit manuali: bash uninstall.sh --name NOME"
    exit 0
  elif (( ${#FOUND[@]} == 1 )); then
    UNIT_NAME="${FOUND[0]}"
  else
    echo "  Unit trovate:"; printf '    - %s\n' "${FOUND[@]}"
    read -rp "  Quale rimuovere? " UNIT_NAME
  fi
fi

SERVICE_FILE="$UNIT_DIR/${UNIT_NAME}.service"
TIMER_FILE="$UNIT_DIR/${UNIT_NAME}.timer"

for f in "$SERVICE_FILE" "$TIMER_FILE"; do
  if [[ -e "$f" ]] && ! grep -qs "$MARKER" "$f"; then
    warn "$f non è stato creato da install.sh."
    ask_yn "Rimuoverlo comunque?" n || { echo "  Annullato."; exit 1; }
    break
  fi
done

echo ""
echo "  ${BOLD}Verranno rimossi:${RESET}"
[[ -e "$TIMER_FILE"   ]] && echo "    $TIMER_FILE"
[[ -e "$SERVICE_FILE" ]] && echo "    $SERVICE_FILE"
echo "  I backup già creati nelle destinazioni NON vengono toccati."
ask_yn "Procedere?" s || { echo "  Annullato."; exit 1; }

$SUDO systemctl disable --now "${UNIT_NAME}.timer" 2>/dev/null
$SUDO systemctl stop "${UNIT_NAME}.service" 2>/dev/null
$SUDO rm -f "$TIMER_FILE" "$SERVICE_FILE"
$SUDO systemctl daemon-reload
$SUDO systemctl reset-failed "${UNIT_NAME}.service" "${UNIT_NAME}.timer" 2>/dev/null
ok "Unit rimosse"

if [[ -f "$SCRIPT_DIR/config.env" ]] && ask_yn "Eliminare anche config.env (contiene percorsi e token)?" n; then
  rm -f "$SCRIPT_DIR/config.env" && ok "config.env eliminato"
fi
if ls "$SCRIPT_DIR"/*.log >/dev/null 2>&1 && ask_yn "Eliminare i file di log in $SCRIPT_DIR?" n; then
  rm -f "$SCRIPT_DIR"/*.log && ok "log eliminati"
fi

echo ""
echo "Fatto. Per rimuovere anche il progetto: rm -rf $SCRIPT_DIR"
