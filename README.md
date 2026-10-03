# autobackup

Backup per macchine Linux con systemd, con **discovery automatica dei progetti**
e **destinazioni multiple** (SSH/rsync, cartelle locali o sincronizzate, rclone).

Lo script scopre cosa salvare leggendo il `WorkingDirectory` di ogni unit
systemd: non c'è nessuna lista di progetti da mantenere a mano. Un installer
interattivo configura tutto, compreso il timer.

## Requisiti

- Linux con systemd
- bash ≥ 4.4
- `rsync`, `zip`, `ssh`
- opzionali: `rclone` (destinazioni cloud), `mysqldump` (dump database), `curl` (notifiche Telegram)

## Installazione rapida

```bash
git clone <url-del-repo> autobackup
cd autobackup
bash setup-wizard.sh     # crea config.env
bash install.sh          # verifica, crea service + timer, backup di prova
```

`install.sh` accetta anche opzioni non interattive:

```bash
bash install.sh -y                              # default, nessuna domanda
bash install.sh --name miobackup                # nome delle unit
bash install.sh --calendar "Sun *-*-* 04:00:00" # schedulazione OnCalendar
bash install.sh --no-test                       # salta il backup di prova
```

Rimozione (non tocca i backup già creati):

```bash
bash uninstall.sh
```

## Struttura

```
autobackup/
├── backup.sh            # script principale
├── setup-wizard.sh      # menu interattivo per generare config.env
├── install.sh           # installer interattivo di service + timer systemd
├── uninstall.sh         # rimozione di service + timer
├── config.env.example   # template di configurazione, valori fittizi
├── config.env           # la TUA configurazione (ignorata da git)
├── .gitignore
└── README.md
```

## Destinazioni

Le destinazioni sono una **lista** (`DESTINATIONS=(...)` in `config.env`),
ognuna con un tipo:

- **`ssh`** — host remoto raggiungibile via SSH/rsync (NAS, server...)
- **`local`** — cartella locale. Può essere un'unità rimovibile (USB, disco
  esterno: con `REQUIRE_MOUNT=true` lo script verifica che sia montata) oppure
  una cartella già sincronizzata nel cloud da un client esterno come Dropbox,
  Nextcloud o Google Drive desktop (`REQUIRE_MOUNT=false`: lo script scrive lì,
  il client fa il resto)
- **`rclone`** — cloud vero tramite [rclone](https://rclone.org) (Drive, S3,
  Backblaze, ecc.)

Puoi avere quante destinazioni vuoi, anche più di una dello stesso tipo.

**Convenzione**: l'ID di ogni destinazione (`ssh1`, `local1`, `local2`...) resta
generico. Il nome descrittivo va solo nel campo `NAME`, quello che compare nei log.

## Configurazione

Con il wizard (consigliato):

```bash
bash setup-wizard.sh
```

È un menu: aggiungi/rimuovi destinazioni, percorsi "documenti", esclusioni,
notifiche, dump database. Alla voce 7 salva in `config.env`. Puoi rilanciarlo
quando vuoi: riparte da ciò che c'è già.

A mano:

```bash
cp config.env.example config.env
nano config.env
chmod 600 config.env
```

`config.env` può contenere token e percorsi: è in `.gitignore`, non versionarlo.

### Percorsi "documenti"

`DOCUMENT_PATHS` — file o cartelle da includere sempre ma che non hanno una
unit systemd (config, note, documenti). Finiscono in `documents/` in ogni destinazione.

### Variabili di esclusione

- `EXCLUDE_PROJECT_PATHS` — sottostringhe di percorso da ignorare nella discovery
- `PROMOTE_TO_PARENT` — suffissi (es. `backend`) per cui si salva la cartella padre
- `RSYNC_EXCLUDES`, `ZIP_EXCLUDES`, `RCLONE_EXCLUDES` — esclusioni per tipo di destinazione

`._*` e `.DS_Store` sono sempre esclusi per le destinazioni `ssh`.

### Prefisso delle cartelle locali

`BACKUP_PREFIX` (default `backup`) dà il nome alle cartelle delle destinazioni
`local`: `backup_YYYY-MM-DD_HH-MM`. La retention cancella **solo** cartelle con
questo prefisso: se lo cambi, quelle vecchie non verranno più ruotate.

## Cosa viene salvato

| Contenuto            | ssh                  | local    | rclone        |
|----------------------|----------------------|----------|---------------|
| Progetti (discovery) | sì (rsync, cartelle) | sì (zip) | sì (cartelle) |
| `DOCUMENT_PATHS`     | sì                   | sì       | sì            |
| Unit systemd         | sì                   | sì       | no            |
| Crontab              | sì                   | sì       | no            |
| Dump database        | sì                   | sì       | no            |

## Retention

| Tipo     | Regola                                                            |
|----------|-------------------------------------------------------------------|
| `ssh`    | ultime `DEST_<id>_KEEP` copie (default 4)                         |
| `local`  | cartelle più vecchie di `DEST_<id>_KEEP_DAYS` giorni (default 30) |
| `rclone` | nessuna rotazione                                                 |

## Destinazioni SSH con filesystem FAT/exFAT

Se il filesystem remoto non supporta `chmod`, rsync termina con codice 23 e
righe `failed to set permissions`. I file sono copiati correttamente: lo script
(`rsync_ssh`) ignora solo questi errori, mentre qualsiasi altro errore rsync
segna il backup come fallito.

## Servizio schedulato: guida manuale

`install.sh` fa tutto questo al posto tuo. Se preferisci procedere a mano, il
backup gira con due unit systemd: un `.service` (esegue lo script una volta) e
un `.timer` (lo avvia a orari fissi). Il service gira come root perché
`backup.sh` usa `systemctl` e legge percorsi di sistema.

Sostituisci `/percorso/autobackup` con la cartella del progetto e `utente` con il
tuo utente.

### 1. Service

```bash
sudo tee /etc/systemd/system/autobackup.service > /dev/null <<'UNIT'
[Unit]
Description=autobackup — backup di progetti, unit systemd e documenti
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=root
WorkingDirectory=/percorso/autobackup
Environment=HOME=/home/utente
ExecStart=/bin/bash /percorso/autobackup/backup.sh
UNIT
```

`Environment=HOME=...` serve perché sotto root `$HOME` varrebbe `/root`: così i
percorsi del `config.env` che usano `$HOME` puntano alla tua home.

### 2. Timer

```bash
sudo tee /etc/systemd/system/autobackup.timer > /dev/null <<'UNIT'
[Unit]
Description=Pianificazione di autobackup.service

[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
UNIT
```

`Persistent=true` recupera le esecuzioni perse se la macchina era spenta all'orario previsto.

### 3. Attivazione

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now autobackup.timer
```

### 4. Verifica

```bash
systemctl list-timers autobackup.timer        # deve mostrare NEXT e LEFT
systemctl status autobackup.timer --no-pager
systemctl cat autobackup.service autobackup.timer
```

### 5. Test e log

```bash
sudo systemctl start autobackup.service
sudo journalctl -u autobackup.service -n 100 --no-pager
sudo journalctl -u autobackup.service --since "-10min" --no-pager | grep -E "ERRORE|ATTENZIONE|==="
```

### Gestione

```bash
sudo systemctl disable --now autobackup.timer   # sospende la schedulazione
sudo systemctl enable --now autobackup.timer    # la riattiva
sudo systemctl edit --full autobackup.timer     # modifica OnCalendar=
sudo systemctl daemon-reload                    # dopo ogni modifica ai file unit
systemd-analyze calendar "*-*-* 03:00:00"       # verifica un'espressione OnCalendar
```

### Esempi di OnCalendar

| Espressione              | Significato                |
|--------------------------|----------------------------|
| `*-*-* 03:00:00`         | ogni giorno alle 03:00     |
| `Sun *-*-* 04:00:00`     | ogni domenica alle 04:00   |
| `*-*-* 00/6:00:00`       | ogni 6 ore                 |
| `*-*-01 02:00:00`        | il primo di ogni mese      |

## SSH come root

Il servizio gira come root, quindi la **prima connessione** verso ogni host SSH
va fatta a mano da root per accettare la host key, altrimenti il backup fallisce
in modo non interattivo:

```bash
sudo ssh -i /percorso/chiave utente@host
```

`install.sh` lo verifica nella fase "Verifica destinazioni".

## Chiave privata SSH

`backup.sh` non include mai una chiave privata nel backup: solo i file che metti
tu in `DOCUMENT_PATHS` (e lì ci va al massimo la chiave *pubblica*). Tieni la
privata in un password manager, oppure fanne una copia cifrata:

```bash
gpg -c ~/.ssh/id_ed25519_backup     # crea id_ed25519_backup.gpg, protetto da passphrase
# ripristino: gpg -d id_ed25519_backup.gpg > id_ed25519_backup
```

## Ripristino

- **Destinazioni `local`**: ogni progetto è uno zip in `projects/`
  (`unzip nome.zip -d /tmp/ripristino`); verifica l'integrità con `unzip -t nome.zip`.
- **Destinazioni `ssh` / `rclone`**: i progetti sono cartelle normali, copiabili con `rsync`/`rclone copy`.
- Le unit systemd salvate sono in `systemd/`: copiale in `/etc/systemd/system/`
  e lancia `sudo systemctl daemon-reload`.

Un backup non provato non è un backup: prova un ripristino dopo la prima installazione.

## Sicurezza

- `config.env` ha permessi `600` (li imposta `install.sh`) e non va mai committato.
- Le credenziali del dump MySQL stanno in un file separato (`DB_CREDENTIALS_FILE`), mai in `config.env`.
- Il token del bot Telegram, se usato, è in `config.env`: trattalo come una password.
