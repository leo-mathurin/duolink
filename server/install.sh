#!/usr/bin/env bash
# Installs or updates the Duolink server as a systemd user service. No sudo.
# Run setup-system.sh once as root first (MPTCP limits, TCP tuning, firewall, linger).
# Idempotent: run it again to update, the password is kept and the service
# restarts only when the binary, the config or the unit changed.
#
#   PORT=8443 LISTEN=:: ./install.sh
set -euo pipefail

# Official SagerNet release. To update, change the version and both checksums
# (sha256 of the .tar.gz assets on the GitHub release page).
SINGBOX_VERSION="1.14.3"
declare -A SINGBOX_SHA256=(
  [arm64]="29dae24d76bea3bc62d07dd3e60cfc12003de7debbd6b768df9be9c68360174e"
  [amd64]="e2bdf179c15a3652955dc44867e33ca0965c9c9b91b34267dcc5a5d639a5feee"
)

PORT="${PORT:-8443}"
METHOD="2022-blake3-aes-128-gcm"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
CONFIG_DIR="${CONFIG_DIR:-$HOME/duolink-server}"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
REQUIRE_MPTCP="${REQUIRE_MPTCP:-0}"
DIR="$(cd "$(dirname "$0")" && pwd)"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# Moves $1 to $2 if the content differs. Returns 0 when $2 changed.
replace_if_changed() {
  if cmp -s "$1" "$2"; then rm -f "$1"; return 1; fi
  mv -f "$1" "$2"
}

[[ $EUID -ne 0 ]] || die "run this script as the user that owns the service, not as root."
systemctl --user show-environment >/dev/null 2>&1 \
  || die "no systemd user manager. Log in with ssh (not su), or set XDG_RUNTIME_DIR=/run/user/$(id -u)."

case "$(uname -m)" in
  aarch64 | arm64) ARCH=arm64 ;;
  x86_64 | amd64) ARCH=amd64 ;;
  *) die "unsupported architecture: $(uname -m)" ;;
esac

if [[ "$(sysctl -n net.mptcp.enabled 2>/dev/null)" != "1" ]]; then
  msg="MPTCP is disabled in this kernel (net.mptcp.enabled != 1). Duolink falls back to plain TCP: no aggregation, and a connection drops when its link goes down."
  [[ "$REQUIRE_MPTCP" == "1" ]] && die "$msg"
  warn "$msg Set REQUIRE_MPTCP=1 to stop here instead."
elif ! systemctl is-enabled --quiet duolink-mptcp.service 2>/dev/null; then
  warn "duolink-mptcp.service is not enabled. Ask an admin to run: sudo ./setup-system.sh"
fi
[[ "$(loginctl show-user "$USER" --property=Linger --value 2>/dev/null)" == "yes" ]] \
  || warn "linger is off for $USER: the service stops at logout and does not start at boot. Ask an admin to run: sudo loginctl enable-linger $USER"

mkdir -p "$BIN_DIR" "$CONFIG_DIR" "$UNIT_DIR"
changed=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

log "sing-box $SINGBOX_VERSION ($ARCH)"
asset="sing-box-$SINGBOX_VERSION-linux-$ARCH"
curl -fsSL -o "$tmp/$asset.tar.gz" \
  "https://github.com/SagerNet/sing-box/releases/download/v$SINGBOX_VERSION/$asset.tar.gz"
echo "${SINGBOX_SHA256[$ARCH]}  $tmp/$asset.tar.gz" | sha256sum -c --quiet - \
  || die "checksum mismatch for $asset.tar.gz"
tar -xzf "$tmp/$asset.tar.gz" -C "$tmp" "$asset/sing-box"
# Rename instead of overwriting: the running binary cannot be written to.
install -m 0755 "$tmp/$asset/sing-box" "$BIN_DIR/.sing-box.new"
replace_if_changed "$BIN_DIR/.sing-box.new" "$BIN_DIR/sing-box" && changed=1
SINGBOX="$BIN_DIR/sing-box"

# Earlier versions kept the password next to this script.
[[ -f "$CONFIG_DIR/.password" || ! -f "$DIR/.password" ]] || cp -p "$DIR/.password" "$CONFIG_DIR/.password"
new_password=0
if [[ ! -s "$CONFIG_DIR/.password" ]]; then
  (umask 077 && "$SINGBOX" generate rand --base64 16 | tr -d '\n' > "$CONFIG_DIR/.password")
  new_password=1
fi
PASSWORD="$(cat "$CONFIG_DIR/.password")"

# Keep the listen address of the current config unless LISTEN is set.
if [[ -z "${LISTEN:-}" && -f "$CONFIG_DIR/config.json" ]]; then
  LISTEN="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["inbounds"][0]["listen"])' "$CONFIG_DIR/config.json" 2>/dev/null || true)"
fi
LISTEN="${LISTEN:-::}"

log "Config: $CONFIG_DIR/config.json (listen $LISTEN, port $PORT)"
(umask 077 && cat > "$tmp/config.json" <<EOF
{
  "log": { "level": "warn", "timestamp": true },
  "inbounds": [
    {
      "type": "shadowsocks",
      "tag": "ss-in",
      "listen": "$LISTEN",
      "listen_port": $PORT,
      "tcp_multi_path": true,
      "method": "$METHOD",
      "password": "$PASSWORD"
    }
  ],
  "outbounds": [{ "type": "direct", "tag": "direct" }]
}
EOF
)
"$SINGBOX" check -c "$tmp/config.json"
replace_if_changed "$tmp/config.json" "$CONFIG_DIR/config.json" && changed=1
chmod 600 "$CONFIG_DIR/config.json" "$CONFIG_DIR/.password"

log "Unit: $UNIT_DIR/duolink.service"
cat > "$tmp/duolink.service" <<EOF
[Unit]
Description=Duolink aggregation server (sing-box, MPTCP)
After=network-online.target

[Service]
# Runs on the host network as $USER: MPTCP subflows stay end to end, and port $PORT needs no privilege.
ExecStart=${SINGBOX/#"$HOME"/%h} run -c ${CONFIG_DIR/#"$HOME"/%h}/config.json
Restart=always
RestartSec=3
NoNewPrivileges=yes

[Install]
WantedBy=default.target
EOF
replace_if_changed "$tmp/duolink.service" "$UNIT_DIR/duolink.service" && changed=1

systemctl --user daemon-reload
systemctl --user enable --quiet duolink.service
if [[ "$changed" == "1" ]]; then
  log "Restarting duolink.service"
  systemctl --user restart duolink.service
else
  log "Nothing changed, duolink.service keeps running"
  systemctl --user start duolink.service
fi

log "Checking that sing-box listens on $LISTEN:$PORT"
case "$LISTEN" in
  :: | 0.0.0.0) want=":$PORT" ;;
  *:*) want="[$LISTEN]:$PORT" ;;
  *) want="$LISTEN:$PORT" ;;
esac
for _ in $(seq 20); do
  if systemctl --user is-active --quiet duolink.service \
    && ss -Hltn "sport = :$PORT" | awk -v want="$want" 'index($4, want) { found = 1 } END { exit !found }'; then
    listening=1
    break
  fi
  sleep 0.5
done
if [[ -z "${listening:-}" ]]; then
  journalctl --user -u duolink.service -n 20 --no-pager >&2 || true
  die "duolink.service does not listen on $LISTEN:$PORT"
fi

if [[ "$new_password" == "1" || "${SHOW_LINK:-0}" == "1" ]]; then
  PUBLIC_IP="${PUBLIC_IP:-$(curl -fsS -m 5 https://ifconfig.me || hostname -I | awk '{print $1}')}"
  USERINFO="$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$METHOD:$PASSWORD")"
  cat <<EOF

Done. Remember to also open TCP $PORT in your cloud firewall
(Oracle: VCN security list or network security group).

Copy this link, then in the Duolink menu click "Coller le lien ss://":

  ss://$USERINFO@$PUBLIC_IP:$PORT#duolink

EOF
else
  echo
  echo "Done. The password did not change. Run SHOW_LINK=1 ./install.sh to print the ss:// link again."
fi
