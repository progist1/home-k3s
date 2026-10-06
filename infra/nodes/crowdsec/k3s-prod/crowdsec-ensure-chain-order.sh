#!/bin/bash
# k3s-prod: ensure CrowdSec ipset DROP in raw/PREROUTING (before kube-router).
# Install: /usr/local/bin/crowdsec-ensure-chain-order.sh
set -uo pipefail

ensure_raw() {
  local ipt=$1 set=$2
  $ipt -t raw -D PREROUTING -m set --match-set "$set" src -j DROP 2>/dev/null || true
  $ipt -t raw -I PREROUTING 1 -m set --match-set "$set" src -j DROP
}

iptables -D FORWARD -j CROWDSEC_CHAIN 2>/dev/null || true
iptables -D INPUT   -j CROWDSEC_CHAIN 2>/dev/null || true
iptables -F CROWDSEC_CHAIN 2>/dev/null || true
iptables -X CROWDSEC_CHAIN 2>/dev/null || true

for chain in INPUT FORWARD; do
  while iptables -D "$chain" -m set --match-set crowdsec-blacklists src -j DROP 2>/dev/null; do :; done
  while iptables -D "$chain" -m set --match-set crowdsec-blacklists src -j DROP \
      -m comment --comment "CrowdSec-ban" 2>/dev/null; do :; done
  while iptables -D "$chain" -m set --match-set crowdsec-blacklists src -j DROP \
      -m comment --comment "CrowdSec ban" 2>/dev/null; do :; done
done

ensure_raw iptables  crowdsec-blacklists
ensure_raw ip6tables crowdsec6-blacklists
