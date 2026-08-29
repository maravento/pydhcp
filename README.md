# [PyDHCP](https://github.com/maravento)

[![status-maintained](https://img.shields.io/badge/status-maintained-purple.svg)](https://github.com/maravento/pydhcp)
[![last commit](https://img.shields.io/github/last-commit/maravento/pydhcp)](https://github.com/maravento/pydhcp)
[![Stargazers](https://img.shields.io/github/stars/maravento/pydhcp?label=Stargazers)](https://github.com/maravento/pydhcp/stargazers)
[![Twitter Follow](https://img.shields.io/twitter/follow/maraventostudio.svg)](https://twitter.com/maraventostudio)

<!-- markdownlint-disable MD033 -->

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      <b>pydhcp</b> is an open-source IPv4 DHCP server written in Python. Since <a href="https://github.com/isc-projects/dhcp">isc-dhcp-server</a> reached End-of-Life (EOL) in 2022, pydhcp aims to preserve many of its familiar features and configuration style for anyone looking to migrate, offering a friendly, similar-feeling alternative rather than a full replacement. It implements RFC 2131 over UDP 67/68, uses a compatible configuration syntax and lease file format under its own file paths, and runs as a native <code>systemd</code> service with an <code>init.d</code> wrapper included.
    </td>
    <td style="width: 50%; vertical-align: top;">
      <b>pydhcp</b> es un servidor DHCP IPv4 de código abierto escrito en Python. Dado que <a href="https://github.com/isc-projects/dhcp">isc-dhcp-server</a> alcanzó su fin de vida (EOL) en 2022, pydhcp busca conservar muchas de sus características y estilo de configuración habituales para quienes quieran migrar, ofreciendo una alternativa amigable y similar, no un reemplazo completo. Implementa RFC 2131 sobre UDP 67/68, usa sintaxis de configuración y formato de concesiones compatible bajo sus propias rutas de archivo, y corre como servicio <code>systemd</code> nativo con wrapper <code>init.d</code> incluido.
    </td>
  </tr>
</table>

## REQUIREMENTS

---

**⚠️ WARNING:** Only tested on Ubuntu 24.04 LTS. Other versions or distros not tested, use at your own risk.

- Python 3.8+
- systemd
- iproute2, gawk, passwd, util-linux, coreutils, grep, sed, iputils-ping, findutils, libc-bin

## ISC-DHCP-SERVER VS PYDHCP

---

> **Legend:** ✅ same behaviour · ⚠️ works, with a difference · ⛔ not implemented
>
> **Leyenda:** ✅ mismo comportamiento · ⚠️ funciona, con una diferencia · ⛔ no implementado

### Protocol and architecture

| isc-dhcp-server | pydhcp | Description | Descripción |
|---|---|---|---|
| DHCPv4 (RFC 2131) over UDP 67/68 | ✅ | Python daemon, same protocol | Demonio Python, mismo protocolo |
| DHCPv6 | ⛔ | IPv4 only | Solo IPv4 |
| Multiple interfaces | ⛔ | Single interface, set in `INTERFACESv4` | Interfaz única, definida en `INTERFACESv4` |
| BOOTP / PXE | ⛔ | Packets are padded to the BOOTP minimum for protocol compliance, but BOOTP clients are not served | Los paquetes se rellenan al mínimo BOOTP por cumplimiento del protocolo, pero no se atiende a clientes BOOTP |
| DHCP relay agents | ⛔ | No legitimate use without multi-segment support. `giaddr`/`hops` are parsed only to close a spoofing hole | Sin uso legítimo sin soporte multi-segmento. `giaddr`/`hops` se parsean solo para cerrar un agujero de suplantación |
| Clients whose `chaddr` differs from the frame source MAC | ⛔ | Dropped and logged: closes a spoofing hole | Descartados y registrados: cierra un agujero de suplantación |
| LDAP backend | ⛔ | Host reservations live in `pydhcpd.conf`, or in the `mac-*.txt` lists that `pyleases.sh` turns into reservations | Las reservas de host viven en `pydhcpd.conf`, o en las listas `mac-*.txt` que `pyleases.sh` convierte en reservas |
| DDNS | ⛔ | The daemon never registers names in DNS; a lease grants an address, nothing else | El demonio nunca registra nombres en DNS; una concesión entrega una dirección, nada más |
| `client-updates` / `deny client-updates` | ⛔ | Depends on DDNS plus the client FQDN option, neither implemented | Depende de DDNS y de la opción FQDN del cliente, ninguna implementada |

### Directives

| isc-dhcp-server | pydhcp | Description | Descripción |
|---|---|---|---|
| `authoritative;` | ✅ | pydhcpd's default, accepted for compatibility | Es el valor por defecto de pydhcpd, se acepta por compatibilidad |
| `not authoritative;` | ✅ | The only way to disable authoritative mode | Única forma de desactivar el modo autoritativo |
| `server-identifier IP;` | ✅ | Mandatory: the daemon refuses to start without it | Obligatoria: el demonio no arranca sin ella |
| `cleanup-interval N;` | ✅ | Seconds between expired-lease sweeps | Segundos entre barridos de concesiones expiradas |
| `abandon-lease-time N;` | ✅ | Seconds an IP is held out of the pool after a DHCPDECLINE | Segundos que una IP queda fuera del pool tras un DHCPDECLINE |
| `deny duplicates;` | ✅ | Re-offers the MAC's existing lease on DISCOVER | Reofrece la concesión existente de la MAC en el DISCOVER |
| `deny declines;` | ✅ | Ignores DHCPDECLINE messages | Ignora mensajes DHCPDECLINE |
| `ping-check true\|false;` | ✅ | Enabled by default in the shipped config, unlike isc | Activado por defecto en la configuración que se entrega, al revés que isc |
| `ping-timeout N;` | ✅ | Seconds to wait for the ICMP reply before sending the OFFER | Segundos de espera de la respuesta ICMP antes de enviar el OFFER |
| `subnet ... { pool { ... } }` | ✅ | Several `pool { }` blocks per subnet are accepted | Se aceptan varios bloques `pool { }` por subred |
| `host NAME { hardware ethernet MAC; fixed-address IP; }` | ✅ | `fixed-address` validated at config load and on `SIGHUP` | `fixed-address` se valida al cargar la configuración y en cada `SIGHUP` |
| `class` / `subclass` / `deny members of` | ✅ | Any class name is accepted, not just `blockdhcp` | Se acepta cualquier nombre de clase, no solo `blockdhcp` |
| `allow\|deny unknown-clients`, `known-clients` | ✅ | Pool-level admission rules | Reglas de admisión a nivel de pool |
| `min-lease-time`, `default-lease-time`, `max-lease-time` | ✅ | Validated together (`0 < min <= default <= max`), at subnet and pool level | Se validan en conjunto (`0 < min <= default <= max`), a nivel de subred y de pool |
| `option routers` | ⚠️ | Accepts a comma-separated list but uses only the first address; the rest are ignored with a notice. No failover between routers | Acepta lista separada por comas pero usa solo la primera dirección; el resto se ignora con aviso. No hay conmutación entre routers |
| `option broadcast-address` | ✅ | Served as option 28 | Se entrega como opción 28 |
| `option domain-name-servers` | ✅ | Comma-separated list, all served | Lista separada por comas, se entregan todas |
| `option wpad ...;` | ✅ | Option 252, gated by `WPAD_ENABLED` in `pydhcp.env` | Opción 252, condicionada por `WPAD_ENABLED` en `pydhcp.env` |
| `one-lease-per-client` | ⚠️ | Always enforced, never declared: a MAC never holds more than one pool lease | Siempre aplicado, nunca declarado: una MAC nunca tiene más de una concesión del pool |
| `option domain-name` | ⛔ | Option 15, the DNS search domain. Validating it would mean resolving a name at config load, which this daemon never does, and a search domain often has no record of its own | Opción 15, el dominio de búsqueda DNS. Validarla exigiría resolver un nombre al cargar la configuración, cosa que este demonio nunca hace, y un dominio de búsqueda a menudo no tiene registro propio |
| `option subnet-mask` override | ⛔ | The netmask sent always matches the `subnet ... netmask ...` declaration | La máscara enviada siempre coincide con la declaración `subnet ... netmask ...` |
| Per-host / per-class option scoping | ⛔ | Options declared at `subnet` level apply to every client uniformly | Las opciones declaradas a nivel `subnet` aplican a todos los clientes por igual |

### Files and paths

| isc-dhcp-server | pydhcp | Description | Descripción |
|---|---|---|---|
| `/etc/dhcp/dhcpd.conf` | `/etc/pydhcp/core/pydhcpd.conf` | Same syntax | Misma sintaxis |
| `/var/lib/dhcp/dhcpd.leases` | `/etc/pydhcp/core/pydhcpd.leases` | Same format | Mismo formato |
| `/etc/default/isc-dhcp-server` | `/etc/pydhcp/pydhcp.env` | Bootstrap values, plus pydhcp's own extras | Valores de arranque, más los extras propios de pydhcp |
| `/run/dhcp-server/dhcpd.pid` | `/run/pydhcp/pydhcpd.pid` | Fixed path, not configurable | Ruta fija, no configurable |
| `/etc/systemd/system/isc-dhcp-server.service` | `/etc/systemd/system/pydhcpd.service` | pydhcp starts already unprivileged (`User=pydhcpd`); isc starts as root and drops privileges itself | pydhcp arranca ya sin privilegios (`User=pydhcpd`); isc arranca como root y baja de privilegios él mismo |
| `/etc/init.d/isc-dhcp-server` | `/etc/init.d/pydhcpd` | Compatible wrapper | Wrapper compatible |
| `/var/log/syslog` | `/var/log/pydhcp.log` | Writes directly to file, does not use syslog, so no `log-facility` directive is needed | Escribe directamente al archivo, no usa syslog, así que no hace falta la directiva `log-facility` |
| `/etc/logrotate.d/rsyslog` | `/etc/logrotate.d/pydhcp` | Daily, one config for the whole project | Diaria, una sola configuración para todo el proyecto |
| `journalctl -u isc-dhcp-server` | `journalctl -u pydhcpd` | Both also reach journald through systemd | Ambos llegan además a journald a través de systemd |

### Commands

| isc-dhcp-server | pydhcp | Description | Descripción |
|---|---|---|---|
| `systemctl start\|stop\|restart\|status isc-dhcp-server` | `systemctl start\|stop\|restart\|status pydhcpd` | Same verbs, same behaviour | Mismos verbos, mismo comportamiento |
| `service isc-dhcp-server start\|stop\|restart\|status` | `service pydhcpd start\|stop\|restart\|status` | Goes through the `init.d` wrapper, which delegates to `systemctl` when systemd is the active init | Pasa por el wrapper de `init.d`, que delega en `systemctl` cuando systemd es el init activo |
| `dhcpd -t -cf /etc/dhcp/dhcpd.conf` | `pydhcpd.py -t -cf /etc/pydhcp/core/pydhcpd.conf` | Config syntax test | Prueba de sintaxis de la configuración |

### Log output

| isc-dhcp-server | pydhcp | Description | Descripción |
|---|---|---|---|
| `DHCPREQUEST for 192.168.0.50 (192.168.0.2) from aa:bb:cc:dd:ee:ff via enpXsX`<br>`DHCPACK on 192.168.0.50 to aa:bb:cc:dd:ee:ff (FOO) via enpXsX` | `REQUEST from aa:bb:cc:dd:ee:ff (FOO)`<br>`ACK aa:bb:cc:dd:ee:ff → 192.168.0.50`<br>`(lease 2592000s)` | Authorized client with static IP (renewal) | Cliente autorizado con IP estática (renovación) |
| `DHCPDISCOVER from bb:cc:dd:ee:ff:aa via enpXsX`<br>`DHCPOFFER on 192.168.0.230 to bb:cc:dd:ee:ff:aa (BAR) via enpXsX`<br>`DHCPREQUEST for 192.168.0.230 (192.168.0.2) from bb:cc:dd:ee:ff:aa (BAR) via enpXsX`<br>`DHCPACK on 192.168.0.230 to bb:cc:dd:ee:ff:aa (BAR) via enpXsX` | `DISCOVER from bb:cc:dd:ee:ff:aa (BAR)`<br>`OFFER bb:cc:dd:ee:ff:aa → 192.168.0.230`<br>`REQUEST from bb:cc:dd:ee:ff:aa (BAR)`<br>`ACK bb:cc:dd:ee:ff:aa → 192.168.0.230`<br>`(lease 60s)` | Unknown client entering the block pool | Cliente desconocido ingresando al pool de bloqueo |
| `DHCPDISCOVER from bb:cc:dd:ee:ff:aa via enpXsX: network 192.168.0.0/24: no free leases` | `DISCOVER from bb:cc:dd:ee:ff:aa (BAR)`<br>`No IP for bb:cc:dd:ee:ff:aa -- skip` | Pool exhausted | Pool agotado |
| `DHCPDISCOVER from bb:cc:dd:ee:ff:aa via enpXsX: network 192.168.0.0/24: no free leases` | `DISCOVER from bb:cc:dd:ee:ff:aa (BAR)`<br>`Blocked bb:cc:dd:ee:ff:aa -- skip` | Blocked client — `isc-dhcp-server` reports it as a full pool | Cliente bloqueado — `isc-dhcp-server` lo reporta como pool lleno |

> A pool with `deny members of "blockdhcp"` becomes invisible to that class, so `isc-dhcp-server` sees no lease available and logs the same message as a genuinely full pool. `pydhcpd` logs the real cause: `Blocked` or `No IP`.
>
> Un pool con `deny members of "blockdhcp"` se vuelve invisible para esa clase, así que `isc-dhcp-server` no ve ninguna concesión disponible y escribe el mismo mensaje que un pool genuinamente lleno. `pydhcpd` registra la causa real: `Blocked` o `No IP`.

### Authoritative behaviour

---

| Configuration | isc-dhcp-server | pydhcpd | Description | Descripción |
|---|---|---|---|---|
| `authoritative;` present | authoritative | authoritative | ✅ same. In pydhcpd it is already the default, so the line changes nothing | ✅ igual. En pydhcpd ya es el valor por defecto, así que la línea no cambia nada |
| `not authoritative;` present | non-authoritative | non-authoritative | ✅ same syntax, same result | ✅ misma sintaxis, mismo resultado |
| **neither directive present** | non-authoritative | **authoritative** | ⚠️ **The only divergence.** A DHCP server that owns its LAN should defend it unless told otherwise | ⚠️ **La única divergencia.** Un servidor DHCP dueño de su LAN debería defenderla salvo que se le indique lo contrario |

> **Migrating from isc-dhcp-server:** if your `dhcpd.conf` did not carry `authoritative;` and you relied on that, add `not authoritative;` explicitly to keep the old behavior. Everyone else needs to change nothing.
>
> **Migrando desde isc-dhcp-server:** si su `dhcpd.conf` no llevaba `authoritative;` y usted dependía de eso, agregue `not authoritative;` de forma explícita para conservar el comportamiento anterior. Los demás no necesitan cambiar nada.

| Event | isc-dhcp-server (as authoritative) | pydhcpd (as authoritative) |
|-------|-------------------------------------|-----------------------------|
| Rogue offers IP to client | *(not observed)* † | *(not observed)* † |
| Client requests rogue IP | `DHCPREQUEST for 192.168.0.222 (192.168.0.249) from bb:cc:dd:ee:ff:aa (BAR) via enpXsX` | `REQUEST from bb:cc:dd:ee:ff:aa (BAR)` |
| Rogue acknowledges | *(not observed)* † | *(not observed)* † |
| **Authoritative server rejects** | `DHCPNAK on 192.168.0.222 to bb:cc:dd:ee:ff:aa via enpXsX` | `NAK → bb:cc:dd:ee:ff:aa`<br>`(Not authorized for this IP)` |
| Client rediscovers | `DHCPDISCOVER from bb:cc:dd:ee:ff:aa via enpXsX` | `DISCOVER from bb:cc:dd:ee:ff:aa (BAR)` |

> † Neither daemon sees these packets: `DHCPOFFER`/`DHCPACK` are addressed to the client, not to other DHCP servers on the segment.
>
> † Ninguno de los dos demonios ve esos paquetes: `DHCPOFFER`/`DHCPACK` van dirigidos al cliente, no a otros servidores DHCP del segmento.

### Rate limiting

| isc-dhcp-server | pydhcpd |
|---|---|
| Has no built-in per-client rate-limiting for lease allocation. Abuse mitigation relies on `deny duplicates;`, plus pool exhaustion (once the pool is full, further `DHCPDISCOVER` messages simply receive no `DHCPOFFER`). Client identification is based on `chaddr` (or `client-id`, option 61) — never on the Ethernet source MAC of the frame, so behavior is identical whether the client is directly attached or behind a relay (`giaddr` is only used for routing the reply).<br><br>No tiene rate-limiting incorporado por cliente para la asignación de leases. La mitigación de abuso depende de `deny duplicates;`, además del agotamiento del pool (una vez lleno, los `DHCPDISCOVER` simplemente no reciben `DHCPOFFER`). La identificación del cliente se basa en `chaddr` (o `client-id`, opción 61) — nunca en la MAC Ethernet origen del frame, por lo que el comportamiento es igual si el cliente está conectado directamente o detrás de un relay (`giaddr` solo se usa para enrutar la respuesta). | Adds a sliding-window rate limit on lease allocation, keyed by **client MAC (`chaddr`)** — the same identifier isc-dhcp-server uses. Each client MAC has its own bucket, so multiple clients behind the same relay are rate-limited independently and do not affect each other. If a single MAC exceeds the allowed number of allocations within the window, further requests are rejected with reason `"rate limited"` until the window slides forward. This is purely an internal safeguard against allocation storms; it is not configurable via `pydhcpd.conf` and has no equivalent directive in isc-dhcp-server.<br><br>Agrega un límite de tasa (sliding window) sobre la asignación de leases, indexado por **MAC del cliente (`chaddr`)** — el mismo identificador que usa isc-dhcp-server. Cada MAC de cliente tiene su propio cupo, de modo que varios clientes detrás del mismo relay se limitan de forma independiente y no se afectan entre sí. Si una MAC supera el número de asignaciones permitidas dentro de la ventana, las solicitudes adicionales se rechazan con la razón `"rate limited"` hasta que la ventana avance. Esto es solo una salvaguarda interna contra ráfagas de asignación; no es configurable desde `pydhcpd.conf` y no tiene directiva equivalente en isc-dhcp-server.<br><br>Note that, unlike isc-dhcp-server, pydhcpd does look at the Ethernet source MAC — not to identify the client, but as a drop filter: a non-relayed packet whose `chaddr` does not match it is discarded (see Scope).<br><br>A diferencia de isc-dhcp-server, pydhcpd sí mira la MAC Ethernet origen — no para identificar al cliente, sino como filtro de descarte: un paquete no relayado cuyo `chaddr` no coincida con ella se descarta (ver Scope). |

> **known limitation, both servers:** neither controls an attacker who rotates MAC addresses to exhaust the pool. `isc-dhcp-server`'s gap is total — it has no per-client throttle at all, so a plain flood from a single MAC already drains the pool, no rotation needed. `pydhcpd`'s gap is narrower: its per-MAC limit stops a single-MAC flood, but is keyed by MAC (`chaddr`), so it only bounds how fast *one* MAC can allocate — it does not cap the total across many different MACs, and an attacker rotating MACs can still drain the pool one new MAC at a time. A global (cross-MAC) rate limit was considered and intentionally left out of `pydhcpd`: it would need careful tuning to avoid rejecting legitimate clients during a normal burst of reconnections (e.g. many devices rejoining after a power outage), and there is no evidence MAC-rotation abuse is a live threat worth that trade-off. Documented here as a known, accepted limitation.
>
> **limitación conocida, en ambos servidores:** ninguno controla a un atacante que rota direcciones MAC para agotar el pool. La brecha de `isc-dhcp-server` es total — no tiene ningún control por cliente, así que una inundación simple desde una sola MAC ya agota el pool, sin necesidad de rotar. La brecha de `pydhcpd` es más acotada: su límite por MAC frena la inundación de una sola MAC, pero está indexado por MAC (`chaddr`), así que solo acota qué tan rápido puede asignar *una* MAC — no limita el total entre muchas MACs distintas, y un atacante que rote MACs igual puede vaciar el pool, una MAC nueva a la vez. Se evaluó un límite global (entre todas las MACs) para `pydhcpd` y se dejó afuera intencionalmente: requeriría un ajuste cuidadoso para no rechazar clientes legítimos durante una ráfaga normal de reconexiones (p.ej. varios dispositivos reconectándose tras un corte de luz), y no hay evidencia de que el abuso por rotación de MAC sea una amenaza activa que justifique ese costo. Se documenta acá como una limitación conocida y aceptada.

### Pool leases per client

| isc-dhcp-server | pydhcpd |
|---|---|
| Does not limit how many pool IPs a single MAC can accumulate | Always limits a MAC to a single pool IP at a time; fixed daemon behavior, not a configurable directive |
| No tiene restricción sobre cuántas IPs del pool puede acumular una MAC | Siempre limita a una MAC a una sola IP del pool a la vez; comportamiento fijo del demonio, no es una directiva configurable |

### WPAD/PAC option scoping

| isc-dhcp-server | pydhcpd |
|---|---|
| Supports scoping any option — including `option wpad` (252) — at multiple levels: `subnet`, `class`/`subclass`, or an individual `host`. A more specific scope overrides a broader one, so an admin can declare WPAD at the `subnet` level for every client and then override or omit it for a specific `class` or `host` (e.g. exclude a group of trusted/unrestricted devices from the PAC).<br><br>Soporta el alcance de cualquier opción — incluyendo `option wpad` (252) — en varios niveles: `subnet`, `class`/`subclass`, o un `host` individual. Un alcance más específico sobreescribe uno más amplio, así que un administrador puede declarar WPAD a nivel `subnet` para todos los clientes y luego sobreescribirlo u omitirlo para una `class` o `host` específico (ej. excluir a un grupo de dispositivos confiables/sin restricción del PAC). | Has no option-scoping mechanism at all — `config.wpad_url` is a single global value read once from the `subnet` block, applied identically to every `OFFER`/`ACK`/`INFORM` it sends. `WPAD_ENABLED` in `pydhcp.env` is therefore all-or-nothing: on turns WPAD on for every client, off turns it off for every client. The existing `class "blockdhcp"`/`subclass` mechanism does not generalize to this — it only marks MACs for lease denial, not a scoping construct for arbitrary options like isc-dhcp-server's classes.<br><br>No tiene ningún mecanismo de alcance de opciones — `config.wpad_url` es un único valor global leído una vez del bloque `subnet`, aplicado igual a cada `OFFER`/`ACK`/`INFORM` que envía. `WPAD_ENABLED` en `pydhcp.env` es entonces todo-o-nada: activado prende WPAD para todos los clientes, desactivado lo apaga para todos. El mecanismo existente de `class "blockdhcp"`/`subclass` no generaliza a este caso — solo marca MACs para negarles el lease, no un constructo de alcance para opciones arbitrarias como sí lo son las clases de isc-dhcp-server. |

> **Workaround (external to pydhcp):** if `WPAD_ENABLED=true` and some MACs must never see the PAC, block their access to the PAC's port (e.g. 18100) at the firewall. This does not stop `pydhcpd` from sending option 252 to them, but the client can never fetch the PAC file, and the PAC's own `DIRECT` fallback lets it proceed without a proxy. This is a firewall-side workaround, not a `pydhcp` feature — `pydhcp` has no firewall component and does not ship or manage this rule itself.
>
> **Workaround (externo a pydhcp):** si `WPAD_ENABLED=true` y algunas MACs nunca deben ver el PAC, bloquee su acceso al puerto del PAC (ej. 18100) en el firewall. Esto no evita que `pydhcpd` les mande la opción 252, pero el cliente nunca podrá descargar el archivo PAC, y el fallback `DIRECT` del propio PAC le permite seguir sin proxy. Este es un workaround del lado del firewall, no una funcionalidad de `pydhcp` — `pydhcp` no tiene componente de firewall y no provee ni gestiona esa regla.

### Improvements over isc-dhcp-server

| isc-dhcp-server | pydhcp | Description | Descripción |
|---|---|---|---|
| ⛔ | ✅ | Per-MAC allocation rate limit: 5 allocations per minute per MAC | Límite de asignación por MAC: 5 asignaciones por minuto y por MAC |
| ⛔ | ✅ | DISCOVER reservations: a DISCOVER earns a 30s in-memory reservation, never a full lease, so a flood cannot hold pool IPs | Reservas por DISCOVER: un DISCOVER obtiene una reserva en memoria de 30s, nunca una concesión completa, así que una inundación no puede retener IPs del pool |
| ⛔ | ✅ | Corrupt lease cleanup at startup: malformed entries are removed from the leases file | Limpieza de concesiones corruptas al arrancar: las entradas malformadas se eliminan del archivo |
| ⛔ | ✅ | ACL automation: `pyleases.sh` rebuilds `pydhcpd.conf` from MAC lists | Automatización de ACL: `pyleases.sh` reconstruye `pydhcpd.conf` desde listas de MAC |

## REPOSITORY STRUCTURE

---

```
pydhcp/
├── acl/
│   └── blockdhcp.txt       # MAC addresses blocked from getting a DHCP lease
│
├── core/
│   ├── pydhcpd.py          # DHCP daemon: handles DISCOVER/OFFER/REQUEST/ACK
│   ├── pydhcpd.conf        # Daemon config: hosts, pools, lease timers
│
├── init.d/
│   └── pydhcpd             # init.d-style start/stop/status wrapper around the systemd service
│
├── service/
│   └── pydhcpd.service     # systemd unit that runs the daemon
│
├── tools/
│   ├── bkstack.sh          # Backs up pydhcp and uhm configuration and data (see Tools section)
│   ├── pyleases.sh         # Rebuilds pydhcpd.conf from ACL files and manages leases (see Tools section)
│   └── pywebmin.sh         # Installs the Webmin module for managing pydhcpd from the browser (see Tools section)
└── pysetup.sh          # Installs, updates or removes pydhcp
```

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      Files generated at runtime (not included in the repository):
    </td>
    <td style="width: 50%; vertical-align: top;">
      Archivos generados en runtime (no incluidos en el repositorio):
    </td>
  </tr>
</table>

```
/etc/pydhcp/core/pydhcpd.leases                  # Active leases database
/run/pydhcp/pydhcpd.pid                          # PID file, written by the daemon
                                                 # (systemd creates the directory)
/etc/pydhcp/bak/pydhcp.env.<TIMESTAMP>           # pydhcp.env backup by pyleases.sh before adding keys, up to 3 kept
/etc/bak/bkstack_<TIMESTAMP>.zip                 # Full backup written by tools/bkstack.sh
/etc/pydhcp/bak/webmin/pydhcpd.conf.<TIMESTAMP>  # Up to 3 kept, written by the Webmin module (pywebmin.sh) on each save
/etc/webmin/pydhcp/.csrf_token                   # CSRF secret for the Webmin module (pywebmin.sh), mode 0600
```

## HOW TO USE

---

### Install

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      Clone the repository and run the installer to deploy all files to their correct system paths:
    </td>
    <td style="width: 50%; vertical-align: top;">
      Clona el repositorio y ejecuta el instalador para desplegar todos los archivos en sus rutas de sistema correctas:
    </td>
  </tr>
</table>

```bash
git clone --depth=1 https://github.com/maravento/pydhcp.git
cd pydhcp
sudo bash pysetup.sh
```

### Update & Remove

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      To update or remove pydhcp, download the updated repository, enter the repository folder and run:
    </td>
    <td style="width: 50%; vertical-align: top;">
      Para actualizar o eliminar pydhcp, descargar el repositorio actualizado, ingresar a la carpeta del repositorio y ejecutar:
    </td>
  </tr>
</table>

```bash
cd pydhcp
sudo bash pysetup.sh --update
# or
sudo bash pysetup.sh --remove
```

| File | `--update` | `--remove` |
|------|-----------|------------|
| `pydhcpd.py` | ✅ overwritten | ✅ removed |
| `pydhcpd.service` | ✅ overwritten | ✅ removed |
| `init.d/pydhcpd` | ✅ overwritten | ✅ removed |
| `tools/bkstack.sh` | ✅ overwritten | ✅ removed (its cron entry is deregistered first) |
| `tools/pyleases.sh` | ✅ overwritten | ✅ removed |
| `tools/pywebmin.sh` | ✅ overwritten | ✅ removed (also uninstalls the Webmin module, if installed) |
| `pydhcpd.conf` | ⛔ preserved | ✅ removed |
| `pydhcpd.leases` | ⛔ preserved | ✅ removed |
| `pydhcp.env` | ⛔ preserved | ✅ removed |
| `/var/log/pydhcp.log` (shared by the daemon, `pysetup.sh` and `tools/pyleases.sh`) | ⛔ preserved | ✅ removed |
| `/etc/logrotate.d/pydhcp` | ⛔ preserved | ✅ removed |
| system user/group `pydhcpd` | ⛔ preserved | ✅ removed |
| `acl/blockdhcp.txt` (pydhcp's own block list) | ⛔ preserved | ✅ removed |
| `bak/` (copies written by `tools/pyleases.sh` and the Webmin module) | ⛔ preserved | ⛔ preserved |
| `/etc/acl/mac/` (administrator's own ACL lists) | ⛔ preserved | ⛔ preserved |

> `/etc/acl` is never touched by `--remove`. It holds the administrator's own `mac-*.txt` lists, edited by hand, which `pydhcp` may or may not use depending on whether the optional `tools/pyleases.sh` tool is ever run — `pysetup.sh` creates the directory regardless, so uninstalling the daemon does not assume that data is safe to discard.
>
> `/etc/acl` nunca se toca en `--remove`. Contiene las listas `mac-*.txt` propias del administrador, editadas a mano, que `pydhcp` puede o no usar según si la herramienta opcional `tools/pyleases.sh` llega a ejecutarse — `pysetup.sh` crea el directorio de todos modos, así que desinstalar el demonio no asume que esos datos sean seguros de descartar.

> `blockdhcp.txt` is a different case: it is `pydhcp`'s own list, written by `pyleases.sh` alone and never edited by hand, so it lives under `/etc/pydhcp/acl/` — the same arrangement `uhm` uses for its own lists under `/etc/uhm/acl/`. `--remove` deletes it along with the rest of `/etc/pydhcp`; run `tools/bkstack.sh` first if you want a copy.
>
> `blockdhcp.txt` es un caso distinto: es la lista propia de `pydhcp`, escrita solo por `pyleases.sh` y nunca editada a mano, así que vive bajo `/etc/pydhcp/acl/` — la misma disposición que usa `uhm` para sus propias listas bajo `/etc/uhm/acl/`. `--remove` la borra junto con el resto de `/etc/pydhcp`; ejecute `tools/bkstack.sh` antes si quiere una copia.

### Daily operation

---

```bash
# Edit main config | Editar configuración principal
sudo nano /etc/pydhcp/core/pydhcpd.conf

# Restart service | Reiniciar servicio
sudo systemctl restart pydhcpd

# Check status | Verificar estado
sudo systemctl status pydhcpd
# ● pydhcpd.service - pydhcpd - Python DHCP Daemon
#      Loaded: loaded (/etc/systemd/system/pydhcpd.service; enabled; preset: enabled)
#      Active: active (running) since Tue 2026-06-09 17:51:49 -05; 17s ago
#        Docs: https://github.com/maravento/pydhcp
#    Main PID: 2356158 (python3)
#       Tasks: 3 (limit: 76240)
#      Memory: 11.0M (peak: 11.6M)
#         CPU: 331ms
#      CGroup: /system.slice/pydhcpd.service
#              └─2356158 /usr/bin/python3 /etc/pydhcp/core/pydhcpd.py
# jun 09 17:51:49 host systemd[1]: Started pydhcpd.service - pydhcpd - Python DHCP Daemon.
# jun 09 17:51:49 host python3[1411247]: 2026-06-09 17:51:49,068 INFO: Attached BPF filter to raw socket (dst port 67)
# jun 09 17:51:49 host python3[1449863]: 2026-06-09 16:20:31,317 INFO: Config loaded: 158 hosts, 208 blocked
# jun 09 17:51:49 host python3[1449863]: 2026-06-09 16:20:31,323 INFO: Leases loaded: 2 entries
# jun 09 17:51:49 host python3[1411247]: 2026-06-09 17:51:49,068 INFO: Listening on enpXsX (DHCP port 67)

# Other entries...
# jun 09 17:51:49 host python3[2356158]: 2026-06-09 17:51:49,071 INFO: pydhcpd started (pid 2356158)
# jun 09 17:51:49 host python3[2356158]: 2026-06-09 17:51:49,071 INFO: interface enpXsX
# jun 09 17:51:49 host python3[2356158]: 2026-06-09 17:51:49,072 INFO: Listening on enpXsX (DHCP port 67)
# jun 09 17:51:52 host python3[2356158]: 2026-06-09 17:51:52,316 INFO: DISCOVER from aa:bb:cc:dd:ee:ff (FooBar)
# jun 09 17:51:52 host python3[2356158]: 2026-06-09 17:51:52,316 INFO: Blocked aa:bb:cc:dd:ee:ff -- skip
# jun 09 17:52:02 host python3[2356158]: 2026-06-09 17:52:02,086 INFO: DISCOVER from bb:cc:dd:ee:ff:aa (<no hostname>)
# jun 09 17:52:02 host python3[2356158]: 2026-06-09 17:52:02,154 INFO: OFFER bb:cc:dd:ee:ff:aa → 192.168.0.231
# jun 09 17:52:02 host python3[2356158]: 2026-06-09 17:52:02,264 INFO: REQUEST from bb:cc:dd:ee:ff:aa (<no hostname>)
# jun 09 17:52:02 host python3[2356158]: 2026-06-09 17:52:02,283 INFO: ACK bb:cc:dd:ee:ff:aa → 192.168.0.231
# jun 09 17:52:02 host python3[2356158]: 2026-06-09 17:52:02,283 INFO: (lease 60s)
# jun 09 17:52:15 host python3[2356158]: 2026-06-09 17:52:15,391 INFO: DISCOVER from cc:dd:ee:ff:aa:bb (BazHost)
# jun 09 17:52:15 host python3[2356158]: 2026-06-09 17:52:15,391 INFO: No IP for cc:dd:ee:ff:aa:bb -- skip
# jun 09 17:53:02 host python3[2356158]: 2026-06-09 17:53:02,173 INFO: Lease expired: 192.168.0.230

# View active leases | Ver concesiones activas
cat /etc/pydhcp/core/pydhcpd.leases

# Reload config without restart (SIGHUP) | Recargar configuración sin reiniciar (SIGHUP)
sudo systemctl reload pydhcpd

# Test configuration syntax without starting the daemon (-t [-cf FILE])
sudo /etc/pydhcp/core/pydhcpd.py --test
sudo /etc/pydhcp/core/pydhcpd.py -t -cf /path/to/alternate.conf

# View logs (journald) | Ver logs (journald)
sudo journalctl -u pydhcpd -f

# View logs (file) | Ver logs (archivo)
sudo tail -f /var/log/pydhcp.log
```

### Config

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      The installer configures the interface, server IP, subnet, pool range, and DNS servers interactively. After installation, edit the configuration file only to add static host reservations or blocked MACs. Then restart the service to apply changes.
    </td>
    <td style="width: 50%; vertical-align: top;">
      El instalador configura la interfaz, IP del servidor, subred, rango del pool y servidores DNS de forma interactiva. Tras la instalación, edita el archivo de configuración solo para agregar reservas estáticas o MACs bloqueadas. Luego reinicia el servicio para aplicar los cambios.
    </td>
  </tr>
</table>

| File | Description | Descripción |
|-------------|-------------|------|
| `/etc/pydhcp/core/pydhcpd.conf` | Main configuration file | Archivo de configuración principal |
| `/etc/pydhcp/core/pydhcpd.leases` | Active leases database | Base de datos de concesiones activas |
| `/etc/pydhcp/pydhcp.env` | Shared config: daemon defaults (config/pid/leases paths, interface, user/group), network values, ACL paths, lease timers and WPAD/ping-check flags — all generated by `pysetup.sh` at install time; `tools/pyleases.sh` only adds any of these that are still missing (e.g. after an update from an older `pysetup.sh`) | Configuración compartida: defaults del demonio (rutas de config/pid/leases, interfaz, usuario/grupo), valores de red, rutas ACL, temporizadores de lease y flags de WPAD/ping-check — todos generados por `pysetup.sh` durante la instalación; `tools/pyleases.sh` solo agrega los que falten (p.ej. tras una actualización desde un `pysetup.sh` anterior) |
| `/etc/systemd/system/pydhcpd.service` | systemd unit | Unidad systemd |
| `/etc/init.d/pydhcpd` | init.d wrapper | Wrapper init.d |

#### pydhcp.env — daemon bootstrap

<table width="100%">
  <tr>
    <td style="width: 50%; vertical-align: top;">
      <code>pydhcp.env</code> holds only bootstrap values -- paths, the interface, and the daemon's user/group -- read once by <code>pydhcpd.py</code> at startup. Every lease timer, <code>ping-check</code>, <code>ping-timeout</code>, <code>abandon-lease-time</code>, WPAD and static host/block-list entry is a <code>pydhcpd.conf</code> directive, never a <code>pydhcp.env</code> key.
    </td>
    <td style="width: 50%; vertical-align: top;">
      <code>pydhcp.env</code> contiene solo valores de arranque -- rutas, la interfaz y el usuario/grupo del demonio -- que <code>pydhcpd.py</code> lee una vez al iniciar. Todo temporizador de concesión, <code>ping-check</code>, <code>ping-timeout</code>, <code>abandon-lease-time</code>, WPAD y entrada de host estático o de lista de bloqueo es una directiva de <code>pydhcpd.conf</code>, nunca una clave de <code>pydhcp.env</code>.
    </td>
  </tr>
</table>

| Variable | Description | Descripción |
|----------|--------------|-------------|
| `INTERFACESv4` | Interface `pydhcpd.py` listens on | Interfaz en la que escucha `pydhcpd.py` |
| `DAEMON_USER`, `DAEMON_GROUP` | Owner the daemon sets on the leases file it rewrites. The process itself is started already unprivileged by `pydhcpd.service`, so it never drops privileges | Propietario que el demonio pone al archivo de concesiones que reescribe. El proceso lo arranca ya sin privilegios `pydhcpd.service`, así que nunca baja de privilegios |
| `DHCPDv4_CONF` | Path to `pydhcpd.conf`, read at startup and on `SIGHUP`/`reload` | Ruta a `pydhcpd.conf`, leída al arrancar y en `SIGHUP`/`reload` |
| `DHCPDv4_BIN`, `DHCPDv4_SCRIPT` | Python interpreter and daemon script path, used by `init.d/pydhcpd` and `pywebmin.sh` to invoke `pydhcpd.py` for config tests | Intérprete Python y ruta del script del demonio, usados por `init.d/pydhcpd` y `pywebmin.sh` para invocar `pydhcpd.py` en las pruebas de configuración |
| `PYDHCPD_LEASES` | Leases database path | Ruta de la base de datos de leases |

#### pydhcp.env — pydhcp-only extras

<table width="100%">
  <tr>
    <td style="width: 50%; vertical-align: top;">
      A second, distinct group in <code>pydhcp.env</code>: features with no <code>pydhcpd.conf</code> directive behind them, so there is nothing to keep in sync with a <code>pydhcpd.conf</code> template -- <code>pydhcpd.py</code> reads them directly from <code>pydhcp.env</code> at startup, the same way it reads the bootstrap group above. <code>pyleases.sh</code> never touches these; they only build <code>pydhcpd.conf</code>, and these values aren't <code>pydhcpd.conf</code> directives.
    </td>
    <td style="width: 50%; vertical-align: top;">
      Un segundo grupo, distinto del anterior, dentro de <code>pydhcp.env</code>: funciones que no tienen detrás una directiva de <code>pydhcpd.conf</code>, así que no hay nada que mantener sincronizado con una plantilla. <code>pydhcpd.py</code> las lee directamente de <code>pydhcp.env</code> al arrancar, igual que el grupo de arranque de arriba. <code>pyleases.sh</code> nunca las toca: solo construye <code>pydhcpd.conf</code>, y estos valores no son directivas de ese archivo.
    </td>
  </tr>
</table>

| Variable | Description | Descripción |
|----------|--------------|-------------|
| `PING_CACHE_TTL_SECONDS` | Seconds a `ping-check` result (alive/dead) is cached before re-checking the same IP; default `120` | Segundos que se cachea el resultado de un `ping-check` (viva/muerta) antes de re-verificar la misma IP; default `120` |
| `RATE_LIMIT_WINDOW_SECONDS`, `RATE_LIMIT_MAX` | Anti-abuse throttle: at most `RATE_LIMIT_MAX` new lease allocations per MAC within `RATE_LIMIT_WINDOW_SECONDS`, to limit pool exhaustion by an attacker rotating MACs; defaults `60`/`5` | Freno anti-abuso: como máximo `RATE_LIMIT_MAX` asignaciones de lease nuevas por MAC dentro de `RATE_LIMIT_WINDOW_SECONDS`, para limitar el agotamiento del pool por un atacante rotando MACs; defaults `60`/`5` |
| `RESERVATION_TTL_SECONDS` | Seconds a DISCOVER-only provisional reservation holds an IP before expiring, if no matching REQUEST follows; default `30` | Segundos que una reserva provisional de un DISCOVER retiene una IP antes de expirar, si no llega el REQUEST correspondiente; default `30` |

All four values above must be at least `1`. A value below `1` (for example `RATE_LIMIT_MAX=0`, which does not mean "unlimited") is rejected with a `WARNING` in the log and the default is used instead.

Los cuatro valores anteriores deben ser como mínimo `1`. Un valor menor que `1` (por ejemplo `RATE_LIMIT_MAX=0`, que no significa "sin límite") se rechaza con un `WARNING` en el log y en su lugar se usa el valor por defecto.

#### pydhcp.env — pyleases.sh automation input (mirrors dhcpd.conf directives)

<table width="100%">
  <tr>
    <td style="width: 50%; vertical-align: top;">
      A third group in <code>pydhcp.env</code>, distinct from the two above: input values for <code>pyleases.sh</code>'s optional automation layer. Unlike the bootstrap group, <code>pydhcpd.py</code> never reads these directly — <code>pysetup.sh</code> creates them and <code>pyleases.sh</code> writes the corresponding directive into <code>pydhcpd.conf</code> on every run (see Supported directives); a bare install managed by hand never needs them. Any missing key is added by <code>pyleases.sh</code> itself, with its own built-in default, right before the file's closing <code># =====...=====</code> line — this only happens on an install that predates a given key.
    </td>
    <td style="width: 50%; vertical-align: top;">
      Un tercer grupo dentro de <code>pydhcp.env</code>, distinto de los dos anteriores: valores de entrada para la capa opcional de automatización de <code>pyleases.sh</code>. A diferencia del grupo de arranque, <code>pydhcpd.py</code> nunca los lee directamente — <code>pysetup.sh</code> los crea y <code>pyleases.sh</code> escribe la directiva correspondiente en <code>pydhcpd.conf</code> en cada ejecución; una instalación gestionada a mano nunca los necesita. Cualquier clave que falte la agrega el propio <code>pyleases.sh</code>, con su valor por defecto, justo antes de la línea de cierre <code># =====...=====</code> del archivo; eso solo ocurre en una instalación anterior a esa clave.
    </td>
  </tr>
</table>

| Variable | `pydhcpd.conf` directive it becomes | Description | Descripción |
|----------|--------------------------------------|--------------|-------------|
| `CLEANUP_INTERVAL` | `cleanup-interval` | Pool cleanup frequency in seconds; default `60` | Frecuencia de limpieza del pool en segundos; default `60` |
| `AUTHORIZED_LEASE_TIME` | subnet `min`/`default`/`max-lease-time` | Lease duration for authorized/static clients in seconds; default `2592000` (30 days) | Duración del lease para clientes autorizados/estáticos en segundos; default `2592000` (30 días) |
| `QUARANTINE_DURATION` | `abandon-lease-time` | See "IP quarantine" in Operational Details below; default `60` | Ver "IP quarantine" en Operational Details abajo; default `60` |
| `WPAD_ENABLED` | `option wpad ...;` | See WPAD/PAC via DHCP option 252 below; default `false` | Ver WPAD/PAC via DHCP option 252 abajo; default `false` |
| `WPAD_PORT` | port inside the `option wpad ...;` URL | TCP port of the Apache VirtualHost serving `wpad.pac`; default `18100`. Only asked for at install time when `apache2` is already installed and WPAD is accepted | Puerto TCP del VirtualHost de Apache que sirve `wpad.pac`; default `18100`. Solo se pregunta durante la instalación si `apache2` ya está instalado y se acepta WPAD |
| `PING_CHECK_ENABLED` | `ping-check` | See "ping-check" in Operational Details below; default `true` | Ver "ping-check" en Operational Details abajo; default `true` |
| `PING_TIMEOUT_SECONDS` | `ping-timeout` | See "ping-check" in Operational Details below; default `1` | Ver "ping-check" en Operational Details abajo; default `1` |

#### Fixed values (not configurable anywhere)

<table width="100%">
  <tr>
    <td style="width: 50%; vertical-align: top;">
      <code>pydhcp.env</code> only ever holds real, admin-adjustable values -- the two groups above, plus the bootstrap group and the <code>pyleases.sh</code> input group described earlier. A handful of internal constants in <code>pydhcpd.py</code> are deliberately **not** exposed in <code>pydhcp.env</code> (or <code>pydhcpd.conf</code>), because each is a protocol/math invariant or an internal implementation detail with no admin-meaningful range of alternatives -- not an operational choice to make:
    </td>
    <td style="width: 50%; vertical-align: top;">
      <code>pydhcp.env</code> solo contiene valores reales, ajustables por el administrador: los dos grupos de arriba, más el grupo de arranque y el de entrada de <code>pyleases.sh</code> descritos antes. Un puñado de constantes internas de <code>pydhcpd.py</code> queda deliberadamente fuera de <code>pydhcp.env</code> (y de <code>pydhcpd.conf</code>), porque cada una es un invariante del protocolo o de la aritmética, o un detalle interno de implementación sin un rango de alternativas con sentido para el administrador; no es una decisión operativa:
    </td>
  </tr>
</table>

| Value | Why it's fixed | Por qué es fijo |
|-------|-----------------|-------------------|
| Max pool/subnet size (`65536` addresses) | Fixed by IPv4 arithmetic, not a policy -- a `/16` is the largest a range can ever be | Fijado por la aritmética de IPv4, no es una política -- un `/16` es el rango más grande que puede existir |
| Max DHCP option length (`255` bytes -- WPAD URL and other option values) | Fixed by the 1-byte length field in the DHCP option format (RFC 2132); there's no larger value the protocol can even represent | Fijado por el campo de longitud de 1 byte del formato de opción DHCP (RFC 2132); no hay un valor mayor que el protocolo pueda siquiera representar |
| Allocation round-robin counter wraparound (`2**16`) | Internal iteration state with no observable effect on behavior -- changing it doesn't change what the daemon does | Estado de iteración interno sin efecto observable en el comportamiento -- cambiarlo no cambia lo que hace el demonio |
| Main-loop shutdown poll timeout (`5`s socket timeout) | Controls how fast a `systemctl stop` is noticed, not DHCP behavior (leases, OFFERs, etc.) | Controla qué tan rápido se nota un `systemctl stop`, no el comportamiento DHCP (leases, OFFERs, etc.) |

### File Ownership and Permissions

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      The daemon runs as the system account <code>pydhcpd</code>, not as root, with two kernel capabilities granted by <code>pydhcpd.service</code>: <code>CAP_NET_RAW</code> (raw socket and ICMP ping-check) and <code>CAP_NET_BIND_SERVICE</code> (bind port 67). No other capability is needed or granted. Ownership is therefore assigned by <b>what the daemon does with each file</b>, not uniformly. These values are set by <code>pysetup.sh</code> and are deliberate — the table documents the reasoning so it does not have to be re-derived. They are also enforced afterwards: on every run, <code>tools/pyleases.sh</code> checks <code>pydhcp.env</code>, <code>pydhcpd.conf</code>, <code>pydhcpd.leases</code>, the ACL lists and <code>/var/log/pydhcp.log</code>, and restores exactly these owners and modes if any of them was changed, logging a <code>WARNING</code>.
    </td>
    <td style="width: 50%; vertical-align: top;">
      El demonio corre bajo la cuenta de sistema <code>pydhcpd</code>, no como root, con dos capacidades del kernel concedidas por <code>pydhcpd.service</code>: <code>CAP_NET_RAW</code> (socket crudo y ping-check ICMP) y <code>CAP_NET_BIND_SERVICE</code> (escuchar en el puerto 67). No necesita ni recibe ninguna otra. Por eso el propietario se asigna según <b>qué hace el demonio con cada archivo</b>, no de forma uniforme. Estos valores los aplica <code>pysetup.sh</code> y son deliberados — la tabla documenta el porqué para no tener que deducirlo otra vez. También se hacen cumplir después: en cada ejecución, <code>tools/pyleases.sh</code> comprueba <code>pydhcp.env</code>, <code>pydhcpd.conf</code>, <code>pydhcpd.leases</code>, las listas ACL y <code>/var/log/pydhcp.log</code>, y restablece exactamente estos propietarios y modos si alguno fue alterado, registrando un <code>WARNING</code>.
    </td>
  </tr>
</table>

| Path | Owner | Mode | What the daemon does | Why |
|------|-------|------|----------------------|-----|
| `/etc/pydhcp` | `root:pydhcpd` | `770` | creates, renames and deletes entries | **Others get nothing** — no other account on the system can even enter the directory. Group `w` is the minimum that works: the daemon creates a temp file and `os.replace()`s it over the leases file, and creates and removes its PID file. `750` breaks all four operations. The group has exactly one member: the daemon's own service account (shell `/bin/false`, no home, no supplementary groups). **No sticky bit** — see the note below |
| `pydhcpd.py` | `root:root` | `755` | reads and executes | Root-owned so the daemon cannot modify the code it is running. `/etc/pydhcp` being `770` already blocks every other account, so the `others` bits are what the daemon reads through |
| `pydhcpd.conf` | `root:pydhcpd` | `640` | reads | Read through the group. Root-owned so a compromised daemon cannot rewrite its own configuration |
| `pydhcp.env` | `root:pydhcpd` | `640` | reads | Same as above. `640` keeps it out of reach of other users |
| `pydhcpd.leases` | `pydhcpd:pydhcpd` | `640` | replaces atomically | Daemon-owned because the daemon writes it: the atomic replace creates a new file and renames it over this one, so the result carries the writer's ownership |
| `pydhcpd.conf.bak` | `root:root` | `640` | never touches it | Single rollback copy written by `tools/pyleases.sh` before it regenerates the config, and restored automatically if the daemon then fails to start. Created with `cp`, which preserves the source's `640` |
| `bak/webmin/pydhcpd.conf.<TIMESTAMP>` | `root:root` | `640` | never touches it | Up to 3 kept by the Webmin module (`tools/pywebmin.sh`), one per save from the browser editor, so repeated saves do not overwrite the original. Perl's `File::Copy` does not preserve the source mode, so `config.cgi` applies `chmod 0640` explicitly — otherwise the backup would land at whatever root's umask dictates and end up more permissive than the config it copies |
| `/var/log/pydhcp.log` | `pydhcpd:pydhcpd` | `640` | appends | Daemon-owned so it can write. `pysetup.sh` and `tools/pyleases.sh` also write to it, but they run as root |
| `tools/` | `root:root` | `755` | never touches it | Run manually by root; not part of the daemon's runtime |
| `pydhcpd.service` | `root:root` | `644` | — | Belongs to systemd |
| `/etc/init.d/pydhcpd` | `root:root` | `755` | — | Belongs to sysvinit |
| `/etc/logrotate.d/pydhcp` | `root:root` | `644` | — | logrotate ignores configuration files not owned by root |

> **⚠️ WARNING:** Do not "unify" these into a single owner. Making everything `pydhcpd:pydhcpd` would hand the directory to the daemon, which could then replace any entry in it, including its own code. Making everything `root:pydhcpd` would break the leases and PID files, whose atomic replace and removal require ownership, and would need `CAP_FOWNER` to work around.
>
> **⚠️ WARNING:** No "unifique" esto en un solo propietario. Poner todo en `pydhcpd:pydhcpd` le entregaría el directorio al demonio, que podría entonces reemplazar cualquier entrada, incluido su propio código. Poner todo en `root:pydhcpd` rompería los archivos de concesiones y PID, cuyo reemplazo atómico y borrado exigen ser propietario, y requeriría `CAP_FOWNER` para sortearlo.

> **⚠️ WARNING:** Why `/etc/pydhcp` carries no sticky bit. A sticky bit (`1770`) would stop the daemon from deleting entries it does not own, which looks like an obvious hardening. It is not usable here: with `fs.protected_regular=2` — the default on several distributions — the kernel refuses to let **any** process, **including root**, truncate or replace a file owned by another user inside a sticky directory. That check ignores capabilities, so `CAP_DAC_OVERRIDE` does not bypass it. The lease-manager tools run as root and rewrite `pydhcpd.leases`, which is owned by the daemon: with the sticky bit set they fail with `EACCES` and the reload chain aborts. The directory is therefore `770`, matching how this project's other service directories are set up.
>
> **⚠️ WARNING:** Por qué `/etc/pydhcp` no lleva bit sticky. Un bit sticky (`1770`) impediría que el demonio borrara entradas que no le pertenecen, y parece un endurecimiento evidente. Aquí no es utilizable: con `fs.protected_regular=2` — el valor por defecto en varias distribuciones — el núcleo impide que **cualquier** proceso, **incluido root**, trunque o reemplace un archivo de otro usuario dentro de un directorio con sticky. Esa comprobación ignora las capacidades, así que `CAP_DAC_OVERRIDE` no la sortea. Las herramientas de gestión de concesiones corren como root y reescriben `pydhcpd.leases`, que pertenece al demonio: con el sticky puesto fallan con `EACCES` y la cadena de recarga se aborta. Por eso el directorio es `770`, en línea con los demás directorios de servicio de este proyecto.

```bash
# Verify ownership and permissions | Verificar propietarios y permisos
sudo ls -ld /etc/pydhcp
sudo ls -l /etc/pydhcp/ /var/log/pydhcp.log
```


### Operational details

---

| Topic | Description | Descripción |
|---|---|---|
| Entry points | `pydhcpd` can be managed through three entry points — `systemctl`, the `/etc/init.d/pydhcpd` wrapper, and `pyleases.sh` (which calls `systemctl stop`/`start` internally whenever it regenerates `pydhcpd.conf`). On a `systemd` host (the only supported environment — see Requirements), the `init.d` wrapper does not start its own process: it detects `systemd` and simply runs the equivalent `systemctl` command, so it and `systemctl` are always in sync, never two independent daemons. The only theoretical race is at the PID-file level (`write_pid()`) if the daemon were ever launched completely outside of `systemd`'s management — not a realistic path on the supported environment, but as a matter of operational hygiene: **use a single entry point at a time.** Don't run `pyleases.sh`, `systemctl`, and the `init.d` wrapper concurrently against the same instance (e.g. don't kick off `pyleases.sh` in one terminal while manually restarting via `systemctl` in another) — let one lifecycle operation finish before starting the next. | `pydhcpd` se puede administrar desde tres puntos de entrada — `systemctl`, el wrapper `/etc/init.d/pydhcpd`, y `pyleases.sh` (que llama internamente a `systemctl stop`/`start` cada vez que regenera `pydhcpd.conf`). En un host con `systemd` (el único entorno soportado — ver Requirements), el wrapper `init.d` no arranca su propio proceso: detecta `systemd` y simplemente ejecuta el `systemctl` equivalente, así que él y `systemctl` siempre están sincronizados, nunca son dos demonios independientes. La única carrera teórica ocurre a nivel del archivo PID (`write_pid()`) si el demonio se lanzara completamente por fuera de la gestión de `systemd` — no es un camino real en el entorno soportado, pero como buena práctica operativa: **usa un solo punto de entrada a la vez.** No corras `pyleases.sh`, `systemctl` y el wrapper `init.d` de forma concurrente sobre la misma instancia (p.ej. no lances `pyleases.sh` en una terminal mientras reiniciás manualmente con `systemctl` en otra) — dejá que termine una operación del ciclo de vida antes de iniciar la siguiente. |
| Automatic restart on failure | if `pydhcpd` crashes or exits with an error (e.g. the configured network interface is not present at startup), `systemd` restarts it automatically — `pydhcpd.service` sets `Restart=on-failure` with `RestartSec=5` (retry every 5 seconds), capped at `StartLimitBurst=10` attempts within a `StartLimitIntervalSec=120` (2 minute) window. If the underlying problem is not resolved within those 10 attempts, `systemd` gives up and leaves the service in a `failed` state — it will **not** keep retrying indefinitely, and `pydhcpd` has no separate alerting mechanism to notify you when this happens. Check with `systemctl status pydhcpd` (a `failed` state needs a manual `systemctl reset-failed pydhcpd` before it can be started again) and watch `/var/log/pydhcp.log` / `journalctl -u pydhcpd` for the root cause. | si `pydhcpd` falla o termina con un error (p.ej. la interfaz de red configurada no existe todavía al arrancar), `systemd` lo reinicia automáticamente — `pydhcpd.service` define `Restart=on-failure` con `RestartSec=5` (reintenta cada 5 segundos), con un tope de `StartLimitBurst=10` intentos dentro de una ventana de `StartLimitIntervalSec=120` (2 minutos). Si el problema de fondo no se resuelve dentro de esos 10 intentos, `systemd` se da por vencido y deja el servicio en estado `failed` — **no** va a seguir reintentando indefinidamente, y `pydhcpd` no tiene un mecanismo de aviso separado que notifique cuando esto pasa. Verifica con `systemctl status pydhcpd` (un estado `failed` necesita un `systemctl reset-failed pydhcpd` manual antes de poder arrancarlo de nuevo) y revisa `/var/log/pydhcp.log` / `journalctl -u pydhcpd` para encontrar la causa raíz. |
| `ping-check` | `ping-check true` is enabled in the shipped `pydhcpd.conf`. The daemon sends a ping before each OFFER to verify the IP is not already in use, except in three cases: the client's MAC is a static host (`host { fixed-address ... }`), the offered IP is already the one that MAC currently holds, or the concurrent ping-check backlog (capped at 64 in-flight) is saturated — in the last case it fails open and sends the OFFER without checking, rather than blocking or dropping the DISCOVER. Waits up to `ping-timeout` seconds (default `1`, read from `pydhcpd.conf` like `ping-check` itself) for a reply, but never blocks the main pool: each check runs on its own worker (capped at 4 concurrent) instead of stalling the DISCOVER handler like the standard blocking implementation. Internally, this ping is sent as a raw ICMP echo request built and read directly by the daemon (requires the `CAP_NET_RAW` capability, already granted in `pydhcpd.service`). If the raw socket cannot be opened (`CAP_NET_RAW` missing or revoked), it falls back to shelling out to the system's `ping` binary instead, logging an `INFO` when this happens (not a bad config value, so not a `WARNING`). A successful or failed result is cached for `PING_CACHE_TTL_SECONDS` seconds (default `120`, read directly from `pydhcp.env`, see pydhcp.env — pydhcp-only extras) to avoid re-pinging the same IP on every DISCOVER during a burst. In environments with strict firewall rules blocking ICMP (on this host, the target, or in between), the request or its reply is silently dropped, the check times out the same way regardless of the underlying mechanism, and `ping-check` will have no effect. To disable it, set `ping-check false;` in `/etc/pydhcp/core/pydhcpd.conf`. If using `pyleases.sh`, set `PING_CHECK_ENABLED=false` in `pydhcp.env` instead — the script regenerates `pydhcpd.conf` on every run. | `ping-check true` viene activado en el `pydhcpd.conf` enviado. El demonio envía un ping antes de cada OFFER para verificar que la IP no está en uso, excepto en tres casos: la MAC del cliente es un host estático (`host { fixed-address ... }`), la IP ofrecida ya es la que esa MAC tiene actualmente, o el cupo de verificaciones concurrentes (limitado a 64 en simultáneo) está saturado — en este último caso falla abierto y envía el OFFER sin verificar, en vez de bloquear o descartar el DISCOVER. Espera hasta `ping-timeout` segundos (default `1`, leída de `pydhcpd.conf` igual que `ping-check`) por una respuesta, pero nunca bloquea el pool principal: cada verificación corre en su propio worker (limitado a 4 concurrentes) en vez de detener el manejo de DISCOVER como hace la implementación bloqueante estándar. Internamente, este ping se envía como una solicitud ICMP echo cruda, construida y leída directamente por el demonio (requiere el privilegio `CAP_NET_RAW`, ya concedido en `pydhcpd.service`). Si el socket crudo no se puede abrir (falta o se revoca `CAP_NET_RAW`), cae al binario `ping` del sistema como respaldo, registrando un `INFO` cuando esto ocurre (no es un valor malo de configuración, así que no es `WARNING`). Un resultado exitoso o fallido se cachea por `PING_CACHE_TTL_SECONDS` segundos (default `120`, leída directamente de `pydhcp.env`, ver pydhcp.env — pydhcp-only extras) para evitar re-pingear la misma IP en cada DISCOVER durante una ráfaga. En entornos con reglas de firewall estrictas que bloquean ICMP (en este host, en el destino, o en el medio), la solicitud o su respuesta se descartan en silencio, la verificación expira igual sin importar el mecanismo interno, y `ping-check` no tendrá ningún efecto. Para desactivarlo, establece `ping-check false;` en `/etc/pydhcp/core/pydhcpd.conf`. Si usas `pyleases.sh`, establece `PING_CHECK_ENABLED=false` en `pydhcp.env` — el script regenera `pydhcpd.conf` en cada ejecución. |
| BPF filter on the raw socket | at startup, the daemon tries to attach an in-kernel BPF filter to its raw socket so only UDP/dst-port-67 frames wake the process — everything else is dropped by the kernel before reaching userspace. This is best-effort: `pydhcpd` runs with `CAP_NET_RAW`/`CAP_NET_BIND_SERVICE` only (see File Ownership and Permissions), and some kernels/containers restrict `SO_ATTACH_FILTER` to processes with `CAP_NET_ADMIN`/`CAP_BPF` instead. If the attach fails, the daemon logs an `INFO` and keeps running unaffected: the receive loop already filters every frame in userspace (ethertype, protocol, destination port) regardless of whether the kernel-level filter is active, so no DHCP functionality is lost — only non-DHCP traffic on the interface now also reaches the process before being discarded, instead of being dropped earlier by the kernel. Not a bad config value, so it is not a `WARNING`: it is an environment limitation the administrator cannot fix by editing a value. Example: `2026-08-25 10:15:32,123 INFO: BPF attach failed -- degraded` | al arrancar, el demonio intenta adjuntar un filtro BPF a nivel de kernel a su socket crudo para que solo los frames UDP con puerto destino 67 despierten al proceso — todo lo demás lo descarta el kernel antes de llegar a userspace. Esto es un intento sin garantía: `pydhcpd` corre solo con `CAP_NET_RAW`/`CAP_NET_BIND_SERVICE` (ver File Ownership and Permissions), y algunos kernels/contenedores restringen `SO_ATTACH_FILTER` a procesos con `CAP_NET_ADMIN`/`CAP_BPF`. Si el intento falla, el demonio registra un `INFO` y sigue funcionando sin verse afectado: el bucle de recepción ya filtra cada frame en userspace (ethertype, protocolo, puerto destino) sin importar si el filtro a nivel de kernel está activo, así que no se pierde ninguna funcionalidad DHCP — solo que el tráfico no-DHCP de la interfaz también llega ahora al proceso antes de descartarse, en vez de ser descartado antes por el kernel. No es un valor malo de configuración, así que no es `WARNING`: es una limitación del entorno que el administrador no puede corregir editando un valor. Ejemplo: `2026-08-25 10:15:32,123 INFO: BPF attach failed -- degraded` |
| `cleanup-interval` | `cleanup-interval` controls how often (in seconds) the daemon removes expired leases from memory. The default is `60`. If you use a short pool lease-time (e.g. `10` or `30` seconds), set `cleanup-interval` to the same value or lower so that expired leases are freed promptly and the pool does not appear exhausted. When using `pyleases.sh`, set `CLEANUP_INTERVAL` in `pydhcp.env` — it is written into `pydhcpd.conf` on every run. Config validation logs a `WARNING` (not an error — the daemon still starts) if `cleanup-interval` is greater than the pool's `min-lease-time`. **Minimum enforced value: `5` seconds** — if you set a lower value, the daemon clamps it to `5` and logs a `WARNING` stating the requested value. | `cleanup-interval` controla con qué frecuencia (en segundos) el demonio elimina los arrendamientos expirados de la memoria. El valor por defecto es `60`. Si usas un lease-time corto en el pool (p.ej. `10` o `30` segundos), establece `cleanup-interval` al mismo valor o menor para que los arrendamientos expirados se liberen rápidamente y el pool no parezca agotado. Al usar `pyleases.sh`, define `CLEANUP_INTERVAL` en `pydhcp.env` — se escribe en `pydhcpd.conf` en cada ejecución. La validación de configuración registra un `WARNING` (no un error — el demonio igual arranca) si `cleanup-interval` es mayor que el `min-lease-time` del pool. **Valor mínimo forzado: `5` segundos** — si se establece un valor menor, el demonio lo recorta a `5` y registra un `WARNING` indicando el valor solicitado. |
| Pool lease time default | the block pool's `min-lease-time` / `default-lease-time` / `max-lease-time` default to **60 seconds**, consistently across every path in this project: the shipped `pydhcpd.conf` template ships with `60` written explicitly in the `pool { }` block, `pyleases.sh` writes `60` (its `CLEANUP_INTERVAL` default) into the pool block on a fresh install, and `pydhcpd.py`'s own built-in fallback is also `60` (used only if a hand-written config omits the pool lease-time lines entirely). This keeps the default consistent with the short-lived, temporary nature of the block pool — unknown clients get a brief lease that is quickly recycled, unlike `AUTHORIZED_LEASE_TIME` (default `2592000`s / 30 days) used for the subnet-level lease given to authorized/static clients.<br><br>**To change it:** this is a per-installation choice, not something you edit in the project's code. At install time, `pysetup.sh` writes your answer to the `CLEANUP_INTERVAL` prompt directly into the `pool { }` block of `pydhcpd.conf`. To change it afterwards: if you manage `pydhcpd.conf` by hand, edit the `pool { min-lease-time / default-lease-time / max-lease-time }` values directly in your live `/etc/pydhcp/core/pydhcpd.conf` and restart/reload the daemon. If you use `pyleases.sh`, edit `CLEANUP_INTERVAL` in your `/etc/pydhcp/pydhcp.env` and re-run `pyleases.sh` — it rewrites `pydhcpd.conf` from that value on every run. | el `min-lease-time` / `default-lease-time` / `max-lease-time` del pool de bloqueo tienen por defecto **60 segundos**, de forma consistente en los tres caminos del proyecto: la plantilla `pydhcpd.conf` incluida trae `60` escrito explícitamente en el bloque `pool { }`, `pyleases.sh` escribe `60` (su valor por defecto de `CLEANUP_INTERVAL`) en el bloque del pool en una instalación nueva, y el respaldo interno propio de `pydhcpd.py` también es `60` (se usa solo si una configuración escrita a mano omite por completo las líneas de lease-time del pool). Esto mantiene el valor por defecto consistente con la naturaleza breve y temporal del pool de bloqueo — los clientes desconocidos reciben un lease corto que se recicla rápido, a diferencia de `AUTHORIZED_LEASE_TIME` (por defecto `2592000`s / 30 días) usado para el lease a nivel de subred que reciben los clientes autorizados/estáticos.<br><br>**Para cambiarlo:** es una decisión de cada instalación, no algo que se edite en el código del proyecto. Al instalar, `pysetup.sh` escribe tu respuesta a la pregunta `CLEANUP_INTERVAL` directamente en el bloque `pool { }` de `pydhcpd.conf`. Para cambiarlo después: si administras `pydhcpd.conf` a mano, edita los valores de `pool { min-lease-time / default-lease-time / max-lease-time }` directamente en tu `/etc/pydhcp/core/pydhcpd.conf` real y reinicia/recarga el demonio. Si usas `pyleases.sh`, edita `CLEANUP_INTERVAL` en tu `/etc/pydhcp/pydhcp.env` y vuelve a correr `pyleases.sh` — reescribe `pydhcpd.conf` a partir de ese valor en cada ejecución. |
| IP quarantine | when an IP is quarantined — either because a client sent a DHCPDECLINE (ignored by default, see `deny declines;` above) or because `ping-check` detects it is already in use before an OFFER — it is held out of the pool for `abandon-lease-time` seconds, **60 by default**. Read from `pydhcpd.conf`, like every other behavior directive — not from `pydhcp.env`. If using `pyleases.sh`, set `QUARANTINE_DURATION` in `pydhcp.env` instead — the script writes it into `pydhcpd.conf` as `abandon-lease-time` on every run, same as `CLEANUP_INTERVAL`/`ping-check`. Picked up live on `SIGHUP`/`reload`, no restart needed. It is independent from the pool's `default-lease-time` (see below); the two are not required to match. | cuando una IP se pone en cuarentena — ya sea porque un cliente envió un DHCPDECLINE (ignorado por defecto, ver `deny declines;` arriba) o porque `ping-check` detecta que ya está en uso antes de un OFFER — se aparta del pool por `abandon-lease-time` segundos **60 por defecto**. Se lee de `pydhcpd.conf`, igual que cualquier otra directiva de comportamiento — no de `pydhcp.env`. Si usas `pyleases.sh`, define `QUARANTINE_DURATION` en `pydhcp.env` — el script la escribe en `pydhcpd.conf` como `abandon-lease-time` en cada ejecución, igual que `CLEANUP_INTERVAL`/`ping-check`. Se aplica en caliente con `SIGHUP`/`reload`, sin reiniciar. Es independiente del `default-lease-time` del pool (ver más abajo); no es necesario que coincidan. |
| Pool range cap | the `pool { range A B; }` directive is capped at **65536 addresses** (a `/16`). The daemon builds the full address set in memory at startup and re-sorts the free set on every allocation, so an oversized range (e.g. a `/8`) would waste memory and CPU proportional to its size. A range larger than the cap is rejected at config load (or `SIGHUP` reload) with a clear error instead of being silently accepted. | la directiva `pool { range A B; }` tiene un tope de **65536 direcciones** (un `/16`). El demonio construye el conjunto completo de direcciones en memoria al arrancar y reordena el conjunto libre en cada asignación, por lo que un rango sobredimensionado (p.ej. un `/8`) desperdiciaría memoria y CPU proporcional a su tamaño. Un rango mayor al tope se rechaza al cargar la configuración (o al recargar con `SIGHUP`) con un error claro, en vez de aceptarse en silencio. |

### Tools

---

#### pyleases

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      <b>pyleases.sh</b> — Advanced DHCP lease and ACL manager for pydhcpd. Parses <code>pydhcpd.leases</code>, detects unauthorized clients, rebuilds <code>pydhcpd.conf</code> from ACL files, and restarts the daemon. Designed for environments enforcing DHCP-based access control.<br><br>
      ACL directories: <code>/etc/acl/mac/</code> (administrator's own, authorized: <code>mac-limited.txt</code>, <code>mac-unlimited.txt</code>) and <code>/etc/pydhcp/acl/</code> (pydhcp's own, blocked: <code>blockdhcp.txt</code>).<br>
      Entry format: <code>a;MAC;IP;HOSTNAME;</code>. The leading <code>a</code> means "active" and is what marks a well-formed entry — any other leading character is malformed (see ACL priority order). There is no opposite value: for the <code>mac-*.txt</code> lists, to deactivate an entry, comment out the whole line by prefixing it with <code>#</code> (<code>#a;MAC;IP;HOSTNAME;</code>) instead of editing the <code>a</code> itself. <code>blockdhcp.txt</code> is the exception: it has no active/inactive state and no <code>#</code> syntax — an entry's mere presence blocks the MAC. To unblock, delete the line; a <code>#</code>-prefixed line there is dropped as malformed.<br>
      A duplicate MAC, IP or hostname is compared on the value alone — a commented (<code>#a;</code>) line counts the same as an active one, since deactivating an entry does not remove it from the file. What happens with each list is in ACL priority order.<br>
      When <code>pyleases.sh</code> blocks a client it also removes it from <code>pydhcpd.leases</code>, so the IP it was using is free for another client at that same instant: a MAC in <code>blockdhcp.txt</code> never holds a lease.<br>
      An <code>IP</code> in <code>mac-*.txt</code> that falls inside the blockdhcp pool range is a misconfiguration: <code>pyleases.sh</code> aborts the run before the daemon is stopped or <code>pydhcpd.conf</code> is rewritten, naming the MAC to move. Commented-out lines are not checked.
    </td>
    <td style="width: 50%; vertical-align: top;">
      <b>pyleases.sh</b> — Gestor avanzado de concesiones y ACLs DHCP para pydhcpd. Parsea <code>pydhcpd.leases</code>, detecta clientes no autorizados, reconstruye <code>pydhcpd.conf</code> a partir de archivos ACL y reinicia el demonio. Diseñado para entornos que aplican control de acceso basado en DHCP.<br><br>
      Directorios ACL: <code>/etc/acl/mac/</code> (propios del administrador, autorizados: <code>mac-limited.txt</code>, <code>mac-unlimited.txt</code>) y <code>/etc/pydhcp/acl/</code> (propio de pydhcp, bloqueados: <code>blockdhcp.txt</code>).<br>
      Formato: <code>a;MAC;IP;HOSTNAME;</code>. La <code>a</code> inicial significa "active" (activo) y es lo que marca una entrada bien formada — cualquier otro carácter inicial es malformado (ver ACL priority order). No existe un valor opuesto: para las listas <code>mac-*.txt</code>, para desactivar una entrada se comenta la línea completa agregando <code>#</code> al inicio (<code>#a;MAC;IP;HOSTNAME;</code>) en vez de editar la <code>a</code> misma. <code>blockdhcp.txt</code> es la excepción: no tiene estado activo/inactivo ni sintaxis <code>#</code> — la sola presencia de una entrada bloquea la MAC. Para desbloquear, se borra la línea; una línea con <code>#</code> ahí se elimina por malformada.<br>
      Una MAC, IP u hostname duplicado se compara solo por el valor — una línea comentada (<code>#a;</code>) cuenta igual que una activa, ya que desactivar una entrada no la quita del archivo. Qué pasa con cada lista está en ACL priority order.<br>
      Cuando <code>pyleases.sh</code> bloquea a un cliente, además lo elimina de <code>pydhcpd.leases</code>, de modo que la IP que estaba usando queda libre para otro cliente en ese mismo instante: una MAC de <code>blockdhcp.txt</code> nunca tiene un lease.<br>
      Una <code>IP</code> de <code>mac-*.txt</code> que caiga dentro del rango del pool blockdhcp es un error de configuración: <code>pyleases.sh</code> aborta la corrida antes de detener el demonio y antes de reescribir <code>pydhcpd.conf</code>, nombrando la MAC que hay que mover. Las líneas comentadas no se revisan.
    </td>
  </tr>
</table>

```bash
sudo bash tools/pyleases.sh
```

##### ACL priority order

| ACL | Priority Level | Description | Descripción |
|---|---|---|---|
| `mac-unlimited.txt` | 1 | List maintained by hand by the administrator. Designed for communications hardware, servers and other essential equipment, not subject to firewall restrictions. A malformed line aborts with `ERROR`. | Lista mantenida manualmente por el administrador. Está diseñada para hardware de comunicaciones, servidores y otros equipos esenciales, no sujetos a restricciones del firewall. Una línea malformada aborta con `ERROR`. |
| `mac-limited.txt` | 2 | List maintained by hand by the administrator. Designed for equipment joining the local network. May be subject to firewall, proxy and other restrictions. A malformed line aborts with `ERROR`. | Lista mantenida manualmente por el administrador. Está diseñada para los equipos que se integran a una red local. Puede estar sujeta a restricciones de firewall, proxy, etc. Una línea malformada aborta con `ERROR`. |
| `blockdhcp.txt` | 0 | List operated by the `pydhcp` daemon and written by `pyleases.sh`. Designed for clients denied a DHCP lease outright: any client with no entry in `mac-*.txt` is added here and loses its lease at that same instant. Authorizes nothing on its own. A malformed line is dropped with `INFO` and the run continues. | Lista operada por el demonio `pydhcp` y escrita por `pyleases.sh`. Está diseñada para los clientes a los que se les niega el lease DHCP por completo: todo cliente sin entrada en `mac-*.txt` se agrega aquí y pierde su lease en ese mismo instante. No autoriza nada por sí sola. Una línea malformada se elimina con `INFO` y la corrida continúa. |

> Lines starting with `#` are treated as deactivated and get blocked. Only applies to the ACLs with Priority Level 1 and 2.
>
> Las líneas que comienzan con `#` se consideran desactivadas y serán bloqueadas. Solo aplica a las ACL con Priority Level 1 y 2.

**Warning**

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      <ul>
        <li><code>--update</code> calls <code>tools/bkstack.sh</code> before overwriting anything, which writes a full backup to <code>/etc/bak/</code>. <code>pydhcpd.conf</code> is <b>never overwritten</b>. <code>pydhcp.env</code> keeps every user config value except <code>LOG_FILE</code>, which is kept in sync to the shipped path on every <code>--update</code>. Any manual edit to the code files (<code>pydhcpd.py</code>, <code>pyleases.sh</code>, <code>pywebmin.sh</code>) will be replaced.</li>
        <li>⚠️ <b>WARNING:</b> <code>pyleases.sh</code> fully rebuilds <code>/etc/pydhcp/core/pydhcpd.conf</code> on every run from its ACL files and <code>pydhcp.env</code>. Any manual edits to <code>pydhcpd.conf</code> — including custom lease times, pools, or directives — will be lost. If you manage <code>pydhcpd.conf</code> manually, do not use <code>pyleases.sh</code>.</li>
        <li><b>Classes and pools:</b> the daemon supports several <code>pool { }</code> blocks and any number of <code>class</code>/<code>subclass</code> declarations. <code>pyleases.sh</code>, by design, only ever writes what this project documents: one pool with <code>deny members of "blockdhcp";</code>, plus the <code>fixed-address</code> reservations from the <code>mac-*.txt</code> lists. Any extra class or pool added by hand is discarded on the next run. Neither is a hard limit: <code>pyleases.sh</code> is a plain shell script, so anyone who needs extra classes or pools can edit the block that writes <code>pydhcpd.conf</code> and emit them there — the daemon will honour whatever the file ends up containing. Keep your own copy of any such change: <code>pysetup.sh --update</code> replaces the script with the shipped version, and although it saves the previous one under <code>/etc/pydhcp/bak/&lt;TIMESTAMP&gt;/</code>, the edit has to be reapplied by hand after every update.</li>
      </ul>
    </td>
    <td style="width: 50%; vertical-align: top;">
      <ul>
        <li><code>--update</code> llama a <code>tools/bkstack.sh</code> antes de sobrescribir nada, que escribe una copia completa en <code>/etc/bak/</code>. <code>pydhcpd.conf</code> <b>nunca se sobreescribe</b>. <code>pydhcp.env</code> conserva cada valor de configuración del usuario excepto <code>LOG_FILE</code>, que se mantiene sincronizado con la ruta del paquete en cada <code>--update</code>. Cualquier edición manual a los archivos de código (<code>pydhcpd.py</code>, <code>pyleases.sh</code>, <code>pywebmin.sh</code>) será reemplazada.</li>
        <li>⚠️ <b>ADVERTENCIA:</b> <code>pyleases.sh</code> reconstruye completamente <code>/etc/pydhcp/core/pydhcpd.conf</code> en cada ejecución a partir de sus archivos ACL y <code>pydhcp.env</code>. Cualquier edición manual a <code>pydhcpd.conf</code> — incluyendo lease times, pools o directivas personalizadas — se perderá. Si gestiona <code>pydhcpd.conf</code> manualmente, no utilice <code>pyleases.sh</code>.</li>
        <li><b>Clases y pools:</b> el demonio soporta varios bloques <code>pool { }</code> y cualquier cantidad de declaraciones <code>class</code>/<code>subclass</code>. <code>pyleases.sh</code>, por diseño, solo escribe lo que este proyecto documenta: un pool con <code>deny members of "blockdhcp";</code>, más las reservas <code>fixed-address</code> de las listas <code>mac-*.txt</code>. Cualquier clase o pool agregado a mano se descarta en la siguiente ejecución. Ninguna de las dos es una camisa de fuerza: <code>pyleases.sh</code> es un script de shell corriente, así que quien necesite clases o pools adicionales puede editar el bloque que escribe <code>pydhcpd.conf</code> y emitirlos ahí — el demonio va a respetar lo que el archivo termine conteniendo. Guarde su propia copia de ese cambio: <code>pysetup.sh --update</code> reemplaza el script por la versión del repositorio y, aunque respalda el anterior en <code>/etc/pydhcp/bak/&lt;TIMESTAMP&gt;/</code>, la edición hay que volver a aplicarla a mano tras cada actualización.</li>
      </ul>
    </td>
  </tr>
</table>

##### WPAD/PAC via DHCP option 252 (optional)

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      <code>pyleases.sh</code> generates <code>/etc/pydhcp/core/pydhcpd.conf</code> dynamically on every run. WPAD/PAC support is controlled entirely from <code>pydhcp.env</code> — no manual editing of <code>pyleases.sh</code> is required.
    </td>
    <td style="width: 50%; vertical-align: top;">
      <code>pyleases.sh</code> genera <code>/etc/pydhcp/core/pydhcpd.conf</code> dinámicamente en cada ejecución. El soporte WPAD/PAC se controla completamente desde <code>pydhcp.env</code> — no se requiere editar manualmente <code>pyleases.sh</code>.
    </td>
  </tr>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      <b>To enable/disable WPAD:</b>
      <ul>
        <li>Set <code>WPAD_ENABLED=true</code> in <code>/etc/pydhcp/pydhcp.env</code> to enable</li>
        <li>Set <code>WPAD_ENABLED=false</code> in <code>/etc/pydhcp/pydhcp.env</code> to disable (default)</li>
      </ul>
      <b>Prerequisites — do these BEFORE setting <code>WPAD_ENABLED=true</code>:</b>
      <ol>
        <li>Install Apache2.</li>
        <li>Create a VirtualHost listening on the port you intend to use (default <code>18100</code>) and add that port to Apache's <code>ports.conf</code> as <code>Listen SERVER_IP:PORT</code>.</li>
        <li>Place a valid <code>wpad.pac</code> file in that VirtualHost's document root.</li>
        <li>Set <code>WPAD_PORT</code> in <code>/etc/pydhcp/pydhcp.env</code> to that port if it is not <code>18100</code>.</li>
      </ol>
      <b>Guard:</b> <code>pyleases.sh</code> never trusts <code>WPAD_ENABLED=true</code> on its own. On every run it fetches <code>http://SERVER_IP:WPAD_PORT/wpad.pac</code> and only writes the two <code>option wpad</code> lines if it gets an HTTP <code>200</code>. Otherwise it logs a <code>WARNING</code>, leaves the lines commented out, and continues normally. This prevents the failure mode where every WPAD-aware client on the LAN stalls on an unreachable PAC URL — a fault that produces no error on the server and shows up only as "the network is slow" everywhere at once. Verify it yourself with:
      <br><code>curl -fsS --noproxy '*' --max-time 5 -o /dev/null "http://SERVER_IP:WPAD_PORT/wpad.pac"; echo $?</code><br>
      A result of <code>0</code> means WPAD will be activated; anything else means it will not.
      <br><br>The project does not deploy the Apache side: no VirtualHost, no <code>wpad.pac</code>. That setup is the administrator's responsibility.
    </td>
    <td style="width: 50%; vertical-align: top;">
      <b>Para activar/desactivar WPAD:</b>
      <ul>
        <li>Establezca <code>WPAD_ENABLED=true</code> en <code>/etc/pydhcp/pydhcp.env</code> para activar</li>
        <li>Establezca <code>WPAD_ENABLED=false</code> en <code>/etc/pydhcp/pydhcp.env</code> para desactivar (por defecto)</li>
      </ul>
      <b>Requisitos previos — haga esto ANTES de poner <code>WPAD_ENABLED=true</code>:</b>
      <ol>
        <li>Instale Apache2.</li>
        <li>Cree un VirtualHost escuchando en el puerto que vaya a usar (default <code>18100</code>) y agregue ese puerto al <code>ports.conf</code> de Apache como <code>Listen SERVER_IP:PORT</code>.</li>
        <li>Coloque un archivo <code>wpad.pac</code> válido en el document root de ese VirtualHost.</li>
        <li>Ajuste <code>WPAD_PORT</code> en <code>/etc/pydhcp/pydhcp.env</code> a ese puerto si no es <code>18100</code>.</li>
      </ol>
      <b>Guarda:</b> <code>pyleases.sh</code> nunca confía en <code>WPAD_ENABLED=true</code> por sí solo. En cada ejecución descarga <code>http://SERVER_IP:WPAD_PORT/wpad.pac</code> y solo escribe las dos líneas <code>option wpad</code> si obtiene un HTTP <code>200</code>. Si no, registra un <code>WARNING</code>, deja las líneas comentadas y continúa con normalidad. Esto evita el fallo en que todos los clientes de la red que atienden WPAD se quedan esperando una URL PAC inalcanzable — una avería que no produce ningún error en el servidor y que solo se manifiesta como "la red está lenta" en todas partes a la vez. Verifíquelo usted mismo con:
      <br><code>curl -fsS --noproxy '*' --max-time 5 -o /dev/null "http://SERVER_IP:WPAD_PORT/wpad.pac"; echo $?</code><br>
      Un resultado <code>0</code> significa que WPAD se activará; cualquier otro, que no.
      <br><br>El proyecto no despliega la parte de Apache: ni el VirtualHost ni el <code>wpad.pac</code>. Ese montaje es responsabilidad del administrador.
    </td>
  </tr>
</table>

> Android and iOS ignore DHCP option 252. The proxy must be configured manually on those devices.
>
> Android e iOS ignoran la opción DHCP 252. El proxy debe configurarse manualmente en esos dispositivos.

#### bkstack

| Command | Description | Descripción |
|---|---|---|
| `sudo bash bkstack.sh` | Create a backup now | Crear una copia ahora |
| `sudo bash bkstack.sh install` | Register the `@monthly` cron entry | Registrar la entrada mensual en cron |
| `sudo bash bkstack.sh uninstall` | Remove the cron entry, keeping the archives | Quitar la entrada de cron, conservando los comprimidos |

> Backs up both projects into `/etc/bak/bkstack_<TIMESTAMP>.zip`: their install trees, the shared ACL lists, the systemd units, the `init.d` wrapper, the logrotate config and the Webmin modules. Paths that do not exist are skipped, so it works whether `uhm` is installed or only `pydhcp`. The archive lives outside `/etc/pydhcp` and `/etc/uhm`, so uninstalling either project never touches it. Restore by unzipping it over `/`.
>
> Respalda ambos proyectos en `/etc/bak/bkstack_<TIMESTAMP>.zip`: sus árboles de instalación, las listas ACL compartidas, las unidades de systemd, el wrapper de `init.d`, la configuración de logrotate y los módulos de Webmin. Las rutas que no existan se omiten, así que funciona tanto con `uhm` instalado como solo con `pydhcp`. El comprimido vive fuera de `/etc/pydhcp` y `/etc/uhm`, así que desinstalar cualquiera de los dos no lo toca. Para restaurar, descomprímalo sobre `/`.

#### pywebmin

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      <b>pywebmin.sh</b> — Optional installer for a PyDHCP module for Webmin. Provides a web interface to manage the pydhcpd daemon: service control (start/stop/restart/reload), active leases table, and configuration file editor. Requires Webmin to be installed on the system.
    </td>
    <td style="width: 50%; vertical-align: top;">
      <b>pywebmin.sh</b> — Instalador opcional de un módulo PyDHCP para Webmin. Proporciona una interfaz web para administrar el demonio pydhcpd: control del servicio (start/stop/restart/reload), tabla de concesiones activas y editor del archivo de configuración. Requiere que Webmin esté instalado en el sistema.
    </td>
  </tr>
</table>

##### Features

| Feature | Description | Descripción |
|---------|--------------|-------------|
| **Service control** | Start / Stop / Restart / Reload buttons for `pydhcpd`. | Botones Iniciar / Detener / Reiniciar / Recargar para `pydhcpd`. |
| **Active leases table** | IP, MAC, hostname, expiry and binding state, read from `pydhcpd.leases`. | IP, MAC, hostname, expiración y estado, leídos de `pydhcpd.leases`. |
| **Config editor** | Edits `pydhcpd.conf` in the browser; validated with `pydhcpd.py -t -cf` before saving, rejected on syntax error. Up to 3 backups kept under `/etc/pydhcp/bak/webmin/`. | Edita `pydhcpd.conf` en el navegador; se valida con `pydhcpd.py -t -cf` antes de guardar, se rechaza si hay error de sintaxis. Guarda hasta 3 respaldos en `/etc/pydhcp/bak/webmin/`. |
| **State badges** | Color-coded: Active (`#d4edda`/`#155724`), Inactive (`#f8d7da`/`#721c24`), Unknown (`#e2e3e5`/`#383d41`), Warning (`#fff3cd`/`#856404`). | Con color: Active (`#d4edda`/`#155724`), Inactive (`#f8d7da`/`#721c24`), Unknown (`#e2e3e5`/`#383d41`), Warning (`#fff3cd`/`#856404`). |

```bash
# Install | Instalar
sudo bash tools/pywebmin.sh install

# Uninstall | Desinstalar
sudo bash tools/pywebmin.sh uninstall
```

> Access is granted to the Webmin `root` account and to the detected local sudo user. For any other Webmin user, grant it from **Webmin → Webmin Users**.
>
> El acceso se concede a la cuenta `root` de Webmin y al usuario local con sudo detectado. Para cualquier otro usuario de Webmin, concederlo desde **Webmin → Webmin Users**.

### Rogue DHCP defense

| Aspect | `authoritative` | DHCP Snooping | Description | Descripción |
|---|---|---|---|---|
| Where it acts | the DHCP server | the switch | One is a daemon directive, the other a network-layer feature | Uno es una directiva del demonio, el otro una función de la red |
| When | after the fact, on the REQUEST | before, on the traffic itself | Correction versus prevention | Corrección frente a prevención |
| What it does | NAKs the request, forcing the client to rediscover | drops the rogue's packets | The client ends up with the correct IP either way | El cliente termina con la IP correcta en ambos casos |
| Reach | cannot stop `DHCPOFFER`/`DHCPACK` from reaching the client | the client never receives them | No DHCP server can block another's packets at the protocol level | Ningún servidor DHCP puede bloquear los paquetes de otro a nivel de protocolo |

> A rogue server may win the OFFER race, but the client's REQUEST is broadcast and always reaches the authoritative server, which NAKs it and forces the client to discard the rogue lease and start over. Check whether your switch supports DHCP Snooping and enable it if so: it blocks rogue DHCP traffic before it ever reaches a client, instead of correcting it afterwards.
>
> Un servidor no autorizado puede ganar la carrera del OFFER, pero el REQUEST del cliente se manda por broadcast y siempre llega al servidor autoritativo, que lo rechaza con NAK y fuerza al cliente a descartar esa concesión y empezar de nuevo. Verifique si su switch soporta DHCP Snooping y actívelo si es así: bloquea el tráfico DHCP no autorizado antes de que llegue al cliente, en vez de corregirlo después.

### DHCP Iptables Rules

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      Add the following rules to allow DHCP traffic on both interfaces. The WAN rules cover the case where the server itself acts as a DHCP client toward an upstream router. The LAN rules allow the server to assign IP addresses to local clients.
    </td>
    <td style="width: 50%; vertical-align: top;">
      Agregue las siguientes reglas para permitir el tráfico DHCP en ambas interfaces. Las reglas de WAN cubren el caso en el que el propio servidor actúa como cliente DHCP hacia un enrutador ascendente. Las reglas de LAN permiten al servidor asignar direcciones IP a clientes locales.
    </td>
  </tr>
</table>

```bash
# WAN — DHCP client (server requests an IP from an upstream DHCP server)
iptables -A OUTPUT -o $wan -p udp --sport 68 --dport 67 -j ACCEPT
iptables -A INPUT  -i $wan -p udp --sport 67 --dport 68 -j ACCEPT

# LAN — DHCP server (server assigns IPs to local clients)
iptables -A INPUT  -i $lan -p udp --sport 68 --dport 67 -j ACCEPT
iptables -A OUTPUT -o $lan -p udp --sport 67 --dport 68 -j ACCEPT
```

### Logs

<table width="100%">
  <tr>
    <td style="width: 50%; vertical-align: top;">
      pydhcpd writes logs directly to <code>/var/log/pydhcp.log</code>. It does not use syslog, therefore no <code>log-facility</code> directive is needed or supported. That single file is shared by the whole project — the daemon, <code>pysetup.sh</code> and <code>tools/pyleases.sh</code> all append to it, under one <code>daily</code> rotation (<code>/etc/logrotate.d/pydhcp</code>). Its path is fixed and not configurable.
    </td>
    <td style="width: 50%; vertical-align: top;">
      pydhcpd escribe los logs directamente a <code>/var/log/pydhcp.log</code>. No utiliza syslog, por lo tanto no se necesita ni se soporta la directiva <code>log-facility</code>. Ese archivo único lo comparte todo el proyecto — el demonio, <code>pysetup.sh</code> y <code>tools/pyleases.sh</code> escriben en él, bajo una sola rotación <code>daily</code> (<code>/etc/logrotate.d/pydhcp</code>). Su ruta es fija y no configurable.
    </td>
  </tr>
</table>

#### Log levels

| Level | Description | Descripción |
|---|---|---|
| `ERROR:` | Exclusively for a message that aborts the current flow -- the process/script stops right there, nothing after it runs. Always paired with the `-- abort` suffix. | Exclusivo para un mensaje que aborta el flujo actual -- el proceso/script se detiene ahí mismo, nada después corre. Siempre acompañado del sufijo `-- abort`. |
| `WARNING:` | Something is seriously wrong and needs the administrator's immediate attention, but execution does not abort. Paired with `-- alert` (a live condition needing supervision, e.g. a possible attack or resource saturation) or `-- fallback` (the administrator supplied a bad/out-of-range value in the config, and the daemon used a built-in default instead -- the value must be corrected). | Algo anda mal y requiere atención inmediata del administrador, pero la ejecución no aborta. Acompañado de `-- alert` (una condición en vivo que amerita supervisión, ej. un posible ataque o saturación de recursos) o `-- fallback` (el administrador puso un valor malo o fuera de rango en la configuración, y el demonio usó un valor por defecto en su lugar -- ese valor debe corregirse). |
| `INFO:` | Everything else: routine state changes, notifications, and anything skipped or defaulted without needing administrator attention. Paired with `-- skip` (an action or packet was discarded, for any reason) or `-- degraded` (a system/environment limitation -- not a bad config value -- left the daemon running without an optimization or protection it would normally have; nothing for the administrator to fix). | Todo lo demás: cambios de estado rutinarios, notificaciones, y cualquier cosa omitida o resuelta con un valor por defecto sin necesitar atención del administrador. Acompañado de `-- skip` (se descartó una acción o paquete, por cualquier razón) o `-- degraded` (una limitación del sistema/entorno -- no un valor malo de configuración -- dejó al demonio funcionando sin una optimización o protección que normalmente tendría; no hay nada que el administrador deba corregir). |

#### Log line width

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      No log line exceeds <b>80 columns</b>, timestamp and level included. Long values are cut at write time so a line can never wrap. <b>MAC and IP addresses are never affected</b> — their limits are 17 and 15 characters, which is exactly what they measure. Everything else is capped:
      <ul>
        <li><b>Client hostname: 15 characters</b> in the daemon's log, 30 in <code>tools/pyleases.sh</code>. Hostnames longer than that are recommended against: the log shows only the beginning. The full name is never lost — it stays in <code>pydhcpd.leases</code> and in the ACL lists.</li>
        <li>File paths: 24 characters, the length of <code>/etc/pydhcp/core/pydhcpd.conf</code>.</li>
        <li>System errors are logged by their reason only (<code>Permission denied</code>), not as Python's full text, which repeats a path the daemon already logs on its own line.</li>
      </ul>
      An event that does not fit on one line is written as several complete records, each with its own timestamp and level — never as an indented continuation, which a <code>grep</code> by level would miss.
    </td>
    <td style="width: 50%; vertical-align: top;">
      Ninguna línea de log supera las <b>80 columnas</b>, contando fecha y nivel. Los valores largos se cortan al escribirse para que una línea nunca se parta sola. <b>Las direcciones MAC e IP nunca se ven afectadas</b> — sus topes son 17 y 15 caracteres, justo lo que miden. Todo lo demás tiene tope:
      <ul>
        <li><b>Nombre de host del cliente: 15 caracteres</b> en el log del demonio, 30 en <code>tools/pyleases.sh</code>. No se recomiendan nombres más largos: en el log se ve solo el principio. El nombre completo no se pierde nunca — queda en <code>pydhcpd.leases</code> y en las listas ACL.</li>
        <li>Rutas de archivo: 24 caracteres, el largo de <code>/etc/pydhcp/core/pydhcpd.conf</code>.</li>
        <li>Los errores del sistema se registran solo por su razón (<code>Permission denied</code>), no con el texto completo de Python, que repite una ruta que el demonio ya escribe en su propia línea.</li>
      </ul>
      Un evento que no cabe en una línea se escribe como varios registros completos, cada uno con su fecha y su nivel — nunca como una continuación indentada, que un <code>grep</code> por nivel no encontraría.
    </td>
  </tr>
</table>

## EOL

---

| Project | Version | EOL Date |
| :-----: | :-----: | :------: |
| [ISC-DHCP](https://github.com/isc-projects/dhcp) | 4.4.3-P1-4ubuntu2 | 2022 |

## NOTICE

---

<table width="100%">
  <tr>
    <td style="width: 50%; vertical-align: top;">
      <strong>This repository</strong>
      <ul>
        <li>May include third-party components.</li>
        <li>Does not accept Pull Requests. Changes must be proposed via Issues.</li>
      </ul>
    </td>
    <td style="width: 50%; vertical-align: top;">
      <strong>Este repositorio</strong>
      <ul>
        <li>Puede incluir componentes de terceros.</li>
        <li>No acepta Pull Requests. Los cambios deben proponerse mediante Issues.</li>
      </ul>
    </td>
  </tr>
</table>

## SPONSOR THIS PROJECT

---

[![Image](https://raw.githubusercontent.com/maravento/winexternal/master/img/maravento-paypal.png)](https://paypal.me/maravento)

## PROJECT LICENSES

---

<table width="100%">
  <tr>
    <td style="width: 50%; vertical-align: top;">
      This project uses a dual-licensing model to balance software freedom with content protection:
    </td>
    <td style="width: 50%; vertical-align: top;">
      Este proyecto utiliza un modelo de licencia dual para equilibrar la libertad del software con la protección del contenido:
    </td>
  </tr>
</table>

| Content | Licensed Under |
|---|---|
|Scripts, Binaries, Infrastructure|[![GPL-3.0](https://img.shields.io/badge/Open_Core-GPLv3-blue.svg?style=for-the-badge&labelWidth=120&logoWidth=20)](LICENSE)|
|RAG, Workers, Specialized Modules, Docs|[![CC](https://img.shields.io/badge/Core_Engine-CC_BY--NC--ND_4.0-lightgrey.svg?style=for-the-badge&labelWidth=120&logoWidth=20)](docs/LICENSE-CC-BY-NC-ND-4.0.md)|

## DISCLAIMER

---

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
