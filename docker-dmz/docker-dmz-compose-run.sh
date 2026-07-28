#!/bin/bash
# Orchestratore unico per il compose del lab DMZ:
#   1. pre-flight: verifica/rimuove container e reti di run precedenti
#   2. docker compose up -d
#   3. postup: rotta esplicita di waf (l'unica cosa che compose non puo' esprimere)
#   4. verifica: stessa suite di test usata in tutto l'articolo
#
# Ogni verifica stampa una spunta verde (ok) o una X rossa (fallito), come
# l'output nativo di "docker compose up".
#
# Uso:
#   bash docker-dmz-compose-run.sh              -- tutto in un colpo solo
#   bash docker-dmz-compose-run.sh --interact    -- si ferma a ogni step con INVIO

set -uo pipefail  # niente -e: alcuni test DEVONO fallire (timeout), non sono errori

INTERACT=0
[ "${1:-}" = "--interact" ] && INTERACT=1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-dmz-compose.yml"

FALLITI=0  # contatore finale -- se resta 0, tutto ok

# ── Colori ──────────────────────────────────────────────────────────────────
C_RESET='\033[0m'
C_TITLE='\033[1;36m'
C_EXPLAIN='\033[0;37m'
C_CMD='\033[1;33m'
C_OK='\033[1;32m'
C_ERR='\033[1;31m'
C_WARN='\033[0;33m'

# ── Helper ──────────────────────────────────────────────────────────────────
pausa() {
  [ "$INTERACT" -eq 1 ] || return 0
  echo ""
  read -rp "$(printf "${C_WARN}   >> Premi INVIO per continuare...${C_RESET} ")"
  echo ""
}

step() {
  echo ""
  printf "${C_TITLE}════════════════════════════════════════════════════════════${C_RESET}\n"
  printf "${C_TITLE}  %s${C_RESET}\n" "$1"
  printf "${C_TITLE}════════════════════════════════════════════════════════════${C_RESET}\n"
}

spiega() { printf "${C_EXPLAIN}%s${C_RESET}\n" "$1"; }
nota()   { printf "${C_WARN}NOTA: %s${C_RESET}\n" "$1"; }
mostra() { printf "${C_CMD}\$ %s${C_RESET}\n" "$1"; }

# Mostra il comando, aspetta INVIO solo in modalita' --interact, poi lo esegue.
# Ritorna il vero exit code del comando (non quello dell'ultimo echo) --
# altrimenti "esito ... $?" subito dopo controllerebbe sempre 0.
esegui() {
  mostra "$1"
  pausa
  eval "$1"
  local rc=$?
  echo ""
  return "$rc"
}

# esito <etichetta> <0-per-ok/1-per-fallito>
# Stampa la spunta verde o la X rossa e tiene il conto dei falliti.
esito() {
  if [ "$2" -eq 0 ]; then
    printf "  ${C_OK}✅ %s${C_RESET}\n" "$1"
  else
    printf "  ${C_ERR}❌ %s${C_RESET}\n" "$1"
    FALLITI=$((FALLITI + 1))
  fi
}

# ── FASE A: pre-flight ────────────────────────────────────────────────────────
step "FASE A -- Pre-flight: cosa c'e' gia' sulla macchina"

NOSTRI_CONTAINER="db attacker fw1 fw2 web waf"
NOSTRE_RETI="net_ext net_dmz net_mgmt net_lan"

spiega "Controllo se esistono gia' container o reti con questi nomi esatti"
spiega "(nomi fissati nel compose con container_name/name -- niente prefissi a sorpresa)."

# tr finale: righe -> spazi, altrimenti ogni nome diventerebbe un comando a se'
# quando la lista finisce dentro eval (bug reale trovato provandolo dal vivo).
TROVATI_CONTAINER=$(docker ps -a --format '{{.Names}}' | grep -Fx -f <(echo "$NOSTRI_CONTAINER" | tr ' ' '\n') | tr '\n' ' ' || true)
TROVATE_RETI=$(docker network ls --format '{{.Name}}' | grep -Fx -f <(echo "$NOSTRE_RETI" | tr ' ' '\n') | tr '\n' ' ' || true)

if [ -z "$TROVATI_CONTAINER" ] && [ -z "$TROVATE_RETI" ]; then
  esito "Niente da ripulire, si parte da zero" 0
else
  [ -n "$TROVATI_CONTAINER" ] && echo "Container trovati: $TROVATI_CONTAINER"
  [ -n "$TROVATE_RETI" ]      && echo "Reti trovate: $TROVATE_RETI"
  nota "Sono tutti nomi di QUESTO lab (mai nomi generici) -- sicuro rimuoverli."
  pausa
  if [ -n "$TROVATI_CONTAINER" ]; then
    esegui "docker rm -f $TROVATI_CONTAINER"
    esito "Container precedenti rimossi" $?
  fi
  if [ -n "$TROVATE_RETI" ]; then
    esegui "docker network rm $TROVATE_RETI"
    esito "Reti precedenti rimosse" $?
  fi
fi

# ── FASE B: docker compose up ─────────────────────────────────────────────────
step "FASE B -- docker compose up"

mostra "docker compose -f \"$COMPOSE_FILE\" up -d"
pausa
docker compose -f "$COMPOSE_FILE" up -d
esito "docker compose up -d" $?

spiega "Attendo che i container finiscano il proprio setup interno (apk add,"
spiega "rotte) prima di procedere -- invece di un'attesa fissa, controllo che"
spiega "siano davvero pronti (evita la race condition vista in questa sessione)."
PRONTO=1
for _ in $(seq 1 15); do
  if docker exec db ip route 2>/dev/null | grep -q "10.22.0.0/24" \
     && docker exec web ip route 2>/dev/null | grep -q "10.23.0.0/24" \
     && docker exec fw1 iptables -L FORWARD -n 2>/dev/null | grep -q "8080"; then
    PRONTO=0
    break
  fi
  sleep 1
done
esito "Container pronti (rotte + iptables configurati)" "$PRONTO"
[ "$PRONTO" -ne 0 ] && printf "${C_WARN}Procedo comunque -- se i test sotto falliscono, potrebbe essere solo questione di tempo.${C_RESET}\n"
pausa

# ── FASE C: postup -- la rotta che compose non puo' esprimere ────────────────
step "FASE C -- Rotta esplicita di waf (operazione host, fuori da compose)"

spiega "owasp/modsecurity-crs:nginx non ha iproute2, e il suo entrypoint fa gia'"
spiega "tutto il lavoro di attivazione CRS -- non lo sovrascriviamo. La rotta di"
spiega "ritorno verso net_ext va aggiunta dall'host con nsenter, sempre."

WAF_ID=$(docker compose -f "$COMPOSE_FILE" ps -q waf)
if [ -z "$WAF_ID" ]; then
  esito "Container 'waf' trovato" 1
  echo "Interrompo -- qualcosa e' andato storto in FASE B." >&2
  exit 1
fi
esito "Container 'waf' trovato" 0
PID=$(docker inspect -f '{{.State.Pid}}' "$WAF_ID")

mostra "sudo nsenter -t $PID -n ip route show 10.20.0.0/24"
if sudo nsenter -t "$PID" -n ip route show 10.20.0.0/24 | grep -q "via 10.21.0.2"; then
  esito "Rotta gia' presente" 0
else
  esegui "sudo nsenter -t $PID -n ip route add 10.20.0.0/24 via 10.21.0.2"
  if sudo nsenter -t "$PID" -n ip route show 10.20.0.0/24 | grep -q "via 10.21.0.2"; then
    esito "Rotta aggiunta con successo" 0
  else
    esito "Rotta aggiunta con successo" 1
  fi
fi

# ── FASE D: verifica ──────────────────────────────────────────────────────────
step "FASE D -- Verifica end-to-end"

echo ""
printf "${C_TITLE}Test 1 -- richiesta legittima: attacker -> fw1 -> waf -> web${C_RESET}\n"
mostra "docker exec attacker sh -c \"printf 'GET / HTTP/1.0\\r\\nHost: 10.21.0.10\\r\\n\\r\\n' | nc -w3 10.21.0.10 8080\""
pausa
OUT1=$(docker exec attacker sh -c "printf 'GET / HTTP/1.0\r\nHost: 10.21.0.10\r\n\r\n' | nc -w3 10.21.0.10 8080")
echo "$OUT1"
echo "$OUT1" | grep -q "200 OK"
esito "Risposta 200 OK ricevuta" $?

printf "\n${C_TITLE}Test 2 -- SQL injection nell'URL, deve bloccarla ModSecurity${C_RESET}\n"
mostra "docker exec attacker sh -c \"printf 'GET /?id=1%%27%%20OR%%20%%271%%27=%%271 HTTP/1.0\\r\\nHost: 10.21.0.10\\r\\n\\r\\n' | nc -w3 10.21.0.10 8080\""
pausa
OUT2=$(docker exec attacker sh -c "printf 'GET /?id=1%%27%%20OR%%20%%271%%27=%%271 HTTP/1.0\r\nHost: 10.21.0.10\r\n\r\n' | nc -w3 10.21.0.10 8080")
echo "$OUT2"
echo "$OUT2" | grep -q "403 Forbidden"
esito "SQLi bloccata con 403 Forbidden" $?

printf "\n${C_TITLE}Test 3 -- percorso verso il DB: web -> fw2 -> db${C_RESET}\n"
mostra "docker exec web sh -c \"echo 'SELECT * FROM lezioni' | nc -w3 10.23.0.10 3306\""
pausa
docker exec web sh -c "echo 'SELECT * FROM lezioni' | nc -w3 10.23.0.10 3306"
OUT3=$(docker exec db cat /tmp/received.log)
echo "$OUT3"
echo "$OUT3" | grep -q "SELECT \* FROM lezioni"
esito "Query arrivata al DB attraverso fw2" $?

printf "\n${C_TITLE}Test 4 -- negativo: attacker prova il DB direttamente${C_RESET}\n"
mostra "docker exec attacker nc -zv -w3 10.23.0.10 3306"
pausa
docker exec attacker nc -zv -w3 10.23.0.10 3306
RC4=$?
# qui il successo e' che la connessione FALLISCA (rc != 0) -- un rc=0
# vorrebbe dire che attacker ha raggiunto il DB scavalcando tutta la DMZ
[ "$RC4" -ne 0 ]
esito "Movimento laterale bloccato (connessione diretta rifiutata)" $?

# ── Riepilogo ──────────────────────────────────────────────────────────────
step "Riepilogo"
if [ "$FALLITI" -eq 0 ]; then
  printf "${C_OK}✅ Tutto ok -- il compose ha ricreato correttamente lo stesso comportamento dell'imperativo.${C_RESET}\n"
else
  printf "${C_ERR}❌ %d controllo/i fallito/i -- scorri sopra per vedere quali.${C_RESET}\n" "$FALLITI"
fi
exit "$FALLITI"
