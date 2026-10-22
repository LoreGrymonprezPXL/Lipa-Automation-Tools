#!/bin/bash

###############################################################################
# LEGACY - NIET GEBRUIKEN VOOR NIEUWE DATTO-RMM JOBS
#
# Gebruik endpoint-management/macos/datto/Datto_macos_update.sh als de enige
# aanbevolen Lipa ICT-component. Dit bestand blijft alleen bewaard als
# historische fallback en mag niet naast de aanbevolen component worden
# ingepland op hetzelfde toestel.
###############################################################################
#
# macOS Patch Management voor Datto RMM
#
# Taken:
#   1. Controleert op beschikbare Apple-updates (security + incrementeel)
#   2. Downloadt en installeert deze geruisloos op de achtergrond
#   3. Vraagt de ingelogde gebruiker om te herstarten (nu of later)
#   4. Logt lokaal en koppelt de status terug naar Datto RMM (stdout,
#      exitcode en optioneel een UDF)
#
# Datto RMM-variabelen (allemaal optioneel, doorgegeven als env-variabelen):
#   MODE                  all (standaard) | install | prompt
#                         install = enkel scannen/installeren (nachtjob)
#                         prompt  = enkel herstart-melding tonen (daghob)
#                         all     = beide in één run
#   UPDATE_SCOPE          recommended (standaard) | all
#   MAX_DEFERRALS         Max. aantal keer "Later" (standaard 3, 0 = nooit forceren)
#   DIALOG_TIMEOUT        Seconden dat de melding zichtbaar blijft (standaard 900)
#   RESTART_DELAY_MIN     Minuten wachttijd na "Herstart nu" (standaard 2)
#   FORCED_DELAY_MIN      Minuten wachttijd bij geforceerde herstart (standaard 15)
#   AUTO_RESTART_NO_USER  true (standaard) | false: herstart automatisch als
#                         niemand is aangemeld
#   MIN_FREE_GB           Minimaal vrije schijfruimte in GB (standaard 15)
#   MIN_BATTERY_PCT       Minimale batterij % indien niet aan de lader (standaard 50)
#   UDF_NUMBER            Nummer van de Datto UDF voor de statusregel (leeg = uit)
#   UPDATE_ADMIN_USER     Volume owner / admin voor Apple Silicon (optioneel)
#   UPDATE_ADMIN_PASS     Wachtwoord van die admin (optioneel, zie opmerking)
#
# Exitcodes: 0 = geslaagd (of niets te doen), 1 = fout
###############################################################################

set -u
set -o pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin"

################################################################################
# Configuratie
################################################################################

MODE="${MODE:-all}"
UPDATE_SCOPE="${UPDATE_SCOPE:-recommended}"
MAX_DEFERRALS="${MAX_DEFERRALS:-3}"
DIALOG_TIMEOUT="${DIALOG_TIMEOUT:-900}"
RESTART_DELAY_MIN="${RESTART_DELAY_MIN:-2}"
FORCED_DELAY_MIN="${FORCED_DELAY_MIN:-15}"
AUTO_RESTART_NO_USER="${AUTO_RESTART_NO_USER:-true}"
MIN_FREE_GB="${MIN_FREE_GB:-15}"
MIN_BATTERY_PCT="${MIN_BATTERY_PCT:-50}"
UDF_NUMBER="${UDF_NUMBER:-}"
UPDATE_ADMIN_USER="${UPDATE_ADMIN_USER:-}"
UPDATE_ADMIN_PASS="${UPDATE_ADMIN_PASS:-}"

LOGFILE="/var/log/macos_updates.log"
STATE_DIR="/Library/Application Support/MSP-Patching"
STATE_FILE="${STATE_DIR}/restart_pending.state"
LOCKDIR="/var/run/macos_updates.lock"

# Numerieke waarden valideren
for var in MAX_DEFERRALS DIALOG_TIMEOUT RESTART_DELAY_MIN FORCED_DELAY_MIN MIN_FREE_GB MIN_BATTERY_PCT; do
    if ! [[ "${!var}" =~ ^[0-9]+$ ]]; then
        echo "WAARSCHUWING: ongeldige waarde voor ${var}, standaardwaarde wordt gebruikt" >&2
        case "$var" in
            MAX_DEFERRALS) MAX_DEFERRALS=3 ;;
            DIALOG_TIMEOUT) DIALOG_TIMEOUT=900 ;;
            RESTART_DELAY_MIN) RESTART_DELAY_MIN=2 ;;
            FORCED_DELAY_MIN) FORCED_DELAY_MIN=15 ;;
            MIN_FREE_GB) MIN_FREE_GB=15 ;;
            MIN_BATTERY_PCT) MIN_BATTERY_PCT=50 ;;
        esac
    fi
done

case "$MODE" in all|install|prompt) ;; *) MODE="all" ;; esac
case "$UPDATE_SCOPE" in
    all) SCOPE_FLAG="--all" ;;
    *)   SCOPE_FLAG="--recommended" ;;
esac

# Runtime-status
PENDING_RESTART=0
RESTART_STATE="geen herstart nodig"
CONSOLE_USER=""
CONSOLE_UID=""

################################################################################
# Logging
################################################################################

if [[ -f "$LOGFILE" ]] && [[ "$(stat -f %z "$LOGFILE" 2>/dev/null || echo 0)" -gt 5242880 ]]; then
    mv -f "$LOGFILE" "${LOGFILE}.1"
fi

_log() {
    local level="$1"; shift
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" | tee -a "$LOGFILE"
}
log_info()  { _log INFO "$@"; }
log_warn()  { _log WARN "$@"; }
log_error() { _log ERROR "$@"; printf 'ERROR: %s\n' "$*" >&2; }

################################################################################
# Datto RMM terugkoppeling (UDF)
################################################################################

set_udf() {
    local nr="$1" value="$2"
    [[ -z "$nr" ]] && return 0
    [[ "$nr" =~ ^[0-9]+$ ]] || return 0

    # UDF max. 255 tekens en XML-veilig maken
    value="${value:0:250}"
    value=$(printf '%s' "$value" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')

    local xml
    xml=$(find /var/root/.mono/registry -name "values.xml" 2>/dev/null | head -n 1)
    if [[ -z "$xml" ]]; then
        log_warn "Datto values.xml niet gevonden; UDF ${nr} niet bijgewerkt"
        return 0
    fi

    local tmp
    tmp=$(mktemp /tmp/udf.XXXXXX) || return 0
    grep -v '</values>' "$xml" > "$tmp"
    printf '<value name="Custom%s" type="string">%s</value>\n</values>\n' "$nr" "$value" >> "$tmp"
    cat "$tmp" > "$xml"
    rm -f "$tmp"
}

report() {
    # $1 = status (OK / FOUT / WACHT), $2 = toelichting
    local status="$1" detail="$2"
    local line
    line="${status} | $(date '+%Y-%m-%d %H:%M') | macOS $(sw_vers -productVersion 2>/dev/null) | ${detail}"
    log_info "Datto-status: ${line}"
    set_udf "$UDF_NUMBER" "$line"
}

fail() {
    log_error "$1"
    report "FOUT" "$1"
    exit 1
}

################################################################################
# Hulpfuncties
################################################################################

get_console_user() {
    local u
    u=$(stat -f %Su /dev/console 2>/dev/null)
    case "$u" in
        ""|root|loginwindow|_mbsetupuser) echo "" ;;
        *) echo "$u" ;;
    esac
}

run_as_user() {
    launchctl asuser "$CONSOLE_UID" sudo -u "$CONSOLE_USER" "$@"
}

boot_ts() {
    sysctl -n kern.boottime 2>/dev/null | sed -n 's/.*sec = \([0-9]*\).*/\1/p'
}

state_get() {
    grep -E "^$1=" "$STATE_FILE" 2>/dev/null | tail -n 1 | cut -d= -f2-
}

state_save() {
    # $1 = aantal uitstellingen
    mkdir -p "$STATE_DIR"
    local since bts
    since=$(state_get SINCE); since="${since:-$(date '+%Y-%m-%d %H:%M:%S')}"
    bts=$(state_get BOOT_TS); bts="${bts:-$(boot_ts)}"
    printf 'DEFERRALS=%s\nBOOT_TS=%s\nSINCE=%s\n' "$1" "$bts" "$since" > "$STATE_FILE"
}

state_clear() {
    rm -f "$STATE_FILE"
}

free_gb() {
    local target="/System/Volumes/Data"
    [[ -d "$target" ]] || target="/"
    df -k "$target" | awk 'NR==2 {print int($4/1048576)}'
}

display_in_use() {
    # Actieve presentatie/vergadering: scherm mag niet in slaapstand
    pmset -g assertions 2>/dev/null | grep -Eq 'PreventUserIdleDisplaySleep[[:space:]]+1'
}

schedule_restart() {
    local minutes="$1" message="$2"
    log_warn "Herstart gepland over ${minutes} minuut/minuten"
    nohup shutdown -r "+${minutes}" "$message" >/dev/null 2>&1 &
    disown 2>/dev/null || true
    RESTART_STATE="herstart gepland over ${minutes} min"
}

notify_user() {
    [[ -n "$CONSOLE_USER" ]] || return 0
    run_as_user /usr/bin/osascript -e \
        "display notification \"$1\" with title \"IT-beheer\"" >/dev/null 2>&1 || true
}

################################################################################
# Herstart-afhandeling
################################################################################

prompt_user_restart() {
    CONSOLE_USER="$1"
    CONSOLE_UID=$(id -u "$CONSOLE_USER")

    local deferrals forced=0
    deferrals=$(state_get DEFERRALS); deferrals="${deferrals:-0}"
    if [[ "$MAX_DEFERRALS" -gt 0 && "$deferrals" -ge "$MAX_DEFERRALS" ]]; then
        forced=1
    fi

    local text buttons
    if [[ "$forced" -eq 1 ]]; then
        text="Er staan beveiligingsupdates klaar die een herstart vereisen. U heeft de herstart al ${deferrals} keer uitgesteld.\n\nUw Mac herstart daarom automatisch over ${FORCED_DELAY_MIN} minuten. Sla uw openstaand werk nu op."
        buttons='{"OK", "Herstart nu"}'
    else
        local left=$(( MAX_DEFERRALS - deferrals ))
        text="De updates zijn geïnstalleerd. Een herstart is vereist om de installatie af te ronden.\n\nSla uw openstaand werk op en kies Herstart nu. Uw Mac herstart dan na ${RESTART_DELAY_MIN} minuten."
        if [[ "$MAX_DEFERRALS" -gt 0 ]]; then
            text="${text}\n\nU kunt de herstart nog ${left} keer uitstellen."
        fi
        buttons='{"Later", "Herstart nu"}'
    fi

    local script
    script="set r to display dialog \"${text}\" buttons ${buttons} default button \"Herstart nu\" with title \"IT-beheer: herstart vereist\" with icon caution giving up after ${DIALOG_TIMEOUT}
if gave up of r then
    return \"TIMEOUT\"
else
    return button returned of r
end if"

    log_info "Herstart-melding tonen aan ${CONSOLE_USER} (uitgesteld: ${deferrals}x, geforceerd: ${forced})"

    local answer rc
    answer=$(run_as_user /usr/bin/osascript -e "$script" 2>&1)
    rc=$?
    log_info "Gebruikerskeuze: ${answer} (rc=${rc})"

    if [[ "$rc" -ne 0 ]]; then
        if grep -qi "User canceled" <<<"$answer"; then
            answer="Later"
        else
            log_warn "Melding tonen mislukt: ${answer}"
            RESTART_STATE="herstart nodig (melding mislukt)"
            return 0
        fi
    fi

    case "$answer" in
        "Herstart nu")
            notify_user "Uw Mac herstart over ${RESTART_DELAY_MIN} minuten. Sla uw werk op."
            schedule_restart "$RESTART_DELAY_MIN" "Herstart voor het afronden van macOS-updates"
            ;;
        "OK")
            notify_user "Uw Mac herstart over ${FORCED_DELAY_MIN} minuten. Sla uw werk op."
            schedule_restart "$FORCED_DELAY_MIN" "Herstart voor het afronden van macOS-updates"
            ;;
        "Later")
            state_save $(( deferrals + 1 ))
            RESTART_STATE="herstart nodig (uitgesteld $((deferrals + 1))/${MAX_DEFERRALS})"
            log_info "Gebruiker stelt herstart uit"
            ;;
        TIMEOUT)
            if [[ "$forced" -eq 1 ]]; then
                notify_user "Uw Mac herstart over ${FORCED_DELAY_MIN} minuten. Sla uw werk op."
                schedule_restart "$FORCED_DELAY_MIN" "Herstart voor het afronden van macOS-updates"
            else
                RESTART_STATE="herstart nodig (geen reactie)"
                log_info "Geen reactie van gebruiker; later opnieuw proberen"
            fi
            ;;
        *)
            RESTART_STATE="herstart nodig (onbekende keuze)"
            ;;
    esac
}

handle_pending_restart() {
    [[ "$PENDING_RESTART" -eq 1 ]] || return 0
    log_warn "Herstart vereist"
    RESTART_STATE="herstart nodig"

    local user
    user=$(get_console_user)

    if [[ -z "$user" ]]; then
        if [[ "$AUTO_RESTART_NO_USER" == "true" ]]; then
            log_info "Geen gebruiker aangemeld; automatische herstart"
            schedule_restart "$RESTART_DELAY_MIN" "Herstart voor het afronden van macOS-updates"
        else
            log_warn "Geen gebruiker aangemeld en automatische herstart staat uit"
            RESTART_STATE="herstart nodig (geen gebruiker)"
        fi
        return 0
    fi

    if [[ "$MODE" == "install" ]]; then
        log_info "Modus 'install': melding wordt door de prompt-job getoond"
        return 0
    fi

    if display_in_use; then
        log_info "Scherm in gebruik (presentatie/vergadering); melding uitgesteld"
        RESTART_STATE="herstart nodig (gebruiker bezig)"
        return 0
    fi

    prompt_user_restart "$user"
}

################################################################################
# Start
################################################################################

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: dit script moet als root uitgevoerd worden." >&2
    exit 1
fi

# Voorkom parallelle runs
if ! mkdir "$LOCKDIR" 2>/dev/null; then
    old_pid=$(cat "$LOCKDIR/pid" 2>/dev/null)
    if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
        log_warn "Er draait al een update-run (PID ${old_pid}); afgebroken"
        exit 0
    fi
    rm -rf "$LOCKDIR"
    mkdir "$LOCKDIR" || { echo "ERROR: lock niet aangemaakt" >&2; exit 1; }
fi
echo $$ > "$LOCKDIR/pid"
trap 'rm -rf "$LOCKDIR"' EXIT

log_info "=================================================="
log_info "Script gestart (modus: ${MODE}, scope: ${UPDATE_SCOPE})"
log_info "macOS versie: $(sw_vers -productVersion) ($(uname -m))"
log_info "Hostname: $(hostname)"
log_info "=================================================="

################################################################################
# Openstaande herstart van een vorige run
################################################################################

if [[ -f "$STATE_FILE" ]]; then
    saved_boot=$(state_get BOOT_TS)
    if [[ -n "$saved_boot" && "$saved_boot" != "$(boot_ts)" ]]; then
        log_info "Mac is herstart sinds de laatste update; status gewist"
        state_clear
    else
        log_info "Herstart uit vorige run staat nog open (sinds $(state_get SINCE))"
        PENDING_RESTART=1
    fi
fi

################################################################################
# Modus 'prompt': enkel herstart afhandelen
################################################################################

if [[ "$MODE" == "prompt" ]]; then
    if [[ "$PENDING_RESTART" -eq 0 ]]; then
        log_info "Geen herstart openstaand"
        report "OK" "up-to-date, geen herstart nodig"
        exit 0
    fi
    handle_pending_restart
    report "WACHT" "$RESTART_STATE"
    log_info "Script afgerond"
    exit 0
fi

################################################################################
# Voorwaarden voor installatie
################################################################################

FREE=$(free_gb)
if [[ -n "$FREE" && "$FREE" -lt "$MIN_FREE_GB" ]]; then
    fail "Te weinig vrije schijfruimte (${FREE} GB, minimaal ${MIN_FREE_GB} GB)"
fi

BATT_INFO=$(pmset -g batt 2>/dev/null)
if grep -q "Battery Power" <<<"$BATT_INFO"; then
    BATT_PCT=$(grep -Eo '[0-9]+%' <<<"$BATT_INFO" | head -n 1 | tr -d '%')
    if [[ -n "$BATT_PCT" && "$BATT_PCT" -lt "$MIN_BATTERY_PCT" ]]; then
        log_warn "Op batterij (${BATT_PCT}%); installatie uitgesteld tot de lader is aangesloten"
        report "WACHT" "installatie uitgesteld (batterij ${BATT_PCT}%)"
        exit 0
    fi
fi

################################################################################
# Controle op updates
################################################################################

log_info "Controleren op beschikbare updates"
UPDATE_LIST=$(softwareupdate --list 2>&1)
SCAN_RC=$?

if grep -qi "No new software available" <<<"$UPDATE_LIST"; then
    log_info "Geen updates beschikbaar"
    handle_pending_restart
    if [[ "$PENDING_RESTART" -eq 1 ]]; then
        report "WACHT" "$RESTART_STATE"
    else
        report "OK" "up-to-date"
    fi
    log_info "Script afgerond"
    exit 0
fi

UPDATE_COUNT=$(grep -cE '^[[:space:]]*\*' <<<"$UPDATE_LIST")

if [[ "$SCAN_RC" -ne 0 ]]; then
    log_error "softwareupdate --list gaf exit code ${SCAN_RC}"
    log_error "$UPDATE_LIST"
    fail "Scan naar updates mislukt (rc=${SCAN_RC})"
fi

if [[ "$UPDATE_COUNT" -eq 0 ]]; then
    log_warn "Geen updates herkend in de uitvoer van softwareupdate"
    log_info "$UPDATE_LIST"
    handle_pending_restart
    report "OK" "geen updates gevonden"
    exit 0
fi

log_info "${UPDATE_COUNT} update(s) gevonden:"
log_info "$UPDATE_LIST"

LIST_NEEDS_RESTART=0
if grep -qiE 'action: restart|\[restart\]' <<<"$UPDATE_LIST"; then
    LIST_NEEDS_RESTART=1
fi

################################################################################
# Download
################################################################################

log_info "Downloaden van updates"
DOWNLOAD_OUTPUT=$(softwareupdate --download "$SCOPE_FLAG" 2>&1)
DOWNLOAD_RC=$?
log_info "$DOWNLOAD_OUTPUT"

if [[ "$DOWNLOAD_RC" -ne 0 ]]; then
    fail "Download mislukt (rc=${DOWNLOAD_RC})"
fi
log_info "Download voltooid"

################################################################################
# Installatie
################################################################################

log_info "Installeren van updates"

ARCH=$(uname -m)
if [[ "$ARCH" == "arm64" && ( -z "$UPDATE_ADMIN_USER" || -z "$UPDATE_ADMIN_PASS" ) ]]; then
    log_warn "Apple Silicon zonder UPDATE_ADMIN_USER/UPDATE_ADMIN_PASS: macOS-updates kunnen om autorisatie vragen en mislukken"
fi

if [[ "$ARCH" == "arm64" && -n "$UPDATE_ADMIN_USER" && -n "$UPDATE_ADMIN_PASS" ]]; then
    INSTALL_OUTPUT=$(printf '%s\n' "$UPDATE_ADMIN_PASS" | softwareupdate --install "$SCOPE_FLAG" --user "$UPDATE_ADMIN_USER" --stdinpass 2>&1)
    INSTALL_RC=$?
else
    INSTALL_OUTPUT=$(softwareupdate --install "$SCOPE_FLAG" 2>&1)
    INSTALL_RC=$?
fi
log_info "$INSTALL_OUTPUT"

if [[ "$INSTALL_RC" -ne 0 ]] || grep -qiE 'failed to install|install failed|error installing' <<<"$INSTALL_OUTPUT"; then
    fail "Installatie mislukt (rc=${INSTALL_RC})"
fi
log_info "Installatie voltooid"

################################################################################
# Herstart nodig?
################################################################################

if [[ "$LIST_NEEDS_RESTART" -eq 1 ]] || \
   grep -qiE 'restart (is )?required|requires? a restart|need(s)? to restart|\[restart\]' <<<"$INSTALL_OUTPUT"; then
    PENDING_RESTART=1
    state_save "$(state_get DEFERRALS | grep -E '^[0-9]+$' || echo 0)"
fi

if [[ "$PENDING_RESTART" -eq 1 ]]; then
    handle_pending_restart
    report "WACHT" "${UPDATE_COUNT} update(s) geïnstalleerd, ${RESTART_STATE}"
else
    log_info "Geen herstart vereist"
    state_clear
    report "OK" "${UPDATE_COUNT} update(s) geïnstalleerd, geen herstart nodig"
fi

################################################################################
# Einde
################################################################################

log_info "Script succesvol afgerond"
log_info "=================================================="
exit 0
