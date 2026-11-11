#!/usr/bin/env bash
# One-time system setup for the Duolink server. Run it as root, once per machine:
#
#   sudo ./setup-system.sh                # linger for $SUDO_USER, firewall for PORT=8443
#   sudo DUOLINK_USER=alice FIREWALL=0 ./setup-system.sh
#
# Then the service user installs and updates sing-box without sudo: ./install.sh
set -euo pipefail

PORT="${PORT:-8443}"
DUOLINK_USER="${DUOLINK_USER:-${SUDO_USER:-}}"
ENABLE_BBR="${ENABLE_BBR:-1}"
FIREWALL="${FIREWALL:-1}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }

[[ $EUID -eq 0 ]] || { echo "Run this script as root: sudo $0" >&2; exit 1; }

if [[ "$(sysctl -n net.mptcp.enabled 2>/dev/null)" != "1" ]]; then
  # Do not force it on: a security policy may have turned it off on purpose.
  warn "MPTCP is disabled (net.mptcp.enabled != 1). Duolink works in plain TCP until it is enabled again. The limits below apply when it is."
fi

log "MPTCP limits (persisted with a systemd unit)"
cat > /etc/systemd/system/duolink-mptcp.service <<'EOF'
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
systemctl daemon-reload
systemctl enable --quiet duolink-mptcp.service
systemctl restart duolink-mptcp.service

log "TCP tuning: /etc/sysctl.d/90-duolink.conf"
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
} > /etc/sysctl.d/90-duolink.conf
sysctl -q -p /etc/sysctl.d/90-duolink.conf

if [[ "$FIREWALL" == "1" ]]; then
  log "Firewall: allow TCP $PORT (iptables)"
  rule=(-p tcp -m tcp --dport "$PORT" -m comment --comment duolink -j ACCEPT)
  for family in iptables ip6tables; do
    command -v "$family" >/dev/null || continue
    if ! "$family" -C INPUT "${rule[@]}" 2>/dev/null; then
      # Insert before the catch-all REJECT that Oracle images ship with.
      reject_line="$("$family" -L INPUT --line-numbers -n | awk '$2 == "REJECT" { print $1; exit }')"
      "$family" -I INPUT "${reject_line:-1}" "${rule[@]}"
    fi
  done
  for saved in /etc/iptables/rules.v4 /etc/iptables/rules.v6; do
    if [[ -f "$saved" ]] && ! grep -q 'comment duolink' "$saved"; then
      # Edit the saved file instead of `netfilter-persistent save`, which would
      # also persist the chains that Docker and Tailscale create at runtime.
      if grep -q '^-A INPUT -j REJECT' "$saved"; then
        sed -i "0,/^-A INPUT -j REJECT/s//-A INPUT -p tcp -m tcp --dport $PORT -m comment --comment duolink -j ACCEPT\n&/" "$saved"
      fi
    fi
  done
else
  log "Firewall: skipped (FIREWALL=0). Make sure your firewall allows TCP $PORT."
fi

if [[ -n "$DUOLINK_USER" ]]; then
  log "Linger for $DUOLINK_USER: the user service starts at boot"
  loginctl enable-linger "$DUOLINK_USER"
else
  warn "No service user (run with sudo, or set DUOLINK_USER). Enable linger later: loginctl enable-linger <user>"
fi

cat <<EOF

Done. As ${DUOLINK_USER:-the service user}, without sudo: ./install.sh
EOF
