#!/bin/sh
# netns для mDNS-reflector: VLAN 30 (Home), 60 (Media), 90 (Guest) живут только внутри netns, хост не маршрутизирует
set -e
ip netns add mdns 2>/dev/null || true
for v in 30 60 90; do
  if ! ip netns exec mdns ip link show vlan$v >/dev/null 2>&1; then
    ip link del vlan$v 2>/dev/null || true
    ip link add link eth0 name vlan$v type vlan id $v
    ip link set vlan$v netns mdns
  fi
done
ip netns exec mdns ip link set lo up
ip netns exec mdns ip addr replace 10.77.30.199/24 dev vlan30
ip netns exec mdns ip addr replace 10.77.60.199/24 dev vlan60
ip netns exec mdns ip addr replace 10.77.90.199/24 dev vlan90
ip netns exec mdns ip link set vlan30 up
ip netns exec mdns ip link set vlan60 up
ip netns exec mdns ip link set vlan90 up
