#!/usr/bin/env bash
# =============================================================================
# install.sh — installazione guidata di autobackup come servizio systemd
#
# Cosa fa:
#   1. controlla i requisiti (bash, systemd, rsync, zip, ...)
#   2. se manca config.env, lancia setup-wizard.sh
#   3. verifica le destinazioni configurate (SSH raggiungibile, mount presenti...)
#   4. crea e abilita service + timer in /etc/systemd/system
#   5. (opzionale) esegue subito un backup di prova
#
# Uso:
#   bash install.sh                       # interattivo
#   bash install.sh -y                    # accetta i default, nessuna domanda
#   bash install.sh --name NOME           # nome delle unit (default: autobackup)
#   bash install.sh --calendar "EXPR"     # OnCalendar systemd (default: *-*-* 03:00:00)
#   bash install.sh --no-test             # non lancia il backup di prova
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.env"
UNIT_DIR="/etc/systemd/system"
MARKER="# Managed by autobackup install.sh"

UNIT_NAME="autobackup"
CALENDAR=""
ASSUME_YES=false
RUN_TEST=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)     ASSUME_YES=true ;;
    --name)       UNIT_NAME="${2:?--name richiede un valore}"; shift ;;
    --calendar)   CALENDAR="${2:?--calendar richiede un valore}"; shift ;;
    --no-test)    RUN_TEST=false ;;
    -h|--help)    sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Opzione sconosciuta: $1 (usa --help)"; exit 2 ;;
  esac
  shift
done

if [[ -t 1 ]]; then
  BOLD=$'\033[1m'; RESET=$'\033[0m'
  CYAN=$'\033[36m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'
else
  BOLD=""; RESET=""; CYAN=""; GREEN=""; YELLOW=""; RED=""
fi
section() { echo ""; echo "${BOLD}${CYAN}▸ $1${RESET}"; }
info()    { echo "  ${YELLOW}ℹ️  $1${RESET}"; }
ok()      { echo "  ${GREEN}✅ $1${RESET}"; }
warn()    { echo "  ${RED}⚠️  $1${RESET}"; }
die()     { echo "  ${RED}✖ $1${RESET}"; exit 1; }

ask() {   # ask "domanda" "default" varname
  local prompt="$1" default="$2" varname="$3" answer
  if [[ "$ASSUME_YES" == true ]]; then printf -v "$varname" '%s' "$default"; return; fi
  read -rp "  ${prompt} [${default}]: " answer
  printf -v "$varname" '%s' "${answer:-$default}"
}
ask_yn() {  # ask_yn "domanda" s|n  -> 0 se sì
  local prompt="$1" default="$2" answer
  if [[ "$ASSUME_YES" == true ]]; then [[ "$default" == s ]]; return; fi
  read -rp "  ${prompt} (s/n) [${default}]: " answer
  answer="${answer:-$default}"
  [[ "$answer" =~ ^[sSyY] ]]
}

SUDO=""
[[ "$EUID" -ne 0 ]] && SUDO="sudo"

# Home dell'utente che sta installando (il servizio gira come root, ma i path
# del config che usano $HOME devono puntare alla tua home, non a /root).
if [[ -n "${SUDO_USER:-}" ]]; then
  INSTALL_USER="$SUDO_USER"
else
  INSTALL_USER="$(id -un)"
fi
INSTALL_HOME="$(getent passwd "$INSTALL_USER" | cut -d: -f6)"
INSTALL_HOME="${INSTALL_HOME:-$HOME}"

# =============================================================================
section "1/5 Requisiti"
# =============================================================================
(( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )) \
  || die "Serve bash >= 4.4 (trovata ${BASH_VERSION})."
ok "bash ${BASH_VERSION}"

command -v systemctl >/dev/null 2>&1 || die "systemd non trovato: questo installer richiede systemd."
ok "systemd presente"

if [[ -n "$SUDO" ]]; then
  command -v sudo >/dev/null 2>&1 || die "Non sei root e sudo non è installato."
  info "Servono privilegi di root per scrivere in $UNIT_DIR: verrà richiesta la password sudo."
  $SUDO -v || die "sudo non disponibile."
fi

MISSING=()
for bin in rsync zip ssh; do
  command -v "$bin" >/dev/null 2>&1 && ok "$bin" || MISSING+=("$bin")
done
if (( ${#MISSING[@]} )); then
  warn "Mancano: ${MISSING[*]}"
  if command -v apt-get >/dev/null 2>&1 && ask_yn "Installarli ora con apt?" s; then
    PKGS=()
    for b in "${MISSING[@]}"; do [[ "$b" == ssh ]] && PKGS+=(openssh-client) || PKGS+=("$b"); done
    $SUDO apt-get update -qq && $SUDO apt-get install -y "${PKGS[@]}" || die "Installazione fallita."
  else
    die "Installa i pacchetti mancanti e rilancia."
  fi
fi

# =============================================================================
section "2/5 Configurazione"
# =============================================================================
if [[ ! -f "$CONFIG_FILE" ]]; then
  info "config.env non trovato."
  if ask_yn "Lanciare il wizard di configurazione ora?" s; then
    [[ "$ASSUME_YES" == true ]] && die "Con -y serve un config.env già presente: lancia prima setup-wizard.sh."
    bash "$SCRIPT_DIR/setup-wizard.sh"
  fi
  [[ -f "$CONFIG_FILE" ]] || die "Serve un config.env: lancia setup-wizard.sh oppure copia config.env.example."
fi
chmod 600 "$CONFIG_FILE" && ok "config.env trovato (permessi 600: può contenere token)"

# shellcheck disable=SC1090
( source "$CONFIG_FILE" ) 2>/dev/null || die "config.env contiene errori di sintassi."
# carichiamo il config con HOME = home dell'installatore, come farà il servizio
HOME="$INSTALL_HOME"
# shellcheck disable=SC1090
source "$CONFIG_FILE"

NEED_RCLONE=false; NEED_MYSQL=false
for id in "${DESTINATIONS[@]:-}"; do
  [[ -z "$id" ]] && continue
  t="DEST_${id}_TYPE"; [[ "${!t:-}" == rclone ]] && NEED_RCLONE=true
done
[[ "${ENABLE_DB_DUMP:-false}" == true ]] && NEED_MYSQL=true
[[ "$NEED_RCLONE" == true ]] && { command -v rclone >/dev/null 2>&1 && ok "rclone" || warn "rclone richiesto dal config ma non installato."; }
[[ "$NEED_MYSQL" == true ]]  && { command -v mysqldump >/dev/null 2>&1 && ok "mysqldump" || warn "dump database attivo ma mysqldump non è installato."; }

# =============================================================================
section "3/5 Verifica destinazioni"
# =============================================================================
PREFLIGHT_WARN=0
for id in "${DESTINATIONS[@]:-}"; do
  [[ -z "$id" ]] && continue
  tv="DEST_${id}_TYPE"; nv="DEST_${id}_NAME"
  type="${!tv:-}"; name="${!nv:-$id}"
  case "$type" in
    ssh)
      hv="DEST_${id}_HOST"; kv="DEST_${id}_KEY"
      if $SUDO ssh -i "${!kv}" -o BatchMode=yes -o ConnectTimeout=10 "${!hv}" true 2>/dev/null; then
        ok "[$name] SSH raggiungibile come root"
      else
        warn "[$name] SSH non raggiungibile come root con la chiave indicata."
        info "Il servizio gira come root: la prima connessione va fatta a mano per accettare la host key:"
        info "  $SUDO ssh -i ${!kv} ${!hv}"
        ((PREFLIGHT_WARN++))
      fi ;;
    local)
      pv="DEST_${id}_PATH"; mv="DEST_${id}_REQUIRE_MOUNT"
      if [[ "${!mv:-true}" == true ]]; then
        mountpoint -q "${!pv}" && ok "[$name] montata su ${!pv}" \
          || { warn "[$name] ${!pv} non risulta montata ora (il backup la salterà finché non lo è)."; ((PREFLIGHT_WARN++)); }
      else
        $SUDO mkdir -p "${!pv}" 2>/dev/null && ok "[$name] cartella ${!pv} accessibile" \
          || { warn "[$name] impossibile creare ${!pv}"; ((PREFLIGHT_WARN++)); }
      fi ;;
    rclone)
      rv="DEST_${id}_REMOTE"; remote_name="${!rv%%:*}:"
      if command -v rclone >/dev/null 2>&1 && rclone listremotes 2>/dev/null | grep -qx "$remote_name"; then
        ok "[$name] remote rclone '$remote_name' configurato"
      else
        warn "[$name] remote rclone '$remote_name' non trovato (per l'utente $INSTALL_USER)."
        info "Il servizio gira come root: se hai configurato rclone con il tuo utente, copia ~/.config/rclone/rclone.conf in /root/.config/rclone/."
        ((PREFLIGHT_WARN++))
      fi ;;
    *) warn "[$id] tipo '${type}' sconosciuto"; ((PREFLIGHT_WARN++)) ;;
  esac
done
(( PREFLIGHT_WARN )) && info "$PREFLIGHT_WARN avvisi: puoi proseguire e correggerli dopo, il backup li segnalerà nel log."

# =============================================================================
section "4/5 Servizio e timer systemd"
# =============================================================================
ask "Nome delle unit (senza estensione)" "$UNIT_NAME" UNIT_NAME
UNIT_NAME="${UNIT_NAME//[^a-zA-Z0-9_.@-]/}"
[[ -z "$UNIT_NAME" ]] && die "Nome unit non valido."

SERVICE_FILE="$UNIT_DIR/${UNIT_NAME}.service"
TIMER_FILE="$UNIT_DIR/${UNIT_NAME}.timer"

if [[ -z "$CALENDAR" ]]; then
  if [[ "$ASSUME_YES" == true ]]; then
    CALENDAR="*-*-* 03:00:00"
  else
    echo "  Quando eseguire il backup?"
    echo "    1) ogni giorno alle 03:00"
    echo "    2) ogni giorno a un orario a scelta"
    echo "    3) ogni settimana (giorno e orario a scelta)"
    echo "    4) ogni N ore"
    echo "    5) espressione OnCalendar personalizzata"
    read -rp "  Scelta [1]: " sched; sched="${sched:-1}"
    case "$sched" in
      1) CALENDAR="*-*-* 03:00:00" ;;
      2) ask "Orario (HH:MM)" "03:00" t; CALENDAR="*-*-* ${t}:00" ;;
      3) ask "Giorno (Mon, Tue, Wed, Thu, Fri, Sat, Sun)" "Sun" d
         ask "Orario (HH:MM)" "03:00" t; CALENDAR="${d} *-*-* ${t}:00" ;;
      4) ask "Ogni quante ore" "6" h; CALENDAR="*-*-* 00/${h}:00:00" ;;
      5) ask "OnCalendar" "*-*-* 03:00:00" CALENDAR ;;
      *) die "Scelta non valida." ;;
    esac
  fi
fi

if command -v systemd-analyze >/dev/null 2>&1; then
  if ! systemd-analyze calendar "$CALENDAR" >/dev/null 2>&1; then
    die "Espressione OnCalendar non valida: $CALENDAR  (verifica con: systemd-analyze calendar \"...\")"
  fi
  info "Prossime esecuzioni:"
  systemd-analyze calendar --iterations=3 "$CALENDAR" 2>/dev/null | grep -E "Next elapse|Iteration" | sed 's/^/     /'
fi

PERSISTENT=false
if ask_yn "Recuperare le esecuzioni perse se la macchina era spenta (Persistent)?" s; then PERSISTENT=true; fi

if [[ -e "$SERVICE_FILE" || -e "$TIMER_FILE" ]]; then
  if ! grep -qs "$MARKER" "$SERVICE_FILE" 2>/dev/null; then
    warn "$SERVICE_FILE esiste già e NON è stato creato da questo installer."
    ask_yn "Sovrascriverlo?" n || die "Interrotto: scegli un altro nome con --name."
  else
    info "Unit esistenti create da questo installer: verranno aggiornate."
  fi
fi

SERVICE_CONTENT="$MARKER
[Unit]
Description=autobackup — backup di progetti, unit systemd e documenti
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=root
WorkingDirectory=$SCRIPT_DIR
Environment=HOME=$INSTALL_HOME
ExecStart=/bin/bash $SCRIPT_DIR/backup.sh
"
TIMER_CONTENT="$MARKER
[Unit]
Description=Pianificazione di ${UNIT_NAME}.service

[Timer]
OnCalendar=$CALENDAR
Persistent=${PERSISTENT}
RandomizedDelaySec=300
Unit=${UNIT_NAME}.service

[Install]
WantedBy=timers.target
"

echo ""
echo "  ${BOLD}Verranno creati:${RESET}"
echo "    $SERVICE_FILE"
echo "    $TIMER_FILE   (OnCalendar=$CALENDAR)"
ask_yn "Procedere?" s || die "Annullato."

printf '%s' "$SERVICE_CONTENT" | $SUDO tee "$SERVICE_FILE" >/dev/null || die "Scrittura service fallita."
printf '%s' "$TIMER_CONTENT"   | $SUDO tee "$TIMER_FILE"   >/dev/null || die "Scrittura timer fallita."
$SUDO systemctl daemon-reload || die "daemon-reload fallito."
$SUDO systemctl enable --now "${UNIT_NAME}.timer" || die "Attivazione timer fallita."
ok "Timer attivo"
systemctl list-timers "${UNIT_NAME}.timer" --no-pager 2>/dev/null | sed 's/^/     /'

# =============================================================================
section "5/5 Backup di prova"
# =============================================================================
if [[ "$RUN_TEST" == true ]] && ask_yn "Eseguire subito un backup di prova?" s; then
  $SUDO rm -f "$SCRIPT_DIR/.last_run"
  info "Avvio ${UNIT_NAME}.service (può richiedere qualche minuto)..."
  if $SUDO systemctl start "${UNIT_NAME}.service"; then
    ok "Backup di prova completato"
  else
    warn "Backup di prova terminato con errori."
  fi
  echo ""
  $SUDO journalctl -u "${UNIT_NAME}.service" --since "-10min" --no-pager | grep -E "ERRORE|ATTENZIONE|===" | tail -20 | sed 's/^/     /'
fi

echo ""
echo "${BOLD}${GREEN}Installazione completata.${RESET}"
echo "  Log:         sudo journalctl -u ${UNIT_NAME}.service -n 100 --no-pager"
echo "  Prossimo:    systemctl list-timers ${UNIT_NAME}.timer"
echo "  Rimozione:   bash $SCRIPT_DIR/uninstall.sh --name ${UNIT_NAME}"
