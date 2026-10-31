#!/bin/bash
# OS layer of "SSH only over Tailscale": port 22 accepted only on tailscale0, password login off. Safe to run twice.
# Run over Tailscale: bash infra/harden-ssh.sh   Exit 0 = hardened, 1 = refused, nothing changed.
# No UFW (Oracle: it "might cause an instance not to boot"). No iptables-restore: it would flush Docker's and Tailscale's chains, so the live rules are
# changed one by one and /etc/iptables/rules.v4 is edited for the next boot. The 169.254 rules are never touched.
set -euo pipefail

rules=/etc/iptables/rules.v4
fail() { echo "[FAIL] $1" >&2; exit 1; }

# Lockout guard: this session must have arrived on the Tailscale address.
ts_ip="$(tailscale ip -4 2>/dev/null || true)"
session_ip="$(echo "${SSH_CONNECTION:-}" | awk '{print $3}')"
[ -n "$ts_ip" ] || fail "tailscale has no IPv4 address"
[ "$session_ip" = "$ts_ip" ] || fail "this session did not come in over Tailscale, refusing"

old='-A INPUT -p tcp -m state --state NEW -m tcp --dport 22 -j ACCEPT'
new='-A INPUT -i tailscale0 -p tcp -m state --state NEW -m tcp --dport 22 -j ACCEPT'

# Check everything before changing anything.
sudo test -f "$rules" || fail "$rules not found"
if ! sudo grep -qxF -- "$new" "$rules" && ! sudo grep -qxF -- "$old" "$rules"; then
  fail "$rules has no known port 22 rule, changed nothing. Look at the file by hand."
fi

# Live: add the Tailscale rule first, so there is never a moment without one.
if ! sudo iptables -C INPUT -i tailscale0 -p tcp -m state --state NEW -m tcp --dport 22 -j ACCEPT 2>/dev/null; then
  sudo iptables -I INPUT 1 -i tailscale0 -p tcp -m state --state NEW -m tcp --dport 22 -j ACCEPT
fi
if sudo iptables -C INPUT -p tcp -m state --state NEW -m tcp --dport 22 -j ACCEPT 2>/dev/null; then
  sudo iptables -D INPUT -p tcp -m state --state NEW -m tcp --dport 22 -j ACCEPT
fi

# Next boot.
if sudo grep -qxF -- "$old" "$rules"; then
  sudo cp -p "$rules" "$rules.before-m7"
  sudo sed -i "s|^$old\$|$new|" "$rules"
fi

printf 'PasswordAuthentication no\nPermitRootLogin no\n' | sudo tee /etc/ssh/sshd_config.d/90-m7.conf >/dev/null
sudo sshd -t
sudo systemctl reload ssh
echo "[PASS] port 22 only on tailscale0, password login off"
