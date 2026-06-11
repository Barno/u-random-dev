#!/bin/bash
# wip_kali.sh - rotte effimere su Kali VM verso il lab DMZ
# esegui con: sudo bash wip_kali.sh

# Ubuntu host (192.168.64.3) e' il nexthop per tutte le reti interne del lab.
# Senza queste rotte Kali non raggiunge nessuna subnet del lab.

ip route add 10.0.0.0/30 via 192.168.64.3    # link esterno: host <-> ns-fw1
ip route add 10.10.10.0/29 via 192.168.64.3   # DMZ: ns-fw1, ns-sofia, ns-fw2
ip route add 10.30.30.0/30 via 192.168.64.3   # LAN: ns-fw2, ns-giulia

echo "Rotte lab aggiunte."
echo "Verifica: ip route show | grep 10\."
