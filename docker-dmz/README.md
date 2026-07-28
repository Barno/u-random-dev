# 🐳 Screened Subnet in Docker

Stesso scenario di sicurezza di rete, tre tecnologie diverse: [Cisco Packet Tracer](../cisco/) → [Linux namespaces](../Linux-namespaces-dmz/) → **Docker**.

Una DMZ classica a quattro zone (esterna, DMZ, management, LAN interna), ricostruita prima a mano con `docker run` un pezzo alla volta (per capire *come* funziona ogni componente), poi cristallizzata in `docker-compose.yml`. Con un WAF ModSecurity davanti al web server per il filtraggio L7, sopra la segmentazione L3/L4 di rete.

Articolo completo con tutto il diario di debug (tcpdump a più livelli, errori reali e perché succedono) su [u-random.dev](https://u-random.dev).

---

## Topologia

```
  ┌──────────┐
  │ attacker │  net_ext: 10.20.0.50
  └────┬─────┘
       │ net_ext   10.20.0.0/24
  ┌────▼─────┐
  │   fw1    │  ACL: ACCEPT 8080/443 verso waf; DROP default
  │          │  net_ext: 10.20.0.2  |  net_dmz: 10.21.0.2
  └────┬─────┘
       │ net_dmz   10.21.0.0/24
  ┌────▼─────┐
  │   waf    │  ModSecurity + OWASP CRS (reverse proxy)
  │          │  net_dmz: 10.21.0.10
  └────┬─────┘
       │ proxy_pass
  ┌────▼─────┐
  │   web    │  nginx (backend reale, mai esposto direttamente)
  │          │  net_dmz: 10.21.0.12  |  net_mgmt: 10.22.0.10
  └────┬─────┘
       │ net_mgmt  10.22.0.0/24
  ┌────▼─────┐
  │   fw2    │  ACL: ACCEPT 3306 SOLO src=web; DROP default
  │          │  net_mgmt: 10.22.0.2  |  net_lan: 10.23.0.2
  └────┬─────┘
       │ net_lan   10.23.0.0/24
  ┌────▼─────┐
  │    db    │  listener :3306
  │          │  net_lan: 10.23.0.10
  └──────────┘
```

| Zona | Subnet | Container |
|---|---|---|
| Esterna | `10.20.0.0/24` | `attacker`, `fw1` |
| DMZ | `10.21.0.0/24` | `fw1`, `waf`, `web` |
| Management | `10.22.0.0/24` | `web`, `fw2` |
| LAN interna | `10.23.0.0/24` | `fw2`, `db` |

---

## Requisiti

- **Host Linux nativo** (Ubuntu, Kali, Debian...) con Docker installato. Su Docker Desktop (Mac/Windows) la Fase 6 (ispezione namespace via `nsenter`) e i comandi che leggono direttamente lo stack di rete dell'host richiedono un container privilegiato in più — vedi l'articolo per il workaround.
- `sudo` — serve per `nsenter` (rotta di ritorno di `waf`, ispezione namespace).
- Nessuna rete Docker già chiamata `net_ext`/`net_dmz`/`net_mgmt`/`net_lan` con subnet diversa da `10.20-23.0.0/24` (gli script controllano e ripuliscono solo le proprie, mai reti di altri progetti).

---

## Due modi di lanciarlo

### 1. Imperativo — `docker-dmz-run.sh`

Ricostruisce tutto a mano, un `docker run` alla volta, con gli errori reali (capability mancanti, sysctl a runtime, porta privilegiata) mostrati mentre succedono e spiegati subito dopo.

```bash
bash docker-dmz-run.sh              # tutto d'un fiato, nessuna pausa
bash docker-dmz-run.sh --interact   # si ferma a ogni comando con INVIO
```

### 2. Dichiarativo — `docker-dmz-compose.yml` + `docker-dmz-compose-run.sh`

Stesso identico risultato, in forma dichiarativa. Un pezzo (la rotta di ritorno di `waf`) resta fuori dal file compose per un motivo reale: l'immagine `owasp/modsecurity-crs` non ha `iproute2` installato e il suo entrypoint gestisce già tutta l'attivazione delle regole OWASP CRS — sovrascriverlo lo romperebbe. Quella rotta va aggiunta dall'host con `nsenter`, dopo l'avvio: è un'operazione host, non qualcosa che un file compose può esprimere.

`docker-dmz-compose-run.sh` fa tutto in un colpo: pulizia preventiva, `docker compose up`, la rotta di `waf`, e una suite di verifica end-to-end con spunta verde (✔) o X rossa (✘) per ogni controllo.

```bash
bash docker-dmz-compose-run.sh              # tutto d'un fiato
bash docker-dmz-compose-run.sh --interact   # con INVIO a ogni step
```

---

## Cosa verifica la suite di test

1. **Richiesta legittima** `attacker → fw1 → waf → web` → `200 OK`
2. **SQL injection nell'URL** → bloccata da ModSecurity, `403 Forbidden`
3. **Percorso verso il DB** `web → fw2 → db` → la query arriva al listener
4. **Movimento laterale** `attacker → db` diretto → bloccato, timeout

---

## Lezioni vere, trovate provandoci (non lette da un tutorial)

- **`--cap-add NET_ADMIN`** serve a *qualsiasi* container che debba toccare le proprie `iptables`/rotte — anche uno che sembra "solo un listener passivo".
- **`net.ipv4.ip_forward`** va abilitato con `--sysctl` al momento della creazione del container: `/proc/sys` è di sola lettura su un container già avviato, a prescindere dalle capability.
- Un'immagine hardened può **rifiutarsi di bindare porte sotto 1024** (l'utente non privilegiato è una scelta di sicurezza, non un bug — il WAF gira su `8080`, non `80`).
- **Il gateway di default del bridge è una scorciatoia inaffidabile** per il traffico di ritorno tra zone diverse: ha funzionato per `web`, ha fallito silenziosamente per `waf` e per `db` nella traduzione in compose. Rotta esplicita verso il router giusto, sempre — mai un'eccezione "perché tanto funziona".
- L'isolamento di rete di Docker tra bridge diversi blocca le **connessioni nuove**, non necessariamente il traffico di ritorno su un flusso già tracciato — un dettaglio che sembra un buco di sicurezza finché non lo capisci.
- **UFW non vede il traffico che Docker gestisce da solo** — le regole `DOCKER-USER`/`FORWARD` del demone vengono valutate prima, e possono rendere una policy `deny (routed)` di UFW puramente decorativa.

---

*« Non ci sono segreti, ci sono solo informazioni che non hai ancora trovato. »*
