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
        <li>Clients whose <code>chaddr</code> differs from the Ethernet source MAC of the frame. For non-relayed packets the daemon requires <code>chaddr == src_mac</code>; a mismatch is dropped and logged as <code>"chaddr spoofing detected"</code>. This closes a spoofing hole, but it also means setups where the two legitimately differ (some virtualization/bridging layers that rewrite the frame MAC, chainloading boot loaders) will not be served</li>
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
        <li>Clientes cuyo <code>chaddr</code> difiere de la MAC Ethernet origen del frame. Para paquetes no relayados el demonio exige <code>chaddr == src_mac</code>; si no coinciden, el paquete se descarta y se registra como <code>"chaddr spoofing detected"</code>. Esto cierra un hueco de spoofing, pero también implica que los escenarios donde ambos difieren legítimamente (capas de virtualización/bridging que reescriben la MAC del frame, cargadores de arranque encadenados) no reciben servicio</li>
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
├── pysetup.sh          # Installer / uninstaller
├── README.md
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
/etc/pydhcp/pydhcpd.leases            # Active leases database
/etc/pydhcp/pydhcpd.pid               # PID file
/etc/pydhcp/pydhcpd.conf.bak          # Previous pydhcpd.conf, written by pyleases.sh before each rebuild
/etc/pydhcp/pydhcp.env.bak            # pydhcp.env backup, written once by pyleases.sh before adding missing keys
/etc/pydhcp/bak/<TIMESTAMP>/          # Per-run backup created by pysetup.sh --update
/etc/pydhcp/pydhcpd.conf.bak.<epoch>  # Up to 5 kept, written by the Webmin module (pywebmin.sh) on each config save
/etc/webmin/pydhcp/.csrf_token        # CSRF secret for the Webmin module (pywebmin.sh), mode 0600
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
| `tools/pyleases.sh` | ✅ overwritten | ✅ removed |
| `tools/pywebmin.sh` | ✅ overwritten | ✅ removed (also uninstalls the Webmin module, if installed) |
| `pydhcpd.conf` | ⛔ preserved | ✅ removed |
| `pydhcpd.leases` | ⛔ preserved | ✅ removed |
| `pydhcp.env` | ⛔ preserved | ✅ removed |
| `/var/log/pydhcp.log` (shared by the daemon, `pysetup.sh` and `tools/pyleases.sh`) | ⛔ preserved | ✅ removed |
| `/etc/logrotate.d/pydhcp` | ⛔ preserved | ✅ removed |
| system user/group `pydhcpd` | ⛔ preserved | ✅ removed |
| `/etc/acl/acl_mac/`, `/etc/acl/acl_dhcp/` (ACL directories/files) | ⛔ preserved | ⛔ preserved |

`/etc/acl` is never touched by `--remove`. These directories hold optional ACL lists that `pydhcp` itself may or may not use, depending on whether the optional `tools/pyleases.sh` tool is ever run — `pysetup.sh` creates them regardless, so uninstalling the daemon does not assume the ACL data is safe to discard.

`/etc/acl` nunca se toca en `--remove`. Estos directorios contienen listas ACL opcionales que `pydhcp` puede o no usar, según si la herramienta opcional `tools/pyleases.sh` llega a ejecutarse — `pysetup.sh` los crea de todos modos, así que desinstalar el demonio no asume que los datos ACL sean seguros de descartar.

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

| Description | Descripción | File |
|-------------|-------------|------|
| Main configuration file | Archivo de configuración principal | `/etc/pydhcp/pydhcpd.conf` |
| Active leases database | Base de datos de concesiones activas | `/etc/pydhcp/pydhcpd.leases` |
| Shared config: daemon defaults (config/pid/leases paths, interface, user/group), network values, ACL paths, lease timers and WPAD/ping-check flags — all generated by `pysetup.sh` at install time; `tools/pyleases.sh` only adds any of these that are still missing (e.g. after an update from an older `pysetup.sh`) | Configuración compartida: defaults del demonio (rutas de config/pid/leases, interfaz, usuario/grupo), valores de red, rutas ACL, temporizadores de lease y flags de WPAD/ping-check — todos generados por `pysetup.sh` durante la instalación; `tools/pyleases.sh` solo agrega los que falten (p.ej. tras una actualización desde un `pysetup.sh` anterior) | `/etc/pydhcp/pydhcp.env` |
| systemd unit | Unidad systemd | `/etc/systemd/system/pydhcpd.service` |
| init.d wrapper | Wrapper init.d | `/etc/init.d/pydhcpd` |

### File Ownership and Permissions

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      The daemon runs as the system account <code>pydhcpd</code>, not as root, with two kernel capabilities granted by <code>pydhcpd.service</code>: <code>CAP_NET_RAW</code> (raw socket and ICMP ping-check) and <code>CAP_NET_BIND_SERVICE</code> (bind port 67). No other capability is needed or granted. Ownership is therefore assigned by <b>what the daemon does with each file</b>, not uniformly. These values are set by <code>pysetup.sh</code> and are deliberate — the table documents the reasoning so it does not have to be re-derived.
    </td>
    <td style="width: 50%; vertical-align: top;">
      El demonio corre bajo la cuenta de sistema <code>pydhcpd</code>, no como root, con dos capacidades del kernel concedidas por <code>pydhcpd.service</code>: <code>CAP_NET_RAW</code> (socket crudo y ping-check ICMP) y <code>CAP_NET_BIND_SERVICE</code> (escuchar en el puerto 67). No necesita ni recibe ninguna otra. Por eso el propietario se asigna según <b>qué hace el demonio con cada archivo</b>, no de forma uniforme. Estos valores los aplica <code>pysetup.sh</code> y son deliberados — la tabla documenta el porqué para no tener que deducirlo otra vez.
    </td>
  </tr>
</table>

| Path | Owner | Mode | What the daemon does | Why |
|------|-------|------|----------------------|-----|
| `/etc/pydhcp` | `root:pydhcpd` | `770` | creates, renames and deletes entries | **Others get nothing** — no other account on the system can even enter the directory. Group `w` is the minimum that works: the daemon creates a temp file and `os.replace()`s it over the leases file, and creates and removes its PID file. `750` breaks all four operations. The group has exactly one member: the daemon's own service account (shell `/bin/false`, no home, no supplementary groups). **No sticky bit** — see the note below |
| `pydhcpd.py` | `root:root` | `755` | reads and executes | Root-owned so the daemon cannot modify the code it is running. `/etc/pydhcp` being `770` already blocks every other account, so the `others` bits are what the daemon reads through |
| `pydhcpd.conf` | `root:pydhcpd` | `640` | reads | Read through the group. Root-owned so a compromised daemon cannot rewrite its own configuration |
| `pydhcp.env` | `root:pydhcpd` | `640` | reads | Same as above. `640` keeps it out of reach of other users |
| `pydhcpd.leases` | `pydhcpd:pydhcpd` | `640` | replaces atomically | Must be daemon-owned: `os.replace()` over it inside a sticky directory requires owning the target file |
| `pydhcpd.pid` | `pydhcpd:pydhcpd` | `640` | creates and deletes | Must be daemon-owned: `os.remove()` inside a sticky directory requires owning the file |
| `pydhcpd.conf.bak` | `root:root` | `640` | never touches it | Single rollback copy written by `tools/pyleases.sh` before it regenerates the config, and restored automatically if the daemon then fails to start. Created with `cp`, which preserves the source's `640` |
| `pydhcpd.conf.bak.<epoch>` | `root:root` | `640` | never touches it | Up to 5 kept by the Webmin module (`tools/pywebmin.sh`), one per save from the browser editor, so repeated saves do not overwrite the original. Perl's `File::Copy` does not preserve the source mode, so `config.cgi` applies `chmod 0640` explicitly — otherwise the backup would land at whatever root's umask dictates and end up more permissive than the config it copies |
| `/var/log/pydhcp.log` | `pydhcpd:pydhcpd` | `640` | appends | Daemon-owned so it can write. `pysetup.sh` and `tools/pyleases.sh` also write to it, but they run as root |
| `tools/` | `root:root` | `755` | never touches it | Run manually by root; not part of the daemon's runtime |
| `pydhcpd.service` | `root:root` | `644` | — | Belongs to systemd |
| `/etc/init.d/pydhcpd` | `root:root` | `755` | — | Belongs to sysvinit |
| `/etc/logrotate.d/pydhcp` | `root:root` | `644` | — | logrotate ignores configuration files not owned by root |

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      <b>Do not "unify" these into a single owner.</b> Making everything <code>pydhcpd:pydhcpd</code> would hand the directory to the daemon, which could then replace any entry in it, including its own code. Making everything <code>root:pydhcpd</code> would break the leases and PID files, whose atomic replace and removal require ownership, and would need <code>CAP_FOWNER</code> to work around.
    </td>
    <td style="width: 50%; vertical-align: top;">
      <b>No "unifique" esto en un solo propietario.</b> Poner todo en <code>pydhcpd:pydhcpd</code> le entregaría el directorio al demonio, que podría entonces reemplazar cualquier entrada, incluido su propio código. Poner todo en <code>root:pydhcpd</code> rompería los archivos de concesiones y PID, cuyo reemplazo atómico y borrado exigen ser propietario, y requeriría <code>CAP_FOWNER</code> para sortearlo.
    </td>
  </tr>
</table>

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      <b>Why <code>/etc/pydhcp</code> carries no sticky bit.</b> A sticky bit (<code>1770</code>) would stop the daemon from deleting entries it does not own, which looks like an obvious hardening. It is not usable here: with <code>fs.protected_regular=2</code> — the default on several distributions — the kernel refuses to let <b>any</b> process, <b>including root</b>, truncate or replace a file owned by another user inside a sticky directory. That check ignores capabilities, so <code>CAP_DAC_OVERRIDE</code> does not bypass it. The lease-manager tools run as root and rewrite <code>pydhcpd.leases</code>, which is owned by the daemon: with the sticky bit set they fail with <code>EACCES</code> and the reload chain aborts. The directory is therefore <code>770</code>, matching how this project's other service directories are set up.
    </td>
    <td style="width: 50%; vertical-align: top;">
      <b>Por qué <code>/etc/pydhcp</code> no lleva bit sticky.</b> Un bit sticky (<code>1770</code>) impediría que el demonio borrara entradas que no le pertenecen, y parece un endurecimiento evidente. Aquí no es utilizable: con <code>fs.protected_regular=2</code> — el valor por defecto en varias distribuciones — el núcleo impide que <b>cualquier</b> proceso, <b>incluido root</b>, trunque o reemplace un archivo de otro usuario dentro de un directorio con sticky. Esa comprobación ignora las capacidades, así que <code>CAP_DAC_OVERRIDE</code> no la sortea. Las herramientas de gestión de concesiones corren como root y reescriben <code>pydhcpd.leases</code>, que pertenece al demonio: con el sticky puesto fallan con <code>EACCES</code> y la cadena de recarga se aborta. Por eso el directorio es <code>770</code>, en línea con los demás directorios de servicio de este proyecto.
    </td>
  </tr>
</table>

```bash
# Verify ownership and permissions | Verificar propietarios y permisos
sudo ls -ld /etc/pydhcp
sudo ls -l /etc/pydhcp/ /var/log/pydhcp.log
```

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
# jun 09 17:51:49 host python3[1411247]: 2026-06-09 17:51:49,068 [INFO] Listening on enpXsX (DHCP port 67)

# Other entries...
# jun 09 17:51:49 host python3[2356158]: 2026-06-09 17:51:49,071 [INFO] pydhcpd started (pid 2356158, interface enpXsX)
# jun 09 17:51:49 host python3[2356158]: 2026-06-09 17:51:49,072 [INFO] Listening on enpXsX (DHCP port 67)
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
sudo tail -f /var/log/pydhcp.log
```

#### pydhcp.env — daemon bootstrap (`/etc/default/isc-dhcp-server` migration)

`isc-dhcp-server` split its config in two: `/etc/default/isc-dhcp-server` held bootstrap values (which interface to listen on, mainly) read once at service start, and `/etc/dhcp/dhcpd.conf` held every actual behavior directive. `pydhcp` keeps that same split: `pydhcp.env` is the direct migration of `/etc/default/isc-dhcp-server` -- only paths, the interface, and the daemon's user/group, read once by `pydhcpd.py` at startup. Every lease timer, `ping-check`, `ping-timeout`, `abandon-lease-time`, WPAD, and static host/block-list entry that DOES have a `dhcpd.conf` equivalent is a `pydhcpd.conf` directive instead, exactly like `dhcpd.conf` (see [Supported directives](#supported-directives) below) -- never in `pydhcp.env`. `pydhcp.env` also carries the network values, ACL paths and `pyleases.sh`-specific keys described in [pydhcp.env — pyleases.sh automation input](#pydhcpenv--pyleasessh-automation-input-mirrors-dhcpdconf-directives) further down (those are `pydhcp`'s own optional automation layer on top, with no `isc-dhcp-server` equivalent, only consumed by `pyleases.sh` to build `pydhcpd.conf`), plus a small set of features that ARE read directly by `pydhcpd.py` because they have no `dhcpd.conf`/`isc-dhcp-server` equivalent at all -- see [pydhcp.env — pydhcp-only extras](#pydhcpenv--pydhcp-only-extras-no-isc-dhcp-server-equivalent) below.

| Variable | `/etc/default/isc-dhcp-server` equivalent | Description | Descripción |
|----------|--------------------------------------------|--------------|-------------|
| `INTERFACESv4` | `INTERFACESv4` (same name) | Interface `pydhcpd.py` listens on | Interfaz en la que escucha `pydhcpd.py` |
| `DAEMON_USER`, `DAEMON_GROUP` | *(hardcoded to the package's own user in isc-dhcp-server)* | System user/group the daemon drops privileges to after binding the socket | Usuario/grupo del sistema al que el demonio baja privilegios tras abrir el socket |
| `DHCPDv4_CONF` | *(hardcoded path, `/etc/dhcp/dhcpd.conf`)* | Path to `pydhcpd.conf`, read at startup and on `SIGHUP`/`reload` | Ruta a `pydhcpd.conf`, leída al arrancar y en `SIGHUP`/`reload` |
| `DHCPDv4_PID` | *(hardcoded path)* | PID file path | Ruta del archivo PID |
| `DHCPDv4_BIN`, `DHCPDv4_SCRIPT` | *(n/a — isc-dhcp-server is a single binary)* | Python interpreter and daemon script path, used by `init.d/pydhcpd` and `pywebmin.sh` to invoke `pydhcpd.py` for config tests | Intérprete Python y ruta del script del demonio, usados por `init.d/pydhcpd` y `pywebmin.sh` para invocar `pydhcpd.py` en las pruebas de configuración |
| `LOG_FILE` | *(logged via syslog in isc-dhcp-server)* | Path of the single log shared by the whole project — the daemon, `pysetup.sh` and `tools/pyleases.sh` all write to it. **Not configurable:** the same path is hardcoded in `/etc/logrotate.d/pydhcp` and covered by the `ReadWritePaths` of `pydhcpd.service`, so changing it here alone would leave the log unrotated. `pydhcpd.py` resolves its own log destination before it can read this file, so instead of silently ignoring the key it compares it at startup and **refuses to start** if it was changed, naming both paths in the error | Ruta del log único que comparte todo el proyecto — el demonio, `pysetup.sh` y `tools/pyleases.sh` escriben en él. **No es configurable:** la misma ruta está fija en `/etc/logrotate.d/pydhcp` y cubierta por el `ReadWritePaths` de `pydhcpd.service`, así que cambiarla solo aquí dejaría el log sin rotar. `pydhcpd.py` resuelve su propio destino de log antes de poder leer este archivo, así que en vez de ignorar la clave en silencio la contrasta al arrancar y **se niega a iniciar** si fue modificada, nombrando ambas rutas en el error |
| `PYDHCPD_LEASES` | *(hardcoded path, `/var/lib/dhcp/dhcpd.leases`)* | Leases database path | Ruta de la base de datos de leases |

#### pydhcp.env — pydhcp-only extras (no isc-dhcp-server equivalent)

A third, distinct group in `pydhcp.env`: features `pydhcp` added that have no `dhcpd.conf`/`isc-dhcp-server` directive to migrate from, so there's nothing to keep in sync with a `pydhcpd.conf` template -- `pydhcpd.py` reads them directly from `pydhcp.env` at startup, the same way it reads the bootstrap group above. `pyleases.sh` never touches these; they only build `pydhcpd.conf`, and these values aren't `pydhcpd.conf` directives.

| Variable | Description | Descripción |
|----------|--------------|-------------|
| `PING_CACHE_TTL_SECONDS` | Seconds a `ping-check` result (alive/dead) is cached before re-checking the same IP; default `120` | Segundos que se cachea el resultado de un `ping-check` (viva/muerta) antes de re-verificar la misma IP; default `120` |
| `RATE_LIMIT_WINDOW_SECONDS`, `RATE_LIMIT_MAX` | Anti-abuse throttle: at most `RATE_LIMIT_MAX` new lease allocations per MAC within `RATE_LIMIT_WINDOW_SECONDS`, to limit pool exhaustion by an attacker rotating MACs; defaults `60`/`5` | Freno anti-abuso: como máximo `RATE_LIMIT_MAX` asignaciones de lease nuevas por MAC dentro de `RATE_LIMIT_WINDOW_SECONDS`, para limitar el agotamiento del pool por un atacante rotando MACs; defaults `60`/`5` |
| `RESERVATION_TTL_SECONDS` | Seconds a DISCOVER-only provisional reservation holds an IP before expiring, if no matching REQUEST follows; default `30` | Segundos que una reserva provisional de un DISCOVER retiene una IP antes de expirar, si no llega el REQUEST correspondiente; default `30` |

All four values above must be at least `1`. A value below `1` (for example `RATE_LIMIT_MAX=0`, which does not mean "unlimited") is rejected with a `WARNING` in the log and the default is used instead.

Los cuatro valores anteriores deben ser como mínimo `1`. Un valor menor que `1` (por ejemplo `RATE_LIMIT_MAX=0`, que no significa "sin límite") se rechaza con un `WARNING` en el log y en su lugar se usa el valor por defecto.

#### pydhcp.env — pyleases.sh automation input (mirrors dhcpd.conf directives)

A third group in `pydhcp.env`, distinct from the two above: input values for `pyleases.sh`'s optional automation layer. Unlike the bootstrap group, `pydhcpd.py` never reads these directly — `pysetup.sh` creates them and `pyleases.sh` writes the corresponding directive into `pydhcpd.conf` on every run (see [Supported directives](#supported-directives)); a bare install managed by hand never needs them. Any missing key is added by `pyleases.sh` itself, with its own built-in default, right before the file's closing `# =====...=====` line — this only happens on an install that predates a given key.

| Variable | `pydhcpd.conf` directive it becomes | Description | Descripción |
|----------|--------------------------------------|--------------|-------------|
| `CLEANUP_INTERVAL` | `cleanup-interval` | Pool cleanup frequency in seconds; default `60` | Frecuencia de limpieza del pool en segundos; default `60` |
| `AUTHORIZED_LEASE_TIME` | subnet `min`/`default`/`max-lease-time` | Lease duration for authorized/static clients in seconds; default `2592000` (30 days) | Duración del lease para clientes autorizados/estáticos en segundos; default `2592000` (30 días) |
| `QUARANTINE_DURATION` | `abandon-lease-time` | See "IP quarantine" in [Operational Details](#operational-details) below; default `60` | Ver "IP quarantine" en [Operational Details](#operational-details) abajo; default `60` |
| `WPAD_ENABLED` | `option wpad ...;` | See [WPAD/PAC via DHCP option 252](#wpadpac-via-dhcp-option-252-optional) below; default `false` | Ver [WPAD/PAC via DHCP option 252](#wpadpac-via-dhcp-option-252-optional) abajo; default `false` |
| `WPAD_PORT` | port inside the `option wpad ...;` URL | TCP port of the Apache VirtualHost serving `wpad.pac`; default `18100`. Only asked for at install time when `apache2` is already installed and WPAD is accepted | Puerto TCP del VirtualHost de Apache que sirve `wpad.pac`; default `18100`. Solo se pregunta durante la instalación si `apache2` ya está instalado y se acepta WPAD |
| `PING_CHECK_ENABLED` | `ping-check` | See "ping-check" in [Operational Details](#operational-details) below; default `true` | Ver "ping-check" en [Operational Details](#operational-details) abajo; default `true` |
| `PING_TIMEOUT_SECONDS` | `ping-timeout` | See "ping-check" in [Operational Details](#operational-details) below; default `1` | Ver "ping-check" en [Operational Details](#operational-details) abajo; default `1` |

#### Fixed values (not configurable anywhere)

`pydhcp.env` only ever holds real, admin-adjustable values -- the two groups above, plus the bootstrap group and the `pyleases.sh` input group described earlier. A handful of internal constants in `pydhcpd.py` are deliberately **not** exposed in `pydhcp.env` (or `pydhcpd.conf`), because each is a protocol/math invariant or an internal implementation detail with no admin-meaningful range of alternatives -- not an operational choice to make:

| Value | Why it's fixed | Por qué es fijo |
|-------|-----------------|-------------------|
| Max pool/subnet size (`65536` addresses) | Fixed by IPv4 arithmetic, not a policy -- a `/16` is the largest a range can ever be | Fijado por la aritmética de IPv4, no es una política -- un `/16` es el rango más grande que puede existir |
| Max DHCP option length (`255` bytes -- WPAD URL and other option values) | Fixed by the 1-byte length field in the DHCP option format (RFC 2132); there's no larger value the protocol can even represent | Fijado por el campo de longitud de 1 byte del formato de opción DHCP (RFC 2132); no hay un valor mayor que el protocolo pueda siquiera representar |
| Allocation round-robin counter wraparound (`2**16`) | Internal iteration state with no observable effect on behavior -- changing it doesn't change what the daemon does | Estado de iteración interno sin efecto observable en el comportamiento -- cambiarlo no cambia lo que hace el demonio |
| Main-loop shutdown poll timeout (`5`s socket timeout) | Controls how fast a `systemctl stop` is noticed, not DHCP behavior (leases, OFFERs, etc.) | Controla qué tan rápido se nota un `systemctl stop`, no el comportamiento DHCP (leases, OFFERs, etc.) |

#### pydhcpd.py vs isc-dhcp-server — same contract, extra optional layer

| Aspect | isc-dhcp-server | In pydhcp | En pydhcp |
|--------|------------------|------------|------------|
| Config file for lease timers/feature directives (`ping-check`, `abandon-lease-time`, `option wpad ...;`, etc.) | `dhcpd.conf` only | `pydhcpd.conf` only — same single-file contract, never `pydhcp.env` | Solo `pydhcpd.conf` — mismo contrato de archivo único, nunca `pydhcp.env` |
| `/etc/default/isc-dhcp-server` / `pydhcp.env` | Bootstrap only (mainly the interface) | Bootstrap, plus two optional layers `isc-dhcp-server` has no equivalent for: `pyleases.sh` input values (mirror `pydhcpd.conf` directives, see table above) and pydhcp-only extras (read directly, see [pydhcp.env — pydhcp-only extras](#pydhcpenv--pydhcp-only-extras-no-isc-dhcp-server-equivalent)) | Arranque, más dos capas opcionales que isc-dhcp-server no tiene: valores de entrada de `pyleases.sh` (reflejan directivas de `pydhcpd.conf`, ver tabla arriba) y las extras propias de pydhcp (se leen directo, ver [pydhcp.env — pydhcp-only extras](#pydhcpenv--pydhcp-only-extras-no-isc-dhcp-server-equivalent)) |
| Managing the daemon config by hand, without the automation script | Edit `dhcpd.conf` directly | Edit `pydhcpd.conf` directly — `pydhcp.env` beyond the bootstrap keys and pydhcp-only extras has no effect at all, exactly as if it didn't exist | Editar `pydhcpd.conf` directamente — `pydhcp.env` más allá de las claves de arranque y las extras propias de pydhcp no tiene ningún efecto, como si no existiera |

#### Supported directives

| Directive | Description | Descripción |
|-----------|-------------|-------------|
| `authoritative;` | Server sends NAK to clients with foreign leases. **This is pydhcpd's default**, so the directive is accepted for `dhcpd.conf` compatibility but changes nothing — omitting it leaves the server authoritative all the same | El servidor envía NAK a clientes con leases ajenos. **Es el modo por defecto de pydhcpd**, así que la directiva se acepta por compatibilidad con `dhcpd.conf` pero no cambia nada — omitirla deja el servidor autoritativo igualmente |
| `not authoritative;` | Standard isc-dhcp-server syntax to explicitly disable authoritative mode. It is the **only** way to disable it: unlike isc-dhcp-server, omitting `authoritative;` does *not* make the server non-authoritative (see [Authoritative by default](#authoritative-by-default)) | Sintaxis estándar de isc-dhcp-server para desactivar explícitamente el modo autoritativo. Es la **única** forma de desactivarlo: a diferencia de isc-dhcp-server, omitir `authoritative;` *no* deja el servidor como no autoritativo (ver [Authoritative by default](#authoritative-by-default)) |
| `cleanup-interval N;` | How often (seconds) expired leases are removed from memory | Frecuencia (segundos) con que se eliminan leases expirados de memoria |
| `abandon-lease-time N;` | Standard isc-dhcp-server directive, same name. Seconds an IP is held out of the pool after a DHCPDECLINE (if `deny declines;` is not set) or a `ping-check` conflict (see IP quarantine below); default `60` | Directiva estándar de isc-dhcp-server, mismo nombre. Segundos que una IP se aparta del pool tras un DHCPDECLINE (si `deny declines;` no está activo) o un conflicto de `ping-check` (ver "IP quarantine" abajo); default `60` |
| `server-identifier IP;` | IP the server uses to identify itself in DHCP replies | IP con la que el servidor se identifica en las respuestas DHCP |
| `deny duplicates;` | Re-offer the MAC's existing lease IP on DISCOVER, instead of allocating a new one. MACs with a `fixed-address` reservation are exempt: they are always offered their reserved IP | Reofrece la IP del lease existente de la MAC en el DISCOVER, en vez de asignar una nueva. Las MAC con reserva `fixed-address` quedan exentas: siempre reciben su IP reservada |
| `one-lease-per-client` | **Always enforced, not declared in `pydhcpd.conf`.** A MAC never holds more than one pool lease at a time; there is no directive to change this — pydhcp does not read or write `one-lease-per-client` | **Siempre aplicado, no se declara en `pydhcpd.conf`.** Una MAC nunca tiene más de una IP del pool a la vez; no existe una directiva para cambiar esto — pydhcp no lee ni escribe `one-lease-per-client` |
| `deny declines;` | Ignore DHCPDECLINE messages | Ignora mensajes DHCPDECLINE |
| `ping-check true\|false;` | Ping IP before OFFER to detect conflicts (controlled via `PING_CHECK_ENABLED` in `pydhcp.env`) | Ping a la IP antes del OFFER para detectar conflictos (controlado via `PING_CHECK_ENABLED` en `pydhcp.env`) |
| `ping-timeout N;` | Standard isc-dhcp-server directive, same name. Seconds to wait for the ICMP reply before giving up and sending the OFFER (controlled via `PING_TIMEOUT_SECONDS` in `pydhcp.env`); default `1`, only takes effect if `ping-check true;` | Directiva estándar de isc-dhcp-server, mismo nombre. Segundos a esperar la respuesta ICMP antes de desistir y enviar el OFFER (controlado via `PING_TIMEOUT_SECONDS` en `pydhcp.env`); default `1`, solo tiene efecto si `ping-check true;` |
| `option wpad ...;` | WPAD/PAC proxy auto-configuration (controlled via `WPAD_ENABLED` in `pydhcp.env`) | Autoconfiguración de proxy WPAD/PAC (controlado via `WPAD_ENABLED` en `pydhcp.env`) |
| `subnet ... { pool { ... } }` | Subnet declaration with dynamic block pool | Declaración de subred con pool de bloqueo dinámico |
| `host NAME { hardware ethernet MAC; fixed-address IP; }` | Static host reservation. The `fixed-address` is validated at config load (and on `SIGHUP` reload): it must be a syntactically valid IPv4 address, must belong to the configured `subnet`, and must not be that subnet's network or broadcast address. It must also not fall inside `pool { range ... }`, nor be assigned to more than one host. Any of these rejects the configuration with a clear error instead of being silently accepted | Reserva estática de host. La `fixed-address` se valida al cargar la configuración (y al recargar con `SIGHUP`): debe ser una dirección IPv4 sintácticamente válida, debe pertenecer a la `subnet` configurada y no puede ser la dirección de red ni la de broadcast de esa subred. Tampoco puede caer dentro de `pool { range ... }`, ni estar asignada a más de un host. Cualquiera de estos casos rechaza la configuración con un error claro, en vez de aceptarse en silencio |
| `class "blockdhcp" { ... }` / `subclass "blockdhcp" ...` | MAC-based DHCP block list. Only `subclass "blockdhcp" 1:<mac>;` lines are parsed and enforced — the `class "blockdhcp" { match pick-first-value (...); }` block is syntax boilerplate a `subclass` requires to be valid, never parsed or acted on itself | Lista de bloqueo DHCP por MAC. Sólo las líneas `subclass "blockdhcp" 1:<mac>;` se parsean y aplican — el bloque `class "blockdhcp" { match pick-first-value (...); }` es sintaxis de relleno que una `subclass` necesita para ser válida, nunca se parsea ni se actúa sobre él |
| `min-lease-time`, `default-lease-time`, `max-lease-time` (subnet level) | Validated together (`0 < min <= default <= max`). Only `default-lease-time` is actually granted, to static (`host { fixed-address ... }`) clients — `min-lease-time` and `max-lease-time` at this level have no effect on any lease | Se validan en conjunto (`0 < min <= default <= max`). Solo `default-lease-time` se entrega realmente, a clientes estáticos (`host { fixed-address ... }`) — `min-lease-time` y `max-lease-time` a este nivel no afectan ningún lease |
| `min-lease-time`, `default-lease-time`, `max-lease-time` (pool level) | Validated together; `default-lease-time` is granted to pool (block/unknown) clients | Se validan en conjunto; `default-lease-time` se entrega a clientes del pool (bloqueados/desconocidos) |
| `option routers`, `option broadcast-address`, `option domain-name-servers` | Standard DHCP options. `option routers` accepts a comma-separated list (as in `isc-dhcp-server`), but only the first IP is used — extra entries are ignored with a `WARNING` | Opciones DHCP estándar. `option routers` acepta una lista separada por comas (como en `isc-dhcp-server`), pero solo se usa la primera IP — las entradas adicionales se ignoran con un `WARNING` |

#### Operational Details

| Topic | Description | Descripción |
|---|---|---|
| Entry points | `pydhcpd` can be managed through three entry points — `systemctl`, the `/etc/init.d/pydhcpd` wrapper, and `pyleases.sh` (which calls `systemctl stop`/`start` internally whenever it regenerates `pydhcpd.conf`). On a `systemd` host (the only supported environment — see [Requirements](#requirements)), the `init.d` wrapper does not start its own process: it detects `systemd` and simply runs the equivalent `systemctl` command, so it and `systemctl` are always in sync, never two independent daemons. The only theoretical race is at the PID-file level (`write_pid()`) if the daemon were ever launched completely outside of `systemd`'s management — not a realistic path on the supported environment, but as a matter of operational hygiene: **use a single entry point at a time.** Don't run `pyleases.sh`, `systemctl`, and the `init.d` wrapper concurrently against the same instance (e.g. don't kick off `pyleases.sh` in one terminal while manually restarting via `systemctl` in another) — let one lifecycle operation finish before starting the next. | `pydhcpd` se puede administrar desde tres puntos de entrada — `systemctl`, el wrapper `/etc/init.d/pydhcpd`, y `pyleases.sh` (que llama internamente a `systemctl stop`/`start` cada vez que regenera `pydhcpd.conf`). En un host con `systemd` (el único entorno soportado — ver [Requirements](#requirements)), el wrapper `init.d` no arranca su propio proceso: detecta `systemd` y simplemente ejecuta el `systemctl` equivalente, así que él y `systemctl` siempre están sincronizados, nunca son dos demonios independientes. La única carrera teórica ocurre a nivel del archivo PID (`write_pid()`) si el demonio se lanzara completamente por fuera de la gestión de `systemd` — no es un camino real en el entorno soportado, pero como buena práctica operativa: **usa un solo punto de entrada a la vez.** No corras `pyleases.sh`, `systemctl` y el wrapper `init.d` de forma concurrente sobre la misma instancia (p.ej. no lances `pyleases.sh` en una terminal mientras reiniciás manualmente con `systemctl` en otra) — dejá que termine una operación del ciclo de vida antes de iniciar la siguiente. |
| Automatic restart on failure | if `pydhcpd` crashes or exits with an error (e.g. the configured network interface is not present at startup), `systemd` restarts it automatically — `pydhcpd.service` sets `Restart=on-failure` with `RestartSec=5` (retry every 5 seconds), capped at `StartLimitBurst=10` attempts within a `StartLimitIntervalSec=120` (2 minute) window. If the underlying problem is not resolved within those 10 attempts, `systemd` gives up and leaves the service in a `failed` state — it will **not** keep retrying indefinitely, and `pydhcpd` has no separate alerting mechanism to notify you when this happens. Check with `systemctl status pydhcpd` (a `failed` state needs a manual `systemctl reset-failed pydhcpd` before it can be started again) and watch `/var/log/pydhcp.log` / `journalctl -u pydhcpd` for the root cause. | si `pydhcpd` falla o termina con un error (p.ej. la interfaz de red configurada no existe todavía al arrancar), `systemd` lo reinicia automáticamente — `pydhcpd.service` define `Restart=on-failure` con `RestartSec=5` (reintenta cada 5 segundos), con un tope de `StartLimitBurst=10` intentos dentro de una ventana de `StartLimitIntervalSec=120` (2 minutos). Si el problema de fondo no se resuelve dentro de esos 10 intentos, `systemd` se da por vencido y deja el servicio en estado `failed` — **no** va a seguir reintentando indefinidamente, y `pydhcpd` no tiene un mecanismo de aviso separado que notifique cuando esto pasa. Verifica con `systemctl status pydhcpd` (un estado `failed` necesita un `systemctl reset-failed pydhcpd` manual antes de poder arrancarlo de nuevo) y revisa `/var/log/pydhcp.log` / `journalctl -u pydhcpd` para encontrar la causa raíz. |
| `ping-check` | `ping-check true` is enabled in the shipped `pydhcpd.conf`, unlike isc-dhcp-server where it defaults to off. The daemon sends a ping before each OFFER to verify the IP is not already in use, except in three cases: the client's MAC is a static host (`host { fixed-address ... }`), the offered IP is already the one that MAC currently holds, or the concurrent ping-check backlog (capped at 64 in-flight) is saturated — in the last case it fails open and sends the OFFER without checking, rather than blocking or dropping the DISCOVER. Waits up to `ping-timeout` seconds (standard isc-dhcp-server directive, same name; default `1`, read from `pydhcpd.conf` like `ping-check` itself) for a reply, but never blocks the main pool: each check runs on its own worker (capped at 4 concurrent) instead of stalling the DISCOVER handler like isc-dhcp-server's own blocking implementation. Internally, this ping is sent as a raw ICMP echo request built and read directly by the daemon (requires the `CAP_NET_RAW` capability, already granted in `pydhcpd.service`). If the raw socket cannot be opened (`CAP_NET_RAW` missing or revoked), it falls back to shelling out to the system's `ping` binary instead, logging a `WARNING` when this happens. A successful or failed result is cached for `PING_CACHE_TTL_SECONDS` seconds (default `120`, no `dhcpd.conf`/isc-dhcp-server equivalent — read directly from `pydhcp.env`, see [pydhcp.env — pydhcp-only extras](#pydhcpenv--pydhcp-only-extras-no-isc-dhcp-server-equivalent)) to avoid re-pinging the same IP on every DISCOVER during a burst. In environments with strict firewall rules blocking ICMP (on this host, the target, or in between), the request or its reply is silently dropped, the check times out the same way regardless of the underlying mechanism, and `ping-check` will have no effect. To disable it, set `ping-check false;` in `/etc/pydhcp/pydhcpd.conf`. If using `pyleases.sh`, set `PING_CHECK_ENABLED=false` in `pydhcp.env` instead — the script regenerates `pydhcpd.conf` on every run. | `ping-check true` viene activado en el `pydhcpd.conf` enviado, a diferencia de isc-dhcp-server donde viene desactivado por defecto. El demonio envía un ping antes de cada OFFER para verificar que la IP no está en uso, excepto en tres casos: la MAC del cliente es un host estático (`host { fixed-address ... }`), la IP ofrecida ya es la que esa MAC tiene actualmente, o el cupo de verificaciones concurrentes (limitado a 64 en simultáneo) está saturado — en este último caso falla abierto y envía el OFFER sin verificar, en vez de bloquear o descartar el DISCOVER. Espera hasta `ping-timeout` segundos (directiva estándar de isc-dhcp-server, mismo nombre; default `1`, leída de `pydhcpd.conf` igual que `ping-check`) por una respuesta, pero nunca bloquea el pool principal: cada verificación corre en su propio worker (limitado a 4 concurrentes) en vez de detener el manejo de DISCOVER como hace la implementación bloqueante propia de isc-dhcp-server. Internamente, este ping se envía como una solicitud ICMP echo cruda, construida y leída directamente por el demonio (requiere el privilegio `CAP_NET_RAW`, ya concedido en `pydhcpd.service`). Si el socket crudo no se puede abrir (falta o se revoca `CAP_NET_RAW`), cae al binario `ping` del sistema como respaldo, registrando un `WARNING` cuando esto ocurre. Un resultado exitoso o fallido se cachea por `PING_CACHE_TTL_SECONDS` segundos (default `120`, sin equivalente en `dhcpd.conf`/isc-dhcp-server — leída directamente de `pydhcp.env`, ver [pydhcp.env — pydhcp-only extras](#pydhcpenv--pydhcp-only-extras-no-isc-dhcp-server-equivalent)) para evitar re-pingear la misma IP en cada DISCOVER durante una ráfaga. En entornos con reglas de firewall estrictas que bloquean ICMP (en este host, en el destino, o en el medio), la solicitud o su respuesta se descartan en silencio, la verificación expira igual sin importar el mecanismo interno, y `ping-check` no tendrá ningún efecto. Para desactivarlo, establece `ping-check false;` en `/etc/pydhcp/pydhcpd.conf`. Si usas `pyleases.sh`, establece `PING_CHECK_ENABLED=false` en `pydhcp.env` — el script regenera `pydhcpd.conf` en cada ejecución. |
| `cleanup-interval` | `cleanup-interval` controls how often (in seconds) the daemon removes expired leases from memory. The default is `60`. If you use a short pool lease-time (e.g. `10` or `30` seconds), set `cleanup-interval` to the same value or lower so that expired leases are freed promptly and the pool does not appear exhausted. When using `pyleases.sh`, set `CLEANUP_INTERVAL` in `pydhcp.env` — it is written into `pydhcpd.conf` on every run. Config validation logs a `WARNING` (not an error — the daemon still starts) if `cleanup-interval` is greater than the pool's `min-lease-time`. **Minimum enforced value: `5` seconds** — if you set a lower value, the daemon clamps it to `5` and logs a `WARNING` stating the requested value. | `cleanup-interval` controla con qué frecuencia (en segundos) el demonio elimina los arrendamientos expirados de la memoria. El valor por defecto es `60`. Si usas un lease-time corto en el pool (p.ej. `10` o `30` segundos), establece `cleanup-interval` al mismo valor o menor para que los arrendamientos expirados se liberen rápidamente y el pool no parezca agotado. Al usar `pyleases.sh`, define `CLEANUP_INTERVAL` en `pydhcp.env` — se escribe en `pydhcpd.conf` en cada ejecución. La validación de configuración registra un `WARNING` (no un error — el demonio igual arranca) si `cleanup-interval` es mayor que el `min-lease-time` del pool. **Valor mínimo forzado: `5` segundos** — si se establece un valor menor, el demonio lo recorta a `5` y registra un `WARNING` indicando el valor solicitado. |
| Pool lease time default | the block pool's `min-lease-time` / `default-lease-time` / `max-lease-time` default to **60 seconds**, consistently across every path in this project: the shipped `pydhcpd.conf` template ships with `60` written explicitly in the `pool { }` block, `pyleases.sh` writes `60` (its `CLEANUP_INTERVAL` default) into the pool block on a fresh install, and `pydhcpd.py`'s own built-in fallback is also `60` (used only if a hand-written config omits the pool lease-time lines entirely). This keeps the default consistent with the short-lived, temporary nature of the block pool — unknown/blocked clients get a brief lease that is quickly recycled, unlike `AUTHORIZED_LEASE_TIME` (default `2592000`s / 30 days) used for the subnet-level lease given to authorized/static clients.<br><br>**To change it:** this is a per-installation choice, not something you edit in the project's code. At install time, `pysetup.sh` writes your answer to the `CLEANUP_INTERVAL` prompt directly into the `pool { }` block of `pydhcpd.conf`. To change it afterwards: if you manage `pydhcpd.conf` by hand, edit the `pool { min-lease-time / default-lease-time / max-lease-time }` values directly in your live `/etc/pydhcp/pydhcpd.conf` and restart/reload the daemon. If you use `pyleases.sh`, edit `CLEANUP_INTERVAL` in your `/etc/pydhcp/pydhcp.env` and re-run `pyleases.sh` — it rewrites `pydhcpd.conf` from that value on every run. | el `min-lease-time` / `default-lease-time` / `max-lease-time` del pool de bloqueo tienen por defecto **60 segundos**, de forma consistente en los tres caminos del proyecto: la plantilla `pydhcpd.conf` incluida trae `60` escrito explícitamente en el bloque `pool { }`, `pyleases.sh` escribe `60` (su valor por defecto de `CLEANUP_INTERVAL`) en el bloque del pool en una instalación nueva, y el respaldo interno propio de `pydhcpd.py` también es `60` (se usa solo si una configuración escrita a mano omite por completo las líneas de lease-time del pool). Esto mantiene el valor por defecto consistente con la naturaleza breve y temporal del pool de bloqueo — los clientes desconocidos/bloqueados reciben un lease corto que se recicla rápido, a diferencia de `AUTHORIZED_LEASE_TIME` (por defecto `2592000`s / 30 días) usado para el lease a nivel de subred que reciben los clientes autorizados/estáticos.<br><br>**Para cambiarlo:** es una decisión de cada instalación, no algo que se edite en el código del proyecto. Al instalar, `pysetup.sh` escribe tu respuesta a la pregunta `CLEANUP_INTERVAL` directamente en el bloque `pool { }` de `pydhcpd.conf`. Para cambiarlo después: si administras `pydhcpd.conf` a mano, edita los valores de `pool { min-lease-time / default-lease-time / max-lease-time }` directamente en tu `/etc/pydhcp/pydhcpd.conf` real y reinicia/recarga el demonio. Si usas `pyleases.sh`, edita `CLEANUP_INTERVAL` en tu `/etc/pydhcp/pydhcp.env` y vuelve a correr `pyleases.sh` — reescribe `pydhcpd.conf` a partir de ese valor en cada ejecución. |
| IP quarantine | when an IP is quarantined — either because a client sent a DHCPDECLINE (ignored by default, see `deny declines;` above) or because `ping-check` detects it is already in use before an OFFER — it is held out of the pool for `abandon-lease-time` seconds (standard isc-dhcp-server directive, same name), **60 by default**. Read from `pydhcpd.conf`, like every other behavior directive — not from `pydhcp.env`. If using `pyleases.sh`, set `QUARANTINE_DURATION` in `pydhcp.env` instead — the script writes it into `pydhcpd.conf` as `abandon-lease-time` on every run, same as `CLEANUP_INTERVAL`/`ping-check`. Picked up live on `SIGHUP`/`reload`, no restart needed. It is independent from the pool's `default-lease-time` (see below); the two are not required to match. | cuando una IP se pone en cuarentena — ya sea porque un cliente envió un DHCPDECLINE (ignorado por defecto, ver `deny declines;` arriba) o porque `ping-check` detecta que ya está en uso antes de un OFFER — se aparta del pool por `abandon-lease-time` segundos (directiva estándar de isc-dhcp-server, mismo nombre), **60 por defecto**. Se lee de `pydhcpd.conf`, igual que cualquier otra directiva de comportamiento — no de `pydhcp.env`. Si usas `pyleases.sh`, define `QUARANTINE_DURATION` en `pydhcp.env` — el script la escribe en `pydhcpd.conf` como `abandon-lease-time` en cada ejecución, igual que `CLEANUP_INTERVAL`/`ping-check`. Se aplica en caliente con `SIGHUP`/`reload`, sin reiniciar. Es independiente del `default-lease-time` del pool (ver más abajo); no es necesario que coincidan. |
| Pool range cap | the `pool { range A B; }` directive is capped at **65536 addresses** (a `/16`). The daemon builds the full address set in memory at startup and re-sorts the free set on every allocation, so an oversized range (e.g. a `/8`) would waste memory and CPU proportional to its size. A range larger than the cap is rejected at config load (or `SIGHUP` reload) with a clear error instead of being silently accepted. | la directiva `pool { range A B; }` tiene un tope de **65536 direcciones** (un `/16`). El demonio construye el conjunto completo de direcciones en memoria al arrancar y reordena el conjunto libre en cada asignación, por lo que un rango sobredimensionado (p.ej. un `/8`) desperdiciaría memoria y CPU proporcional a su tamaño. Un rango mayor al tope se rechaza al cargar la configuración (o al recargar con `SIGHUP`) con un error claro, en vez de aceptarse en silencio. |

### Tools

---

#### pyleases

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      <b>pyleases.sh</b> — Advanced DHCP lease and ACL manager for pydhcpd. Parses <code>pydhcpd.leases</code>, detects unauthorized clients, rebuilds <code>pydhcpd.conf</code> from ACL files, and restarts the daemon. Designed for environments enforcing DHCP-based access control.<br><br>
      ACL directories: <code>/etc/acl/acl_mac/</code> (authorized: <code>mac-proxy.txt</code>, <code>mac-unlimited.txt</code>) and <code>/etc/acl/acl_dhcp/</code> (blocked: <code>blockdhcp.txt</code>).<br>
      Entry format: <code>a;MAC;IP;HOSTNAME;</code>. The leading <code>a</code> means "active" and is what marks a well-formed entry — any other leading character aborts parsing. There is no opposite value: for the <code>mac-*.txt</code> lists, to deactivate an entry, comment out the whole line by prefixing it with <code>#</code> (<code>#a;MAC;IP;HOSTNAME;</code>) instead of editing the <code>a</code> itself. <code>blockdhcp.txt</code> is the exception: it has no active/inactive state and no <code>#</code> syntax — an entry's mere presence blocks the MAC. To unblock, delete the line; a <code>#</code>-prefixed line there is rejected as malformed.
    </td>
    <td style="width: 50%; vertical-align: top;">
      <b>pyleases.sh</b> — Gestor avanzado de concesiones y ACLs DHCP para pydhcpd. Parsea <code>pydhcpd.leases</code>, detecta clientes no autorizados, reconstruye <code>pydhcpd.conf</code> a partir de archivos ACL y reinicia el demonio. Diseñado para entornos que aplican control de acceso basado en DHCP.<br><br>
      Directorios ACL: <code>/etc/acl/acl_mac/</code> (autorizados: <code>mac-proxy.txt</code>, <code>mac-unlimited.txt</code>) y <code>/etc/acl/acl_dhcp/</code> (bloqueados: <code>blockdhcp.txt</code>).<br>
      Formato: <code>a;MAC;IP;HOSTNAME;</code>. La `a` inicial significa "active" (activo) y es lo que marca una entrada bien formada — cualquier otro carácter inicial aborta el parseo. No existe un valor opuesto: para las listas <code>mac-*.txt</code>, para desactivar una entrada se comenta la línea completa agregando <code>#</code> al inicio (<code>#a;MAC;IP;HOSTNAME;</code>) en vez de editar la `a` misma. <code>blockdhcp.txt</code> es la excepción: no tiene estado activo/inactivo ni sintaxis <code>#</code> — la sola presencia de una entrada bloquea la MAC. Para desbloquear, se borra la línea; una línea con <code>#</code> ahí se rechaza por malformada.
    </td>
  </tr>
</table>

```bash
sudo bash tools/pyleases.sh
```

**Warning**

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      <ul>
        <li><code>--update</code> backs up replaced files to <code>/etc/pydhcp/bak/TIMESTAMP/</code> before overwriting them. <code>pydhcpd.conf</code> and <code>pydhcp.env</code> are <b>never overwritten</b> by <code>--update</code> (user config is preserved). Any manual edit to the code files (<code>pydhcpd.py</code>, <code>pyleases.sh</code>, <code>pywebmin.sh</code>) will be replaced.</li>
        <li>⚠️ <b>WARNING:</b> <code>pyleases.sh</code> fully rebuilds <code>/etc/pydhcp/pydhcpd.conf</code> on every run from its ACL files and <code>pydhcp.env</code>. Any manual edits to <code>pydhcpd.conf</code> — including custom lease times, pools, or directives — will be lost. If you manage <code>pydhcpd.conf</code> manually, do not use <code>pyleases.sh</code>.</li>
      </ul>
    </td>
    <td style="width: 50%; vertical-align: top;">
      <ul>
        <li><code>--update</code> respalda los archivos reemplazados en <code>/etc/pydhcp/bak/TIMESTAMP/</code> antes de sobrescribirlos. <code>pydhcpd.conf</code> y <code>pydhcp.env</code> <b>nunca se sobreescriben</b> (la configuración del usuario se preserva). Cualquier edición manual a los archivos de código (<code>pydhcpd.py</code>, <code>pyleases.sh</code>, <code>pywebmin.sh</code>) será reemplazada.</li>
        <li>⚠️ <b>ADVERTENCIA:</b> <code>pyleases.sh</code> reconstruye completamente <code>/etc/pydhcp/pydhcpd.conf</code> en cada ejecución a partir de sus archivos ACL y <code>pydhcp.env</code>. Cualquier edición manual a <code>pydhcpd.conf</code> — incluyendo lease times, pools o directivas personalizadas — se perderá. Si gestiona <code>pydhcpd.conf</code> manualmente, no utilice <code>pyleases.sh</code>.</li>
      </ul>
    </td>
  </tr>
</table>

##### WPAD/PAC via DHCP option 252 (optional)

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      <code>pyleases.sh</code> generates <code>/etc/pydhcp/pydhcpd.conf</code> dynamically on every run. WPAD/PAC support is controlled entirely from <code>pydhcp.env</code> — no manual editing of <code>pyleases.sh</code> is required.
    </td>
    <td style="width: 50%; vertical-align: top;">
      <code>pyleases.sh</code> genera <code>/etc/pydhcp/pydhcpd.conf</code> dinámicamente en cada ejecución. El soporte WPAD/PAC se controla completamente desde <code>pydhcp.env</code> — no se requiere editar manualmente <code>pyleases.sh</code>.
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
| `/etc/default/isc-dhcp-server` | `/etc/pydhcp/pydhcp.env` |
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
| Log file | `/var/log/syslog` | `/var/log/pydhcp.log` (single log for the whole project) |
| Log rotation | `/etc/logrotate.d/rsyslog` | `/etc/logrotate.d/pydhcp` (daily, one config for the whole project) |
| journald | `journalctl -u isc-dhcp-server` | `journalctl -u pydhcpd` |

> pydhcpd writes logs directly to `/var/log/pydhcp.log`. It does not use syslog, therefore no `log-facility` directive is needed or supported. That single file is shared by the whole project — the daemon, `pysetup.sh` and `tools/pyleases.sh` all append to it, under one `daily` rotation (`/etc/logrotate.d/pydhcp`). Its path is declared as `LOG_FILE` in `pydhcp.env` and is not configurable: the daemon refuses to start if that key names a different path.
>
> pydhcpd escribe los logs directamente a `/var/log/pydhcp.log`. No utiliza syslog, por lo tanto no se necesita ni se soporta la directiva `log-facility`. Ese archivo único lo comparte todo el proyecto — el demonio, `pysetup.sh` y `tools/pyleases.sh` escriben en él, bajo una sola rotación `daily` (`/etc/logrotate.d/pydhcp`). Su ruta se declara como `LOG_FILE` en `pydhcp.env` y no es configurable: el demonio se niega a arrancar si esa clave nombra otra ruta.

#### Scenario

| Scenario | isc-dhcp-server | pydhcpd |
|----------|-----------------|---------|
| Authorized client with static IP (renewal) / Cliente autorizado con IP estática (renovación) | `DHCPREQUEST for 192.168.0.50 (192.168.0.2) from aa:bb:cc:dd:ee:ff via enpXsX`<br>`DHCPACK on 192.168.0.50 to aa:bb:cc:dd:ee:ff (FOO) via enpXsX` | `REQUEST from aa:bb:cc:dd:ee:ff (FOO)`<br>`ACK aa:bb:cc:dd:ee:ff → 192.168.0.50 (lease 2592000s)` |
| Unknown client entering the block pool / Cliente desconocido ingresando al pool de bloqueo | `DHCPDISCOVER from bb:cc:dd:ee:ff:aa via enpXsX`<br>`DHCPOFFER on 192.168.0.230 to bb:cc:dd:ee:ff:aa (BAR) via enpXsX`<br>`DHCPREQUEST for 192.168.0.230 (192.168.0.2) from bb:cc:dd:ee:ff:aa (BAR) via enpXsX`<br>`DHCPACK on 192.168.0.230 to bb:cc:dd:ee:ff:aa (BAR) via enpXsX` | `DISCOVER from bb:cc:dd:ee:ff:aa (BAR)`<br>`OFFER bb:cc:dd:ee:ff:aa → 192.168.0.230`<br>`REQUEST from bb:cc:dd:ee:ff:aa (BAR)`<br>`ACK bb:cc:dd:ee:ff:aa → 192.168.0.230 (lease 60s)` |
| Pool exhausted / Pool agotado | `DHCPDISCOVER from bb:cc:dd:ee:ff:aa via enpXsX: network 192.168.0.0/24: no free leases` | `DISCOVER from bb:cc:dd:ee:ff:aa (BAR)`<br>`No IP available for bb:cc:dd:ee:ff:aa` |
| Blocked client / Cliente bloqueado | `DHCPDISCOVER from bb:cc:dd:ee:ff:aa via enpXsX: network 192.168.0.0/24: no free leases` † | `DISCOVER from bb:cc:dd:ee:ff:aa (BAR)`<br>`Blocked: bb:cc:dd:ee:ff:aa (deny blockdhcp)` |

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
      <b>pydhcpd</b> también acepta <code>not authoritative;</code>, la misma sintaxis estándar de <code>dhcpd.conf</code>, pero <b>no</b> es equivalente a omitir <code>authoritative;</code> — ver abajo.
    </td>
  </tr>
</table>

### Authoritative by default

---

<table>
  <tr>
    <td style="width: 50%; vertical-align: top;">
      <b>pydhcpd is authoritative by default.</b> This is a deliberate divergence from isc-dhcp-server, the only one in how this directive is interpreted:
      <ul>
        <li><code>authoritative;</code> — authoritative (accepted for <code>dhcpd.conf</code> compatibility; it is already the default, so it changes nothing)</li>
        <li><code>not authoritative;</code> — non-authoritative</li>
        <li><b>neither directive present</b> — authoritative in pydhcpd; <b>non</b>-authoritative in isc-dhcp-server</li>
      </ul>
      The reason: a DHCP server that owns its LAN should defend it unless told otherwise. Leaving the safe behavior to depend on remembering a directive means a forgotten line silently disables the only defense against a rogue DHCP server (see the section above).
      <br><br>
      <b>Migrating from isc-dhcp-server:</b> if your <code>dhcpd.conf</code> did not carry <code>authoritative;</code> and you relied on that, add <code>not authoritative;</code> explicitly to keep the old behavior. Everyone else needs to change nothing.
    </td>
    <td style="width: 50%; vertical-align: top;">
      <b>pydhcpd es autoritativo por defecto.</b> Es una divergencia deliberada respecto a isc-dhcp-server, la única en la interpretación de esta directiva:
      <ul>
        <li><code>authoritative;</code> — autoritativo (se acepta por compatibilidad con <code>dhcpd.conf</code>; ya es el valor por defecto, así que no cambia nada)</li>
        <li><code>not authoritative;</code> — no autoritativo</li>
        <li><b>ninguna de las dos presente</b> — autoritativo en pydhcpd; <b>no</b> autoritativo en isc-dhcp-server</li>
      </ul>
      La razón: un servidor DHCP que es dueño de su LAN debería defenderla salvo que se le indique lo contrario. Dejar que el comportamiento seguro dependa de recordar una directiva significa que una línea olvidada desactiva en silencio la única defensa frente a un servidor DHCP no autorizado (ver la sección anterior).
      <br><br>
      <b>Migrando desde isc-dhcp-server:</b> si su <code>dhcpd.conf</code> no llevaba <code>authoritative;</code> y usted dependía de eso, agregue <code>not authoritative;</code> de forma explícita para conservar el comportamiento anterior. Los demás no necesitan cambiar nada.
    </td>
  </tr>
</table>

The table below compares what each daemon's own log would show if it were the **authoritative** server defending against the same rogue, event by event — not a mixed trace of one daemon acting as the rogue.

| Event | isc-dhcp-server (as authoritative) | pydhcpd (as authoritative) |
|-------|-------------------------------------|-----------------------------|
| Rogue offers IP to client | *(not observed)* † | *(not observed)* † |
| Client requests rogue IP | `DHCPREQUEST for 192.168.0.222 (192.168.0.249) from bb:cc:dd:ee:ff:aa (BAR) via enpXsX` | `REQUEST from bb:cc:dd:ee:ff:aa (BAR)` |
| Rogue acknowledges | *(not observed)* † | *(not observed)* † |
| **Authoritative server rejects** | `DHCPNAK on 192.168.0.222 to bb:cc:dd:ee:ff:aa via enpXsX` | `NAK → bb:cc:dd:ee:ff:aa` |
| Client rediscovers | `DHCPDISCOVER from bb:cc:dd:ee:ff:aa via enpXsX` | `DISCOVER from bb:cc:dd:ee:ff:aa (BAR)` |

† Neither daemon sees these packets: `DHCPOFFER`/`DHCPACK` are addressed to the client, not to other DHCP servers on the segment.

#### Rate Limiting

| isc-dhcp-server | pydhcpd |
|---|---|
| Has no built-in per-client rate-limiting for lease allocation. Abuse mitigation relies on `deny duplicates;`, plus pool exhaustion (once the pool is full, further `DHCPDISCOVER` messages simply receive no `DHCPOFFER`). Client identification is based on `chaddr` (or `client-id`, option 61) — never on the Ethernet source MAC of the frame, so behavior is identical whether the client is directly attached or behind a relay (`giaddr` is only used for routing the reply).<br><br>No tiene rate-limiting incorporado por cliente para la asignación de leases. La mitigación de abuso depende de `deny duplicates;`, además del agotamiento del pool (una vez lleno, los `DHCPDISCOVER` simplemente no reciben `DHCPOFFER`). La identificación del cliente se basa en `chaddr` (o `client-id`, opción 61) — nunca en la MAC Ethernet origen del frame, por lo que el comportamiento es igual si el cliente está conectado directamente o detrás de un relay (`giaddr` solo se usa para enrutar la respuesta). | Adds a sliding-window rate limit on lease allocation, keyed by **client MAC (`chaddr`)** — the same identifier isc-dhcp-server uses. Each client MAC has its own bucket, so multiple clients behind the same relay are rate-limited independently and do not affect each other. If a single MAC exceeds the allowed number of allocations within the window, further requests are rejected with reason `"rate limited"` until the window slides forward. This is purely an internal safeguard against allocation storms; it is not configurable via `pydhcpd.conf` and has no equivalent directive in isc-dhcp-server.<br><br>Agrega un límite de tasa (sliding window) sobre la asignación de leases, indexado por **MAC del cliente (`chaddr`)** — el mismo identificador que usa isc-dhcp-server. Cada MAC de cliente tiene su propio cupo, de modo que varios clientes detrás del mismo relay se limitan de forma independiente y no se afectan entre sí. Si una MAC supera el número de asignaciones permitidas dentro de la ventana, las solicitudes adicionales se rechazan con la razón `"rate limited"` hasta que la ventana avance. Esto es solo una salvaguarda interna contra ráfagas de asignación; no es configurable desde `pydhcpd.conf` y no tiene directiva equivalente en isc-dhcp-server.<br><br>Note that, unlike isc-dhcp-server, pydhcpd does look at the Ethernet source MAC — not to identify the client, but as a drop filter: a non-relayed packet whose `chaddr` does not match it is discarded (see Scope).<br><br>A diferencia de isc-dhcp-server, pydhcpd sí mira la MAC Ethernet origen — no para identificar al cliente, sino como filtro de descarte: un paquete no relayado cuyo `chaddr` no coincida con ella se descarta (ver Scope). |

> **known limitation, both servers:** neither controls an attacker who rotates MAC addresses to exhaust the pool. `isc-dhcp-server`'s gap is total — it has no per-client throttle at all, so a plain flood from a single MAC already drains the pool, no rotation needed. `pydhcpd`'s gap is narrower: its per-MAC limit stops a single-MAC flood, but is keyed by MAC (`chaddr`), so it only bounds how fast *one* MAC can allocate — it does not cap the total across many different MACs, and an attacker rotating MACs can still drain the pool one new MAC at a time. A global (cross-MAC) rate limit was considered and intentionally left out of `pydhcpd`: it would need careful tuning to avoid rejecting legitimate clients during a normal burst of reconnections (e.g. many devices rejoining after a power outage), and there is no evidence MAC-rotation abuse is a live threat worth that trade-off. Documented here as a known, accepted limitation.
>

#### Pool Leases per Client

| isc-dhcp-server | pydhcpd |
|---|---|
| Does not limit how many pool IPs a single MAC can accumulate | Always limits a MAC to a single pool IP at a time; fixed daemon behavior, not a configurable directive |
| No tiene restricción sobre cuántas IPs del pool puede acumular una MAC | Siempre limita a una MAC a una sola IP del pool a la vez; comportamiento fijo del demonio, no es una directiva configurable |
> **limitación conocida, en ambos servidores:** ninguno controla a un atacante que rota direcciones MAC para agotar el pool. La brecha de `isc-dhcp-server` es total — no tiene ningún control por cliente, así que una inundación simple desde una sola MAC ya agota el pool, sin necesidad de rotar. La brecha de `pydhcpd` es más acotada: su límite por MAC frena la inundación de una sola MAC, pero está indexado por MAC (`chaddr`), así que solo acota qué tan rápido puede asignar *una* MAC — no limita el total entre muchas MACs distintas, y un atacante que rote MACs igual puede vaciar el pool, una MAC nueva a la vez. Se evaluó un límite global (entre todas las MACs) para `pydhcpd` y se dejó afuera intencionalmente: requeriría un ajuste cuidadoso para no rechazar clientes legítimos durante una ráfaga normal de reconexiones (p.ej. varios dispositivos reconectándose tras un corte de luz), y no hay evidencia de que el abuso por rotación de MAC sea una amenaza activa que justifique ese costo. Se documenta acá como una limitación conocida y aceptada.

#### WPAD/PAC Option Scoping

| isc-dhcp-server | pydhcpd |
|---|---|
| Supports scoping any option — including `option wpad` (252) — at multiple levels: `subnet`, `class`/`subclass`, or an individual `host`. A more specific scope overrides a broader one, so an admin can declare WPAD at the `subnet` level for every client and then override or omit it for a specific `class` or `host` (e.g. exclude a group of trusted/unrestricted devices from the PAC).<br><br>Soporta el alcance de cualquier opción — incluyendo `option wpad` (252) — en varios niveles: `subnet`, `class`/`subclass`, o un `host` individual. Un alcance más específico sobreescribe uno más amplio, así que un administrador puede declarar WPAD a nivel `subnet` para todos los clientes y luego sobreescribirlo u omitirlo para una `class` o `host` específico (ej. excluir a un grupo de dispositivos confiables/sin restricción del PAC). | Has no option-scoping mechanism at all — `config.wpad_url` is a single global value read once from the `subnet` block, applied identically to every `OFFER`/`ACK`/`INFORM` it sends. `WPAD_ENABLED` in `pydhcp.env` is therefore all-or-nothing: on turns WPAD on for every client, off turns it off for every client. The existing `class "blockdhcp"`/`subclass` mechanism does not generalize to this — it only marks MACs for lease denial, not a scoping construct for arbitrary options like isc-dhcp-server's classes.<br><br>No tiene ningún mecanismo de alcance de opciones — `config.wpad_url` es un único valor global leído una vez del bloque `subnet`, aplicado igual a cada `OFFER`/`ACK`/`INFORM` que envía. `WPAD_ENABLED` en `pydhcp.env` es entonces todo-o-nada: activado prende WPAD para todos los clientes, desactivado lo apaga para todos. El mecanismo existente de `class "blockdhcp"`/`subclass` no generaliza a este caso — solo marca MACs para negarles el lease, no un constructo de alcance para opciones arbitrarias como sí lo son las clases de isc-dhcp-server. |

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
