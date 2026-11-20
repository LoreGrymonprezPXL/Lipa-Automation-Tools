#!/bin/bash
# =============================================================================
# Lipa ICT - Datto RMM component: macOS update/upgrade naar de nieuwste versie
#
#   Starter (Datto-job, enkele seconden) -> eenmalige LaunchDaemon -> worker
#   De worker haalt de installer op, waarschuwt de gebruiker en installeert.
#   Datto toont "Completed" zodra de daemon draait; een herstart maakt niets stuk.
#
#   Live meekijken (SSH):   tail -f /var/log/lipa-macos-upgrade.log
#
# Datto-variabelen (alle optioneel):
#   ADMIN_USER / ADMIN_PASS  volume-owner, ALLEEN nodig op Apple Silicon [clientadmin / -]
#                            (ADMIN_PASS als gemaskeerde variabele)
#   MIN_FREE_GB              minimaal vrije schijfruimte in GB           [35]
#   INSTALLER_VERSION        vaste installerversie, bv. 26.7.3           [leeg = Apple kiest]
#   RESTART_WARN_SEC         zo lang staat de herstart-melding open      [120]
#   MAX_DEFERRALS            maximaal aantal keren uitstellen            [2]
#
# De gebruiker krijgt ALLEEN een melding als het moet:
#   - te weinig opslagruimte  -> vrijmaken of Lipa support bellen
#   - niet op netstroom       -> lader aansluiten
#   - herstart nodig          -> sla uw werk op, de laptop herstart
# Exitcodes: 0 = gestart of niets te doen | 1 = daemon starten mislukt | 2 = pre-flight niet OK
# =============================================================================
#
# Samenvatting uitgevoerde verbeteringen:
# - Herstartmeldingen en uitstelregistratie werkend gemaakt in de worker.
# - Deferral-variabelen toegevoegd, inclusief standaardwaarde van twee uitstellen.
# - Installer-versies betrouwbaarder bepaald via Apple-metadata en versievergelijking.
# - Mislukte installer-downloads worden nu correct gelogd en afgebroken.
# - Bestaande installers en het Apple Silicon-wachtwoord veiliger afgehandeld.
#

ADMIN_USER="${ADMIN_USER:-clientadmin}"
MIN_FREE_GB="${MIN_FREE_GB:-35}"
INSTALLER_VERSION="${INSTALLER_VERSION:-}"
RESTART_WARN_SEC="${RESTART_WARN_SEC:-120}"
MAX_DEFERRALS="${MAX_DEFERRALS:-2}"
SUPPORT_TEL="011 462325"
RESTART_MSG="Herstart nodig: uw laptop herstart automatisch over enkele minuten om de update te installeren. Sla nu uw werk op."

LOG=/var/log/lipa-macos-upgrade.log
LABEL=com.lipaict.macos-upgrade
DIR=/Library/Management/lipa
WORKER=$DIR/worker.sh; PWFILE=$DIR/pw; PWKEY=""
DEFER_FILE=$DIR/restart-deferrals
APPS=/Applications
PATH=/usr/bin:/bin:/usr/sbin:/sbin

# ---- Functies (de worker gebruikt dezelfde) ----------------------------------
log()      { printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG"; }
fail()     { log "FOUT: $1"; [ -n "$2" ] && start_daemon "$LABEL.notice" notice "$2" 45; exit 2; }   # fail "<log>" ["<popup>"]
ac_ok()    { pmset -g batt | head -1 | grep -q 'AC Power'; }
run()      { "$@" >>"$LOG" 2>&1; }                   # uitvoer van commando's live naar het logbestand
find_app() {
  local app
  for app in "$APPS"/Install\ macOS*.app; do
    [ -d "$app" ] && { printf '%s\n' "$app"; return 0; }
  done
  return 1
}

# Major-versie van een "Install macOS <naam>.app".
app_major() {
  case "$1" in *Tahoe*) echo 26;; *Sequoia*) echo 15;; *Sonoma*) echo 14;; *Ventura*) echo 13;;
               *Monterey*) echo 12;; *"Big Sur"*) echo 11;; *) echo 0;; esac
}

app_version() {
  /usr/libexec/PlistBuddy -c 'Print :System Image Info:version' \
    "$1/Contents/SharedSupport/InstallInfo.plist" 2>/dev/null
}

version_gt() {
  awk -F. -v a="$1" -v b="$2" '
    BEGIN {
      split(a, av); split(b, bv); n = 4
      for (i = 1; i <= n; i++) {
        ai = (av[i] == "" ? 0 : av[i]) + 0
        bi = (bv[i] == "" ? 0 : bv[i]) + 0
        if (ai > bi) exit 0
        if (ai < bi) exit 1
      }
      exit 1
    }'
}

app_is_newer() {
  local app="$1" current="$2" version
  version=$(app_version "$app")
  if [ -n "$version" ]; then
    version_gt "$version" "$current"
    return $?
  fi
  [ "$(app_major "$app")" -gt "${current%%.*}" ]
}

# Popup in de GUI-sessie van de ingelogde gebruiker; geeft zichzelf op na <sec> seconden.
notify() {   # notify "<tekst>" <sec>
  local u uid out
  u=$(stat -f%Su /dev/console 2>/dev/null)
  case "$u" in ""|root|_mbsetupuser) log "Melding overgeslagen: niemand ingelogd."; return;; esac
  uid=$(id -u "$u")
  out=$(launchctl asuser "$uid" sudo -u "$u" /usr/bin/osascript -e \
    "display dialog \"$1\" with title \"Lipa ICT - macOS update\" buttons {\"OK\"} default button \"OK\" with icon caution giving up after $2" 2>&1)
  log "Melding aan '$u' (max $2 s): ${out:-geen uitvoer}"
}

# Wacht tot de lader zit; vraagt de gebruiker er pas om als het echt nodig is (max ~6 min).
wait_for_power() {
  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    ac_ok && return 0
    if [ "$i" -eq 1 ] || [ "$i" -eq 7 ]; then
      notify "Sluit uw laptop aan op netstroom zodat de macOS-update kan doorgaan." 60
    fi
    sleep 30
  done
  return 1
}

# Vraagt bij herstart om bevestiging met max $MAX_DEFERRALS keer uitstellen.
# Return 0 = nu herstarten/doorgaan | Return 1 = uitgesteld
ask_restart() {
  local u uid count rem out
  u=$(stat -f%Su /dev/console 2>/dev/null)
  case "$u" in ""|root|_mbsetupuser)
    log "Geen actieve GUI-gebruiker; herstart gaat door."
    rm -f "$DEFER_FILE"
    return 0
    ;;
  esac

  count=0
  [ -f "$DEFER_FILE" ] && count=$(cat "$DEFER_FILE" 2>/dev/null || echo 0)
  case "$count" in ''|*[!0-9]*) count=0;; esac
  uid=$(id -u "$u")

  if [ "$count" -lt "$MAX_DEFERRALS" ]; then
    rem=$((MAX_DEFERRALS - count))
    out=$(launchctl asuser "$uid" sudo -u "$u" /usr/bin/osascript -e \
      "display dialog \"Er staat een macOS-update klaar waarvoor een herstart nodig is. U kunt dit nog $rem keer uitstellen.\" with title \"Lipa ICT - macOS update\" buttons {\"Uitstellen\", \"Nu herstarten\"} default button \"Nu herstarten\" with icon caution giving up after $RESTART_WARN_SEC" 2>&1)
    log "Keuze aan '$u' (uitstel $count/$MAX_DEFERRALS): ${out:-timeout}"

    if echo "$out" | grep -q "Nu herstarten"; then
      rm -f "$DEFER_FILE"
      return 0
    fi

    count=$((count + 1))
    printf '%s\n' "$count" > "$DEFER_FILE"
    log "Herstart uitgesteld ($count/$MAX_DEFERRALS)."
    return 1
  fi

  out=$(launchctl asuser "$uid" sudo -u "$u" /usr/bin/osascript -e \
    "display dialog \"Maximaal aantal keer uitgesteld ($MAX_DEFERRALS/$MAX_DEFERRALS). Sla uw werk nu op; uw Mac herstart zo.\" with title \"Lipa ICT - Verplichte herstart\" buttons {\"Nu herstarten\"} default button \"Nu herstarten\" with icon caution giving up after $RESTART_WARN_SEC" 2>&1)
  log "Verplichte herstartmelding aan '$u': ${out:-timeout}"
  rm -f "$DEFER_FILE"
  return 0
}

# ---- Worker: draait als LaunchDaemon, los van de Datto-job -------------------
worker() {
  local arch osver cur newest app name rc pass="" old_app fetch=(--fetch-full-installer) auth=()
  [ "${1:-}" = notice ] && { notify "$2" "$3"; return 0; }     # alleen een popup tonen (voor pre-flight fouten)
  arch=$(uname -m); osver=$(sw_vers -productVersion); cur=${osver%%.*}
  log "=== Worker gestart: macOS $osver ($arch) ==="
  caffeinate -i -m -s -w $$ >/dev/null 2>&1 &         # Mac niet laten slapen tijdens download/installatie
  if [ "$arch" = arm64 ]; then
    if ! IFS= read -r pass; then
      log "FOUT: volume-owner wachtwoord kon niet worden gelezen."
      return 1
    fi
    rm -f "$PWFILE"
    auth=(--user "$ADMIN_USER" --stdinpass)
  fi
  [ -n "$INSTALLER_VERSION" ] && fetch+=(--full-installer-version "$INSTALLER_VERSION")

  # 1) Nieuwe major beschikbaar? Dan volledige installer ophalen en startosinstall draaien.
  newest=$(softwareupdate --list-full-installers 2>/dev/null | sed -n 's/.*Version: \([0-9]*\).*/\1/p' | sort -n | tail -1)
  log "Huidige major: $cur | nieuwste major in catalogus: ${newest:-onbekend}"
  if [ -n "$INSTALLER_VERSION" ] || [ "${newest:-0}" -gt "$cur" ]; then
    app=$(find_app)
    if [ -n "$app" ] && [ -z "$INSTALLER_VERSION" ] && app_is_newer "$app" "$osver"; then
      log "Installer staat al klaar: $app"
    else
      for old_app in "$APPS"/Install\ macOS*.app; do
        [ -d "$old_app" ] && rm -rf "$old_app"
      done
      log "Installer ophalen: softwareupdate ${fetch[*]}  (duurt lang, voortgang hieronder)"
      if ! run softwareupdate "${fetch[@]}"; then
        log "FOUT: ophalen van de macOS-installer is mislukt."
        return 1
      fi
      log "fetch-full-installer succesvol afgerond."
      app=$(find_app)
    fi

    if [ -n "$app" ] && app_is_newer "$app" "$osver"; then
      name=$(basename "$app" .app); name=${name#Install }
      log "Installer klaar: $name. Netstroom controleren, gebruiker om herstart waarschuwen, daarna startosinstall."
      wait_for_power || { log "FOUT: geen netstroom; upgrade uitgesteld (installer blijft staan voor de volgende run)."; return 1; }
      ask_restart || { log "Update/herstart uitgesteld door gebruiker."; return 0; }
      run "$app/Contents/Resources/startosinstall" --agreetolicense --forcequitapps --nointeraction "${auth[@]}" < <(printf '%s\n' "$pass"); rc=$?
      log "startosinstall eindigde met code $rc"
      [ "$rc" -eq 0 ] && { log "Upgrade gestart; de Mac herstart zo."; return 0; }
      log "WAARSCHUWING: startosinstall mislukt; terugval op kleine updates."
    else
      log "Geen geschikte nieuwe major-installer; verder met kleine updates."
    fi
  fi

  # 2) Geen nieuwe major (of upgrade mislukt): gewone updates
  log "Kleine updates: softwareupdate --install --all --restart"
  if softwareupdate --list 2>&1 | grep -qi restart; then                  # herstart nodig? dan pas een melding
    wait_for_power || { log "FOUT: geen netstroom; updates uitgesteld tot de volgende run."; return 1; }
    notify "$RESTART_MSG" "$RESTART_WARN_SEC"
  fi
  run softwareupdate --install --all --restart "${auth[@]}" < <(printf '%s\n' "$pass"); rc=$?
  log "softwareupdate eindigde met code $rc"
  log "=== Worker klaar ==="
  return "$rc"
}

# ---- Eenmalige LaunchDaemon: draait de worker los van de Datto-job -------------
# start_daemon <label> [worker-argumenten]
# De plist staat bewust NIET in /Library/LaunchDaemons en wordt direct verwijderd: geen herstart-lus.
# (Argumenten komen onbewerkt in de plist: gebruik er geen < > & in.)
start_daemon() {
  local label="$1" a args="" plist="$DIR/$1.plist"; shift
  for a in "$@"; do args="$args<string>$a</string>"; done
  { echo '#!/bin/bash'                          # worker = dezelfde functies + variabelen, als scriptbestand
    declare -p LOG LABEL APPS ADMIN_USER INSTALLER_VERSION RESTART_WARN_SEC RESTART_MSG PATH PWFILE MAX_DEFERRALS DEFER_FILE
    declare -f log ac_ok run find_app app_major app_version version_gt app_is_newer notify wait_for_power ask_restart worker
    echo 'worker "$@"'; } > "$WORKER.new"
  chmod 700 "$WORKER.new"; mv -f "$WORKER.new" "$WORKER"
  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$WORKER</string>$args</array>
  <key>RunAtLoad</key><true/>
  <key>AbandonProcessGroup</key><true/>
  <key>StandardOutPath</key><string>/dev/null</string>
  <key>StandardErrorPath</key><string>$LOG</string>
  $PWKEY
</dict></plist>
EOF
  chown root:wheel "$plist"; chmod 600 "$plist"
  launchctl bootout "system/$label" >/dev/null 2>&1
  if ! launchctl bootstrap system "$plist" >>"$LOG" 2>&1; then
    rm -f "$plist" "$PWFILE"; log "FOUT: launchctl bootstrap is mislukt (zie $LOG)."; return 1
  fi
  sleep 3
  log "Daemon $label: $(launchctl print "system/$label" 2>/dev/null | grep -E 'state =|last exit code' | tr -s ' \n' ' ')"
  rm -f "$plist"                                # worker verwijdert het wachtwoord na het lezen
}

# ---- Starter: pre-flight, daemon starten, afsluiten --------------------------
[ "$(id -u)" -eq 0 ] || { echo "Dit script moet als root draaien."; exit 2; }
mkdir -p "$DIR" "$(dirname "$LOG")"; chmod 755 "$DIR"; touch "$LOG"; chmod 644 "$LOG"

OS=$(sw_vers -productVersion)
log "=== Starter: macOS $OS ($(uname -m)) op $(scutil --get ComputerName 2>/dev/null) ==="
IFS=. read -r MAJ MIN _ <<< "$OS"
[ "$MAJ" -gt 13 ] || { [ "$MAJ" -eq 13 ] && [ "${MIN:-0}" -ge 3 ]; } || fail "macOS $OS is ouder dan 13.3: niet ondersteund."

if launchctl print "system/$LABEL" 2>/dev/null | grep -q 'state = running' || pgrep -x startosinstall >/dev/null; then
  log "Er loopt al een upgrade op deze Mac; niets te doen."; exit 0
fi

ac_ok || fail "Mac hangt niet aan netstroom (AC Power)." "Sluit uw laptop aan op netstroom zodat de macOS-update kan doorgaan."
FREE=$(df -Pk /System/Volumes/Data | awk 'NR==2{printf "%d", $4/1048576}')
[ "$FREE" -ge "$MIN_FREE_GB" ] || fail "Slechts ${FREE} GB vrij; minimaal ${MIN_FREE_GB} GB nodig." \
  "Er is te weinig opslagruimte om de macOS-update te installeren. Maak ruimte vrij of bel Lipa support op $SUPPORT_TEL."
log "Pre-flight OK: netstroom aangesloten, ${FREE} GB vrij."

if [ "$(uname -m)" = arm64 ]; then
  [ -n "$ADMIN_PASS" ] || fail "Apple Silicon vereist ADMIN_PASS (volume-owner: $ADMIN_USER)."
  dscl . -authonly "$ADMIN_USER" "$ADMIN_PASS" >/dev/null 2>&1 || fail "Wachtwoord van '$ADMIN_USER' is onjuist."
  rm -f "$PWFILE"
  ( umask 077; printf '%s\n' "$ADMIN_PASS" > "$PWFILE" )           # wordt via stdin aan de daemon gegeven
  PWKEY="<key>StandardInPath</key><string>$PWFILE</string>"
fi

start_daemon "$LABEL" || exit 1
log "Gestart: de Mac werkt op de achtergrond verder. Live volgen: tail -f $LOG"
exit 0