#!/usr/bin/env bash
# =============================================================================
# setup-wizard.sh — configura config.env con un menu interattivo
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.env"

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

ask() {
  local prompt="$1" default="$2" varname="$3"
  local answer
  read -rp "  ${prompt} [${default}]: " answer
  printf -v "$varname" '%s' "${answer:-$default}"
}

ask_bool() {
  local prompt="$1" default_raw="$2" varname="$3"
  local default_sn answer
  case "$default_raw" in
    true|s|S|y|Y) default_sn="s" ;;
    *) default_sn="n" ;;
  esac
  read -rp "  ${prompt} (s/n) [${default_sn}]: " answer
  answer="${answer:-$default_sn}"
  if [[ "$answer" =~ ^[sSyY] ]]; then
    printf -v "$varname" 'true'
  else
    printf -v "$varname" 'false'
  fi
}

clean_path() {
  local p="$1"
  p="${p%\"}"; p="${p#\"}"
  p="${p%\'}"; p="${p#\'}"
  p="${p//\\ / }"
  printf '%s' "$p"
}

# se esiste già un config.env, lo carichiamo come base
DESTINATIONS=()
DOCUMENT_PATHS=()
EXCLUDE_PROJECT_PATHS=()
PROMOTE_TO_PARENT=(backend api src)
DB_NAMES=()
if [[ -f "$CONFIG_FILE" ]]; then
  source "$CONFIG_FILE"
  info "Caricato config.env esistente come base."
fi

# =============================================================================
# gestione DESTINATIONS
# =============================================================================
list_destinations() {
  if [[ "${#DESTINATIONS[@]}" -eq 0 ]]; then
    info "Nessuna destinazione configurata."
    return
  fi
  local i=1
  for id in "${DESTINATIONS[@]}"; do
    local typevar="DEST_${id}_TYPE" namevar="DEST_${id}_NAME"
    echo "  $i) ${!namevar:-$id}  ${YELLOW}(id: $id, tipo: ${!typevar:-?})${RESET}"
    ((i++))
  done
}

add_destination() {
  echo ""
  echo "  Tipo di destinazione:"
  echo "    1) ssh    — un host remoto raggiungibile via SSH (NAS, server...)"
  echo "    2) local  — una cartella locale (USB, disco, o sincronizzata da un client come Dropbox/Google Drive/ecc.)"
  echo "    3) rclone — cloud vero tramite rclone (Drive, S3, Backblaze...)"
  read -rp "  Scelta [1/2/3]: " type_choice

  local suggested_id=""
  case "$type_choice" in
    1) suggested_id="ssh" ;;
    2) suggested_id="local" ;;
    3) suggested_id="cloud" ;;
  esac
  local n=1
  while printf '%s\n' "${DESTINATIONS[@]:-}" | grep -qx "${suggested_id}${n}"; do
    ((n++))
  done
  suggested_id="${suggested_id}${n}"

  local id
  read -rp "  Identificativo breve, senza spazi [${suggested_id}]: " id
  id="${id:-$suggested_id}"
  id=$(echo "$id" | tr -cd 'a-zA-Z0-9_')
  if [[ -z "$id" ]]; then
    warn "Identificativo non valido, destinazione non aggiunta."
    return
  fi
  if printf '%s\n' "${DESTINATIONS[@]:-}" | grep -qx "$id"; then
    warn "Esiste già una destinazione con id '$id', scegline un altro."
    return
  fi

  ask "Nome descrittivo (comparirà nei log)" "$id" name
  declare -g "DEST_${id}_NAME=$name"

  case "$type_choice" in
    1)
      declare -g "DEST_${id}_TYPE=ssh"
      ask "Host SSH (utente@indirizzo)" "user@remote-host" val; declare -g "DEST_${id}_HOST=$val"
      ask "Percorso chiave SSH privata" "$HOME/.ssh/id_ed25519" val; declare -g "DEST_${id}_KEY=$val"
      ask "Percorso di destinazione sull'host remoto" "/path/backup" val; declare -g "DEST_${id}_BASE_PATH=$val"
      ask "Quanti snapshot storici mantenere" "4" val; declare -g "DEST_${id}_KEEP=$val"
      ;;
    2)
      declare -g "DEST_${id}_TYPE=local"
      ask "Percorso della cartella" "/media/user/BACKUP_DRIVE" val; declare -g "DEST_${id}_PATH=$val"
      ask "Elimina backup più vecchi di N giorni" "30" val; declare -g "DEST_${id}_KEEP_DAYS=$val"
      info "Se è un'unità rimovibile (USB) che deve risultare montata, rispondi sì."
      info "Se è una cartella normale (es. sincronizzata da Dropbox/Google Drive/ecc.), rispondi no."
      ask_bool "Richiede che il percorso sia un mount point?" "s" require_mount
      declare -g "DEST_${id}_REQUIRE_MOUNT=$require_mount"
      ;;
    3)
      declare -g "DEST_${id}_TYPE=rclone"
      ask "Remote rclone (nome:percorso, da 'rclone config')" "remote:backup" val
      declare -g "DEST_${id}_REMOTE=$val"
      ;;
    *)
      warn "Scelta non valida, destinazione non aggiunta."
      return
      ;;
  esac

  DESTINATIONS+=("$id")
  ok "Destinazione '$id' aggiunta."
}

remove_destination() {
  if [[ "${#DESTINATIONS[@]}" -eq 0 ]]; then
    info "Nessuna destinazione da rimuovere."
    return
  fi
  list_destinations
  read -rp "  Numero da rimuovere (invio per annullare): " num
  [[ -z "$num" ]] && return
  local idx=$((num - 1))
  if [[ "$idx" -lt 0 || "$idx" -ge "${#DESTINATIONS[@]}" ]]; then
    warn "Numero non valido."
    return
  fi
  local removed_id="${DESTINATIONS[$idx]}"
  DESTINATIONS=("${DESTINATIONS[@]:0:$idx}" "${DESTINATIONS[@]:$((idx + 1))}")
  ok "Destinazione '$removed_id' rimossa dall'elenco attivo (i parametri restano salvati sotto, puoi riaggiungerla con lo stesso id)."
}

# =============================================================================
# MENU PRINCIPALE
# =============================================================================
while true; do
  section "🛠️  Setup autobackup — menu principale"
  echo "  Destinazioni attuali:"
  list_destinations
  echo ""
  echo "  1) Aggiungi destinazione"
  echo "  2) Rimuovi destinazione"
  echo "  3) Gestisci percorsi 'documenti' (file/cartelle senza unit systemd)"
  echo "  4) Gestisci esclusioni dalla discovery automatica"
  echo "  5) Notifiche"
  echo "  6) Dump database"
  echo "  7) Salva e termina"
  read -rp "  Scelta: " choice

  case "$choice" in
    1) add_destination ;;
    2) remove_destination ;;
    3)
      section "Percorsi 'documenti'"
      if [[ "${#DOCUMENT_PATHS[@]}" -gt 0 ]]; then
        info "Percorsi già presenti:"
        for p in "${DOCUMENT_PATHS[@]}"; do echo "     • $p"; done
      fi
      while true; do
        ask_bool "Aggiungere un percorso (file o cartella)?" "n" add_doc
        [[ "$add_doc" != true ]] && break
        read -rp "     Percorso completo, senza virgolette: " raw
        new_path=$(clean_path "$raw")
        [[ -z "$new_path" ]] && { warn "Percorso vuoto, ignorato."; continue; }
        if [[ -e "$new_path" ]]; then
          DOCUMENT_PATHS+=("$new_path"); ok "aggiunto: $new_path"
        else
          ask_bool "     '$new_path' non esiste ora. Aggiungerlo comunque?" "n" add_anyway
          [[ "$add_anyway" == true ]] && DOCUMENT_PATHS+=("$new_path") && ok "aggiunto (non verificato): $new_path"
        fi
      done
      if [[ "${#DOCUMENT_PATHS[@]}" -gt 0 ]]; then
        ask_bool "Rimuovere qualche percorso esistente?" "n" do_remove
        while [[ "$do_remove" == true ]]; do
          i=1
          for p in "${DOCUMENT_PATHS[@]}"; do echo "     $i) $p"; ((i++)); done
          read -rp "     Numero da rimuovere (invio per fermarsi): " num
          [[ -z "$num" ]] && break
          idx=$((num - 1))
          if [[ "$idx" -ge 0 && "$idx" -lt "${#DOCUMENT_PATHS[@]}" ]]; then
            ok "rimosso: ${DOCUMENT_PATHS[$idx]}"
            DOCUMENT_PATHS=("${DOCUMENT_PATHS[@]:0:$idx}" "${DOCUMENT_PATHS[@]:$((idx + 1))}")
          fi
          [[ "${#DOCUMENT_PATHS[@]}" -eq 0 ]] && break
        done
      fi
      ;;
    4)
      section "Esclusioni dalla discovery automatica"
      if [[ "${#EXCLUDE_PROJECT_PATHS[@]}" -gt 0 ]]; then
        info "Esclusioni già presenti:"
        for p in "${EXCLUDE_PROJECT_PATHS[@]}"; do echo "     • $p"; done
      fi
      while true; do
        ask_bool "Aggiungere una sottostringa di path da escludere?" "n" add_excl
        [[ "$add_excl" != true ]] && break
        read -rp "     Sottostringa: " raw
        new_excl=$(clean_path "$raw")
        [[ -n "$new_excl" ]] && EXCLUDE_PROJECT_PATHS+=("$new_excl") && ok "aggiunta: $new_excl"
      done
      ask "Sottocartelle da 'promuovere' al padre (separate da spazio)" "${PROMOTE_TO_PARENT[*]}" promote_raw
      read -ra PROMOTE_TO_PARENT <<< "$promote_raw"
      ;;
    5)
      section "Notifiche"
      ask_bool "Attivare le notifiche?" "${ENABLE_NOTIFICATIONS:-n}" ENABLE_NOTIFICATIONS
      if [[ "$ENABLE_NOTIFICATIONS" == true ]]; then
        ask "Bot token" "${NOTIFY_BOT_TOKEN:-}" NOTIFY_BOT_TOKEN
        ask "Chat ID" "${NOTIFY_CHAT_ID:-}" NOTIFY_CHAT_ID
      fi
      ;;
    6)
      section "Dump database"
      ask_bool "Attivare il dump database?" "${ENABLE_DB_DUMP:-n}" ENABLE_DB_DUMP
      if [[ "$ENABLE_DB_DUMP" == true ]]; then
        ask "Nomi database separati da spazio" "${DB_NAMES[*]:-}" db_names_raw
        read -ra DB_NAMES <<< "$db_names_raw"
        ask "File credenziali mysqldump" "${DB_CREDENTIALS_FILE:-$HOME/.my-backup.cnf}" DB_CREDENTIALS_FILE
      fi
      ;;
    7) break ;;
    *) warn "Scelta non valida." ;;
  esac
done

# =============================================================================
# scrittura config.env
# =============================================================================
{
  echo "# Generato da setup-wizard.sh il $(date '+%Y-%m-%d %H:%M')"
  echo ""
  echo "DESTINATIONS=(${DESTINATIONS[*]:-})"
  echo ""
  for id in "${DESTINATIONS[@]:-}"; do
    typevar="DEST_${id}_TYPE"
    echo "# ── $id ──"
    echo "DEST_${id}_TYPE=\"${!typevar}\""
    namevar="DEST_${id}_NAME"; echo "DEST_${id}_NAME=\"${!namevar:-$id}\""
    case "${!typevar}" in
      ssh)
        for suf in HOST KEY BASE_PATH KEEP; do
          v="DEST_${id}_${suf}"
          echo "DEST_${id}_${suf}=\"${!v:-}\""
        done
        ;;
      local)
        for suf in PATH KEEP_DAYS REQUIRE_MOUNT; do
          v="DEST_${id}_${suf}"
          echo "DEST_${id}_${suf}=\"${!v:-}\""
        done
        ;;
      rclone)
        v="DEST_${id}_REMOTE"
        echo "DEST_${id}_REMOTE=\"${!v:-}\""
        ;;
    esac
    echo ""
  done

  echo "ENABLE_NOTIFICATIONS=${ENABLE_NOTIFICATIONS:-false}"
  echo "NOTIFY_BOT_TOKEN=\"${NOTIFY_BOT_TOKEN:-}\""
  echo "NOTIFY_CHAT_ID=\"${NOTIFY_CHAT_ID:-}\""
  echo ""
  echo "BACKUP_PREFIX=\"${BACKUP_PREFIX:-backup}\""
  echo "LOG_FILE=\"${LOG_FILE:-$SCRIPT_DIR/backup.log}\""
  echo ""
  echo "PROMOTE_TO_PARENT=(${PROMOTE_TO_PARENT[*]:-backend api src})"
  echo "EXCLUDE_PROJECT_PATHS=("
  for p in "${EXCLUDE_PROJECT_PATHS[@]:-}"; do [[ -n "$p" ]] && echo "  \"$p\""; done
  echo ")"
  echo ""
  echo "DOCUMENT_PATHS=("
  for p in "${DOCUMENT_PATHS[@]:-}"; do [[ -n "$p" ]] && echo "  \"$p\""; done
  echo ")"
  echo ""
  echo "ENABLE_DB_DUMP=${ENABLE_DB_DUMP:-false}"
  echo "DB_NAMES=(${DB_NAMES[*]:-})"
  echo "DB_CREDENTIALS_FILE=\"${DB_CREDENTIALS_FILE:-$HOME/.my-backup.cnf}\""
  echo ""
  echo "RSYNC_EXCLUDES=(--exclude '__pycache__' --exclude '.git' --exclude 'venv' --exclude '.venv' --exclude 'node_modules' --exclude '*.pyc')"
  echo "ZIP_EXCLUDES=(-x \"*/__pycache__/*\" -x \"*/.git/*\" -x \"*/venv/*\" -x \"*/.venv/*\" -x \"*/node_modules/*\" -x \"*.pyc\")"
  echo "RCLONE_EXCLUDES=(--exclude \"__pycache__/**\" --exclude \".git/**\" --exclude \"venv/**\" --exclude \".venv/**\" --exclude \"node_modules/**\")"
} > "$CONFIG_FILE"

echo ""
echo "${BOLD}${GREEN}✅ config.env scritto in $CONFIG_FILE${RESET}"
echo "   ${CYAN}📄 Rivedilo con:${RESET} cat $CONFIG_FILE"
echo "   ${CYAN}🚀 Testa con:${RESET}    bash $SCRIPT_DIR/backup.sh"
