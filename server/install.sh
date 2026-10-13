#!/usr/bin/env bash
# Sets up the Duolink aggregation server on a Linux VPS (Ubuntu/Debian, kernel >= 5.15).
# Idempotent: run it again after a change, the password is kept.
#
#   PORT=8443 ./install.sh
set -euo pipefail

PORT="${PORT:-8443}"
METHOD="2022-blake3-aes-128-gcm"
ENABLE_BBR="${ENABLE_BBR:-1}"
DIR="$(cd "$(dirname "$0")" && pwd)"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

[[ "$(sysctl -n net.mptcp.enabled 2>/dev/null)" == "1" ]] || {
  echo "MPTCP is not enabled in this kernel (sysctl net.mptcp.enabled)." >&2
  exit 1
}
command -v docker >/dev/null || { echo "Docker is required." >&2; exit 1; }

log "MPTCP limits (persisted with a systemd unit)"
sudo tee /etc/systemd/system/duolink-mptcp.service >/dev/null <<'EOF'
[Unit]
Description=Duolink MPTCP subflow limits
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/ip mptcp limits set subflows 8 add_addr_accepted 8
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now duolink-mptcp.service >/dev/null
sudo systemctl restart duolink-mptcp.service

if [[ "$ENABLE_BBR" == "1" ]]; then
  log "BBR congestion control (better on lossy cellular links)"
  sudo tee /etc/sysctl.d/90-duolink.conf >/dev/null <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
  sudo sysctl -q --system
fi

log "Firewall: allow TCP $PORT"
rule=(-p tcp -m tcp --dport "$PORT" -m comment --comment duolink -j ACCEPT)
if ! sudo iptables -C INPUT "${rule[@]}" 2>/dev/null; then
  # Insert before the catch-all REJECT that Oracle images ship with.
  reject_line="$(sudo iptables -L INPUT --line-numbers -n | awk '$2 == "REJECT" { print $1; exit }')"
  sudo iptables -I INPUT "${reject_line:-1}" "${rule[@]}"
fi
if [[ -f /etc/iptables/rules.v4 ]] && ! sudo grep -q 'comment duolink' /etc/iptables/rules.v4; then
  # Edit the saved file instead of `netfilter-persistent save`, which would
  # also persist the chains that Docker and Tailscale create at runtime.
  sudo sed -i "0,/^-A INPUT -j REJECT/s//-A INPUT -p tcp -m tcp --dport $PORT -m comment --comment duolink -j ACCEPT\n&/" /etc/iptables/rules.v4
fi

if [[ -f "$DIR/.password" ]]; then
  PASSWORD="$(cat "$DIR/.password")"
else
  PASSWORD="$(openssl rand -base64 16)"
  (umask 077 && printf '%s' "$PASSWORD" > "$DIR/.password")
fi

log "sing-box config"
(umask 077 && cat > "$DIR/config.json" <<EOF
{
  "log": { "level": "warn", "timestamp": true },
  "inbounds": [
    {
      "type": "shadowsocks",
      "tag": "ss-in",
      "listen": "::",
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

log "Starting the container"
(cd "$DIR" && docker compose up -d --force-recreate)

PUBLIC_IP="${PUBLIC_IP:-$(curl -fsS -m 5 https://ifconfig.me || hostname -I | awk '{print $1}')}"
USERINFO="$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$METHOD:$PASSWORD")"

cat <<EOF

Done. Remember to also open TCP $PORT in your cloud firewall
(Oracle: VCN security list or network security group).

Paste this link in Duolink (menu bar > Importer un lien ss://):

  ss://$USERINFO@$PUBLIC_IP:$PORT#duolink

EOF
