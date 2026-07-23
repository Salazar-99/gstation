#!/usr/bin/env bash
#
# setup.sh - Configure this Mac as an always-on, lid-closed home server.
#
# Usage:
#   chmod +x setup.sh
#   sudo ./setup.sh
#
# Assumes the machine stays connected to AC power permanently. Safe to
# re-run: every step is idempotent and independently verified afterward.

set -euo pipefail

FAILURES=0
pass() { echo "  [OK]   $*"; }
fail() { echo "  [FAIL] $*" >&2; FAILURES=$((FAILURES + 1)); }

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Error: this script only runs on macOS." >&2
  exit 1
fi

if [[ "${EUID}" -ne 0 ]]; then
  echo "Error: run with sudo (pmset/systemsetup/launchctl require root)." >&2
  echo "  sudo $0" >&2
  exit 1
fi

REAL_USER="${SUDO_USER:-$USER}"
[[ "$(uname -m)" == "arm64" ]] && BREW_BIN="/opt/homebrew/bin/brew" || BREW_BIN="/usr/local/bin/brew"

echo "==> Configuring $(hostname) as a headless server (user: $REAL_USER)"
echo

# ---------------------------------------------------------------------------
# 1. Homebrew + AlDente
#    A Mac left on AC power 24/7 sits at 100% charge indefinitely, which
#    accelerates battery wear. AlDente caps the charge ceiling (e.g. 80%).
# ---------------------------------------------------------------------------
echo "==> 1. Homebrew & AlDente (battery charge limiter)"

if [[ ! -x "$BREW_BIN" ]]; then
  echo "Installing Homebrew for $REAL_USER..."
  sudo -u "$REAL_USER" /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
[[ -x "$BREW_BIN" ]] && pass "Homebrew installed" || fail "Homebrew missing at $BREW_BIN"

sudo -u "$REAL_USER" "$BREW_BIN" list --cask aldente &>/dev/null || sudo -u "$REAL_USER" "$BREW_BIN" install --cask aldente
sudo -u "$REAL_USER" "$BREW_BIN" list --cask aldente &>/dev/null \
  && pass "AlDente installed (open it once and set a charge limit, e.g. 80%)" \
  || fail "AlDente install failed"
echo

# ---------------------------------------------------------------------------
# 2. Power management - never sleep while on AC power
# ---------------------------------------------------------------------------
echo "==> 2. Power management (pmset)"

pmset -c sleep 0 || true          # never idle-sleep the system on AC
pmset -c disksleep 0 || true      # never spin disks down on AC
pmset -c displaysleep 15 || true  # display may blank; system stays up
pmset -c womp 1 || true           # Wake-on-LAN - only works over wired Ethernet, not Wi-Fi
pmset -a autorestart 0 || true    # do NOT auto power-on after a full power failure - see note below
pmset -a disablesleep 1 || true   # global flag: refuse sleep outright, even user-initiated

AC_BLOCK=$(pmset -g custom | awk '/^AC Power:/{f=1;next}/^[A-Za-z].*:$/{f=0}f')
check_ac() { echo "$AC_BLOCK" | grep -qE "^[[:space:]]*$1[[:space:]]+$2([[:space:]]|\$)" && pass "$1 = $2" || fail "$1 is not $2 on AC power"; }
check_ac sleep 0
check_ac womp 1

# autorestart/disablesleep are global (not per-power-source) settings that
# `pmset -g` never displays at all (confirmed empirically) - they only show up
# in the underlying prefs plist, so check that directly instead.
PM_PLIST="/Library/Preferences/com.apple.PowerManagement.plist"
check_plist() { plutil -extract "$1" raw -o - "$PM_PLIST" 2>/dev/null | grep -qix "$2" && pass "$1 = $2" || fail "$1 is not $2 (see: $PM_PLIST)"; }
check_plist "AC Power.Automatic Restart On Power Loss" 0
check_plist "SystemPowerSettings.SleepDisabled" true
echo
echo "  [NOTE] Unplugging AC does NOT stop this Mac - the battery takes over"
echo "         automatically and nothing here restarts it. 'autorestart' only"
echo "         controls what happens if the battery *also* fully drains during"
echo "         an outage; per your instruction it's set to 0 (stay off, don't"
echo "         auto power-on) rather than powering back on unattended."
echo

# ---------------------------------------------------------------------------
# 3. Remote access - SSH (Remote Login) and Screen Sharing (VNC)
# ---------------------------------------------------------------------------
echo "==> 3. Remote access"

# systemsetup's remote-login toggle is gated by Full Disk Access (TCC), separate
# from root/sudo - if Terminal (or whatever app is running this) lacks it, this
# silently no-ops even as root. Capture stderr so the real reason is visible.
SETSSH_ERR=$(systemsetup -setremotelogin on 2>&1 >/dev/null || true)
if systemsetup -getremotelogin 2>/dev/null | grep -qi "on"; then
  pass "Remote Login (SSH) is on"
else
  fail "Remote Login is off${SETSSH_ERR:+ ($SETSSH_ERR)}"
  echo "  -> Grant Full Disk Access to the app you run this script from (Terminal/iTerm):"
  echo "     System Settings > Privacy & Security > Full Disk Access, then re-run."
  sudo -u "$REAL_USER" open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles" 2>/dev/null || true
fi

launchctl enable system/com.apple.screensharing >/dev/null 2>&1 || true
launchctl bootstrap system /System/Library/LaunchDaemons/com.apple.screensharing.plist >/dev/null 2>&1 || true
launchctl print system/com.apple.screensharing >/dev/null 2>&1 \
  && pass "Screen Sharing (VNC) is loaded" \
  || fail "Screen Sharing is off - enable manually: System Settings > General > Sharing > Screen Sharing"
echo

# ---------------------------------------------------------------------------
# 4. Belt-and-suspenders keep-awake LaunchDaemon
#    pmset covers idle sleep; this catches anything that doesn't (e.g. a
#    misbehaving app calling sleep directly) and survives reboots.
# ---------------------------------------------------------------------------
echo "==> 4. Keep-awake LaunchDaemon"

PLIST_PATH="/Library/LaunchDaemons/com.local.keepawake.plist"
cat > "$PLIST_PATH" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.local.keepawake</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/caffeinate</string>
        <string>-s</string>
        <string>-i</string>
        <string>-d</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
EOF
chown root:wheel "$PLIST_PATH"
chmod 644 "$PLIST_PATH"

launchctl bootout system "$PLIST_PATH" >/dev/null 2>&1 || true
launchctl bootstrap system "$PLIST_PATH" >/dev/null 2>&1 || true
launchctl print system/com.local.keepawake >/dev/null 2>&1 \
  && pass "keepawake daemon is loaded" \
  || fail "keepawake daemon failed to load"
echo

# ---------------------------------------------------------------------------
# 5. Firewall - sensible default once SSH/VNC are exposed to the network
# ---------------------------------------------------------------------------
echo "==> 5. Application firewall"

/usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on >/dev/null 2>&1 || true
/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate 2>/dev/null | grep -qi "enabled" \
  && pass "Firewall is enabled" \
  || fail "Firewall is off - enable manually: System Settings > Network > Firewall"
echo

# ---------------------------------------------------------------------------
# 6. Things that can't be safely automated - surfaced as warnings/reminders
# ---------------------------------------------------------------------------
echo "==> 6. Manual checklist"

if pmset -g batt | grep -q "AC Power"; then
  pass "Currently running on AC power"
else
  echo "  [WARN] Currently on BATTERY - plug into AC before relying on this setup."
fi

echo "  [NOTE] Closing the lid only keeps a Mac awake (clamshell mode) when, in"
echo "         addition to AC power, an external display OR a paired keyboard/mouse"
echo "         is attached. With neither, closing the lid forces sleep regardless"
echo "         of every pmset/caffeinate setting above."

IFACE=$(route get default 2>/dev/null | awk '/interface:/{print $2}')
echo "  [NOTE] Active network interface: ${IFACE:-unknown}. Wake-on-LAN (womp) only"
echo "         works over wired Ethernet - confirm once this Mac is plugged into it."
echo

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "=================================================================="
if [[ "$FAILURES" -eq 0 ]]; then
  echo " All automated checks passed."
else
  echo " $FAILURES check(s) failed - see [FAIL] lines above."
fi
echo " Hostname: $(scutil --get LocalHostName 2>/dev/null || hostname).local"
echo " IP:       $(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo unknown)"
echo "=================================================================="

exit $(( FAILURES > 0 ? 1 : 0 ))
