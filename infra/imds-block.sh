#!/bin/bash
# Keeps containers away from the instance metadata service (169.254.169.254). User-data, with the spent Tailscale key, is readable there.
# Run by docker-imds-block.service after Docker starts, as root. Safe to run twice: it rebuilds its own chain and hooks it in once.
# The host itself is not affected (DOCKER-USER only sees forwarded container traffic), so the Oracle Cloud Agent keeps working.
# DNS stays open: OCI's resolver is the same address, and Docker's embedded DNS may forward from the container's namespace.
# Never touches /etc/iptables/rules.v4 or the host's own 169.254 rules, and never runs iptables-restore (it would wipe Docker's and Tailscale's chains).
set -euo pipefail

chain=M7-IMDS
iptables -w -N "$chain" 2>/dev/null || true
iptables -w -F "$chain"
iptables -w -A "$chain" -d 169.254.169.254/32 -p udp --dport 53 -j RETURN
iptables -w -A "$chain" -d 169.254.169.254/32 -p tcp --dport 53 -j RETURN
iptables -w -A "$chain" -d 169.254.0.0/16 -j REJECT --reject-with icmp-admin-prohibited
iptables -w -C DOCKER-USER -j "$chain" 2>/dev/null || iptables -w -I DOCKER-USER 1 -j "$chain"
echo "[PASS] $chain hooked into DOCKER-USER"
