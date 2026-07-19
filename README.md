# [PyDHCP](https://github.com/maravento)

[![status-maintained](https://img.shields.io/badge/status-maintained-purple.svg)](https://github.com/maravento/pydhcp)
[![last commit](https://img.shields.io/github/last-commit/maravento/pydhcp)](https://github.com/maravento/pydhcp)
[![Stargazers](https://img.shields.io/github/stars/maravento/pydhcp?label=Stargazers)](https://github.com/maravento/pydhcp/stargazers)
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/maravento/pydhcp)
[![Twitter Follow](https://img.shields.io/twitter/follow/maraventostudio.svg)](https://twitter.com/maraventostudio)

<!-- markdownlint-disable MD033 -->

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      <b>pydhcp</b> is an open-source IPv4 DHCP server written in Python. Since <a href="https://github.com/isc-projects/dhcp">isc-dhcp-server</a> reached End-of-Life (EOL) in 2022, pydhcp aims to preserve many of its familiar features and configuration style for anyone looking to migrate — offering a friendly, similar-feeling alternative rather than a full replacement. It implements RFC 2131 over UDP 67/68, uses a compatible configuration syntax and lease file format under its own file paths, and runs as a native <code>systemd</code> service with an <code>init.d</code> wrapper included.
    </td>
    <td style="width: 50%; vertical-align: top;">
      <b>pydhcp</b> es un servidor DHCP IPv4 de código abierto escrito en Python. Dado que <a href="https://github.com/isc-projects/dhcp">isc-dhcp-server</a> alcanzó su fin de vida (EOL) en 2022, pydhcp busca conservar muchas de sus características y estilo de configuración habituales para quienes quieran migrar — ofreciendo una alternativa amigable y similar, no un reemplazo completo. Implementa RFC 2131 sobre UDP 67/68, usa sintaxis de configuración y formato de concesiones compatible bajo sus propias rutas de archivo, y corre como servicio <code>systemd</code> nativo con wrapper <code>init.d</code> incluido.
    </td>
  </tr>
</table>

## Requirements

---

**⚠️ WARNING:** Only tested on Ubuntu 24.04 LTS. Other versions or distros not tested, use at your own risk.

- Python 3.8+
- systemd

## Scope

---

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      <b>What pydhcp does:</b>
      <ul>
        <li>Python daemon implementing DHCP (RFC 2131) over UDP 67/68</li>
        <li>Reads <code>/etc/pydhcp/pydhcpd.conf</code> (compatible with <code>dhcpd.conf</code> format)</li>
        <li>Writes <code>/etc/pydhcp/pydhcpd.leases</code> (compatible with <code>dhcpd.leases</code> format)</li>
        <li>Supports a subset of <code>isc-dhcp-server</code> directives (see <a href="#config">Config</a> section for the full list)</li>
        <li>Runs as a <code>systemd</code> service under the <code>pydhcpd</code> user</li>
        <li>Responds to <code>/etc/init.d/pydhcpd stop|start</code> (compatible wrapper)</li>
        <li>IPv4 only, single interface</li>
      </ul>
    </td>
    <td style="width: 50%; vertical-align: top;">
      <b>Lo que pydhcp hace:</b>
      <ul>
        <li>Demonio Python que implementa DHCP (RFC 2131) sobre UDP 67/68</li>
        <li>Lee <code>/etc/pydhcp/pydhcpd.conf</code> (compatible con el formato de <code>dhcpd.conf</code>)</li>
        <li>Escribe <code>/etc/pydhcp/pydhcpd.leases</code> (compatible con el formato de <code>dhcpd.leases</code>)</li>
        <li>Soporta un subconjunto de directivas de <code>isc-dhcp-server</code> (ver sección <a href="#config">Config</a> para la lista completa)</li>
        <li>Corre como servicio <code>systemd</code> bajo el usuario <code>pydhcpd</code></li>
        <li>Responde a <code>/etc/init.d/pydhcpd stop|start</code> (wrapper compatible)</li>
        <li>Solo IPv4, interfaz única</li>
      </ul>
    </td>
  </tr>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      <b>Out of scope (not implemented):</b>
      <ul>
        <li>IPv6</li>
        <li>LDAP</li>
        <li>DDNS</li>
        <li>Multiple interfaces</li>
        <li>BOOTP / PXE</li>
        <li>DHCP relay agents (no legitimate use case without multi-segment/multi-interface support — see above). The <code>giaddr</code>/<code>hops</code> fields are still parsed, but only to close a spoofing hole, not to offer relay functionality: without any validation, an attacker could set an arbitrary <code>giaddr</code> and get the server to send unsolicited DHCP replies to that IP (reflection). The check requires <code>hops >= 1</code> and <code>giaddr == src_ip</code> (the sender's real IP) — if it doesn't match, the packet is dropped and logged as <code>"Spoofed relay dropped"</code>. This is a hardening measure for a field that must be parsed either way, not relay support a deployment could rely on</li>
        <li><code>client-updates</code> / <code>deny client-updates</code> (depends on DDNS + client FQDN option, neither implemented)</li>
        <li><code>option subnet-mask</code> override (the netmask sent to clients always matches the <code>subnet ... netmask ...</code> declaration; no override support)</li>
        <li>Per-host/per-class option scoping: options declared at the <code>subnet</code> level (e.g. <code>option wpad ...;</code>) apply to every client uniformly. Unlike <code>isc-dhcp-server</code>, there is no way to override or omit a subnet-level option for a specific <code>host</code> or <code>class</code>/<code>subclass</code> — <code>class</code>/<code>subclass</code> here only support the MAC-block use case (see <code>blockdhcp</code> below)</li>
      </ul>
    </td>
    <td style="width: 50%; vertical-align: top;">
      <b>Fuera de alcance (no implementado):</b>
      <ul>
        <li>IPv6</li>
        <li>LDAP</li>
        <li>DDNS</li>
        <li>Múltiples interfaces</li>
        <li>BOOTP / PXE</li>
        <li>Agentes de relay DHCP (sin caso de uso legítimo sin soporte multi-segmento/multi-interfaz — ver arriba). Los campos <code>giaddr</code>/<code>hops</code> igual se parsean, pero solo para cerrar un hueco de spoofing, no para ofrecer funcionalidad de relay: sin ninguna validación, un atacante podría poner cualquier <code>giaddr</code> y lograr que el servidor mande respuestas DHCP no solicitadas a esa IP (reflection). El chequeo exige <code>hops >= 1</code> y que <code>giaddr == src_ip</code> (la IP real de quien envía) — si no coincide, el paquete se descarta y se registra como <code>"Spoofed relay dropped"</code>. Es una medida de hardening sobre un campo que hay que parsear de todas formas, no soporte de relay del que un despliegue pueda depender</li>
        <li><code>client-updates</code> / <code>deny client-updates</code> (depende de DDNS + opción FQDN del cliente, ninguna implementada)</li>
        <li>Override de <code>option subnet-mask</code> (la máscara enviada a los clientes siempre coincide con la declaración <code>subnet ... netmask ...</code>; sin soporte de override)</li>
        <li>Alcance de opciones por host/clase: las opciones declaradas a nivel <code>subnet</code> (ej. <code>option wpad ...;</code>) aplican a todos los clientes por igual. A diferencia de <code>isc-dhcp-server</code>, no hay forma de sobreescribir u omitir una opción de nivel subnet para un <code>host</code> o <code>class</code>/<code>subclass</code> específico — aquí <code>class</code>/<code>subclass</code> solo soportan el caso de bloqueo por MAC (ver <code>blockdhcp</code> abajo)</li>
      </ul>
    </td>
  </tr>
</table>

> DHCP (RFC 2131) inherits its minimum packet format from BOOTP (RFC 951); pydhcpd pads packets to that minimum for protocol compliance. This does not imply support for BOOTP clients or PXE boot.
>
> DHCP (RFC 2131) hereda el formato mínimo de paquete de BOOTP (RFC 951); pydhcpd rellena los paquetes a ese mínimo por cumplimiento del protocolo. Esto no implica soporte para clientes BOOTP ni arranque PXE.

## Repository Structure

---

```
pydhcp/
├── pydhcpd.py          # Daemon + all DHCP logic (DISCOVER/OFFER/REQUEST/ACK)
├── pydhcpd.conf        # Main config (replaces /etc/dhcp/dhcpd.conf)
├── pydhcpd.service     # systemd unit
├── pyinstall.sh        # Installer / uninstaller
├── init.d/
│   └── pydhcpd         # init.d wrapper (replaces /etc/init.d/isc-dhcp-server)
└── tools/
    ├── pyleases.sh     # Optional ACL and lease manager (see Tools section)
    └── pywebmin.sh     # Optional Webmin module installer (see Tools section)
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
/etc/pydhcp/default/pydhcpd       # Interface and daemon settings (created by installer, preserved on update)
/etc/pydhcp/pydhcpd.leases        # Active leases database
/etc/pydhcp/pydhcpd.pid           # PID file
/etc/pydhcp/tools/pyleases.env    # pyleases environment (auto-generated on first run)
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
sudo bash pyinstall.sh
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
sudo bash pyinstall.sh --update
# or
sudo bash pyinstall.sh --remove
```

| File | `--update` | `--remove` |
|------|-----------|------------|
| `pydhcpd.py` | ✅ overwritten | ✅ removed |
| `pydhcpd.service` | ✅ overwritten | ✅ removed |
| `init.d/pydhcpd` | ✅ overwritten | ✅ removed |
| `tools/pyleases.sh` | ✅ overwritten | ✅ removed |
| `tools/pywebmin.sh` | ✅ overwritten | ✅ removed |
| `pydhcpd.conf` | ⛔ preserved | ✅ removed |
| `default/pydhcpd` | ⛔ preserved | ✅ removed |
| `pydhcpd.leases` | ⛔ preserved | ✅ removed |
| `tools/pyleases.env` | ⛔ preserved | ✅ removed |
| `/var/log/pydhcpd.log` | ⛔ preserved | ✅ removed |
| `/etc/logrotate.d/pydhcpd` | ⛔ preserved | ✅ removed |
| `/var/log/pydhcp.log` (from `tools/pyleases.sh`) | ⛔ preserved | ✅ removed |
| `/etc/logrotate.d/pydhcp` (from `tools/pyleases.sh`) | ⛔ preserved | ✅ removed |
| system user/group `pydhcpd` | ⛔ preserved | ✅ removed |

### Config

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      The installer configures the interface, server IP, subnet, and pool range interactively. After installation, edit the configuration file only to add static host reservations or blocked MACs. Then restart the service to apply changes.
    </td>
    <td style="width: 50%; vertical-align: top;">
      El instalador configura la interfaz, IP del servidor, subred y rango del pool de forma interactiva. Tras la instalación, edita el archivo de configuración solo para agregar reservas estáticas o MACs bloqueadas. Luego reinicia el servicio para aplicar los cambios.
    </td>
  </tr>
</table>

| Description | Descripción | File |
|-------------|-------------|------|
| Main configuration file | Archivo de configuración principal | `/etc/pydhcp/pydhcpd.conf` |
| Default interface settings | Configuración de interfaz por defecto | `/etc/pydhcp/default/pydhcpd` |
| Active leases database | Base de datos de concesiones activas | `/etc/pydhcp/pydhcpd.leases` |
| pyleases environment (auto-generated on first run) | Entorno de pyleases (auto-generado en primera corrida) | `/etc/pydhcp/tools/pyleases.env` |
| systemd unit | Unidad systemd | `/etc/systemd/system/pydhcpd.service` |
| init.d wrapper | Wrapper init.d | `/etc/init.d/pydhcpd` |

```bash
# Edit main config | Editar configuración principal
sudo nano /etc/pydhcp/pydhcpd.conf

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
#              └─2356158 /usr/bin/python3 /etc/pydhcp/pydhcpd.py
# jun 09 17:51:49 host systemd[1]: Started pydhcpd.service - pydhcpd - Python DHCP Daemon.
# jun 09 17:51:49 host python3[1411247]: 2026-06-09 17:51:49,068 [INFO] Attached BPF filter to raw socket (udp dst port 67)
# jun 09 17:51:49 host python3[1449863]: 2026-06-09 16:20:31,317 [INFO] Config loaded: 158 static hosts, 208 blocked MACs
# jun 09 17:51:49 host python3[1449863]: 2026-06-09 16:20:31,323 [INFO] Leases loaded: 2 entries
# jun 09 17:51:49 host python3[1411247]: 2026-06-09 17:51:49,068 [INFO] Listening on enp2s0 (DHCP port 67)

# Other entries...
# jun 09 17:51:49 host python3[2356158]: 2026-06-09 17:51:49,071 [INFO] pydhcpd started (pid 2356158, interface enp2s0)
# jun 09 17:51:49 host python3[2356158]: 2026-06-09 17:51:49,072 [INFO] Listening on enp2s0 (DHCP port 67)
# jun 09 17:51:52 host python3[2356158]: 2026-06-09 17:51:52,316 [INFO] DISCOVER from aa:bb:cc:dd:ee:ff (FooBar)
# jun 09 17:51:52 host python3[2356158]: 2026-06-09 17:51:52,316 [WARNING] Blocked: aa:bb:cc:dd:ee:ff (deny blockdhcp)
# jun 09 17:52:02 host python3[2356158]: 2026-06-09 17:52:02,086 [INFO] DISCOVER from bb:cc:dd:ee:ff:aa (<no hostname>)
# jun 09 17:52:02 host python3[2356158]: 2026-06-09 17:52:02,154 [INFO] OFFER bb:cc:dd:ee:ff:aa → 192.168.0.231
# jun 09 17:52:02 host python3[2356158]: 2026-06-09 17:52:02,264 [INFO] REQUEST from bb:cc:dd:ee:ff:aa (<no hostname>)
# jun 09 17:52:02 host python3[2356158]: 2026-06-09 17:52:02,283 [INFO] ACK bb:cc:dd:ee:ff:aa → 192.168.0.231 (lease 60s)
# jun 09 17:52:15 host python3[2356158]: 2026-06-09 17:52:15,391 [INFO] DISCOVER from cc:dd:ee:ff:aa:bb (BazHost)
# jun 09 17:52:15 host python3[2356158]: 2026-06-09 17:52:15,391 [WARNING] No IP available for cc:dd:ee:ff:aa:bb
# jun 09 17:53:02 host python3[2356158]: 2026-06-09 17:53:02,173 [INFO] Lease expired: 192.168.0.230

# View active leases | Ver concesiones activas
cat /etc/pydhcp/pydhcpd.leases

# Reload config without restart (SIGHUP) | Recargar configuración sin reiniciar (SIGHUP)
sudo systemctl reload pydhcpd

# Test configuration syntax without starting the daemon (isc-dhcp-server compatible: -t [-cf FILE])
sudo /etc/pydhcp/pydhcpd.py --test
sudo /etc/pydhcp/pydhcpd.py -t -cf /path/to/alternate.conf

# View logs (journald) | Ver logs (journald)
sudo journalctl -u pydhcpd -f

# View logs (file) | Ver logs (archivo)
sudo tail -f /var/log/pydhcpd.log
```

#### Supported directives

| Directive | Description | Descripción |
|-----------|-------------|-------------|
| `authoritative;` | Server sends NAK to clients with foreign leases | El servidor envía NAK a clientes con leases ajenos |
| `not authoritative;` | Standard isc-dhcp-server syntax to explicitly disable authoritative mode (equivalent to omitting `authoritative;`) | Sintaxis estándar de isc-dhcp-server para desactivar explícitamente el modo autoritativo (equivalente a omitir `authoritative;`) |
| `cleanup-interval N;` | How often (seconds) expired leases are removed from memory | Frecuencia (segundos) con que se eliminan leases expirados de memoria |
| `server-identifier IP;` | IP the server uses to identify itself in DHCP replies | IP con la que el servidor se identifica en las respuestas DHCP |
| `deny duplicates;` | Reject requests from a MAC that already holds a lease | Rechaza solicitudes de una MAC que ya tiene un lease |
| `one-lease-per-client true;` | Release old lease before assigning a new one to the same MAC | Libera el lease anterior antes de asignar uno nuevo a la misma MAC |
| `deny declines;` | Ignore DHCPDECLINE messages | Ignora mensajes DHCPDECLINE |
| `ping-check true\|false;` | Ping IP before OFFER to detect conflicts (controlled via `PING_CHECK_ENABLED` in `pyleases.env`) | Ping a la IP antes del OFFER para detectar conflictos (controlado via `PING_CHECK_ENABLED` en `pyleases.env`) |
| `option wpad ...;` | WPAD/PAC proxy auto-configuration (controlled via `WPAD_ENABLED` in `pyleases.env`) | Autoconfiguración de proxy WPAD/PAC (controlado via `WPAD_ENABLED` en `pyleases.env`) |
| `subnet ... { pool { ... } }` | Subnet declaration with dynamic block pool | Declaración de subred con pool de bloqueo dinámico |
| `host NAME { hardware ethernet MAC; fixed-address IP; }` | Static host reservation | Reserva estática de host |
| `class "blockdhcp" { ... }` / `subclass "blockdhcp" ...` | MAC-based DHCP block list | Lista de bloqueo DHCP por MAC |
| `min-lease-time`, `default-lease-time`, `max-lease-time` | Lease duration controls | Control de duración de leases |
| `option routers`, `option broadcast-address`, `option domain-name-servers` | Standard DHCP options | Opciones DHCP estándar |

#### Operational Details

| Topic | Description | Descripción |
|---|---|---|
| Entry points | `pydhcpd` can be managed through three entry points — `systemctl`, the `/etc/init.d/pydhcpd` wrapper, and `pyleases.sh` (which calls `systemctl stop`/`start` internally whenever it regenerates `pydhcpd.conf`). On a `systemd` host (the only supported environment — see [Requirements](#requirements)), the `init.d` wrapper does not start its own process: it detects `systemd` and simply runs the equivalent `systemctl` command, so it and `systemctl` are always in sync, never two independent daemons. The only theoretical race is at the PID-file level (`write_pid()`) if the daemon were ever launched completely outside of `systemd`'s management — not a realistic path on the supported environment, but as a matter of operational hygiene: **use a single entry point at a time.** Don't run `pyleases.sh`, `systemctl`, and the `init.d` wrapper concurrently against the same instance (e.g. don't kick off `pyleases.sh` in one terminal while manually restarting via `systemctl` in another) — let one lifecycle operation finish before starting the next. | `pydhcpd` se puede administrar desde tres puntos de entrada — `systemctl`, el wrapper `/etc/init.d/pydhcpd`, y `pyleases.sh` (que llama internamente a `systemctl stop`/`start` cada vez que regenera `pydhcpd.conf`). En un host con `systemd` (el único entorno soportado — ver [Requirements](#requirements)), el wrapper `init.d` no arranca su propio proceso: detecta `systemd` y simplemente ejecuta el `systemctl` equivalente, así que él y `systemctl` siempre están sincronizados, nunca son dos demonios independientes. La única carrera teórica ocurre a nivel del archivo PID (`write_pid()`) si el demonio se lanzara completamente por fuera de la gestión de `systemd` — no es un camino real en el entorno soportado, pero como buena práctica operativa: **usa un solo punto de entrada a la vez.** No corras `pyleases.sh`, `systemctl` y el wrapper `init.d` de forma concurrente sobre la misma instancia (p.ej. no lances `pyleases.sh` en una terminal mientras reiniciás manualmente con `systemctl` en otra) — dejá que termine una operación del ciclo de vida antes de iniciar la siguiente. |
| Automatic restart on failure | if `pydhcpd` crashes or exits with an error (e.g. the configured network interface is not present at startup), `systemd` restarts it automatically — `pydhcpd.service` sets `Restart=on-failure` with `RestartSec=5` (retry every 5 seconds), capped at `StartLimitBurst=10` attempts within a `StartLimitIntervalSec=120` (2 minute) window. If the underlying problem is not resolved within those 10 attempts, `systemd` gives up and leaves the service in a `failed` state — it will **not** keep retrying indefinitely, and `pydhcpd` has no separate alerting mechanism to notify you when this happens. Check with `systemctl status pydhcpd` (a `failed` state needs a manual `systemctl reset-failed pydhcpd` before it can be started again) and watch `/var/log/pydhcpd.log` / `journalctl -u pydhcpd` for the root cause. | si `pydhcpd` falla o termina con un error (p.ej. la interfaz de red configurada no existe todavía al arrancar), `systemd` lo reinicia automáticamente — `pydhcpd.service` define `Restart=on-failure` con `RestartSec=5` (reintenta cada 5 segundos), con un tope de `StartLimitBurst=10` intentos dentro de una ventana de `StartLimitIntervalSec=120` (2 minutos). Si el problema de fondo no se resuelve dentro de esos 10 intentos, `systemd` se da por vencido y deja el servicio en estado `failed` — **no** va a seguir reintentando indefinidamente, y `pydhcpd` no tiene un mecanismo de aviso separado que notifique cuando esto pasa. Verifica con `systemctl status pydhcpd` (un estado `failed` necesita un `systemctl reset-failed pydhcpd` manual antes de poder arrancarlo de nuevo) y revisa `/var/log/pydhcpd.log` / `journalctl -u pydhcpd` para encontrar la causa raíz. |
| `ping-check` | `ping-check true` is enabled in the shipped `pydhcpd.conf`. The daemon sends a ping before each OFFER to verify the IP is not already in use. In environments with strict firewall rules blocking ICMP, the ping will always time out silently and `ping-check` will have no effect. To disable it, set `ping-check false;` in `/etc/pydhcp/pydhcpd.conf`. If using `pyleases.sh`, set `PING_CHECK_ENABLED=false` in `pyleases.env` instead — the script regenerates `pydhcpd.conf` on every run. | `ping-check true` viene activado en el `pydhcpd.conf` enviado. El demonio envía un ping antes de cada OFFER para verificar que la IP no está en uso. En entornos con reglas de firewall estrictas que bloquean ICMP, el ping siempre expirará sin respuesta y `ping-check` no tendrá ningún efecto. Para desactivarlo, establece `ping-check false;` en `/etc/pydhcp/pydhcpd.conf`. Si usas `pyleases.sh`, establece `PING_CHECK_ENABLED=false` en `pyleases.env` — el script regenera `pydhcpd.conf` en cada ejecución. |
| `cleanup-interval` | `cleanup-interval` controls how often (in seconds) the daemon removes expired leases from memory. The default is `60`. If you use a short pool lease-time (e.g. `10` or `30` seconds), set `cleanup-interval` to the same value or lower so that expired leases are freed promptly and the pool does not appear exhausted. When using `pyleases.sh`, set `CLEANUP_INTERVAL` in `pyleases.env` — it is written into `pydhcpd.conf` on every run. Config validation logs a `WARNING` (not an error — the daemon still starts) if `cleanup-interval` is greater than the pool's `min-lease-time`. | `cleanup-interval` controla con qué frecuencia (en segundos) el demonio elimina los arrendamientos expirados de la memoria. El valor por defecto es `60`. Si usas un lease-time corto en el pool (p.ej. `10` o `30` segundos), establece `cleanup-interval` al mismo valor o menor para que los arrendamientos expirados se liberen rápidamente y el pool no parezca agotado. Al usar `pyleases.sh`, define `CLEANUP_INTERVAL` en `pyleases.env` — se escribe en `pydhcpd.conf` en cada ejecución. La validación de configuración registra un `WARNING` (no un error — el demonio igual arranca) si `cleanup-interval` es mayor que el `min-lease-time` del pool. |
| Pool lease time default | the block pool's `min-lease-time` / `default-lease-time` / `max-lease-time` default to **60 seconds**, consistently across every path in this project: the shipped `pydhcpd.conf` template ships with `60` written explicitly in the `pool { }` block, `pyleases.sh` writes `60` (its `CLEANUP_INTERVAL` default) into the pool block on a fresh install, and `pydhcpd.py`'s own built-in fallback is also `60` (used only if a hand-written config omits the pool lease-time lines entirely). This keeps the default consistent with the short-lived, temporary nature of the block pool — unknown/blocked clients get a brief lease that is quickly recycled, unlike `AUTHORIZED_LEASE_TIME` (default `2592000`s / 30 days) used for the subnet-level lease given to authorized/static clients.<br><br>**To change it:** this is a per-installation choice, not something you edit in the project's code. If you manage `pydhcpd.conf` by hand, edit the `pool { min-lease-time / default-lease-time / max-lease-time }` values directly in your live `/etc/pydhcp/pydhcpd.conf` and restart/reload the daemon. If you use `pyleases.sh`, edit `CLEANUP_INTERVAL` in your `/etc/pydhcp/tools/pyleases.env` and re-run `pyleases.sh` — it rewrites `pydhcpd.conf` from that value on every run. | el `min-lease-time` / `default-lease-time` / `max-lease-time` del pool de bloqueo tienen por defecto **60 segundos**, de forma consistente en los tres caminos del proyecto: la plantilla `pydhcpd.conf` incluida trae `60` escrito explícitamente en el bloque `pool { }`, `pyleases.sh` escribe `60` (su valor por defecto de `CLEANUP_INTERVAL`) en el bloque del pool en una instalación nueva, y el respaldo interno propio de `pydhcpd.py` también es `60` (se usa solo si una configuración escrita a mano omite por completo las líneas de lease-time del pool). Esto mantiene el valor por defecto consistente con la naturaleza breve y temporal del pool de bloqueo — los clientes desconocidos/bloqueados reciben un lease corto que se recicla rápido, a diferencia de `AUTHORIZED_LEASE_TIME` (por defecto `2592000`s / 30 días) usado para el lease a nivel de subred que reciben los clientes autorizados/estáticos.<br><br>**Para cambiarlo:** es una decisión de cada instalación, no algo que se edite en el código del proyecto. Si administras `pydhcpd.conf` a mano, edita los valores de `pool { min-lease-time / default-lease-time / max-lease-time }` directamente en tu `/etc/pydhcp/pydhcpd.conf` real y reinicia/recarga el demonio. Si usas `pyleases.sh`, edita `CLEANUP_INTERVAL` en tu `/etc/pydhcp/tools/pyleases.env` y vuelve a correr `pyleases.sh` — reescribe `pydhcpd.conf` a partir de ese valor en cada ejecución. |
| IP quarantine | when an IP is quarantined — either because a client sent a DHCPDECLINE (ignored by default, see `deny declines;` above) or because `ping-check` detects it is already in use before an OFFER — it is held out of the pool for **60 seconds**, matching the pool lease time so a quarantined address is retried on the same cadence as a normal lease cycle instead of being held far longer than any lease would last. | cuando una IP se pone en cuarentena — ya sea porque un cliente envió un DHCPDECLINE (ignorado por defecto, ver `deny declines;` arriba) o porque `ping-check` detecta que ya está en uso antes de un OFFER — se aparta del pool por **60 segundos**, igual que el lease del pool, para que una dirección en cuarentena se reintente con la misma cadencia que un ciclo de lease normal en vez de quedar apartada mucho más tiempo del que dura cualquier lease. |
| Pool range cap | the `pool { range A B; }` directive is capped at **65536 addresses** (a `/16`). The daemon builds the full address set in memory at startup and re-sorts the free set on every allocation, so an oversized range (e.g. a `/8`) would waste memory and CPU proportional to its size. A range larger than the cap is rejected at config load (or `SIGHUP` reload) with a clear error instead of being silently accepted. | la directiva `pool { range A B; }` tiene un tope de **65536 direcciones** (un `/16`). El demonio construye el conjunto completo de direcciones en memoria al arrancar y reordena el conjunto libre en cada asignación, por lo que un rango sobredimensionado (p.ej. un `/8`) desperdiciaría memoria y CPU proporcional a su tamaño. Un rango mayor al tope se rechaza al cargar la configuración (o al recargar con `SIGHUP`) con un error claro, en vez de aceptarse en silencio. |

### Tools

---

#### pyleases

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      <b>pyleases.sh</b> — Advanced DHCP lease and ACL manager for pydhcpd. Parses <code>pydhcpd.leases</code>, detects unauthorized clients, rebuilds <code>pydhcpd.conf</code> from ACL files, and restarts the daemon. Designed for environments enforcing DHCP-based access control.<br><br>
      ACL directories: <code>/etc/acl/acl_mac/</code> (authorized: <code>mac-proxy.txt</code>, <code>mac-unlimited.txt</code>) and <code>/etc/acl/acl_dhcp/</code> (blocked: <code>blockdhcp.txt</code>).<br>
      Entry format: <code>a;MAC;IP;HOSTNAME;</code>
    </td>
    <td style="width: 50%; vertical-align: top;">
      <b>pyleases.sh</b> — Gestor avanzado de concesiones y ACLs DHCP para pydhcpd. Parsea <code>pydhcpd.leases</code>, detecta clientes no autorizados, reconstruye <code>pydhcpd.conf</code> a partir de archivos ACL y reinicia el demonio. Diseñado para entornos que aplican control de acceso basado en DHCP.<br><br>
      Directorios ACL: <code>/etc/acl/acl_mac/</code> (autorizados: <code>mac-proxy.txt</code>, <code>mac-unlimited.txt</code>) y <code>/etc/acl/acl_dhcp/</code> (bloqueados: <code>blockdhcp.txt</code>).<br>
      Formato: <code>a;MAC;IP;HOSTNAME;</code>
    </td>
  </tr>
</table>

```bash
sudo bash tools/pyleases.sh
```

> **First run**: pyleases.sh launches an interactive setup that asks for DHCP server IP, netmask, block-pool range, and DNS servers, and writes `/etc/pydhcp/tools/pyleases.env`. Delete this file to re-run the setup. Some of these prompts overlap with `pyinstall.sh` — answer consistently.
>
> **Primera corrida**: pyleases.sh inicia un setup interactivo que pregunta IP del servidor DHCP, máscara, rango del pool de bloqueo y DNS, y escribe `/etc/pydhcp/tools/pyleases.env`. Elimine ese archivo para volver a ejecutar el setup. Algunas preguntas se solapan con `pyinstall.sh` — responda consistentemente.

**Warning**

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      <ul>
        <li><code>--update</code> backs up replaced files to <code>/etc/pydhcp/bak/TIMESTAMP/</code> before overwriting them. <code>pydhcpd.conf</code> and <code>default/pydhcpd</code> are <b>never overwritten</b> by <code>--update</code> (user config is preserved). Any manual edit to the code files (<code>pydhcpd.py</code>, <code>pyleases.sh</code>, <code>pywebmin.sh</code>) will be replaced. To persist a custom directive, edit the template inside <code>pyleases.sh</code> itself.</li>
        <li><code>pyleases.sh</code> fully rebuilds <code>/etc/pydhcp/pydhcpd.conf</code> on every run from its ACL files and <code>pyleases.env</code>. Any manual edits to <code>pydhcpd.conf</code> — including custom lease times, pools, or directives — will be lost. If you manage <code>pydhcpd.conf</code> manually, do not use <code>pyleases.sh</code>.</li>
      </ul>
    </td>
    <td style="width: 50%; vertical-align: top;">
      <ul>
        <li><code>--update</code> respalda los archivos reemplazados en <code>/etc/pydhcp/bak/TIMESTAMP/</code> antes de sobrescribirlos. <code>pydhcpd.conf</code> y <code>default/pydhcpd</code> <b>nunca se sobreescriben</b> (la configuración del usuario se preserva). Cualquier edición manual a los archivos de código (<code>pydhcpd.py</code>, <code>pyleases.sh</code>, <code>pywebmin.sh</code>) será reemplazada. Para preservar una directiva personalizada, edite el template dentro del propio <code>pyleases.sh</code>.</li>
        <li><code>pyleases.sh</code> reconstruye completamente <code>/etc/pydhcp/pydhcpd.conf</code> en cada ejecución a partir de sus archivos ACL y <code>pyleases.env</code>. Cualquier edición manual a <code>pydhcpd.conf</code> — incluyendo lease times, pools o directivas personalizadas — se perderá. Si gestiona <code>pydhcpd.conf</code> manualmente, no utilice <code>pyleases.sh</code>.</li>
      </ul>
    </td>
  </tr>
</table>

##### WPAD/PAC via DHCP option 252 (optional)

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      <code>pyleases.sh</code> generates <code>/etc/pydhcp/pydhcpd.conf</code> dynamically on every run. WPAD/PAC support is controlled entirely from <code>pyleases.env</code> — no manual editing of <code>pyleases.sh</code> is required.
    </td>
    <td style="width: 50%; vertical-align: top;">
      <code>pyleases.sh</code> genera <code>/etc/pydhcp/pydhcpd.conf</code> dinámicamente en cada ejecución. El soporte WPAD/PAC se controla completamente desde <code>pyleases.env</code> — no se requiere editar manualmente <code>pyleases.sh</code>.
    </td>
  </tr>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      <b>To enable/disable WPAD:</b>
      <ul>
        <li>Set <code>WPAD_ENABLED=true</code> in <code>/etc/pydhcp/tools/pyleases.env</code> to enable</li>
        <li>Set <code>WPAD_ENABLED=false</code> in <code>/etc/pydhcp/tools/pyleases.env</code> to disable (default)</li>
      </ul>
      <b>Prerequisites (if enabled):</b>
      <ol>
        <li>Install Apache2 and create a VirtualHost on port 18100.</li>
        <li>Place a valid <code>wpad.pac</code> file in the Apache document root for that VirtualHost.</li>
      </ol> The two <code>option wpad</code> lines will be automatically written to <code>/etc/pydhcp/pydhcpd.conf</code> on the next <code>pyleases.sh</code> run.
    </td>
    <td style="width: 50%; vertical-align: top;">
      <b>Para activar/desactivar WPAD:</b>
      <ul>
        <li>Establezca <code>WPAD_ENABLED=true</code> en <code>/etc/pydhcp/tools/pyleases.env</code> para activar</li>
        <li>Establezca <code>WPAD_ENABLED=false</code> en <code>/etc/pydhcp/tools/pyleases.env</code> para desactivar (por defecto)</li>
      </ul>
      <b>Requisitos previos (si está activado):</b>
      <ol>
        <li>Instale Apache2 y cree un VirtualHost en el puerto 18100.</li>
        <li>Coloque un archivo <code>wpad.pac</code> válido en el document root de ese VirtualHost.</li>
      </ol> Las dos líneas <code>option wpad</code> se escribirán automáticamente en <code>/etc/pydhcp/pydhcpd.conf</code> en la próxima ejecución de <code>pyleases.sh</code>.
    </td>
  </tr>
</table>

> Android and iOS ignore DHCP option 252. The proxy must be configured manually on those devices.
>
> Android e iOS ignoran la opción DHCP 252. El proxy debe configurarse manualmente en esos dispositivos.

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

```bash
# Install | Instalar
sudo bash tools/pywebmin.sh install

# Uninstall | Desinstalar
sudo bash tools/pywebmin.sh uninstall
```

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

## Replacing isc-dhcp-server

---

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      The following table maps <code>isc-dhcp-server</code> paths and commands to their <code>pydhcp</code> equivalents:
    </td>
    <td style="width: 50%; vertical-align: top;">
      La siguiente tabla mapea las rutas y comandos de <code>isc-dhcp-server</code> con sus equivalentes en <code>pydhcp</code>:
    </td>
  </tr>
</table>

| isc-dhcp-server | pydhcp |
|-----------------|--------|
| `/etc/dhcp/dhcpd.conf` | `/etc/pydhcp/pydhcpd.conf` |
| `/var/lib/dhcp/dhcpd.leases` | `/etc/pydhcp/pydhcpd.leases` |
| `/etc/default/isc-dhcp-server` | `/etc/pydhcp/default/pydhcpd` |
| `/var/run/dhcpd.pid` | `/etc/pydhcp/pydhcpd.pid` |
| `/etc/systemd/system/isc-dhcp-server.service` | `/etc/systemd/system/pydhcpd.service` |
| `/etc/init.d/isc-dhcp-server` | `/etc/init.d/pydhcpd` |
| `systemctl start\|stop\|restart\|status isc-dhcp-server` | `systemctl start\|stop\|restart\|status pydhcpd` |
| `service isc-dhcp-server start\|stop\|restart\|status` | `service pydhcpd start\|stop\|restart\|status` |
| `dhcpd -t -cf /etc/dhcp/dhcpd.conf` | `pydhcpd.py -t -cf /etc/pydhcp/pydhcpd.conf` |

### Logs

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      Log output format differs between servers but the behavior is equivalent. The following examples show the three main scenarios.<br>
      <em>isc-dhcp-server shows the hostname starting from OFFER; pydhcpd shows it from DISCOVER onward.</em>
    </td>
    <td style="width: 50%; vertical-align: top;">
      El formato de log difiere entre servidores pero el comportamiento es equivalente. Los siguientes ejemplos muestran los tres escenarios principales.<br>
      <em>isc-dhcp-server muestra el hostname a partir del OFFER; pydhcpd lo muestra desde el DISCOVER.</em>
    </td>
  </tr>
</table>

#### Path

| Resource | isc-dhcp-server | pydhcpd |
|----------|-----------------|---------|
| Log file | `/var/log/syslog` | `/var/log/pydhcpd.log` |
| Log rotation | `/etc/logrotate.d/rsyslog` | `/etc/logrotate.d/pydhcpd` |
| journald | `journalctl -u isc-dhcp-server` | `journalctl -u pydhcpd` |

> pydhcpd writes logs directly to `/var/log/pydhcpd.log`. It does not use syslog, therefore no `log-facility` directive is needed or supported.
>
> pydhcpd escribe los logs directamente a `/var/log/pydhcpd.log`. No utiliza syslog, por lo tanto no se necesita ni se soporta la directiva `log-facility`.

#### Scenario

| Scenario | isc-dhcp-server | pydhcpd |
|----------|-----------------|---------|
| Authorized client with static IP (renewal) / Cliente autorizado con IP estática (renovación) | `DHCPREQUEST for 192.168.0.50 (192.168.0.2) from aa:bb:cc:dd:ee:ff via enp2s0`<br>`DHCPACK on 192.168.0.50 to aa:bb:cc:dd:ee:ff (FOO) via enp2s0` | `REQUEST from aa:bb:cc:dd:ee:ff (FOO)`<br>`ACK aa:bb:cc:dd:ee:ff → 192.168.0.50 (lease 2592000s)` |
| Unknown client entering the block pool / Cliente desconocido ingresando al pool de bloqueo | `DHCPDISCOVER from bb:cc:dd:ee:ff:aa via enp2s0`<br>`DHCPOFFER on 192.168.0.230 to bb:cc:dd:ee:ff:aa (BAR) via enp2s0`<br>`DHCPREQUEST for 192.168.0.230 (192.168.0.2) from bb:cc:dd:ee:ff:aa (BAR) via enp2s0`<br>`DHCPACK on 192.168.0.230 to bb:cc:dd:ee:ff:aa (BAR) via enp2s0` | `DISCOVER from bb:cc:dd:ee:ff:aa (BAR)`<br>`OFFER bb:cc:dd:ee:ff:aa → 192.168.0.230`<br>`REQUEST from bb:cc:dd:ee:ff:aa (BAR)`<br>`ACK bb:cc:dd:ee:ff:aa → 192.168.0.230 (lease 60s)` |
| Pool exhausted / Pool agotado | `DHCPDISCOVER from bb:cc:dd:ee:ff:aa via enp2s0: network 192.168.0.0/24: no free leases` | `DISCOVER from bb:cc:dd:ee:ff:aa (BAR)`<br>`No IP available for bb:cc:dd:ee:ff:aa` |
| Blocked client / Cliente bloqueado | `DHCPDISCOVER from bb:cc:dd:ee:ff:aa via enp2s0: network 192.168.0.0/24: no free leases` † | `DISCOVER from bb:cc:dd:ee:ff:aa (BAR)`<br>`Blocked: bb:cc:dd:ee:ff:aa (deny blockdhcp)` |

† Not a copy-paste of the row above — this is the actual `isc-dhcp-server` log line for a blocked client too. A `deny members of "blockdhcp"` pool becomes invisible to that class, so from `isc-dhcp-server`'s point of view there is no lease available for it, the same message as a genuinely full pool. It cannot tell the two cases apart in its log; `pydhcpd` can (`Blocked:` vs `No IP available`).

#### Authoritative

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      When <code>authoritative;</code> is set, the server sends NAK to clients that request an IP assigned by a rogue DHCP server on the same network. The rogue may win the OFFER race, but the authoritative server destroys the lease by sending NAK to the REQUEST — forcing the client to rediscover and obtain the correct IP. This behavior is equivalent between isc-dhcp-server and pydhcpd.
      <br><br>
      <code>authoritative;</code> does not prevent a rogue DHCP server from reaching clients — <code>DHCPOFFER</code>/<code>DHCPACK</code> go directly to the client, and no DHCP server can block another's packets at the protocol level. It only forces a correction after the fact: the client's <code>REQUEST</code> is broadcast and always reaches the authoritative server, which can NAK it, forcing the client to discard the rogue lease and restart. As a complementary measure, it is recommended to check whether your switch hardware supports <b>DHCP Snooping</b> and, if so, consider enabling it — this blocks rogue DHCP traffic at the network layer, before it ever reaches a client, rather than correcting it afterward like <code>authoritative</code> does.
    </td>
    <td style="width: 50%; vertical-align: top;">
      Cuando se configura <code>authoritative;</code>, el servidor envía NAK a clientes que solicitan una IP asignada por un servidor DHCP no autorizado en la misma red. El rogue puede ganar la carrera del OFFER, pero el servidor autoritativo destruye el arrendamiento enviando NAK al REQUEST — forzando al cliente a redescubrir y obtener la IP correcta. Este comportamiento es equivalente entre isc-dhcp-server y pydhcpd.
      <br><br>
      <code>authoritative;</code> no evita que un servidor DHCP no autorizado le llegue a los clientes — <code>DHCPOFFER</code>/<code>DHCPACK</code> van directo al cliente, y ningún servidor DHCP puede bloquear los paquetes de otro a nivel de protocolo. Solo corrige el resultado después del hecho: el <code>REQUEST</code> del cliente se manda por broadcast y siempre llega al servidor autoritativo, que puede rechazarlo con NAK, forzando al cliente a descartar el lease del rogue y reiniciar. Como medida complementaria, se recomienda verificar si su hardware de switch soporta <b>DHCP Snooping</b> y, de ser así, considerar activarlo — esto bloquea el tráfico DHCP no autorizado a nivel de red, antes de que le llegue al cliente, en vez de corregirlo después como hace <code>authoritative</code>.
    </td>
  </tr>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      <b>isc-dhcp-server</b> also accepts the explicit negation <code>not authoritative;</code>, standard <code>dhcpd.conf</code> syntax to mark a scope as non-authoritative (equivalent to omitting <code>authoritative;</code>).
    </td>
    <td style="width: 50%; vertical-align: top;">
      <b>pydhcpd</b> también acepta <code>not authoritative;</code>, la misma sintaxis estándar de <code>dhcpd.conf</code> (equivalente a omitir <code>authoritative;</code>).
    </td>
  </tr>
</table>

The table below compares what each daemon's own log would show if it were the **authoritative** server defending against the same rogue, event by event — not a mixed trace of one daemon acting as the rogue.

| Event | isc-dhcp-server (as authoritative) | pydhcpd (as authoritative) |
|-------|-------------------------------------|-----------------------------|
| Rogue offers IP to client | *(not observed)* † | *(not observed)* † |
| Client requests rogue IP | `DHCPREQUEST for 192.168.0.222 (192.168.0.249) from bb:cc:dd:ee:ff:aa (BAR) via enp2s0` | `REQUEST from bb:cc:dd:ee:ff:aa (BAR)` |
| Rogue acknowledges | *(not observed)* † | *(not observed)* † |
| **Authoritative server rejects** | `DHCPNAK on 192.168.0.222 to bb:cc:dd:ee:ff:aa via enp2s0` | `NAK → bb:cc:dd:ee:ff:aa` |
| Client rediscovers | `DHCPDISCOVER from bb:cc:dd:ee:ff:aa via enp2s0` | `DISCOVER from bb:cc:dd:ee:ff:aa (BAR)` |

† Neither daemon sees these packets: `DHCPOFFER`/`DHCPACK` are addressed to the client, not to other DHCP servers on the segment.

#### Rate Limiting

| isc-dhcp-server | pydhcpd |
|---|---|
| Has no built-in per-client rate-limiting for lease allocation. Abuse mitigation relies on `deny duplicates;` and `one-lease-per-client true;`, plus pool exhaustion (once the pool is full, further `DHCPDISCOVER` messages simply receive no `DHCPOFFER`). Client identification is based on `chaddr` (or `client-id`, option 61) — never on the Ethernet source MAC of the frame, so behavior is identical whether the client is directly attached or behind a relay (`giaddr` is only used for routing the reply).<br><br>No tiene rate-limiting incorporado por cliente para la asignación de leases. La mitigación de abuso depende de `deny duplicates;` y `one-lease-per-client true;`, además del agotamiento del pool (una vez lleno, los `DHCPDISCOVER` simplemente no reciben `DHCPOFFER`). La identificación del cliente se basa en `chaddr` (o `client-id`, opción 61) — nunca en la MAC Ethernet origen del frame, por lo que el comportamiento es igual si el cliente está conectado directamente o detrás de un relay (`giaddr` solo se usa para enrutar la respuesta). | Adds a sliding-window rate limit on lease allocation, keyed by **client MAC (`chaddr`)** — the same identifier isc-dhcp-server uses. Each client MAC has its own bucket, so multiple clients behind the same relay are rate-limited independently and do not affect each other. If a single MAC exceeds the allowed number of allocations within the window, further requests are rejected with reason `"rate limited"` until the window slides forward. This is purely an internal safeguard against allocation storms; it is not configurable via `pydhcpd.conf` and has no equivalent directive in isc-dhcp-server.<br><br>Agrega un límite de tasa (sliding window) sobre la asignación de leases, indexado por **MAC del cliente (`chaddr`)** — el mismo identificador que usa isc-dhcp-server. Cada MAC de cliente tiene su propio cupo, de modo que varios clientes detrás del mismo relay se limitan de forma independiente y no se afectan entre sí. Si una MAC supera el número de asignaciones permitidas dentro de la ventana, las solicitudes adicionales se rechazan con la razón `"rate limited"` hasta que la ventana avance. Esto es solo una salvaguarda interna contra ráfagas de asignación; no es configurable desde `pydhcpd.conf` y no tiene directiva equivalente en isc-dhcp-server. |

> **known limitation, both servers:** neither controls an attacker who rotates MAC addresses to exhaust the pool. `isc-dhcp-server`'s gap is total — it has no per-client throttle at all, so a plain flood from a single MAC already drains the pool, no rotation needed. `pydhcpd`'s gap is narrower: its per-MAC limit stops a single-MAC flood, but is keyed by MAC (`chaddr`), so it only bounds how fast *one* MAC can allocate — it does not cap the total across many different MACs, and an attacker rotating MACs can still drain the pool one new MAC at a time. A global (cross-MAC) rate limit was considered and intentionally left out of `pydhcpd`: it would need careful tuning to avoid rejecting legitimate clients during a normal burst of reconnections (e.g. many devices rejoining after a power outage), and there is no evidence MAC-rotation abuse is a live threat worth that trade-off. Documented here as a known, accepted limitation.
>
> **limitación conocida, en ambos servidores:** ninguno controla a un atacante que rota direcciones MAC para agotar el pool. La brecha de `isc-dhcp-server` es total — no tiene ningún control por cliente, así que una inundación simple desde una sola MAC ya agota el pool, sin necesidad de rotar. La brecha de `pydhcpd` es más acotada: su límite por MAC frena la inundación de una sola MAC, pero está indexado por MAC (`chaddr`), así que solo acota qué tan rápido puede asignar *una* MAC — no limita el total entre muchas MACs distintas, y un atacante que rote MACs igual puede vaciar el pool, una MAC nueva a la vez. Se evaluó un límite global (entre todas las MACs) para `pydhcpd` y se dejó afuera intencionalmente: requeriría un ajuste cuidadoso para no rechazar clientes legítimos durante una ráfaga normal de reconexiones (p.ej. varios dispositivos reconectándose tras un corte de luz), y no hay evidencia de que el abuso por rotación de MAC sea una amenaza activa que justifique ese costo. Se documenta acá como una limitación conocida y aceptada.

#### WPAD/PAC Option Scoping

| isc-dhcp-server | pydhcpd |
|---|---|
| Supports scoping any option — including `option wpad` (252) — at multiple levels: `subnet`, `class`/`subclass`, or an individual `host`. A more specific scope overrides a broader one, so an admin can declare WPAD at the `subnet` level for every client and then override or omit it for a specific `class` or `host` (e.g. exclude a group of trusted/unrestricted devices from the PAC).<br><br>Soporta el alcance de cualquier opción — incluyendo `option wpad` (252) — en varios niveles: `subnet`, `class`/`subclass`, o un `host` individual. Un alcance más específico sobreescribe uno más amplio, así que un administrador puede declarar WPAD a nivel `subnet` para todos los clientes y luego sobreescribirlo u omitirlo para una `class` o `host` específico (ej. excluir a un grupo de dispositivos confiables/sin restricción del PAC). | Has no option-scoping mechanism at all — `config.wpad_url` is a single global value read once from the `subnet` block, applied identically to every `OFFER`/`ACK`/`INFORM` it sends. `WPAD_ENABLED` in `pyleases.env` is therefore all-or-nothing: on turns WPAD on for every client, off turns it off for every client. The existing `class "blockdhcp"`/`subclass` mechanism does not generalize to this — it only marks MACs for lease denial, not a scoping construct for arbitrary options like isc-dhcp-server's classes.<br><br>No tiene ningún mecanismo de alcance de opciones — `config.wpad_url` es un único valor global leído una vez del bloque `subnet`, aplicado igual a cada `OFFER`/`ACK`/`INFORM` que envía. `WPAD_ENABLED` en `pyleases.env` es entonces todo-o-nada: activado prende WPAD para todos los clientes, desactivado lo apaga para todos. El mecanismo existente de `class "blockdhcp"`/`subclass` no generaliza a este caso — solo marca MACs para negarles el lease, no un constructo de alcance para opciones arbitrarias como sí lo son las clases de isc-dhcp-server. |

> **Workaround (external to pydhcp):** if `WPAD_ENABLED=true` and some MACs must never see the PAC, block their access to the PAC's port (e.g. 18100) at the firewall. This does not stop `pydhcpd` from sending option 252 to them, but the client can never fetch the PAC file, and the PAC's own `DIRECT` fallback lets it proceed without a proxy. This is a firewall-side workaround, not a `pydhcp` feature — `pydhcp` has no firewall component and does not ship or manage this rule itself.
>
> **Workaround (externo a pydhcp):** si `WPAD_ENABLED=true` y algunas MACs nunca deben ver el PAC, bloquee su acceso al puerto del PAC (ej. 18100) en el firewall. Esto no evita que `pydhcpd` les mande la opción 252, pero el cliente nunca podrá descargar el archivo PAC, y el fallback `DIRECT` del propio PAC le permite seguir sin proxy. Este es un workaround del lado del firewall, no una funcionalidad de `pydhcp` — `pydhcp` no tiene componente de firewall y no provee ni gestiona esa regla.

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
|Scripts, Binaries, Infrastructure|[![GPL-3.0](https://img.shields.io/badge/Open_Core-GPLv3-blue.svg?style=for-the-badge&labelWidth=120&logoWidth=20)](https://www.gnu.org/licenses/gpl.txt)|
|RAG, Workers, Specialized Modules, Docs|[![CC](https://img.shields.io/badge/Core_Engine-CC_BY--NC--ND_4.0-lightgrey.svg?style=for-the-badge&labelWidth=120&logoWidth=20)](https://creativecommons.org/licenses/by-nc-nd/4.0/)|

## DISCLAIMER

---

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
