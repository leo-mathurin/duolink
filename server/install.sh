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

log "TCP tuning"
{
  # MPTCP shares one send buffer between subflows. When a 5G subflow is
  # loaded its RTT climbs to about 200 ms, and the 4 MB default keeps the
  # server waiting instead of feeding both links.
  echo "net.ipv4.tcp_wmem = 4096 16384 16777216"
  if [[ "$ENABLE_BBR" == "1" ]]; then
    # BBR copes better with lossy cellular links.
    echo "net.core.default_qdisc = fq"
    echo "net.ipv4.tcp_congestion_control = bbr"
  fi
} | sudo tee /etc/sysctl.d/90-duolink.conf >/dev/null
sudo sysctl -q --system

log "Firewall: allow TCP $PORT"
rule=(-p tcp -m tcp --dport "$PORT" -m comment --comment duolink -j ACCEPT)
for family in iptables ip6tables; do
  command -v "$family" >/dev/null || continue
  if ! sudo "$family" -C INPUT "${rule[@]}" 2>/dev/null; then
    # Insert before the catch-all REJECT that Oracle images ship with.
    reject_line="$(sudo "$family" -L INPUT --line-numbers -n | awk '$2 == "REJECT" { print $1; exit }')"
    sudo "$family" -I INPUT "${reject_line:-1}" "${rule[@]}"
  fi
done
for saved in /etc/iptables/rules.v4 /etc/iptables/rules.v6; do
  if [[ -f "$saved" ]] && ! sudo grep -q 'comment duolink' "$saved"; then
    # Edit the saved file instead of `netfilter-persistent save`, which would
    # also persist the chains that Docker and Tailscale create at runtime.
    if sudo grep -q '^-A INPUT -j REJECT' "$saved"; then
      sudo sed -i "0,/^-A INPUT -j REJECT/s//-A INPUT -p tcp -m tcp --dport $PORT -m comment --comment duolink -j ACCEPT\n&/" "$saved"
    fi
  fi
done

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

Copy this link, then in the Duolink menu click "Coller le lien ss://":

  ss://$USERINFO@$PUBLIC_IP:$PORT#duolink

EOF
