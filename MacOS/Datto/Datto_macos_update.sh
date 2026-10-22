#!/bin/bash
# =============================================================================
# Datto RMM Component: macOS minor updates + major upgrades (10.15 Catalina -> latest)
#
# Paths:
#   macOS 11+ and SUPER available  -> SUPER v5 (https://github.com/Macjutsu/super)
#   macOS 10.15 (or SUPER missing/failed) -> native softwareupdate / startosinstall
#
# Datto component variables (all optional except ADMIN_PASS on Apple Silicon):
#   ADMIN_USER          Volume-owner / SecureToken admin   (default: clientadmin)
#   ADMIN_PASS          Its password. Mark as a masked/password variable in Datto.
#   MIN_FREE_GB         Required free disk space           (default: 35)
#   MAJOR_UPGRADES      true|false                         (default: true)
#   MAX_TARGET_MAJOR    Cap upgrades at this major, e.g. 15 (default: 0 = no cap)
#   MAX_WAIT_MIN        Max minutes the job watches SUPER  (default: 90)
#   DOWNLOAD_TIMEOUT_MIN Cap for each installer download   (default: 120)
#   UPGRADE_WATCH_MIN   Minutes to watch startosinstall    (default: 30)
#   USER_WARN_SECONDS   Warning shown to logged-in user before native
#                       update/upgrade starts              (default: 120)
#   FORCE_INSTALLER_VERSION  e.g. 15.7.1 - skip discovery, fetch this installer (native path)
#   SKIP_AC_CHECK       true to skip AC power check        (default: false)
#
# Exit codes / DATTO_RESULT statuses:
#   0  UP_TO_DATE | UPDATE_STARTED | UPGRADE_STARTED | SUPER_COMPLETED | SUPER_IN_PROGRESS
#   22 UPGRADE_CHECK_FAILED (could not determine newer major; never reported as up-to-date)
#   10 NO_AC_POWER        11 LOW_DISK         12 NO_NETWORK
#   13 AUTH_FAILED        14 UNSUPPORTED_OS / NOT_ROOT
#   20 TIMEOUT            21 INSTALLER_FAILED 30 SUPER_ERRORS
# =============================================================================

exec 2>&1                       # stderr -> stdout immediately, so Datto sees everything
set +x                          # never trace (would leak ADMIN_PASS)
umask 077
PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin

# ---- Output helpers (printf to a pipe is unbuffered in bash) -----------------
ts()   { date '+%Y-%m-%d %H:%M:%S'; }
log()  { printf '%s [INFO ] %s\n'  "$(ts)" "$*"; }
warn() { printf '%s [WARN ] %s\n'  "$(ts)" "$*"; }
err()  { printf '%s [ERROR] %s\n'  "$(ts)" "$*"; }
step() { printf '\n%s ===== %s =====\n' "$(ts)" "$*"; }

TAIL_PIDS=""
cleanup() { for p in $TAIL_PIDS; do kill "$p" 2>/dev/null; done; }
trap cleanup EXIT

finish() {   # finish <exit-code> <STATUS> <message...>
  local code="$1" status="$2"; shift 2
  [ "$code" -ne 0 ] && err "$*"
  printf '%s [INFO ] Job finished.\n' "$(ts)"
  printf 'DATTO_RESULT: %s | exit=%s | %s\n' "$status" "$code" "$*"
  exit "$code"
}

# ---- Config -----------------------------------------------------------------
ADMIN_USER="${ADMIN_USER:-clientadmin}"
MIN_FREE_GB="${MIN_FREE_GB:-35}"
MAJOR_UPGRADES="${MAJOR_UPGRADES:-true}"
MAX_TARGET_MAJOR="${MAX_TARGET_MAJOR:-0}"
MAX_WAIT_MIN="${MAX_WAIT_MIN:-90}"
DOWNLOAD_TIMEOUT_MIN="${DOWNLOAD_TIMEOUT_MIN:-120}"
UPGRADE_WATCH_MIN="${UPGRADE_WATCH_MIN:-30}"
USER_WARN_SECONDS="${USER_WARN_SECONDS:-120}"
SKIP_AC_CHECK="${SKIP_AC_CHECK:-false}"
MAX_INSTALLER_ATTEMPTS=3
FORCE_INSTALLER_VERSION="${FORCE_INSTALLER_VERSION:-}"
UPGRADE_CHECK_FAILED=0

SUPER_DIR="/Library/Management/super"
SUPER_BIN="$SUPER_DIR/super"
LOG_DIR="/var/log/DattoMacUpdate"
mkdir -p "$LOG_DIR" 2>/dev/null
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
START_EPOCH="$(date +%s)"
RL_DETACH=0; RL_FEED_PASS=0; RL_LOG=""; RL_RC=0; RL_PROGRESS_FILE=""

# ---- run_logged: native timeout + live output -------------------------------
# Runs a command in the background, writing to a log file that is tailed live to
# stdout (no command substitution, nothing buffered). Prints a heartbeat every 30s.
#   RL_DETACH=1     run under nohup and DON'T kill on timeout (for startosinstall/SUPER)
#   RL_FEED_PASS=1  feed $ADMIN_PASS on the command's stdin (for --stdinpass)
# Returns the command's exit code, or 124 on timeout.
run_logged() {
  local secs="$1" label="$2"; shift 2
  local lf; lf="$(mktemp "$LOG_DIR/run.XXXXXX")"; RL_LOG="$lf"
  local pre=(); [ "$RL_DETACH" = "1" ] && pre=(nohup)
  log ">>> START: $label (timeout ${secs}s) - log: $lf"
  tail -f "$lf" & local tpid=$!; TAIL_PIDS="$TAIL_PIDS $tpid"
  if [ "$RL_FEED_PASS" = "1" ]; then
    "${pre[@]}" "$@" >>"$lf" 2>&1 < <(printf '%s\n' "$ADMIN_PASS") &
  else
    "${pre[@]}" "$@" >>"$lf" 2>&1 < /dev/null &
  fi
  local pid=$! start now last rc
  start="$(date +%s)"; last="$start"
  while kill -0 "$pid" 2>/dev/null; do
    sleep 2
    now="$(date +%s)"
    if [ $(( now - start )) -ge "$secs" ]; then
      if [ "$RL_DETACH" = "1" ]; then
        warn "$label still running after ${secs}s; leaving it running detached."
        { kill "$tpid"; wait "$tpid"; } 2>/dev/null
        RL_RC=124; return 124
      fi
      warn "$label TIMED OUT after ${secs}s - terminating."
      pkill -TERM -P "$pid" 2>/dev/null; kill -TERM "$pid" 2>/dev/null; sleep 5
      pkill -KILL -P "$pid" 2>/dev/null; kill -KILL "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null; sleep 1
      { kill "$tpid"; wait "$tpid"; } 2>/dev/null
      RL_RC=124; return 124
    fi
    if [ $(( now - last )) -ge 30 ]; then
      if [ -n "$RL_PROGRESS_FILE" ] && [ -f "$RL_PROGRESS_FILE" ]; then
        log "... $label still running ($(( now - start ))s elapsed, downloaded $(( $(stat -f%z "$RL_PROGRESS_FILE" 2>/dev/null || echo 0) / 1048576 )) MB)"
      else
        log "... $label still running ($(( now - start ))s elapsed)"
      fi
      last="$now"
    fi
  done
  wait "$pid" 2>/dev/null; rc=$?
  sleep 1; { kill "$tpid"; wait "$tpid"; } 2>/dev/null
  log "<<< END: $label (exit code $rc)"
  RL_RC=$rc; return $rc
}

free_gb() {
  local vol="/"; [ -d /System/Volumes/Data ] && vol="/System/Volumes/Data"
  df -Pk "$vol" | awk 'NR==2{printf "%d", $4/1024/1024}'
}

console_user() {
  local u; u="$(stat -f%Su /dev/console 2>/dev/null)"
  case "$u" in root|_mbsetupuser|"") echo "";; *) echo "$u";; esac
}

# Non-blocking user warning (dialog auto-dismisses; job never waits for a click)
warn_user_then_wait() {
  local msg="$1" cu uid
  cu="$(console_user)"
  if [ -z "$cu" ]; then
    log "No user logged in: proceeding immediately; Mac will restart automatically."
    return 0
  fi
  uid="$(id -u "$cu")"
  log "User '$cu' is logged in: showing notice, then waiting ${USER_WARN_SECONDS}s before starting."
  launchctl asuser "$uid" sudo -u "$cu" /usr/bin/osascript -e \
    "display dialog \"$msg\" with title \"IT Maintenance\" buttons {\"OK\"} default button \"OK\" with icon caution giving up after $USER_WARN_SECONDS" \
    >/dev/null 2>&1 &
  local waited=0
  while [ "$waited" -lt "$USER_WARN_SECONDS" ]; do
    sleep 10; waited=$(( waited + 10 ))
    [ $(( waited % 30 )) -eq 0 ] && log "Grace period: $(( USER_WARN_SECONDS - waited ))s remaining..."
  done
}

# =============================================================================
step "START: macOS update job on $(scutil --get ComputerName 2>/dev/null || hostname)"
[ "$(id -u)" -eq 0 ] || finish 14 NOT_ROOT "Script must run as root."

OS_VER="$(sw_vers -productVersion)"
OS_MAJOR="${OS_VER%%.*}"
OS_MINOR="$(echo "$OS_VER" | cut -d. -f2)"
ARCH="$(uname -m)"
log "macOS $OS_VER | arch: $ARCH | model: $(sysctl -n hw.model 2>/dev/null) | console user: '$(console_user)'"
if [ "$OS_MAJOR" -eq 10 ] && [ "$OS_MINOR" -lt 15 ]; then
  finish 14 UNSUPPORTED_OS "macOS $OS_VER is older than 10.15 Catalina; not supported by this component."
fi

# ---- Pre-flight -------------------------------------------------------------
step "1/5 Pre-flight: AC power"
if [ "$SKIP_AC_CHECK" = "true" ]; then
  warn "AC power check skipped by variable."
elif pmset -g batt 2>/dev/null | head -1 | grep -q "AC Power"; then
  log "OK: connected to AC power."
else
  finish 10 NO_AC_POWER "Mac is on battery power ($(pmset -g batt | head -1)). Connect AC power and re-run."
fi

step "2/5 Pre-flight: free disk space"
FREE="$(free_gb)"
log "Free space: ${FREE} GB (required: ${MIN_FREE_GB} GB)"
[ "$FREE" -ge "$MIN_FREE_GB" ] || finish 11 LOW_DISK "Only ${FREE} GB free; ${MIN_FREE_GB} GB required. Free up space and re-run."
log "OK: enough disk space."

step "3/5 Pre-flight: Apple update servers"
log "Contacting swscan.apple.com (20s timeout)..."
if curl -s -o /dev/null -I --connect-timeout 10 --max-time 20 https://swscan.apple.com/; then
  log "OK: swscan.apple.com reachable."
else
  finish 12 NO_NETWORK "Cannot reach swscan.apple.com (no internet, proxy or firewall?)."
fi

# ---- Decide path ------------------------------------------------------------
LOCAL_SUPER=""
for c in "$SCRIPT_DIR/super" "./super"; do [ -f "$c" ] && { LOCAL_SUPER="$c"; break; }; done
USE_SUPER=0
if [ "$OS_MAJOR" -ge 11 ] && { [ -n "$LOCAL_SUPER" ] || [ -f "$SUPER_BIN" ]; }; then USE_SUPER=1; fi
if [ "$USE_SUPER" = "1" ]; then log "Path: SUPER v5 (macOS $OS_VER >= 11)."
elif [ "$OS_MAJOR" -ge 11 ]; then log "Path: native softwareupdate/startosinstall (SUPER not attached/installed)."
else log "Path: native softwareupdate/startosinstall (macOS 10.15; SUPER v5 requires 11+)."; fi

step "4/5 Pre-flight: Apple Silicon authentication"
if [ "$ARCH" = "arm64" ]; then
  if [ -z "$ADMIN_PASS" ]; then
    if [ "$USE_SUPER" = "1" ]; then
      warn "ADMIN_PASS not set. SUPER will ask the logged-in user to save a password (needs a user present)."
    else
      finish 13 AUTH_FAILED "Apple Silicon requires ADMIN_PASS for ADMIN_USER='$ADMIN_USER' but none was supplied."
    fi
  else
    id "$ADMIN_USER" >/dev/null 2>&1 || finish 13 AUTH_FAILED "Account '$ADMIN_USER' does not exist on this Mac."
    if ! sysadminctl -secureTokenStatus "$ADMIN_USER" 2>&1 | grep -qi "ENABLED"; then
      finish 13 AUTH_FAILED "Account '$ADMIN_USER' has no SecureToken/volume ownership."
    fi
    # NOTE: dscl takes the password as an argument; exposure is brief and local to root.
    if ! dscl . -authonly "$ADMIN_USER" "$ADMIN_PASS" >/dev/null 2>&1; then
      finish 13 AUTH_FAILED "Password for '$ADMIN_USER' is incorrect."
    fi
    log "OK: '$ADMIN_USER' has SecureToken and the password is valid."
  fi
else
  log "Intel Mac: running as root, no credentials required."
fi

# =============================================================================
# SUPER path (verified v5 flags only - see wiki pages Install-macOS-Updates-and-Upgrades,
# Apple-Silicon-Local-Credentials, Alternate-Workflows)
# =============================================================================
super_path() {
  step "5/5 SUPER workflow"
  if [ -n "$LOCAL_SUPER" ]; then chmod 755 "$LOCAL_SUPER"; fi
  local SUPER_RUN
  if [ ! -f "$SUPER_BIN" ]; then
    [ -n "$LOCAL_SUPER" ] || return 2
    log "SUPER not installed; first run will self-install."; SUPER_RUN="$LOCAL_SUPER"
  elif [ -n "$LOCAL_SUPER" ] && [ "$(shasum "$SUPER_BIN" | awk '{print $1}')" != "$(shasum "$LOCAL_SUPER" | awk '{print $1}')" ]; then
    log "Attached SUPER differs from installed: replacing."
    pkill -f "$SUPER_BIN" 2>/dev/null; sleep 2
    mkdir -p "$SUPER_DIR"; cp -f "$LOCAL_SUPER" "$SUPER_BIN"; chmod 755 "$SUPER_BIN"; SUPER_RUN="$SUPER_BIN"
  else
    log "SUPER present and current."; SUPER_RUN="$SUPER_BIN"
  fi

  local SARGS=( --workflow-install-now )
  [ "$MAJOR_UPGRADES" = "true" ] && SARGS+=( --install-macos-major-upgrades )
  [ "$MAJOR_UPGRADES" = "true" ] && [ "$MAX_TARGET_MAJOR" -gt 0 ] && SARGS+=( --install-macos-major-version-target="$MAX_TARGET_MAJOR" )
  if [ "$ARCH" = "arm64" ]; then
    if [ -n "$ADMIN_PASS" ]; then
      SARGS+=( --auth-local-account="$ADMIN_USER" --auth-local-password="$ADMIN_PASS" )
      [ -n "$(console_user)" ] && SARGS+=( --auth-credential-failover-to-user )
    else
      SARGS+=( --auth-ask-user-to-save-password )
    fi
  fi
  log "SUPER options: --workflow-install-now $( [ "$MAJOR_UPGRADES" = "true" ] && echo --install-macos-major-upgrades ) $( [ "$MAX_TARGET_MAJOR" -gt 0 ] && echo --install-macos-major-version-target=$MAX_TARGET_MAJOR ) $( [ "$ARCH" = "arm64" ] && echo '[auth options: credentials hidden]' )"
  log "Logged-in user: SUPER shows its own restart dialog. No user: SUPER installs and restarts automatically."

  RL_DETACH=1; RL_FEED_PASS=0
  run_logged $(( MAX_WAIT_MIN * 60 )) "SUPER workflow" "$SUPER_RUN" "${SARGS[@]}"
  local rc=$?
  if [ "$rc" -eq 124 ]; then
    finish 0 SUPER_IN_PROGRESS "SUPER still running after ${MAX_WAIT_MIN} min (likely waiting on user restart/deferral). Check $SUPER_DIR/logs."
  fi
  if [ "$rc" -ne 0 ]; then
    warn "SUPER launcher failed with exit code $rc; falling back to native update handling."
    return 1
  fi

  # SUPER's launcher may return while its LaunchDaemon keeps working: monitor until idle.
  local slog; slog="$(ls -t "$SUPER_DIR"/logs/*.log 2>/dev/null | grep -v -e audit -e metrics | head -1)"
  if [ -n "$slog" ]; then
    log "Following SUPER log: $slog"
    tail -n 0 -F "$slog" 2>/dev/null & TAIL_PIDS="$TAIL_PIDS $!"
  else
    warn "SUPER log file not found; relying on process monitoring only."
  fi
  local idle=0 hb=0 now
  while :; do
    now="$(date +%s)"
    if [ $(( now - START_EPOCH )) -ge $(( MAX_WAIT_MIN * 60 )) ]; then
      finish 0 SUPER_IN_PROGRESS "Watch window of ${MAX_WAIT_MIN} min ended; SUPER may still be working in the background."
    fi
    if pgrep -f "$SUPER_BIN" >/dev/null 2>&1 || pgrep -x softwareupdate >/dev/null 2>&1 \
       || pgrep -x startosinstall >/dev/null 2>&1 || pgrep -x mist >/dev/null 2>&1; then idle=0; else idle=$(( idle + 1 )); fi
    hb=$(( hb + 1 )); [ $(( hb % 6 )) -eq 0 ] && log "Heartbeat: monitoring SUPER ($(( (now - START_EPOCH) / 60 )) min elapsed)."
    [ "$idle" -ge 9 ] && break
    sleep 10
  done
  log "No SUPER/installer processes active for ~90s: workflow finished or waiting on a deferral timer."
  if [ -n "$slog" ] && tail -n 100 "$slog" | grep -qE '(^|[^A-Za-z])(ERROR|FAILURE|FAILED)([^A-Za-z]|$)'; then
    err "SUPER log contains error lines; last 15 lines:"; tail -n 15 "$slog"
    warn "SUPER reported errors; falling back to native update handling."
    return 1
  fi
  return 0
}

# =============================================================================
# Native path
# =============================================================================
STOS_AUTH=()
[ "$ARCH" = "arm64" ] && STOS_AUTH=( --user "$ADMIN_USER" --stdinpass )
FEED=0; [ "$ARCH" = "arm64" ] && FEED=1

# ---- SOFA feed parsing (osascript -l JavaScript: present on Catalina, no python/jq needed) ----
# Verified against the real v2 feed schema:
#   OSVersions[].SupportedModels[].Identifiers  -> keys are hw.model strings (e.g. "MacBookPro16,1")
#   InstallationApps.LatestUMA / AllPreviousUMA -> {Version, URL (InstallAssistant.pkg), Size}
# Output: first line "HW:ok" then one "version|url|bytes" line per supported major (newest first).
read -r -d '' JXA_PICK <<'JXAEOF'
function gt(a, b) {
  var x = a.split('.').map(Number), y = b.split('.').map(Number);
  for (var i = 0; i < Math.max(x.length, y.length); i++) {
    var p = x[i] || 0, q = y[i] || 0; if (p !== q) return p > q;
  } return false;
}
function pick(j, model, cur, max) {
  var supported = {}, fallbackVer = {}, haveModels = false;
  (j.OSVersions || []).forEach(function (o) {
    var lv = o.Latest && o.Latest.ProductVersion ? String(o.Latest.ProductVersion) : '';
    var m = parseInt(lv.split('.')[0], 10);
    if (!m) return;
    (o.SupportedModels || []).forEach(function (s) {
      haveModels = true;
      if (s.Identifiers && Object.prototype.hasOwnProperty.call(s.Identifiers, model)) { supported[m] = true; fallbackVer[m] = lv; }
    });
  });
  if (!haveModels) return { err: 'feed has no SupportedModels data' };
  var apps = [], ia = j.InstallationApps || {};
  if (ia.LatestUMA) apps.push(ia.LatestUMA);
  (ia.AllPreviousUMA || []).forEach(function (a) { apps.push(a); });
  var best = {};
  apps.forEach(function (a) {
    if (!a || !a.Version || !a.URL) return;
    var m = parseInt(String(a.Version).split('.')[0], 10);
    if (!supported[m]) return;
    if (!best[m] || gt(String(a.Version), best[m].v)) best[m] = { v: String(a.Version), u: a.URL, s: a.Size || 0 };
  });
  Object.keys(supported).forEach(function (m) { if (!best[m]) best[m] = { v: fallbackVer[m], u: '', s: 0 }; });
  var lines = Object.keys(best).map(Number)
    .filter(function (m) { return m > cur && m >= 11 && !(max > 0 && m > max); })
    .sort(function (a, b) { return b - a; })
    .map(function (m) { return best[m].v + '|' + best[m].u + '|' + best[m].s; });
  return { lines: lines };
}
function run(argv) {
  ObjC.import('Foundation');
  var data = $.NSData.dataWithContentsOfFile(argv[1]);
  if (!data) return 'ERR:cannot read feed file';
  var s = ObjC.unwrap($.NSString.alloc.initWithDataEncoding(data, $.NSUTF8StringEncoding));
  var r = pick(JSON.parse(s), argv[0], parseInt(argv[2], 10), parseInt(argv[3], 10) || 0);
  if (r.err) return 'ERR:' + r.err;
  return 'HW:ok\n' + r.lines.join('\n');
}
JXAEOF

# Fills $CAND_FILE with "version|url|bytes" lines (newest first).
# Returns 0 = determined (file may be empty = already on newest supported major),
#         1 = could NOT determine (never treated as "up to date").
discover_candidates() {
  CAND_FILE="$LOG_DIR/candidates.$$"; : > "$CAND_FILE"
  if [ -n "$FORCE_INSTALLER_VERSION" ]; then
    log "FORCE_INSTALLER_VERSION set: using $FORCE_INSTALLER_VERSION"; echo "${FORCE_INSTALLER_VERSION}||0" > "$CAND_FILE"; return 0
  fi
  if softwareupdate --help 2>&1 | grep -q -- '--list-full-installers'; then
    RL_DETACH=0; RL_FEED_PASS=0
    run_logged 300 "List full installers (Apple catalog)" softwareupdate --list-full-installers
    local rc=$? lf="$RL_LOG"
    [ "$rc" -eq 124 ] && finish 20 TIMEOUT "Apple catalog query timed out after 5 min."
    grep -qi 'unrecognized option' "$lf" && return 1
    grep 'Title: macOS' "$lf" | sed -n 's/.*Version: \([0-9][0-9.]*\).*/\1/p' \
      | sort -t. -k1,1nr -k2,2nr -k3,3nr \
      | awk -F. -v cur="$OS_MAJOR" -v max="$MAX_TARGET_MAJOR" '$1>cur && (max==0 || $1<=max) && !seen[$1]++ {print $0 "||0"}' > "$CAND_FILE"
    return 0
  fi
  log "macOS $OS_VER has no 'softwareupdate --list-full-installers'; using the SOFA feed + this Mac's hardware model."
  local model feed="$LOG_DIR/sofa-feed.json" url ok=0
  model="$(sysctl -n hw.model)"
  for url in https://sofa.macadmins.io/v2/macos_data_feed.json \
             https://raw.githubusercontent.com/macadmins/sofa/main/v2/macos_data_feed.json; do
    log "Downloading SOFA feed: $url (60s timeout)"
    if curl -fsSL --connect-timeout 10 --max-time 60 -o "$feed" "$url"; then
      ok=1; log "Feed downloaded ($(wc -c < "$feed" | tr -d ' ') bytes)."; break
    fi
    warn "Could not download $url"
  done
  [ "$ok" -eq 1 ] || return 1
  log "Evaluating which macOS versions model '$model' supports..."
  if ! osascript -l JavaScript -e "$JXA_PICK" "$model" "$feed" "$OS_MAJOR" "$MAX_TARGET_MAJOR" > "$CAND_FILE.raw" 2> "$CAND_FILE.err"; then
    warn "Feed parsing failed: $(head -c 300 "$CAND_FILE.err")"; return 1
  fi
  if grep -q '^ERR:' "$CAND_FILE.raw"; then warn "Feed parsing: $(grep '^ERR:' "$CAND_FILE.raw")"; return 1; fi
  grep -q '^HW:ok' "$CAND_FILE.raw" || { warn "Unexpected parser output: $(head -c 200 "$CAND_FILE.raw")"; return 1; }
  grep -E '^[0-9]+(\.[0-9]+)*\|' "$CAND_FILE.raw" > "$CAND_FILE"
  return 0
}

# Direct download of Apple's InstallAssistant.pkg with resume, stall detection and size check.
download_installer() {   # download_installer URL DEST EXPECTED_BYTES
  local url="$1" dest="$2" want="$3" i rc got
  for i in 1 2 3 4; do
    log "curl attempt $i/4 (resumes partial file; aborts if slower than 10 KB/s for 120 s)"
    curl -fL -sS --connect-timeout 20 --speed-limit 10240 --speed-time 120 -C - -o "$dest" "$url"; rc=$?
    [ "$rc" -eq 0 ] && break
    warn "curl attempt $i ended with rc=$rc"; sleep 10
  done
  got="$(stat -f%z "$dest" 2>/dev/null)"
  log "Downloaded ${got:-0} bytes (expected ${want:-unknown})."
  if [ -n "$want" ] && [ "$want" -gt 0 ] 2>/dev/null && [ "${got:-0}" != "$want" ]; then
    err "Size mismatch - download incomplete or corrupt."; return 1
  fi
  [ -n "$got" ] && [ "$got" -gt 1000000000 ]
}

native_upgrade() {   # 0 = started, 3 = none newer, 4 = could not determine, 1 = all attempts failed
  step "5/5 Native major upgrade check"
  discover_candidates || { warn "Could not determine available upgrades."; return 4; }
  local cands; cands="$(cat "$CAND_FILE")"
  if [ -z "$cands" ]; then log "Confirmed: no newer major macOS than $OS_MAJOR is supported/offered for this Mac."; return 3; fi
  log "Supported upgrade targets for this Mac (newest first): $(echo "$cands" | cut -d'|' -f1 | tr '\n' ' ')"

  local attempt=0 line v url size app rc got need pkg
  for line in $cands; do
    v="${line%%|*}"; rest="${line#*|}"; url="${rest%%|*}"; size="${rest#*|}"
    attempt=$(( attempt + 1 )); [ "$attempt" -gt "$MAX_INSTALLER_ATTEMPTS" ] && break
    step "Upgrade attempt $attempt: macOS $v"
    need=$(( size / 1000000000 * 2 + 15 )); [ "$need" -lt "$MIN_FREE_GB" ] && need="$MIN_FREE_GB"
    log "Free space needed for this attempt: ${need} GB (installer pkg + app + working space); have $(free_gb) GB."
    [ "$(free_gb)" -ge "$need" ] || { warn "Not enough disk space for macOS $v."; continue; }
    rm -rf /Applications/Install\ macOS*.app 2>/dev/null
    got=0

    # Prefer Apple's softwareupdate downloader: it handles catalog downloads
    # and interrupted transfers more reliably than a second independent curl.
    log "Trying softwareupdate --fetch-full-installer first..."
    for t in "$v" "${v%%.*}"; do
      RL_DETACH=0; RL_FEED_PASS=0
      run_logged $(( DOWNLOAD_TIMEOUT_MIN * 60 )) "softwareupdate --fetch-full-installer --full-installer-version $t" \
        softwareupdate --fetch-full-installer --full-installer-version "$t"
      rc=$?; app="$(ls -d /Applications/Install\ macOS*.app 2>/dev/null | head -1)"
      if [ "$rc" -eq 0 ] && [ -n "$app" ] && [ -x "$app/Contents/Resources/startosinstall" ]; then got=1; break; fi
      warn "fetch-full-installer with '$t' failed or produced no installer (rc=$rc)."
      [ "$t" = "${v%%.*}" ] && break
    done

    # Use the direct InstallAssistant URL only when softwareupdate failed.
    if [ "$got" -ne 1 ] && [ -n "$url" ]; then
      log "Trying direct InstallAssistant download as fallback..."
      pkg="/private/var/tmp/InstallAssistant-$v.pkg"
      RL_DETACH=0; RL_FEED_PASS=0; RL_PROGRESS_FILE="$pkg"
      run_logged $(( DOWNLOAD_TIMEOUT_MIN * 60 )) "Download macOS $v InstallAssistant.pkg (~$(( size / 1000000000 )) GB)" download_installer "$url" "$pkg" "$size"
      rc=$?; RL_PROGRESS_FILE=""
      if [ "$rc" -eq 0 ]; then
        log "pkg signature (informational): $(pkgutil --check-signature "$pkg" 2>&1 | grep -m1 -i 'status')"
        RL_DETACH=0; RL_FEED_PASS=0
        run_logged 1800 "Install InstallAssistant.pkg (creates Install macOS app)" installer -pkg "$pkg" -target / -verboseR
        rc=$?; rm -f "$pkg"
        app="$(ls -d /Applications/Install\ macOS*.app 2>/dev/null | head -1)"
        [ "$rc" -eq 0 ] && [ -n "$app" ] && [ -x "$app/Contents/Resources/startosinstall" ] && got=1
      else
        warn "Direct download of macOS $v failed (rc=$rc)."; rm -f "$pkg"
      fi
    fi
    [ "$got" -eq 1 ] || continue
    log "Installer ready: $app"
    warn_user_then_wait "Your Mac will upgrade to macOS $v and restart shortly. Please save your work. Open apps will be closed automatically."
    RL_DETACH=1; RL_FEED_PASS=$FEED
    run_logged $(( UPGRADE_WATCH_MIN * 60 )) "startosinstall macOS $v" \
      "$app/Contents/Resources/startosinstall" --agreetolicense --forcequitapps --nointeraction "${STOS_AUTH[@]}"
    rc=$?
    if [ "$rc" -eq 0 ] || [ "$rc" -eq 124 ]; then
      finish 0 UPGRADE_STARTED "macOS $v upgrade launched via startosinstall (rc=$rc). Mac will restart automatically; log: $RL_LOG"
    fi
    warn "startosinstall for macOS $v exited with rc=$rc (installer error or incompatible). Trying next older candidate."
  done
  return 1
}

native_minor() {
  step "5/5 Native minor update check"
  RL_DETACH=0; RL_FEED_PASS=0
  run_logged 300 "softwareupdate --list" softwareupdate --list
  local rc=$?; local lf="$RL_LOG"
  [ "$rc" -eq 124 ] && finish 20 TIMEOUT "softwareupdate --list timed out after 5 min."
  if grep -qi "No new software available" "$lf"; then
    [ "$UPGRADE_CHECK_FAILED" = "1" ] && finish 22 UPGRADE_CHECK_FAILED "No minor updates pending, but could NOT determine whether a newer major macOS is available (see output above). Set FORCE_INSTALLER_VERSION to force one."
    finish 0 UP_TO_DATE "macOS $OS_VER is already on the newest available version; no updates pending."
  fi
  warn_user_then_wait "Your Mac will install macOS updates and restart shortly. Please save your work."
  RL_DETACH=1; RL_FEED_PASS=$FEED
  run_logged $(( UPGRADE_WATCH_MIN * 60 )) "softwareupdate --install --all --restart" \
    softwareupdate --install --all --restart "${STOS_AUTH[@]}"
  rc=$?
  if [ "$rc" -eq 0 ] || [ "$rc" -eq 124 ]; then
    finish 0 UPDATE_STARTED "Updates installing/installed (rc=$rc); Mac will restart if required. Log: $RL_LOG"
  fi
  finish 21 INSTALLER_FAILED "softwareupdate --install failed (rc=$rc). Log: $RL_LOG"
}

# =============================================================================
if [ "$USE_SUPER" = "1" ]; then
  super_path; SRC=$?
  if [ "$SRC" -eq 0 ]; then
    finish 0 SUPER_COMPLETED "SUPER workflow ended. macOS now $(sw_vers -productVersion). A restart may be pending per SUPER's deadline/dialog flow."
  fi
  [ "$OS_MAJOR" -ge 11 ] && warn "SUPER unavailable or failed; falling back to native path."
fi

if [ "$MAJOR_UPGRADES" = "true" ]; then
  native_upgrade; URC=$?
  [ "$URC" -eq 4 ] && UPGRADE_CHECK_FAILED=1
  [ "$URC" -eq 1 ] && finish 21 INSTALLER_FAILED "All upgrade attempts failed (unsupported hardware, download failure or installer error). See output above."
  # URC=3 -> already on newest major supported/offered: fall through to minor updates
fi
native_minor