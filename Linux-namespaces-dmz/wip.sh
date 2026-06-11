#!/bin/bash
# wip.sh - Tutorial interattivo: topologia DMZ con Linux namespaces
# esegui con: sudo bash wip.sh

# ---------------------------------------------------------------------------
# Colori
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
GRAY='\033[0;90m'
BOLD='\033[1m'
NC='\033[0m'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
header() {
    clear
    echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${WHITE}  STEP $1  ${GRAY}|  $2${NC}"
    echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

explain() {
    echo -e "${YELLOW}  ℹ  $1${NC}"
}

cisco() {
    echo -e "${GRAY}  ≡  Cisco: $1${NC}"
}

cmd_preview() {
    echo -e "${CYAN}  \$  $1${NC}"
}

ok() {
    echo -e "${GREEN}  ✓  $1${NC}"
}

err() {
    echo -e "${RED}  ✗  $1${NC}"
}

divider() {
    echo ""
    echo -e "${GRAY}  ────────────────────────────────────────────────────────${NC}"
    echo ""
}

next() {
    echo ""
    echo -e "${GRAY}  ↵  Premi INVIO per eseguire...${NC}"
    read -r
}

next_step() {
    echo ""
    echo -e "${GRAY}  ↵  Premi INVIO per il prossimo step...${NC}"
    read -r
}

# ---------------------------------------------------------------------------
# Intro
# ---------------------------------------------------------------------------
clear
echo ""
echo -e "${BOLD}${GREEN}  ██████╗ ███╗   ███╗███████╗    ██╗      █████╗ ██████╗ ${NC}"
echo -e "${BOLD}${GREEN}  ██╔══██╗████╗ ████║╚══███╔╝    ██║     ██╔══██╗██╔══██╗${NC}"
echo -e "${BOLD}${GREEN}  ██║  ██║██╔████╔██║  ███╔╝     ██║     ███████║██████╔╝${NC}"
echo -e "${BOLD}${GREEN}  ██║  ██║██║╚██╔╝██║ ███╔╝      ██║     ██╔══██║██╔══██╗${NC}"
echo -e "${BOLD}${GREEN}  ██████╔╝██║ ╚═╝ ██║███████╗    ███████╗██║  ██║██████╔╝${NC}"
echo -e "${BOLD}${GREEN}  ╚═════╝ ╚═╝     ╚═╝╚══════╝    ╚══════╝╚═╝  ╚═╝╚═════╝ ${NC}"
echo ""
echo -e "${WHITE}  Topologia DMZ con Linux namespaces — setup interattivo${NC}"
echo -e "${GRAY}  Kali (192.168.64.200) → Ubuntu (192.168.64.3) → ns-fw1 → DMZ → ns-fw2 → LAN${NC}"
echo ""
echo -e "${YELLOW}  Questo script ricrea da zero l'intera topologia.${NC}"
echo -e "${YELLOW}  Ogni step mostra cosa sta per succedere — premi INVIO per eseguire.${NC}"
echo ""
echo -e "${GRAY}  ↵  Premi INVIO per iniziare...${NC}"
read -r

# ---------------------------------------------------------------------------
# STEP 1 — Namespace
# ---------------------------------------------------------------------------
header "1 / 7" "Creazione namespace"

explain "Un namespace Linux e' uno stack IP isolato: interfacce, routing table e iptables propri."
explain "Stesso kernel, rete separata — come avere quattro router virtuali su una sola macchina."
cisco "trascinare FW1, FW2, Sofia, Giulia sulla canvas di Packet Tracer."
divider
cmd_preview "ip netns add ns-fw1    # FW1 ASA - firewall perimetrale"
cmd_preview "ip netns add ns-sofia   # Sofia/nginx - web server DMZ"
cmd_preview "ip netns add ns-fw2    # FW2 ASA - firewall interno"
cmd_preview "ip netns add ns-giulia  # Giulia/MySQL - database LAN"
next

ip netns add ns-fw1
ip netns add ns-sofia
ip netns add ns-fw2
ip netns add ns-giulia

echo ""
ok "Namespace creati:"
ip netns list | while read -r line; do echo -e "     ${GREEN}${line}${NC}"; done
next_step

# ---------------------------------------------------------------------------
# STEP 2 — Veth pair e bridge
# ---------------------------------------------------------------------------
header "2 / 7" "Veth pair e bridge DMZ"

explain "Un veth pair e' un cavo virtuale: due interfacce collegate, quello che entra da una esce dall'altra."
explain "br-dmz e' uno switch virtuale L2 — commuta frame in base al MAC come SW-DMZ in Cisco."
explain "FW1, Sofia e FW2 sono tutti sulla stessa subnet DMZ 10.10.10.0/29: servono sul bridge."
cisco "collegare i cavi tra dispositivi sulla canvas + VLAN 20 su SW-DMZ."
divider
cmd_preview "ip link add veth-host type veth peer name veth-fw1-out"
cmd_preview "ip link add br-dmz type bridge && ip link set br-dmz up"
cmd_preview "ip link add veth-fw1-dmz type veth peer name veth-fw1-dmz-br  # fw1 -> bridge"
cmd_preview "ip link add veth-sofia type veth peer name veth-sofia-br       # sofia -> bridge"
cmd_preview "ip link add veth-fw2-dmz type veth peer name veth-fw2-dmz-br  # fw2 -> bridge"
cmd_preview "ip link add veth-fw2-lan type veth peer name veth-giulia       # fw2 -> giulia"
next

# link host <-> ns-fw1
ip link add veth-host type veth peer name veth-fw1-out
ip link set veth-fw1-out netns ns-fw1

# bridge DMZ
ip link add br-dmz type bridge
ip link set br-dmz up

# ns-fw1 <-> bridge
ip link add veth-fw1-dmz type veth peer name veth-fw1-dmz-br
ip link set veth-fw1-dmz netns ns-fw1
ip link set veth-fw1-dmz-br master br-dmz
ip link set veth-fw1-dmz-br up

# ns-sofia <-> bridge
ip link add veth-sofia type veth peer name veth-sofia-br
ip link set veth-sofia netns ns-sofia
ip link set veth-sofia-br master br-dmz
ip link set veth-sofia-br up

# ns-fw2 <-> bridge
ip link add veth-fw2-dmz type veth peer name veth-fw2-dmz-br
ip link set veth-fw2-dmz netns ns-fw2
ip link set veth-fw2-dmz-br master br-dmz
ip link set veth-fw2-dmz-br up

# ns-fw2 <-> ns-giulia
ip link add veth-fw2-lan type veth peer name veth-giulia
ip link set veth-fw2-lan netns ns-fw2
ip link set veth-giulia netns ns-giulia

echo ""
ok "Bridge e veth pair creati."
ok "Interfacce sul bridge br-dmz:"
bridge link show br-dmz 2>/dev/null | while read -r line; do echo -e "     ${GREEN}${line}${NC}"; done
next_step

# ---------------------------------------------------------------------------
# STEP 3 — Indirizzi IP
# ---------------------------------------------------------------------------
header "3 / 7" "Configurazione IP e routing interno"

explain "ip addr add + ip link set up = 'ip address + no shutdown' su interfaccia Cisco."
explain "Le rotte statiche replicano i comandi 'route' dell'ASA."
explain "Sofia ha bisogno di una rotta statica verso la LAN via ns-fw2, altrimenti il traffico finisce su ns-fw1 che lo droppa."
cisco "ip address / no shutdown / route su FW1 e FW2."
divider
cmd_preview "ip addr add 10.0.0.1/30 dev veth-host && ip link set veth-host up"
cmd_preview "ip netns exec ns-fw1  ip addr add 10.0.0.2/30  dev veth-fw1-out  + 10.10.10.1/29 dev veth-fw1-dmz"
cmd_preview "ip netns exec ns-sofia ip addr add 10.10.10.2/29 dev veth-sofia  + route default via 10.10.10.1"
cmd_preview "ip netns exec ns-sofia ip route add 10.30.30.0/30 via 10.10.10.3  # LAN via FW2"
cmd_preview "ip netns exec ns-fw2  ip addr add 10.10.10.3/29 dev veth-fw2-dmz + 10.30.30.1/30 dev veth-fw2-lan"
cmd_preview "ip netns exec ns-giulia ip addr add 10.30.30.2/30 dev veth-giulia + route default via 10.30.30.1"
next

# host
ip addr add 10.0.0.1/30 dev veth-host
ip link set veth-host up

# ns-fw1
ip netns exec ns-fw1 ip link set lo up
ip netns exec ns-fw1 ip addr add 10.0.0.2/30 dev veth-fw1-out
ip netns exec ns-fw1 ip link set veth-fw1-out up
ip netns exec ns-fw1 ip addr add 10.10.10.1/29 dev veth-fw1-dmz
ip netns exec ns-fw1 ip link set veth-fw1-dmz up
ip netns exec ns-fw1 ip route add default via 10.0.0.1
ip netns exec ns-fw1 ip route add 10.30.30.0/30 via 10.10.10.3

# ns-sofia
ip netns exec ns-sofia ip link set lo up
ip netns exec ns-sofia ip addr add 10.10.10.2/29 dev veth-sofia
ip netns exec ns-sofia ip link set veth-sofia up
ip netns exec ns-sofia ip route add default via 10.10.10.1
ip netns exec ns-sofia ip route add 10.30.30.0/30 via 10.10.10.3

# ns-fw2
ip netns exec ns-fw2 ip link set lo up
ip netns exec ns-fw2 ip addr add 10.10.10.3/29 dev veth-fw2-dmz
ip netns exec ns-fw2 ip link set veth-fw2-dmz up
ip netns exec ns-fw2 ip addr add 10.30.30.1/30 dev veth-fw2-lan
ip netns exec ns-fw2 ip link set veth-fw2-lan up
ip netns exec ns-fw2 ip route add default via 10.10.10.1

# ns-giulia
ip netns exec ns-giulia ip link set lo up
ip netns exec ns-giulia ip addr add 10.30.30.2/30 dev veth-giulia
ip netns exec ns-giulia ip link set veth-giulia up
ip netns exec ns-giulia ip route add default via 10.30.30.1

echo ""
ok "IP configurati. Riepilogo:"
echo -e "     ${CYAN}ns-fw1  ${NC}: 10.0.0.2/30  +  10.10.10.1/29"
echo -e "     ${CYAN}ns-sofia${NC}: 10.10.10.2/29  gw 10.10.10.1"
echo -e "     ${CYAN}ns-fw2  ${NC}: 10.10.10.3/29  +  10.30.30.1/30"
echo -e "     ${CYAN}ns-giulia${NC}: 10.30.30.2/30  gw 10.30.30.1"
next_step

# ---------------------------------------------------------------------------
# STEP 4 — Rotte Ubuntu host
# ---------------------------------------------------------------------------
header "4 / 7" "Rotte Ubuntu host verso DMZ e LAN"

explain "Ubuntu conosce solo 10.0.0.0/30 (link diretto con ns-fw1)."
explain "Aggiungiamo DMZ e LAN via ns-fw1 (10.0.0.2) — altrimenti Ubuntu droppa i pacchetti di Kali."
cisco "In Cisco Kali aveva FW1 come default gateway e raggiungeva tutto automaticamente."
divider
cmd_preview "ip route add 10.10.10.0/29 via 10.0.0.2 dev veth-host   # DMZ"
cmd_preview "ip route add 10.30.30.0/30 via 10.0.0.2 dev veth-host   # LAN"
next

ip route add 10.10.10.0/29 via 10.0.0.2 dev veth-host
ip route add 10.30.30.0/30 via 10.0.0.2 dev veth-host

echo ""
ok "Rotte aggiunte. Routing table Ubuntu:"
ip route show | grep "10\." | while read -r line; do echo -e "     ${GREEN}${line}${NC}"; done
next_step

# ---------------------------------------------------------------------------
# STEP 5 — ip_forward
# ---------------------------------------------------------------------------
header "5 / 7" "ip_forward — il kernel diventa un router"

explain "ip_forward=1 dice al kernel: se ricevi un pacchetto non destinato a te, instradalo."
explain "Senza di esso ogni namespace si comporta come un host finale, non come un router."
explain "Attenzione: Docker/Wazuh lo abilita gia' a livello sistema — qui lo impostiamo esplicitamente"
explain "anche nei singoli namespace per garantire il comportamento corretto."
cisco "Routing abilitato per default sull'ASA — in Linux va attivato esplicitamente."
divider
cmd_preview "sysctl -w net.ipv4.ip_forward=1                          # Ubuntu host"
cmd_preview "ip netns exec ns-fw1 sysctl -w net.ipv4.ip_forward=1    # ns-fw1"
cmd_preview "ip netns exec ns-fw2 sysctl -w net.ipv4.ip_forward=1    # ns-fw2"
next

sysctl -w net.ipv4.ip_forward=1 > /dev/null
ip netns exec ns-fw1 sysctl -w net.ipv4.ip_forward=1 > /dev/null
ip netns exec ns-fw2 sysctl -w net.ipv4.ip_forward=1 > /dev/null

echo ""
ok "ip_forward attivo su host, ns-fw1 e ns-fw2."
next_step

# ---------------------------------------------------------------------------
# STEP 6 — Fix FORWARD chain host (Docker/ufw)
# ---------------------------------------------------------------------------
header "6 / 7" "Fix FORWARD chain Ubuntu host"

explain "Docker e ufw hanno policy DROP sulla FORWARD chain del namespace di default."
explain "I pacchetti di Kali arrivano su enp0s1 ma vengono droppati prima di raggiungere ns-fw1."
explain "-I inserisce le regole in cima alla chain, prima delle catene Docker/ufw."
cisco "Non esiste un equivalente Cisco — e' un problema specifico dell'ambiente con Docker/Wazuh."
divider
cmd_preview "iptables -I FORWARD -i enp0s1  -o veth-host -j ACCEPT   # Kali -> ns-fw1"
cmd_preview "iptables -I FORWARD -i veth-host -o enp0s1  -j ACCEPT   # ns-fw1 -> Kali (reply)"
next

iptables -I FORWARD -i enp0s1 -o veth-host -j ACCEPT
iptables -I FORWARD -i veth-host -o enp0s1 -j ACCEPT

echo ""
ok "Regole FORWARD host aggiunte. Kali puo' ora raggiungere ns-fw1."
next_step

# ---------------------------------------------------------------------------
# STEP 7 — iptables
# ---------------------------------------------------------------------------
header "7 / 8" "iptables: default DROP + ACL porta 80 e 443"

explain "iptables -P FORWARD DROP = security-level ASA: nessun traffico inter-zona senza ACL."
explain "Poi apriamo TCP 80 da outside verso DMZ e il ritorno con ESTABLISHED,RELATED."
explain "FORWARD = traffico in transito attraverso il namespace."
explain "OUTPUT = traffico originato dal namespace stesso (non bloccato da FORWARD DROP)."
cisco "access-list outside_in permit tcp any host 10.10.10.2 eq 80 + access-group."
divider
cmd_preview "ip netns exec ns-fw1 iptables -P FORWARD DROP             # default deny"
cmd_preview "ip netns exec ns-fw2 iptables -P FORWARD DROP             # default deny"
cmd_preview "ip netns exec ns-fw1 iptables -A FORWARD -i veth-fw1-out -o veth-fw1-dmz -p tcp --dport 80 -j ACCEPT"
cmd_preview "ip netns exec ns-fw1 iptables -A FORWARD -i veth-fw1-dmz -o veth-fw1-out -m state --state ESTABLISHED,RELATED -j ACCEPT"
cmd_preview "ip netns exec ns-fw1 iptables -A FORWARD -i veth-fw1-out -o veth-fw1-dmz -p tcp --dport 443 -j ACCEPT"
next

ip netns exec ns-fw1 iptables -P FORWARD DROP
ip netns exec ns-fw2 iptables -P FORWARD DROP

ip netns exec ns-fw1 iptables -A FORWARD \
  -i veth-fw1-out -o veth-fw1-dmz \
  -p tcp --dport 80 -j ACCEPT

ip netns exec ns-fw1 iptables -A FORWARD \
  -i veth-fw1-dmz -o veth-fw1-out \
  -m state --state ESTABLISHED,RELATED -j ACCEPT

ip netns exec ns-fw1 iptables -A FORWARD \
  -i veth-fw1-out -o veth-fw1-dmz \
  -p tcp --dport 443 -j ACCEPT

echo ""
ok "iptables configurato. Regole ns-fw1:"
ip netns exec ns-fw1 iptables -L FORWARD -v -n | while read -r line; do
    echo -e "     ${CYAN}${line}${NC}"
done
next_step

# ---------------------------------------------------------------------------
# STEP 8 — iptables ns-fw2
# ---------------------------------------------------------------------------
header "8 / 8" "iptables ns-fw2: ACL MySQL verso ns-giulia"

explain "ns-fw2 permette solo TCP 3306 da ns-sofia (10.10.10.2) verso ns-giulia (10.30.30.2)."
explain "Solo il web server puo' aprire connessioni al database — non qualsiasi host della DMZ."
explain "ESTABLISHED,RELATED copre le risposte MySQL verso ns-sofia."
cisco "access-list DMZ_IN permit tcp host 10.10.10.2 host 10.30.30.2 eq 3306"
divider
cmd_preview "ip netns exec ns-fw2 iptables -A FORWARD -i veth-fw2-dmz -o veth-fw2-lan -p tcp --dport 3306 -s 10.10.10.2 -d 10.30.30.2 -j ACCEPT"
cmd_preview "ip netns exec ns-fw2 iptables -A FORWARD -i veth-fw2-lan -o veth-fw2-dmz -m state --state ESTABLISHED,RELATED -j ACCEPT"
next

ip netns exec ns-fw2 iptables -A FORWARD \
  -i veth-fw2-dmz -o veth-fw2-lan \
  -p tcp --dport 3306 \
  -s 10.10.10.2 -d 10.30.30.2 \
  -j ACCEPT

ip netns exec ns-fw2 iptables -A FORWARD \
  -i veth-fw2-lan -o veth-fw2-dmz \
  -m state --state ESTABLISHED,RELATED -j ACCEPT

echo ""
ok "ACL ns-fw2 configurata. Regole ns-fw2:"
ip netns exec ns-fw2 iptables -L FORWARD -v -n | while read -r line; do
    echo -e "     ${CYAN}${line}${NC}"
done
next_step

# ---------------------------------------------------------------------------
# Riepilogo finale
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}${GREEN}  Topologia DMZ pronta.${NC}"
echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${WHITE}  Namespace attivi:${NC}"
ip netns list | while read -r line; do echo -e "     ${GREEN}✓  ${line}${NC}"; done
echo ""
echo -e "${WHITE}  Test suggeriti:${NC}"
echo -e "     ${CYAN}sudo ip netns exec ns-sofia nc -l -p 80${NC}                                                    (listener HTTP)"
echo -e "     ${CYAN}echo 'hello' | nc 10.10.10.2 80${NC}                                                           (da Kali)"
echo -e "     ${CYAN}sudo ip netns exec ns-giulia nc -l -p 3306${NC}                                                 (listener MySQL simulato)"
echo -e "     ${CYAN}sudo ip netns exec ns-sofia bash -c \"echo 'SELECT * FROM lezioni' | nc 10.30.30.2 3306\"${NC}"
echo -e "     ${CYAN}nc -w3 10.30.30.2 3306${NC}                                                                     (da Kali: deve fallire)"
echo ""
echo -e "${YELLOW}  Ricorda: esegui wip_kali.sh su Kali per aggiungere le rotte.${NC}"
echo ""
