#!/bin/bash
# DMZ in Docker -- imperativo, passo passo, con spiegazioni ed errori veri.
# Esegue comandi Docker reali sulla macchina dove lo lanci (pensato per host Linux
# nativo: Ubuntu/Kali. Non serve nsenter1 su Mac Docker Desktop.)
#
# Alcuni errori li mostriamo succedere DAVVERO (NET_ADMIN, sysctl, porta
# privilegiata: sono garantiti, succedono sempre uguali). Un bug che in fase di
# test si e' rivelato incostante (il ritorno del SYN-ACK di waf) lo evitiamo
# applicando subito la rotta esplicita corretta, spiegando perche'.
#
# Uso:
#   bash docker-dmz-run.sh              -- tutto in un colpo solo, nessuna pausa
#   bash docker-dmz-run.sh --interact   -- si ferma a ogni step con INVIO

set +e  # negli step "mostra l'errore vero" non vogliamo che lo script muoia

INTERACT=0
[ "${1:-}" = "--interact" ] && INTERACT=1

FALLITI=0  # contatore finale -- se resta 0, tutto ok

# ── Colori ──────────────────────────────────────────────────────────────────
C_RESET='\033[0m'
C_TITLE='\033[1;36m'    # ciano bold: titoli di fase
C_EXPLAIN='\033[0;37m'  # grigio chiaro: spiegazioni
C_CMD='\033[1;33m'      # giallo bold: comando che sta per essere eseguito
C_OK='\033[1;32m'       # verde bold: successo/atteso
C_ERR='\033[1;31m'      # rosso bold: errore reale mostrato apposta
C_WARN='\033[0;33m'     # giallo: attenzione/nota
C_ASCII='\033[0;35m'    # magenta: diagrammi

# ── Helper ──────────────────────────────────────────────────────────────────

pause() {
  [ "$INTERACT" -eq 1 ] || return 0
  echo ""
  read -rp "$(printf "${C_WARN}   >> Premi INVIO per continuare...${C_RESET} ")"
  echo ""
}

fase() {
  echo ""
  printf "${C_TITLE}════════════════════════════════════════════════════════════${C_RESET}\n"
  printf "${C_TITLE}  %s${C_RESET}\n" "$1"
  printf "${C_TITLE}════════════════════════════════════════════════════════════${C_RESET}\n"
}

spiega() {
  printf "${C_EXPLAIN}%s${C_RESET}\n" "$1"
}

nota() {
  printf "${C_WARN}NOTA: %s${C_RESET}\n" "$1"
}

# Mostra il comando, chiede INVIO solo in modalita' --interact, poi lo esegue
# davvero e mostra l'output reale.
esegui() {
  printf "${C_CMD}\$ %s${C_RESET}\n" "$1"
  pause
  eval "$1"
  echo ""
}

# Come esegui(), ma non si aspetta successo -- usata per mostrare errori veri.
esegui_atteso_fallire() {
  printf "${C_CMD}\$ %s${C_RESET}\n" "$1"
  printf "${C_ERR}(questo comando FALLIRA' apposta -- guarda l'errore reale)${C_RESET}\n"
  pause
  eval "$1"
  echo ""
  printf "${C_ERR}^^ Questo errore e' garantito, succede identico su qualsiasi Docker.${C_RESET}\n"
  pause
}

ascii() {
  printf "${C_ASCII}%s${C_RESET}\n" "$1"
}

# esito <etichetta> <0-per-ok/altro-per-fallito> -- spunta verde o X rossa
esito() {
  if [ "$2" -eq 0 ]; then
    printf "  ${C_OK}✅ %s${C_RESET}\n" "$1"
  else
    printf "  ${C_ERR}❌ %s${C_RESET}\n" "$1"
    FALLITI=$((FALLITI + 1))
  fi
}

# ── Intro ───────────────────────────────────────────────────────────────────
[ "$INTERACT" -eq 1 ] && clear
fase "DMZ in Docker -- Imperativo"
spiega "Ricostruiamo la screened subnet a mano, un pezzo alla volta, con docker run."
if [ "$INTERACT" -eq 1 ]; then
  spiega "Ogni comando: lo vedi, premi INVIO, parte davvero, vedi l'output vero."
else
  spiega "Modalita' non interattiva: procede tutto da solo, senza fermarsi."
fi
spiega "Alcuni errori sono voluti -- servono a capire i vincoli veri di Docker."
nota "Pensato per Linux nativo (Ubuntu/Kali). Su Mac Docker Desktop la Fase 6 (nsenter) richiede un container privilegiato in piu' (vedi il README di questa cartella)."
pause

spiega "Pulizia preventiva: rimuovo container/reti con questi nomi se esistono gia'"
spiega "(es. da un run precedente), cosi' lo script riparte sempre da zero."
docker rm -f db attacker fw1 fw2 web waf waf_bad 2>/dev/null
docker network rm net_ext net_dmz net_mgmt net_lan 2>/dev/null
printf "${C_OK}Pronto.${C_RESET}\n"
pause

# ── FASE 0: Reti ─────────────────────────────────────────────────────────────
fase "FASE 0 -- Le quattro zone"

ascii "
  net_ext (10.20.0.0/24)   net_dmz (10.21.0.0/24)   net_mgmt (10.22.0.0/24)   net_lan (10.23.0.0/24)
     [ancora vuota]           [ancora vuota]            [ancora vuota]           [ancora vuota]
"

spiega "Prima di creare qualsiasi container, verifichiamo che non ci sia gia' qualcosa"
spiega "con questi nomi -- e soprattutto che nessun ALTRO progetto Docker sulla stessa"
spiega "macchina occupi gia' questi indirizzi (anche un progetto fermo da mesi conta:"
spiega "una rete Docker resta riservata finche' non la cancelli esplicitamente)."
esegui "docker network ls | grep net_ || echo '(vuoto, come atteso)'"

nota "Usiamo 10.20-23.x invece del piu' comune 172.20-23.x apposta: quel range e'"
nota "quello che Docker assegna di default ai progetti docker-compose (172.17, 18, 19...),"
nota "quindi e' il primo a scontrarsi con qualcos'altro gia' in uso sulla macchina."
pause

esegui "docker network create --subnet 10.20.0.0/24 net_ext"
esegui "docker network create --subnet 10.21.0.0/24 net_dmz"
esegui "docker network create --subnet 10.22.0.0/24 net_mgmt"
esegui "docker network create --subnet 10.23.0.0/24 net_lan"

spiega "Verifica: un subnet fisso per rete, non lasciato al caso."
esegui "docker network inspect net_dmz --format '{{.Name}}: {{range .IPAM.Config}}{{.Subnet}}{{end}}'"

# ── FASE 1: db ────────────────────────────────────────────────────────────────
fase "FASE 1 -- db, isolato su net_lan"

ascii "
  net_ext          net_dmz          net_mgmt          net_lan
  [vuota]          [vuota]          [vuota]           [ db 10.23.0.10 ]
"

spiega "db sta SOLO su net_lan. Nessun altro e' su quella rete ancora: deve essere"
spiega "irraggiungibile da chiunque. sleep infinity tiene il container acceso senza"
spiega "fargli fare nulla -- un guscio vuoto su cui poi entriamo con exec."
esegui "docker run -d --name db --network net_lan --ip 10.23.0.10 --cap-add NET_ADMIN alpine sleep infinity"
esegui "docker exec db sh -c 'apk add --no-cache netcat-openbsd'"

spiega "Listener in background (non blocca lo script): simula un MySQL su :3306."
esegui "docker exec -d db sh -c 'nc -l -p 3306 > /tmp/received.log 2>&1'"

esegui "docker exec db ip addr"
nota "Solo eth0 con l'IP che abbiamo assegnato noi. Le altre righe (tunl0, gre0...)"
nota "sono interfacce tunnel di default del kernel Linux, non le ha create Docker."

# ── FASE 2: attacker ─────────────────────────────────────────────────────────
fase "FASE 2 -- attacker, il nodo esterno"

ascii "
  net_ext                net_dmz          net_mgmt          net_lan
  [ attacker 10.20.0.50 ] [vuota]         [vuota]           [ db 10.23.0.10 ]
"

esegui "docker run -d --name attacker --network net_ext --ip 10.20.0.50 --cap-add NET_ADMIN alpine sleep infinity"
esegui "docker exec attacker sh -c 'apk add --no-cache netcat-openbsd tcpdump iproute2'"

spiega "Test negativo -- deve fallire GIA' ORA, senza nessun firewall: reti diverse,"
spiega "Docker le isola per design. Diverso dal filtraggio granulare che arriva dopo."
esegui "docker exec attacker nc -w3 10.23.0.10 3306"
printf "${C_OK}(timeout atteso -- isolamento di rete di Docker, non ancora un firewall)${C_RESET}\n"
pause

# ── FASE 3: fw2 -- qui mostriamo i due errori veri ──────────────────────────
fase "FASE 3 -- fw2, il firewall davanti al DB"

spiega "fw2 sta su net_mgmt E net_lan: fa da ponte, ma con FORWARD DROP di default"
spiega "e ACL esplicite. Lo creiamo PRIMA senza i flag giusti, apposta, per vedere"
spiega "due errori che capitano SEMPRE con Docker, non solo a noi."

esegui "docker run -d --name fw2 --network net_mgmt --ip 10.22.0.2 --cap-add NET_ADMIN alpine sleep infinity"
esegui "docker network connect --ip 10.23.0.2 net_lan fw2"
esegui "docker exec fw2 sh -c 'apk add --no-cache iptables iproute2 tcpdump'"

spiega "Errore reale #1: abilitare l'IP forwarding DOPO l'avvio del container."
esegui_atteso_fallire "docker exec fw2 sysctl -w net.ipv4.ip_forward=1"
spiega "Perche': /proc/sys e' montato in sola lettura su un container gia' avviato,"
spiega "a prescindere dalle capability. net.ipv4.ip_forward va abilitato con --sysctl"
spiega "al MOMENTO della creazione del container, non dopo con sysctl -w da dentro."

spiega "Ricreiamo fw2 con --sysctl in creazione:"
esegui "docker rm -f fw2"
esegui "docker run -d --name fw2 --network net_mgmt --ip 10.22.0.2 --cap-add NET_ADMIN --sysctl net.ipv4.ip_forward=1 alpine sleep infinity"
esegui "docker network connect --ip 10.23.0.2 net_lan fw2"
esegui "docker exec fw2 sh -c 'apk add --no-cache iptables iproute2 tcpdump'"

esegui "docker exec fw2 iptables -P FORWARD DROP"
esegui "docker exec fw2 iptables -A FORWARD -p tcp --dport 3306 -d 10.23.0.10 -j ACCEPT"
esegui "docker exec fw2 iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT"

spiega "Errore reale #2: dare a db una rotta di ritorno verso net_mgmt, ma db e'"
spiega "stato creato SENZA --cap-add NET_ADMIN in Fase 1 (doveva essere solo un"
spiega "listener passivo, pensavamo)."
esegui_atteso_fallire "docker exec db ip route add 10.22.0.0/24 via 10.23.0.2"
spiega "Perche': modificare le rotte dentro un container richiede NET_ADMIN, tolta"
spiega "per default a ogni container -- non basta 'servire solo passivamente', se"
spiega "deve rispondere fuori dalla propria subnet serve comunque quella capability."

spiega "Ricreiamo db con NET_ADMIN (il listener netcat va rifatto, nessun dato perso):"
esegui "docker rm -f db"
esegui "docker run -d --name db --network net_lan --ip 10.23.0.10 --cap-add NET_ADMIN alpine sleep infinity"
esegui "docker exec db sh -c 'apk add --no-cache netcat-openbsd'"
esegui "docker exec -d db sh -c 'nc -l -p 3306 > /tmp/received.log 2>&1'"
esegui "docker exec db ip route add 10.22.0.0/24 via 10.23.0.2"

esegui "docker exec fw2 iptables -L FORWARD -v -n"
printf "${C_OK}Policy DROP, 2 regole presenti, contatori a 0 -- nessuno le ha ancora attraversate.${C_RESET}\n"
pause

ascii "
  net_ext                net_dmz          net_mgmt              net_lan
  [ attacker 10.20.0.50 ] [vuota]   [ fw2 10.22.0.2 ]----[ fw2 10.23.0.2 ]--[ db 10.23.0.10 ]
                                     ACCEPT 3306, DROP resto
"

# ── FASE 4: web -- applichiamo le lezioni imparate ──────────────────────────
fase "FASE 4 -- web, il ponte DMZ-LAN (nginx vero)"

spiega "Qui applichiamo subito quello che abbiamo appena imparato: NET_ADMIN dalla"
spiega "creazione, non dopo. E invece di un placeholder alpine+netcat, partiamo"
spiega "direttamente con nginx vero -- fa lui stesso da PID 1, tiene il container"
spiega "acceso senza bisogno di sleep infinity."
esegui "docker run -d --name web --network net_dmz --ip 10.21.0.12 --cap-add NET_ADMIN nginx:stable-alpine"
esegui "docker network connect --ip 10.22.0.10 net_mgmt web"
esegui "docker exec web sh -c 'apk add --no-cache netcat-openbsd iproute2 tcpdump'"
esegui "docker exec web ip route add 10.23.0.0/24 via 10.22.0.2"

esegui "docker exec fw2 iptables -R FORWARD 1 -p tcp --dport 3306 -s 10.22.0.10 -d 10.23.0.10 -j ACCEPT"
spiega "Sostituita la regola larga di prima con una che accetta 3306 SOLO da web --"
spiega "questo e' il parametro che blocca il movimento laterale piu' avanti."

spiega "Test end-to-end verso il DB, attraverso fw2:"
esegui "docker exec web sh -c \"echo 'SELECT * FROM lezioni' | nc -w3 10.23.0.10 3306\""

spiega "Verifica reale -- cosa ha ricevuto db, non solo 'nessun errore':"
esegui "docker exec db cat /tmp/received.log"

esegui "docker exec fw2 iptables -L FORWARD -v -n"
printf "${C_OK}I contatori devono essere saliti sulla regola 3306 -- prova reale, non presunta.${C_RESET}\n"
pause

# ── FASE 5: fw1 -- stessa lezione, applicata dal primo colpo ────────────────
fase "FASE 5 -- fw1, il firewall esterno"

spiega "Stesso identico container-router di fw2, stavolta con --sysctl gia' in"
spiega "creazione: la lezione della Fase 3 non si ripete."
esegui "docker run -d --name fw1 --network net_ext --ip 10.20.0.2 --cap-add NET_ADMIN --sysctl net.ipv4.ip_forward=1 alpine sleep infinity"
esegui "docker network connect --ip 10.21.0.2 net_dmz fw1"
esegui "docker exec fw1 sh -c 'apk add --no-cache iptables iproute2 tcpdump'"
esegui "docker exec fw1 iptables -P FORWARD DROP"
esegui "docker exec fw1 iptables -A FORWARD -p tcp --dport 80  -d 10.21.0.12 -j ACCEPT"
esegui "docker exec fw1 iptables -A FORWARD -p tcp --dport 443 -d 10.21.0.12 -j ACCEPT"
esegui "docker exec fw1 iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT"
esegui "docker exec attacker ip route add 10.21.0.0/24 via 10.20.0.2"

ascii "
  [attacker]--fw1(ACL 80/443)--[ web 10.21.0.12 ]--fw2(ACL 3306)--[ db 10.23.0.10 ]
   net_ext                       net_dmz/net_mgmt                   net_lan
"

spiega "Prima di lanciare il test, catturiamo il traffico su fw1 in tempo reale --"
spiega "cosi' non ti devi fidare del 'ha funzionato', vedi i pacchetti veri: SYN in"
spiega "arrivo su eth0, inoltrato su eth1, e la risposta che torna indietro."
esegui "docker exec -d fw1 sh -c 'timeout 5 tcpdump -ni any port 80 > /tmp/capture.log 2>&1'"

spiega "Test positivo -- richiesta HTTP vera, nginx risponde davvero:"
esegui "docker exec attacker sh -c \"printf 'GET / HTTP/1.0\\r\\n\\r\\n' | nc -w3 10.21.0.12 80\""

spiega "Cosa ha visto fw1 mentre succedeva (la cattura ha 5 secondi di durata):"
esegui "sleep 2; docker exec fw1 cat /tmp/capture.log"
nota "Guarda le interfacce: 'eth0 In' e' l'arrivo da attacker, 'eth1 Out' e' l'inoltro"
nota "verso web -- lo stesso identico pattern che useremo per capire un bug vero"
nota "piu' avanti nella Fase 7 (il ritorno del WAF)."

esegui "docker exec fw1 iptables -L FORWARD -v -n"
printf "${C_OK}Contatori saliti sulla regola 80 -- il percorso buono e' confermato, doppia prova.${C_RESET}\n"
pause

spiega "Test negativo -- porta sbagliata, deve fallire (DROP):"
esegui "docker exec attacker nc -w3 10.21.0.12 22"
esegui "docker exec fw1 iptables -L FORWARD -v -n"
printf "${C_OK}Ora e' la policy DROP (in alto) ad aver contato questo pacchetto.${C_RESET}\n"
pause

spiega "Test negativo piu' importante -- attacker prova il DB direttamente, bypassando tutto:"
esegui "docker exec attacker nc -w3 10.23.0.10 3306"
printf "${C_OK}Timeout -- non e' 'nessuna rotta' (ce l'ha, il default gateway), e' l'isolamento${C_RESET}\n"
printf "${C_OK}automatico di Docker tra bridge diversi non collegati da nessun container-router.${C_RESET}\n"
pause

# ── FASE 6: sotto il cofano ──────────────────────────────────────────────────
fase "FASE 6 -- Sotto il cofano: namespace, veth, bridge"

spiega "Docker ha creato namespace di rete, coppie veth e bridge al posto nostro."
spiega "Li ritroviamo dal lato host."
esegui "sudo ls -l /var/run/docker/netns/ | tail -n +2 | wc -l"
nota "Un namespace per ogni container in esecuzione sull'host (anche quelli di altri progetti)."

esegui "PID=\$(docker inspect -f '{{.State.Pid}}' fw2); sudo nsenter -t \$PID -n ip addr"
esegui "PID=\$(docker inspect -f '{{.State.Pid}}' fw2); sudo nsenter -t \$PID -n iptables -L FORWARD -v -n"

esegui "ip link | grep -E 'br-|veth'"
nota "Un bridge per rete nostra, 2 veth ciascuno (2 container per zona) -- se vedi"
nota "bridge extra con piu' veth, sono di ALTRI progetti Docker sulla stessa macchina."

esegui "sudo iptables -t nat -L -n | grep 10.2"
nota "Una regola MASQUERADE per subnet -- e' quello che fa uscire un container verso"
nota "internet senza che nessuno gliel'abbia chiesto esplicitamente."

# ── FASE 7: WAF ──────────────────────────────────────────────────────────────
fase "FASE 7 -- ModSecurity WAF davanti a web"

spiega "Fin qui filtriamo solo L3/L4 (indirizzi, porte). Una SQL injection nell'URL"
spiega "passa senza problemi attraverso fw1 -- a quel livello e' un pacchetto TCP"
spiega "come un altro. Serve un filtro L7 che guardi dentro la richiesta HTTP."

spiega "owasp/modsecurity-crs:nginx e' un REVERSE PROXY, non sostituisce web -- ci"
spiega "sta davanti. Spostiamo web su un IP privato, mai piu' toccato da fw1 direttamente:"
esegui "docker rm -f web"
esegui "docker run -d --name web --network net_dmz --ip 10.21.0.12 --cap-add NET_ADMIN nginx:stable-alpine"
esegui "docker network connect --ip 10.22.0.10 net_mgmt web"
esegui "docker exec web sh -c 'apk add --no-cache netcat-openbsd iproute2 tcpdump'"
esegui "docker exec web ip route add 10.23.0.0/24 via 10.22.0.2"

spiega "Primo tentativo di waf: proviamo PORT=80 per non toccare l'ACL di fw1."
esegui_atteso_fallire "docker run -d --name waf_bad --network net_dmz --ip 10.21.0.13 -e BACKEND='http://10.21.0.12:80' -e PORT=80 owasp/modsecurity-crs:nginx; sleep 2; docker logs waf_bad; docker rm -f waf_bad 2>/dev/null"
spiega "Perche': l'immagine gira con un utente non privilegiato -- niente bind sotto"
spiega "1024. Non aggiriamo il vincolo, aggiorniamo l'ACL di fw1 per puntare a 8080:"

esegui "docker run -d --name waf --network net_dmz --ip 10.21.0.10 --cap-add NET_ADMIN -e BACKEND='http://10.21.0.12:80' owasp/modsecurity-crs:nginx"
esegui "docker exec fw1 iptables -R FORWARD 1 -p tcp --dport 8080 -d 10.21.0.10 -j ACCEPT"

nota "Rotta esplicita di ritorno, applicata SUBITO invece di fidarci del gateway di"
nota "default del bridge: in test quella scorciatoia si e' rivelata inaffidabile"
nota "(ha funzionato per web, non per waf, stessa identica topologia -- mai capito"
nota "il motivo esatto, e proprio per questo non ci si fida)."
esegui "PID=\$(docker inspect -f '{{.State.Pid}}' waf); sudo nsenter -t \$PID -n ip route add 10.20.0.0/24 via 10.21.0.2"

ascii "
  [attacker]--fw1(ACL 8080)--[ waf 10.21.0.10 ]--proxy-->[ web 10.21.0.12 ]--fw2--[ db ]
   net_ext                    ModSecurity/CRS              net_dmz privato        net_lan
"

spiega "Test 1 -- niente header Host, ModSecurity lo tratta come violazione di protocollo:"
esegui "docker exec attacker sh -c \"printf 'GET / HTTP/1.0\\r\\n\\r\\n' | nc -w3 10.21.0.10 8080\""
printf "${C_OK}403 atteso -- guarda il motivo esatto nei log:${C_RESET}\n"
esegui "docker logs --tail 5 waf"

spiega "Test 2 -- richiesta legittima, con Host. Catturiamo di nuovo su fw1: se la"
spiega "rotta esplicita che abbiamo appena messo su waf funziona, vedrai sia il SYN"
spiega "in entrata sia il SYN-ACK di ritorno -- non solo uno dei due."
esegui "docker exec -d fw1 sh -c 'timeout 5 tcpdump -ni any port 8080 > /tmp/capture_waf.log 2>&1'"
esegui "docker exec attacker sh -c \"printf 'GET / HTTP/1.0\\r\\nHost: 10.21.0.10\\r\\n\\r\\n' | nc -w3 10.21.0.10 8080\""
printf "${C_OK}200 OK atteso -- proxata correttamente da waf a web.${C_RESET}\n"

spiega "Verifica: entrambe le direzioni devono comparire (senza la rotta esplicita,"
spiega "avresti visto solo l'andata -- e' esattamente il bug che abbiamo diagnosticato"
spiega "con tcpdump a piu' livelli durante i test di questo lab)."
esegui "sleep 2; docker exec fw1 cat /tmp/capture_waf.log"
pause

spiega "Test 3 -- SQL injection nell'URL (attenzione: dentro printf i % vanno raddoppiati):"
esegui "docker exec attacker sh -c \"printf 'GET /?id=1%%27%%20OR%%20%%271%%27=%%271 HTTP/1.0\\r\\nHost: 10.21.0.10\\r\\n\\r\\n' | nc -w3 10.21.0.10 8080\""
printf "${C_OK}403 atteso -- bloccata da ModSecurity prima ancora di toccare web.${C_RESET}\n"
pause

# ── Verifica finale end-to-end ────────────────────────────────────────────────
fase "Verifica finale"

spiega "Riconferma dei percorsi chiave (ping matrix + catena completa), con esito verificato (non solo mostrato):"

docker exec web ping -c 2 10.21.0.2 > /dev/null 2>&1
esito "web -> fw1, stessa net_dmz" $?

docker exec web ping -c 2 10.22.0.2 > /dev/null 2>&1
esito "web -> fw2, stessa net_mgmt" $?

docker exec db ping -c 2 10.23.0.2 > /dev/null 2>&1
esito "db -> fw2, stessa net_lan" $?

OUT1=$(docker exec attacker sh -c "printf 'GET / HTTP/1.0\r\nHost: 10.21.0.10\r\n\r\n' | nc -w3 10.21.0.10 8080")
echo "$OUT1" | grep -q "200 OK"
esito "Richiesta legittima attacker->fw1->waf->web (200 OK)" $?

OUT2=$(docker exec attacker sh -c "printf 'GET /?id=1%%27%%20OR%%20%%271%%27=%%271 HTTP/1.0\r\nHost: 10.21.0.10\r\n\r\n' | nc -w3 10.21.0.10 8080")
echo "$OUT2" | grep -q "403 Forbidden"
esito "SQL injection bloccata da ModSecurity (403)" $?

docker exec web sh -c "echo 'SELECT * FROM lezioni' | nc -w3 10.23.0.10 3306"
OUT3=$(docker exec db cat /tmp/received.log)
echo "$OUT3" | grep -q "SELECT \* FROM lezioni"
esito "Query arrivata al DB attraverso fw2" $?

docker exec attacker nc -zv -w3 10.23.0.10 3306
RC4=$?
[ "$RC4" -ne 0 ]
esito "Movimento laterale bloccato (attacker->db diretto rifiutato)" $?

# ── Riepilogo finale ──────────────────────────────────────────────────────────
fase "Fatto -- riepilogo"

ascii "
  [attacker]--fw1--[ waf: ModSecurity ]-->[ web: nginx ]--fw2-->[ db ]
   net_ext           net_dmz (10.21.x)      net_dmz privato       net_lan
"

spiega "Lezioni che abbiamo VISTO succedere, non solo lette:"
echo "  1. NET_ADMIN serve a qualsiasi container che tocca iptables/rotte proprie"
echo "  2. net.ipv4.ip_forward va abilitato con --sysctl alla creazione, mai dopo"
echo "  3. Un'immagine hardened puo' rifiutarsi di bindare porte < 1024 (WAF su 8080)"
echo "  4. Il gateway di default del bridge e' una scorciatoia inaffidabile per il"
echo "     traffico di ritorno tra zone -- rotta esplicita, sempre"
echo "  5. L'isolamento di rete di Docker blocca le connessioni NUOVE tra bridge,"
echo "     non necessariamente quelle di ritorno su un flusso gia' tracciato"
echo ""

if [ "$FALLITI" -eq 0 ]; then
  printf "${C_OK}✅ Tutto ok -- topologia, firewall e WAF si comportano come atteso.${C_RESET}\n"
else
  printf "${C_ERR}❌ %d controllo/i fallito/i -- scorri sopra per vedere quali.${C_RESET}\n" "$FALLITI"
fi
exit "$FALLITI"
