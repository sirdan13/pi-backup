#!/usr/bin/env bash
# =============================================================================
# backup.sh — Backup con discovery automatica e destinazioni multiple
#
# Scopre i progetti da salvare leggendo il WorkingDirectory di ogni unit
# systemd attiva: nessuna lista statica da mantenere a mano.
#
# Le destinazioni sono definite in config.env come una lista di ID
# (DESTINATIONS=(...)) — ognuna con il proprio tipo (ssh / local / rclone)
# e i propri parametri (DEST_<id>_...). Puoi averne quante vuoi, anche
# più di una dello stesso tipo (es. due dischi locali diversi).
#
# Vedi config.env.example per il formato completo e commentato.
# Percorso di config alternativo: BACKUP_CONFIG=/percorso/config.env bash backup.sh
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${BACKUP_CONFIG:-$SCRIPT_DIR/config.env}"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERRORE: config.env non trovato in $SCRIPT_DIR"
  echo "Lancia setup-wizard.sh per generarlo, oppure copia config.env.example."
  exit 1
fi

# shellcheck source=config.env.example
source "$CONFIG_FILE"
RSYNC_EXCLUDES+=("--exclude=._*" "--exclude=.DS_Store")

# prefisso delle cartelle di backup per le destinazioni di tipo "local"
BACKUP_PREFIX="${BACKUP_PREFIX:-backup}"

# sudo solo se non siamo già root
SUDO=""
[[ "$EUID" -ne 0 ]] && SUDO="sudo"

TIMESTAMP=$(date '+%Y-%m-%d_%H-%M')
STATUS_OK=true
SUMMARY=()
DB_DUMP_TMP_DIR=""

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "${LOG_FILE:?LOG_FILE non impostato in config.env}"; }

# legge DEST_<id>_<suffisso> con un default se non impostata
get_var() {
  local id="$1" suffix="$2" default="${3:-}"
  local varname="DEST_${id}_${suffix}"
  if [[ -n "${!varname:-}" ]]; then
    printf '%s' "${!varname}"
  else
    printf '%s' "$default"
  fi
}

# =============================================================================
# 0. DUMP DATABASE (opzionale, condiviso da tutte le destinazioni)
# =============================================================================
dump_databases() {
  [[ "${ENABLE_DB_DUMP:-false}" != true ]] && return
  log "=== Dump database ==="
  DB_DUMP_TMP_DIR=$(mktemp -d)

  if ! command -v mysqldump > /dev/null 2>&1; then
    log "ATTENZIONE: mysqldump non trovato — dump database saltato."
    return
  fi

  for db in "${DB_NAMES[@]}"; do
    if mysqldump --defaults-extra-file="$DB_CREDENTIALS_FILE" "$db" \
        > "$DB_DUMP_TMP_DIR/${db}.sql" 2>>"$LOG_FILE"; then
      log "  Dump completato: $db"
    else
      log "  ERRORE dump database: $db"
      STATUS_OK=false
    fi
  done
}

# =============================================================================
# 1. DISCOVERY — trova i progetti dai WorkingDirectory delle unit systemd
# =============================================================================
discover_projects() {
  log "=== Discovery progetti da systemd ==="

  local raw_dirs
  raw_dirs=$($SUDO systemctl list-units --type=service --all --no-legend --plain \
    | awk '{print $1}' \
    | while read -r unit; do
        wd=$($SUDO systemctl show "$unit" -p WorkingDirectory --value 2>/dev/null)
        [[ -n "$wd" ]] && echo "$wd"
      done)

  PROJECTS=()
  while IFS= read -r dir; do
    [[ -z "$dir" ]] && continue
    [[ "$dir" == "/" || "$dir" == "!"* ]] && continue

    for suffix in "${PROMOTE_TO_PARENT[@]}"; do
      if [[ "$dir" == *"/$suffix" ]]; then
        dir=$(dirname "$dir")
        break
      fi
    done

    local skip=false
    for excl in "${EXCLUDE_PROJECT_PATHS[@]}"; do
      [[ -n "$excl" && "$dir" == *"$excl"* ]] && skip=true && break
    done
    [[ "$skip" == true ]] && continue

    PROJECTS+=("$dir")
  done <<< "$raw_dirs"

  mapfile -t PROJECTS < <(printf '%s\n' "${PROJECTS[@]:-}" | sed '/^$/d' | sort -u)

  # rimuove sottocartelle già incluse in un progetto padre della lista
  local deduped=()
  for candidate in "${PROJECTS[@]}"; do
    local is_subpath=false
    for other in "${PROJECTS[@]}"; do
      [[ "$candidate" == "$other" ]] && continue
      [[ "$candidate" == "$other/"* ]] && is_subpath=true && break
    done
    [[ "$is_subpath" == false ]] && deduped+=("$candidate")
  done
  PROJECTS=("${deduped[@]:-}")
  [[ -z "${PROJECTS[0]:-}" ]] && PROJECTS=()

  log "Progetti trovati (${#PROJECTS[@]}):"
  for p in "${PROJECTS[@]}"; do
    log "  - $p"
  done
}

# =============================================================================
# 2. DESTINAZIONE tipo: ssh (rsync su host remoto)
# =============================================================================
# rsync verso SSH: ignora i soli errori di chmod (destinazioni con filesystem
# FAT/exFAT che non supportano i permessi POSIX). Qualsiasi altro errore resta.
rsync_ssh() {
  local out rc filtered
  out=$(rsync "$@" 2>&1); rc=$?
  filtered=$(grep -v -e 'failed to set permissions' \
                     -e 'some files/attrs were not transferred' <<<"$out")
  [[ -n "$filtered" ]] && echo "$filtered" >> "$LOG_FILE"
  if [[ $rc -eq 23 ]]; then
    grep -q 'rsync:' <<<"$filtered" && return 23
    return 0
  fi
  return $rc
}

backup_ssh_destination() {
  local id="$1"
  local name; name=$(get_var "$id" NAME "$id")
  local host; host=$(get_var "$id" HOST)
  local key; key=$(get_var "$id" KEY)
  local base_path; base_path=$(get_var "$id" BASE_PATH)
  local keep; keep=$(get_var "$id" KEEP 4)

  log "=== Backup verso [$name] (SSH: $host) ==="
  if ! ssh -i "$key" -o ConnectTimeout=10 "$host" "echo ok" > /dev/null 2>&1; then
    log "ERRORE: [$name] non raggiungibile via SSH — saltata."
    STATUS_OK=false
    SUMMARY+=("❌ $name: irraggiungibile")
    return
  fi

  local dest="$base_path/$TIMESTAMP"
  ssh -i "$key" "$host" "mkdir -p $dest/projects $dest/documents $dest/systemd $dest/databases"

  for src in "${PROJECTS[@]}"; do
    if [[ -d "$src" ]]; then
      local pname; pname=$(basename "$src")
      rsync_ssh -rz --no-perms --no-owner --no-group "${RSYNC_EXCLUDES[@]}" --no-times --inplace \
        -e "ssh -i $key" "$src" "$host:$dest/projects/" \
        --rsync-path="rsync --no-perms --no-owner --no-group --no-times --no-acls --no-xattrs" \
        && log "  [$name] -> $pname" \
        || { log "  ERRORE [$name] su $pname"; STATUS_OK=false; }
    fi
  done

  for f in "${DOCUMENT_PATHS[@]}"; do
    if [[ -e "$f" ]]; then
      rsync_ssh -rz --no-perms --no-owner --no-group "${RSYNC_EXCLUDES[@]}" --no-times --inplace \
        -e "ssh -i $key" "$f" "$host:$dest/documents/" \
        --rsync-path="rsync --no-perms --no-owner --no-group --no-times --no-acls --no-xattrs" \
        && log "  [$name] -> $(basename "$f") (documenti)" || STATUS_OK=false
    fi
  done

  local tmp_systemd; tmp_systemd=$(mktemp -d)
  find /etc/systemd/system -maxdepth 1 \( -name "*.service" -o -name "*.timer" \) \
    ! -name "getty*" ! -name "serial*" -exec cp {} "$tmp_systemd/" \; 2>/dev/null
  rsync_ssh -rz --no-perms --no-owner --no-group -e "ssh -i $key" --no-times --inplace \
        --rsync-path="rsync --no-perms --no-owner --no-group --no-times --no-acls --no-xattrs" \
    "$tmp_systemd"/ "$host:$dest/systemd/" || STATUS_OK=false
  rm -rf "$tmp_systemd"

  if [[ -n "$DB_DUMP_TMP_DIR" && -d "$DB_DUMP_TMP_DIR" && -n "$(ls -A "$DB_DUMP_TMP_DIR" 2>/dev/null)" ]]; then
    rsync_ssh -rz --no-perms --no-owner --no-group -e "ssh -i $key" --no-times --inplace \
        --rsync-path="rsync --no-perms --no-owner --no-group --no-times --no-acls --no-xattrs" \
      "$DB_DUMP_TMP_DIR"/ "$host:$dest/databases/" || STATUS_OK=false
    log "  [$name] -> dump database"
  fi

  local tmp_cron; tmp_cron=$(mktemp)
  crontab -l > "$tmp_cron" 2>/dev/null || true
  rsync_ssh -rz --no-perms --no-owner --no-group -e "ssh -i $key" --no-times --inplace \
        --rsync-path="rsync --no-perms --no-owner --no-group --no-times --no-acls --no-xattrs" \
    "$tmp_cron" "$host:$dest/documents/crontab-backup.txt" || STATUS_OK=false
  rm -f "$tmp_cron"

  ssh -i "$key" "$host" \
    "cd $base_path && ls -1dt 20[0-9][0-9]-* | tail -n +$((keep + 1)) | xargs -r rm -rf"

  log "  → [$name] completata in $dest"
  SUMMARY+=("✅ $name: $dest")
}

# =============================================================================
# 3. DESTINAZIONE tipo: local (cartella locale — USB, disco, o cartella
#    sincronizzata da un client esterno tipo Dropbox/Nextcloud/ecc.)
# =============================================================================
zip_project() {
  zip -r -q "$@"; local rc=$?
  if [[ $rc -eq 18 ]]; then log "  ATTENZIONE: file spariti durante lo zip (ignorato)"; return 0; fi
  return $rc
}

backup_local_destination() {
  local id="$1"
  local name; name=$(get_var "$id" NAME "$id")
  local path; path=$(get_var "$id" PATH)
  local keep_days; keep_days=$(get_var "$id" KEEP_DAYS 30)
  local require_mount; require_mount=$(get_var "$id" REQUIRE_MOUNT true)

  log "=== Backup verso [$name] ($path) ==="

  if [[ "$require_mount" == true ]]; then
    if ! mountpoint -q "$path"; then
      log "ERRORE: [$name] non montata su $path — saltata."
      STATUS_OK=false
      SUMMARY+=("❌ $name: non montata")
      return
    fi
  else
    if ! mkdir -p "$path" 2>/dev/null; then
      log "ERRORE: [$name] impossibile creare/accedere a $path — saltata."
      STATUS_OK=false
      SUMMARY+=("❌ $name: percorso non accessibile")
      return
    fi
  fi

  local dest="$path/backups/${BACKUP_PREFIX}_$TIMESTAMP"
  mkdir -p "$dest/projects" "$dest/documents" "$dest/systemd" "$dest/databases"

  for src in "${PROJECTS[@]}"; do
    if [[ -d "$src" ]]; then
      local pname; pname=$(basename "$src")
      zip_project "$dest/projects/${pname}.zip" "$src" "${ZIP_EXCLUDES[@]}" \
        && log "  [$name] -> ${pname}.zip" \
        || { log "  ERRORE [$name] su $pname"; STATUS_OK=false; }
    fi
  done

  for f in "${DOCUMENT_PATHS[@]}"; do
    if [[ -e "$f" ]]; then
      cp -rL "$f" "$dest/documents/" && log "  [$name] -> $(basename "$f") (documenti)"
    fi
  done

  find /etc/systemd/system -maxdepth 1 \( -name "*.service" -o -name "*.timer" \) \
    ! -name "getty*" ! -name "serial*" -exec cp {} "$dest/systemd/" \; 2>/dev/null

  if [[ -n "$DB_DUMP_TMP_DIR" && -d "$DB_DUMP_TMP_DIR" && -n "$(ls -A "$DB_DUMP_TMP_DIR" 2>/dev/null)" ]]; then
    cp -r "$DB_DUMP_TMP_DIR"/* "$dest/databases/" 2>/dev/null
    log "  [$name] -> dump database"
  fi

  crontab -l > "$dest/documents/crontab-backup.txt" 2>/dev/null || true

  find "$path/backups" -maxdepth 1 -name "${BACKUP_PREFIX}_*" -type d \
    -mtime "+$keep_days" -exec rm -rf {} \;

  local total_size; total_size=$(du -sh "$dest" | cut -f1)
  log "  → [$name] completata — $total_size in $dest"
  SUMMARY+=("✅ $name: $total_size in $dest")
}

# =============================================================================
# 4. DESTINAZIONE tipo: rclone (cloud vero — Drive, S3, Backblaze, ecc.)
# =============================================================================
backup_rclone_destination() {
  local id="$1"
  local name; name=$(get_var "$id" NAME "$id")
  local remote; remote=$(get_var "$id" REMOTE)

  log "=== Backup verso [$name] (rclone: $remote) ==="
  if ! command -v rclone > /dev/null 2>&1; then
    log "ERRORE: rclone non installato — [$name] saltata."
    STATUS_OK=false
    SUMMARY+=("❌ $name: rclone non installato")
    return
  fi

  local dest="$remote/$TIMESTAMP"
  for src in "${PROJECTS[@]}"; do
    if [[ -d "$src" ]]; then
      local pname; pname=$(basename "$src")
      rclone copy "$src" "$dest/projects/$pname" "${RCLONE_EXCLUDES[@]}" \
        && log "  [$name] -> $pname" \
        || { log "  ERRORE [$name] su $pname"; STATUS_OK=false; }
    fi
  done

  for f in "${DOCUMENT_PATHS[@]}"; do
    if [[ -e "$f" ]]; then
      rclone copy "$f" "$dest/documents/$(basename "$f")" \
        && log "  [$name] -> $(basename "$f") (documenti)"
    fi
  done

  log "  → [$name] completata in $dest"
  SUMMARY+=("✅ $name: $dest")
}

# =============================================================================
# 5. NOTIFICA
# =============================================================================
send_notification() {
  [[ "${ENABLE_NOTIFICATIONS:-false}" != true ]] && return
  if [[ -z "${NOTIFY_BOT_TOKEN:-}" || -z "${NOTIFY_CHAT_ID:-}" ]]; then
    log "ATTENZIONE: ENABLE_NOTIFICATIONS=true ma credenziali mancanti — notifica saltata."
    return
  fi
  local message="$FINAL_STATUS"$'\n'"$(printf '%s\n' "${SUMMARY[@]}")"
  curl -s -X POST "https://api.telegram.org/bot${NOTIFY_BOT_TOKEN}/sendMessage" \
    -d chat_id="${NOTIFY_CHAT_ID}" \
    --data-urlencode text="${message}" > /dev/null
}

# =============================================================================
# ESECUZIONE
# =============================================================================
# --- protezione: lock + intervallo minimo tra due backup ---
# Salta i run ravvicinati (riavvii, recuperi del timer, avvii doppi).
# Per forzare: sudo FORCE=1 bash backup.sh
STATE_DIR="${STATE_DIR:-$SCRIPT_DIR}"
LAST_RUN_FILE="$STATE_DIR/.last_run"
MIN_INTERVAL_HOURS="${MIN_INTERVAL_HOURS:-12}"

exec 9>"$STATE_DIR/.backup.lock"
if ! flock -n 9; then
  log "Backup già in esecuzione — salto."
  exit 0
fi

if [[ "${FORCE:-0}" != 1 && -f "$LAST_RUN_FILE" ]]; then
  age=$(( $(date +%s) - $(stat -c %Y "$LAST_RUN_FILE") ))
  if (( age < MIN_INTERVAL_HOURS * 3600 )); then
    log "Ultimo backup avviato $((age / 60)) min fa (minimo ${MIN_INTERVAL_HOURS}h) — salto."
    exit 0
  fi
fi
touch "$LAST_RUN_FILE"

log "=== Backup avviato — $TIMESTAMP ==="

dump_databases
discover_projects

if [[ "${#DESTINATIONS[@]}" -eq 0 ]]; then
  log "ATTENZIONE: nessuna destinazione configurata in DESTINATIONS — nulla da fare."
fi

for id in "${DESTINATIONS[@]}"; do
  typevar="DEST_${id}_TYPE"
  type="${!typevar:-}"
  case "$type" in
    ssh)    backup_ssh_destination "$id" ;;
    local)  backup_local_destination "$id" ;;
    rclone) backup_rclone_destination "$id" ;;
    *)
      log "ATTENZIONE: destinazione '$id' ha TYPE mancante o sconosciuto ('$type') — saltata."
      STATUS_OK=false
      ;;
  esac
done

if [[ "$STATUS_OK" == true ]]; then
  FINAL_STATUS="✅ Backup completato ($TIMESTAMP)"
else
  FINAL_STATUS="⚠️ Backup completato con errori ($TIMESTAMP) — controllare log"
fi
log "=== $FINAL_STATUS ==="

send_notification

[[ -n "$DB_DUMP_TMP_DIR" && -d "$DB_DUMP_TMP_DIR" ]] && rm -rf "$DB_DUMP_TMP_DIR"

[[ "$STATUS_OK" == true ]] && exit 0 || exit 1
