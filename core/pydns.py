#!/usr/bin/env python3
# pydns -- publish pydhcp reservations and active leases in Unbound
# FILE: core/pydns.py

import fcntl
import ipaddress
import json
import logging
import os
from pathlib import Path
import re
import subprocess
import shutil
import stat
import sys
import tempfile
from datetime import datetime, timezone

PYDHCP_ENV = Path('/etc/pydhcp/pydhcp.env')
STATE_DIR = Path('/var/lib/pydhcp-dns')
UNBOUND_CONF = '/etc/unbound/unbound.conf'
FORWARD_CONF = Path('/etc/unbound/unbound.conf.d/forward.conf')
UH_HOST = re.compile(r'^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$')
UH_FQDN = re.compile(r'^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$')
UH_MAC = re.compile(r'^(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$')


def read_env(path):
    values = {}
    for line in path.read_text().splitlines():
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        key, sep, value = line.partition('=')
        if (not sep or not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', key)
                or (value and (value[0] in ' \t\"\'' or value[-1] in ' \t\"\''))):
            raise ValueError('invalid pydhcp.env syntax')
        values[key] = value
    for key in ('SERVER_IP', 'SERV_DOMAIN', 'SERV_SUBNET', 'SERV_MASK', 'DHCPDv4_CONF', 'PYDHCPD_LEASES'):
        if not values.get(key):
            raise ValueError(f'{key} missing or empty')
    domain = values['SERV_DOMAIN']
    if len(domain) > 253 or not UH_FQDN.fullmatch(domain):
        raise ValueError('SERV_DOMAIN invalid domain')
    return values



def configure_dns(values, config_path=FORWARD_CONF, run=subprocess.run):
    address = ipaddress.IPv4Address(values['SERVER_IP'])
    network = ipaddress.IPv4Network(f"{values['SERV_SUBNET']}/{values['SERV_MASK']}", strict=False)
    if (str(network.netmask) != values['SERV_MASK'] or address not in network
            or address.is_loopback or address in (network.network_address, network.broadcast_address)):
        raise ValueError('invalid SERVER_IP or LAN subnet/mask')
    domain = values['SERV_DOMAIN'].lower()
    if not UH_FQDN.fullmatch(domain) or len(domain) > 253:
        raise ValueError('SERV_DOMAIN invalid domain')
    if config_path.is_symlink():
        raise ValueError('Unbound configuration must not be a symbolic link')
    original = config_path.read_text()
    section = re.search(r'(?ms)^server:[ \t]*\n(.*?)(?=^\S|\Z)', original)
    if not section:
        raise ValueError('Unbound server section missing')
    body = section[1]
    directives = (
        ('interface', 2, f'    interface: 127.0.0.1\n    interface: {address}\n'),
        ('access-control', 2, f'    access-control: 127.0.0.0/8 allow\n    access-control: {network} allow\n'),
        ('local-zone', 1, f'    local-zone: "{domain}." static\n'),
    )
    for name, count, replacement in directives:
        pattern = re.compile(r'(?m)^[ \t]+' + re.escape(name) + r':[^\n]*(?:\n|$)')
        matches = list(pattern.finditer(body))
        if len(matches) != count:
            raise ValueError(f'expected {count} managed {name} directives')
        first = matches[0].start()
        body = pattern.sub(lambda match: replacement if match.start() == first else '', body)
    updated = original[:section.start(1)] + body + original[section.end(1):]
    if updated == original:
        return False
    metadata = config_path.stat()
    backup = config_path.with_name(config_path.name + '.bak')
    if backup.is_symlink():
        raise ValueError('Unbound backup must not be a symbolic link')
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode='w', dir=config_path.parent,
                                         prefix='forward-', suffix='.tmp', delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(updated)
            stream.flush()
            os.fsync(stream.fileno())
            os.fchmod(stream.fileno(), stat.S_IMODE(metadata.st_mode))
            os.fchown(stream.fileno(), metadata.st_uid, metadata.st_gid)
        run(['/usr/sbin/unbound-checkconf', str(temporary)], check=True,
            capture_output=True, text=True, timeout=10)
        shutil.copy2(config_path, backup)
        os.chown(backup, metadata.st_uid, metadata.st_gid)
        os.replace(temporary, config_path)
        temporary = None
        try:
            run(['systemctl', 'restart', 'unbound'], check=True,
                capture_output=True, text=True, timeout=30)
        except (OSError, subprocess.SubprocessError):
            os.replace(backup, config_path)
            run(['systemctl', 'restart', 'unbound'], check=True,
                capture_output=True, text=True, timeout=30)
            raise
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    return True


def local_name(name, domain):
    name = name.lower().rstrip('.')
    suffix = '.' + domain.lower()
    if name.endswith(suffix):
        name = name[:-len(suffix)]
    if not UH_HOST.fullmatch(name):
        return None
    fqdn = name + suffix + '.'
    return fqdn if len(fqdn) <= 254 else None


def read_records(values, now):
    domain = values['SERV_DOMAIN'].lower()
    network = ipaddress.IPv4Network(f"{values['SERV_SUBNET']}/{values['SERV_MASK']}", strict=False)
    config = Path(values['DHCPDv4_CONF']).read_text()
    config = re.sub(r'"(?:[^"\\]|\\.)*"|#[^\n]*',
                    lambda m: m[0] if m[0].startswith('"') else '', config)
    configured = re.search(r'\boption\s+domain-name\s+"([^"\n]+)"\s*;', config)
    if not configured or configured[1].lower() != domain:
        raise ValueError('DHCP domain differs from SERV_DOMAIN; rebuild configuration')
    blocked = {mac.lower() for mac in re.findall(
        r'\bsubclass\s+"blockdhcp"\s+1:([^\s;]+)\s*;', config)}
    candidates = []
    reserved_ips = set()
    reserved_macs = set()
    for match in re.finditer(r'\bhost\s+(\S+)\s*\{([^{}]*)\}', config):
        mac = re.search(r'hardware\s+ethernet\s+([^\s;]+)\s*;', match[2])
        address = re.search(r'fixed-address\s+([^\s;]+)\s*;', match[2])
        if not mac or not address or not UH_MAC.fullmatch(mac[1]):
            continue
        try:
            ip = ipaddress.IPv4Address(address[1])
        except ValueError:
            continue
        reserved_ips.add(str(ip))
        reserved_macs.add(mac[1].lower())
        name = local_name(match[1], domain)
        if name and ip in network and ip not in (network.network_address, network.broadcast_address):
            candidates.append((0, 0, name, str(ip), None))

    # The daemon replaces this file atomically; a missing file is an error,
    # not an empty snapshot that would withdraw every dynamic name.
    leases = Path(values['PYDHCPD_LEASES']).read_text()
    for match in re.finditer(r'\blease\s+([^\s{}]+)\s*\{([^{}]*)\}', leases):
        body = match[2]
        host = re.search(r'client-hostname\s+"([^"\n]*)"\s*;', body)
        end = re.search(r'ends\s+\d+\s+(\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2})\s*;', body)
        mac = re.search(r'hardware\s+ethernet\s+([^\s;]+)\s*;', body)
        binding = re.search(r'binding\s+state\s+(\w+)\s*;', body)
        if not host or not end or not mac or not UH_MAC.fullmatch(mac[1]):
            continue
        if binding and binding[1] != 'active':
            continue
        try:
            ip = ipaddress.IPv4Address(match[1])
            expiry = datetime.strptime(end[1], '%Y/%m/%d %H:%M:%S').replace(tzinfo=timezone.utc).timestamp()
        except ValueError:
            continue
        name = local_name(host[1], domain)
        if (name and expiry > now and ip in network
                and ip not in (network.network_address, network.broadcast_address)
                and str(ip) not in reserved_ips and mac[1].lower() not in reserved_macs
                and mac[1].lower() not in blocked):
            candidates.append((1, -expiry, name, str(ip), expiry))

    # Reservations win; dynamic ties prefer the latest expiry, then name/IP.
    records = set()
    names, addresses = set(), set()
    for priority, _, name, address, expiry in sorted(candidates):
        if name in names or address in addresses:
            continue
        names.add(name)
        addresses.add(address)
        ttl = 30 if priority == 0 else max(1, min(30, int(expiry - now)))
        reverse = ipaddress.IPv4Address(address).reverse_pointer + '.'
        records.add(f'{name} {ttl} IN A {address}')
        records.add(f'{reverse} {ttl} IN PTR {name}')
    return records


def control(command, *args, data=None):
    result = subprocess.run(
        ['/usr/sbin/unbound-control', '-c', UNBOUND_CONF, command, *args],
        input=data, text=True, capture_output=True, timeout=10, check=True)
    return result.stdout


def record_key(record):
    parts = record.split()
    if len(parts) < 5 or parts[2] != 'IN':
        raise ValueError('invalid managed DNS state')
    return parts[0].lower(), parts[3], ' '.join(parts[4:]).lower()


def synchronize(desired, state_path, run_control=control):
    previous = set(json.loads(state_path.read_text())) if state_path.exists() else set()
    previous_by_key = {record_key(record): record for record in previous}
    desired_by_key = {record_key(record): record for record in desired}
    live = {}
    for line in run_control('list_local_data').splitlines():
        try:
            live[record_key(line)] = line
        except ValueError:
            continue

    foreign_types = {key[:2] for key in live if key not in previous_by_key}
    for key in desired_by_key:
        if key[:2] in foreign_types:
            raise ValueError(f'DNS record already managed elsewhere: {key[0]} {key[1]}')

    obsolete = set(previous_by_key) - set(desired_by_key)
    additions = [record for key, record in desired_by_key.items()
                 if key not in live or live[key].split()[1] != record.split()[1]]
    if not obsolete and not additions and previous == desired:
        return

    # Persist ownership before mutations so an interrupted run remains recoverable.
    pending = previous | desired
    temporary = state_path.with_suffix('.new')
    temporary.write_text(json.dumps(sorted(pending)) + '\n')
    os.replace(temporary, state_path)
    # Bulk name removal is safe only when no unrelated RR shares that owner.
    owners = {key[0] for key in obsolete}
    live_owners = {}
    for key in live:
        live_owners.setdefault(key[0], set()).add(key)
    desired_owners = {key[0] for key in desired_by_key}
    bulk = {owner for owner in owners
            if live_owners.get(owner, set()) <= obsolete and owner not in desired_owners}
    if bulk:
        run_control('local_datas_remove', data='\n'.join(sorted(bulk)) + '\n')
    # Unbound removes whole names only (a full RR is answered "ok" and kept),
    # so drop the name and put back every RR on it that must stay.
    removed_owners = sorted({key[0] for key in obsolete if key in live} - bulk)
    for owner in removed_owners:
        run_control('local_data_remove', owner)
    restored = {key: line for key, line in live.items()
                if key[0] in removed_owners and key not in obsolete and key not in desired_by_key}
    additions = sorted(set(additions) | set(restored.values())
                       | {record for key, record in desired_by_key.items() if key[0] in removed_owners})
    if additions:
        run_control('local_datas', data='\n'.join(additions) + '\n')
    # Commit the new state only once Unbound really matches it; otherwise the
    # pending state keeps ownership and the next run retries.
    still_live = set()
    for line in run_control('list_local_data').splitlines():
        try:
            still_live.add(record_key(line))
        except ValueError:
            continue
    for problem, keys in (('cannot remove', obsolete & still_live),
                          ('cannot publish', set(desired_by_key) - still_live),
                          ('cannot restore', set(restored) - still_live)):
        if keys:
            key = min(keys)
            raise ValueError(f'{problem} DNS record: {key[0]} {key[1]} {key[2]}')
    temporary.write_text(json.dumps(sorted(desired)) + '\n')
    os.replace(temporary, state_path)


def main():
    logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s: %(message)s',
                        datefmt='%Y-%m-%d %H:%M:%S')
    if os.geteuid() != 0:
        logging.error('This script must be run as root -abort')
        return 1
    if sys.argv[1:] not in ([], ['--configure']):
        logging.error('Usage: pydns.py [--configure] -abort')
        return 1
    configure = sys.argv[1:] == ['--configure']
    # State files are root-only (600); without this they inherit umask 022 (644).
    os.umask(0o077)
    try:
        # Direct reload callers also need the same root-only state and lock.
        STATE_DIR.mkdir(mode=0o700, exist_ok=True)
        with (STATE_DIR / 'publish.lock').open('a') as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX if configure else fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return 0
            values = read_env(PYDHCP_ENV)
            desired = read_records(values, datetime.now(timezone.utc).timestamp())
            if configure:
                configure_dns(values)
            synchronize(desired, STATE_DIR / 'records.json')
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        logging.error('DNS: %s -abort', error)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
