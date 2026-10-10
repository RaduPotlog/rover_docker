#!/usr/bin/env python3
# Copyright 2026 Mechatronics Academy
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
"""Keep the rover's balenaCloud variables in a YAML file.

The YAML file (default: balena_env.yaml next to this script) lists every variable that
docker-compose.yml declares, one entry per (name, level, service):

    value    what to set on balenaCloud; null = not managed (the compose default applies)
    default  the docker-compose.yml default, for reference
    level    device | fleet
    service  '*' (all services) or one compose service, e.g. rover-a1-network

Run without arguments for the interactive menu. The same actions exist as subcommands:

    balena_env.py init                 # (re)generate the YAML from docker-compose.yml
    balena_env.py dump                 # balenaCloud -> YAML
    balena_env.py diff                 # YAML vs balenaCloud
    balena_env.py write [--dry-run]    # YAML -> balenaCloud (changed entries only)
    balena_env.py migrate [--dry-run]  # old names on balenaCloud -> new (env_renames.yaml)

Talks to balenaCloud through the balena CLI, which must be installed and logged in.
Secrets (names containing PASSWORD, SECRET or TOKEN) are never stored in the YAML; set them
from the menu, which passes the value to the CLI through its environment, not its argv.
"""

from __future__ import annotations

import argparse
import dataclasses
import getpass
import json
import os
import re
import shutil
import subprocess
import sys
from collections import Counter
from pathlib import Path
from typing import Callable

import yaml

HERE = Path(__file__).resolve().parent
DEFAULT_COMPOSE = HERE.parent / 'docker-compose.yml'
DEFAULT_FILE = HERE / 'balena_env.yaml'
DEFAULT_RENAMES = HERE / 'env_renames.yaml'
DEFAULT_FLEET = 'g_potlog_radu/rovera1'

ALL = '*'
LEVELS = ('device', 'fleet')
SECRET_RE = re.compile(r'PASSWORD|SECRET|TOKEN')
UUID_RE = re.compile(r'^[0-9a-f]{7,62}$')

# Read by more than one service, so README.md asks for all-services variables: every
# ROVER_SYSTEM_* one, and ROVER_PLATFORM_ENABLE (the orchestrator idles without a platform).
ALL_SERVICES_ONLY_RE = re.compile(r'^(ROVER_SYSTEM_|ROVER_PLATFORM_ENABLE$)')

# Documented in README.md but not declared in docker-compose.yml: (name, default).
EXTRA_VARIABLES = (
    ('ROVER_SYSTEM_LAN_IP', '192.168.1.201'),
    ('ROVER_SYSTEM_LOG_MAX_MB', '20'),
    ('ROVER_SYSTEM_LOG_BACKUPS', '3'),
    ('ROVER_SYSTEM_ROS_LOG_MAX_MB', '300'),
    ('ROVER_SYSTEM_ROS_LOG_KEEP_DAYS', '7'),
    ('ROVER_UI_AUX_OUTPUT_NAMES', None),
    ('ROVER_UI_AUX_INPUT_NAMES', None),
)

# Container scope token of each compose service (ROVER_<SCOPE>_*, ROVER_ZENOH_MODE_<SCOPE>).
SERVICE_SCOPES = {
    'rover-a1-platform': 'PLATFORM',
    'rover-a1-orchestrator': 'ORCH',
    'rover-a1-sensors': 'SENSORS',
    'rover-a1-drive-interface': 'UI',
    'rover-a1-vda5050': 'VDA5050',
    'rover-a1-network': 'NETWORK',
}

# Display / file grouping by name scope, first match wins. Mirrors the README "Device
# variables" tables. Names not in the schema (e.g. old ones still on balenaCloud) go to Other.
GROUPS = (
    ('Network uplink page (rover-a1-network)',
     re.compile(r'^(ROVER_NETWORK_|NETUI_|RUTX11_|UPLINK_|LAN_ZONE$|CLIENT_NETS$)')),
    ('System (all services)', re.compile(r'^ROVER_SYSTEM_(?!MOUNT_)')),
    ('Sensor mount poses (all services)', re.compile(r'^ROVER_SYSTEM_MOUNT_')),
    ('Zenoh session mode', re.compile(r'^ROVER_ZENOH_MODE_')),
    ('Platform', re.compile(r'^ROVER_PLATFORM_')),
    ('Orchestrator', re.compile(r'^ROVER_ORCH_')),
    ('Sensors', re.compile(r'^ROVER_SENSORS_')),
    ('Drive interface', re.compile(r'^ROVER_UI_')),
    ('VDA 5050', re.compile(r'^ROVER_VDA5050_')),
    ('Other', re.compile(r'')),
)

FILE_HEADER = """\
# balenaCloud variables of the Rover A1 fleet, managed with tools/balena_env.py.
#
# device: UUID, UUID prefix or name; null = the fleet's only device.
#
# One entry per (name, level, service):
#   value    what balena_env.py writes; null = not managed (the compose default applies)
#   default  docker-compose.yml default, for reference only
#   level    device | fleet
#   service  '*' = all services, or one compose service (e.g. rover-a1-network)
#   secret   never stored here; set it from the menu ("Set a secret")
#
# Regenerate from docker-compose.yml with `balena_env.py init` (keeps your values).
"""


class BalenaError(RuntimeError):
    """A balena CLI call failed."""


def _to_str(value: object) -> str | None:
    """Return a YAML scalar as the string balenaCloud stores (true -> 'true')."""
    if value is None:
        return None
    if isinstance(value, bool):
        return 'true' if value else 'false'
    return str(value)


def is_secret(name: str) -> bool:
    return bool(SECRET_RE.search(name))


def group_of(name: str) -> str:
    return next(title for title, regex in GROUPS if regex.search(name))


@dataclasses.dataclass
class Entry:
    """One variable as balenaCloud scopes it."""

    name: str
    value: str | None = None
    default: str | None = None
    level: str = 'device'
    service: str = ALL
    secret: bool = False

    @property
    def key(self) -> tuple[str, str, str]:
        return (self.name, self.level, self.service)

    def to_dict(self) -> dict:
        data = {'name': self.name, 'value': None if self.secret else self.value,
                'default': self.default, 'level': self.level, 'service': self.service}
        if self.secret:
            data['secret'] = True
        return data

    @classmethod
    def from_dict(cls, data: dict) -> Entry:
        if not isinstance(data, dict) or not data.get('name'):
            raise ValueError(f'variable entry without a name: {data!r}')
        name = str(data['name'])
        level = str(data.get('level', 'device'))
        if level not in LEVELS:
            raise ValueError(f'{name}: level must be one of {LEVELS}, not {level!r}')
        secret = bool(data.get('secret', False)) or is_secret(name)
        return cls(name=name,
                   value=None if secret else _to_str(data.get('value')),
                   default=_to_str(data.get('default')),
                   level=level,
                   service=str(data.get('service') or ALL),
                   secret=secret)


@dataclasses.dataclass
class Config:
    fleet: str
    device: str | None
    entries: list[Entry]


def row_key(row: dict) -> tuple[str, str, str]:
    """(name, level, service) of a `balena env list --json` row."""
    level = 'fleet' if row.get('deviceUUID') in (None, ALL) else 'device'
    return (row['name'], level, row.get('serviceName') or ALL)


# --------------------------------------------------------------------------- compose / YAML

def compose_services(compose: dict) -> list[str]:
    return list((compose.get('services') or {}).keys())


def _environment(spec: dict) -> dict[str, str | None]:
    env = spec.get('environment') or {}
    if isinstance(env, list):  # ["KEY=value", "KEY"]
        pairs = (item.split('=', 1) for item in env)
        return {p[0]: (p[1] if len(p) > 1 else None) for p in pairs}
    return {k: _to_str(v) for k, v in env.items()}


def entries_from_compose(compose: dict) -> list[Entry]:
    """One entry per variable, plus a service-scoped one per service whose default differs.

    Variables of the services that share the ROVER_* list (those declaring
    ROVER_SYSTEM_NAMESPACE) are all-services, as README.md asks. A variable only one other
    service declares (the rover-a1-network ones) is scoped to that service, so e.g. the router
    password stays there.
    """
    defaults: dict[str, dict[str, str | None]] = {}
    shared: set[str] = set()
    for service, spec in (compose.get('services') or {}).items():
        env = _environment(spec or {})
        if 'ROVER_SYSTEM_NAMESPACE' in env:
            shared.add(service)
        for name, default in env.items():
            defaults.setdefault(name, {})[service] = default

    entries = []
    for name, per_service in defaults.items():
        secret = is_secret(name)
        if len(per_service) == 1 and not shared & per_service.keys():
            (service, default), = per_service.items()
            entries.append(Entry(name, None, default, service=service, secret=secret))
            continue
        common = Counter(per_service.values()).most_common(1)[0][0]
        entries.append(Entry(name, None, common, secret=secret))
        entries.extend(Entry(name, None, default, service=service, secret=secret)
                       for service, default in per_service.items() if default != common)

    declared = set(defaults)
    entries.extend(Entry(name, None, default, secret=is_secret(name))
                   for name, default in EXTRA_VARIABLES if name not in declared)
    return entries


def load_compose(path: Path) -> tuple[list[Entry], list[str]]:
    compose = yaml.safe_load(path.read_text())
    return entries_from_compose(compose), compose_services(compose)


def merge_entries(old: list[Entry], fresh: list[Entry]) -> list[Entry]:
    """Fresh compose entries, keeping the value/level/service already in the file.

    Entries the user added (other scopes, other names) are kept; a stale entry for a name
    compose no longer declares is dropped only when it has no value.
    """
    fresh_names = {e.name for e in fresh}
    base_default = {e.name: e.default for e in fresh if e.service == ALL}
    by_name_service = {(e.name, e.service): e for e in fresh}

    out: list[Entry] = []
    seen: set[tuple[str, str, str]] = set()
    for f in fresh:
        matches = [o for o in old if (o.name, o.service) == (f.name, f.service)]
        for o in matches or [f]:
            if o.key not in seen:
                seen.add(o.key)
                out.append(dataclasses.replace(o, default=f.default, secret=f.secret))
    for o in old:
        if o.key in seen:
            continue
        if o.name in fresh_names:
            match = by_name_service.get((o.name, o.service))
            default = match.default if match else base_default.get(o.name, o.default)
            out.append(dataclasses.replace(o, default=default))
        elif o.value is not None:
            out.append(o)
        seen.add(o.key)
    return sort_entries(out, fresh)


def sort_entries(entries: list[Entry], reference: list[Entry]) -> list[Entry]:
    """Group order of GROUPS, then compose order inside a group, all-services first."""
    group_index = {title: i for i, (title, _) in enumerate(GROUPS)}
    name_index: dict[str, int] = {}
    for e in reference:
        name_index.setdefault(e.name, len(name_index))
    return sorted(entries, key=lambda e: (group_index[group_of(e.name)],
                                          name_index.get(e.name, len(name_index)),
                                          e.service != ALL, e.level != 'device'))


def load_config(path: Path) -> Config:
    data = yaml.safe_load(path.read_text()) or {}
    if not isinstance(data, dict):
        raise ValueError(f'{path}: expected a mapping with fleet, device and variables')
    entries = [Entry.from_dict(item) for item in data.get('variables') or []]
    keys = Counter(e.key for e in entries)
    dupes = [k for k, n in keys.items() if n > 1]
    if dupes:
        raise ValueError(f'{path}: duplicate (name, level, service): {dupes}')
    return Config(fleet=str(data.get('fleet') or DEFAULT_FLEET),
                  device=_to_str(data.get('device')), entries=entries)


def dump_config(config: Config) -> str:
    """The YAML text: one flow-style line per entry, a comment line per group."""
    head = yaml.safe_dump({'fleet': config.fleet, 'device': config.device},
                          sort_keys=False, default_flow_style=False)
    lines = [FILE_HEADER, head.rstrip('\n'), '', 'variables:']
    current = None
    for e in config.entries:
        group = group_of(e.name)
        if group != current:
            lines.append(f'  # --- {group} ---')
            current = group
        item = yaml.safe_dump(e.to_dict(), sort_keys=False, default_flow_style=True,
                              width=10_000).strip()
        lines.append(f'  - {item}')
    return '\n'.join(lines) + '\n'


def save_config(path: Path, config: Config) -> None:
    tmp = path.with_suffix(path.suffix + '.tmp')
    tmp.write_text(dump_config(config))
    tmp.replace(path)


# --------------------------------------------------------------------------- cloud <-> file

def overlay_cloud(entries: list[Entry], rows: list[dict]) -> list[Entry]:
    """Entries with the cloud's values filled in (dump). Secrets stay null.

    A cloud row whose scope matches no entry takes over an unset entry of the same name and
    service at the other level (compose entries default to device level); otherwise it is
    appended as a new entry.
    """
    out = [dataclasses.replace(e) for e in entries]
    by_key = {e.key: e for e in out}
    claimed: set[tuple[str, str, str]] = set()
    for row in sorted(rows, key=lambda r: r['name']):
        name, level, service = row_key(row)
        value = None if is_secret(name) else _to_str(row.get('value'))
        entry = by_key.get((name, level, service))
        if entry is None:
            entry = next((e for e in out if (e.name, e.service) == (name, service)
                          and e.value is None and e.key not in claimed), None)
            if entry is not None:
                del by_key[entry.key]
                entry.level = level
                by_key[entry.key] = entry
        if entry is None:
            entry = Entry(name, level=level, service=service, secret=is_secret(name))
            out.append(entry)
            by_key[entry.key] = entry
        entry.value = value
        claimed.add(entry.key)
    return sort_entries(out, entries)


@dataclasses.dataclass
class Change:
    action: str  # add | update | same
    entry: Entry
    cloud_value: str | None


def diff(entries: list[Entry], rows: list[dict]) -> tuple[list[Change], list[dict]]:
    """Changes for every entry with a value, and the cloud rows the file does not list."""
    cloud = {row_key(r): r for r in rows}
    changes = []
    for e in entries:
        if e.value is None:
            continue
        row = cloud.get(e.key)
        if row is None:
            changes.append(Change('add', e, None))
        else:
            cloud_value = _to_str(row.get('value'))
            changes.append(Change('same' if cloud_value == e.value else 'update', e, cloud_value))
    file_keys = {e.key for e in entries}
    extra = [r for r in rows if row_key(r) not in file_keys]
    return changes, extra


def scope_warnings(entries: list[Entry]) -> list[str]:
    return [f'{e.name} is scoped to {e.service}; README.md asks for an all-services variable'
            for e in entries
            if ALL_SERVICES_ONLY_RE.match(e.name) and e.service != ALL and e.value is not None]


# --------------------------------------------------------------------------- renames

def load_renames(path: Path) -> dict[str, list[str]]:
    """Old name -> new name(s) from env_renames.yaml; a list splits one variable in several."""
    data = yaml.safe_load(path.read_text()) or {}
    return {old: [new] if isinstance(new, str) else list(new)
            for old, new in (data.get('renames') or {}).items()}


@dataclasses.dataclass
class Rename:
    row: dict            # the old variable on balenaCloud
    entry: Entry         # the new variable to set (same level; service as below)
    value: str
    action: str          # add | same | conflict
    cloud_value: str | None = None


def plan_renames(rows: list[dict], renames: dict[str, list[str]]) -> list[Rename]:
    """What `migrate` sets, for every balenaCloud row whose name was renamed.

    The new variable keeps the old one's level, service and value. A split (the old Zenoh
    mode, one per container) goes, for an all-services row, to every new name - except a container
    that has its own service-scoped old row at that level; for a service-scoped row, to that
    container's new name only (none for a service without one, e.g. the Zenoh router). A new
    name already on balenaCloud is left alone: same value = nothing to do, else a conflict.
    """
    cloud = {row_key(r): r for r in rows}
    plan = []
    for row in sorted(rows, key=row_key):
        name, level, service = row_key(row)
        new_names = renames.get(name)
        if not new_names:
            continue
        if len(new_names) > 1:
            if service == ALL:
                own = {SERVICE_SCOPES.get(s) for (n, lv, s) in cloud
                       if n == name and lv == level and s != ALL}
                new_names = [n for n in new_names if n.rsplit('_', 1)[-1] not in own]
            else:
                token = SERVICE_SCOPES.get(service)
                new_names = [n for n in new_names if token and n.endswith(f'_{token}')]
        value = _to_str(row.get('value')) or ''
        for new in new_names:
            entry = Entry(new, None if is_secret(new) else value, level=level, service=service,
                          secret=is_secret(new))
            existing = cloud.get(entry.key)
            if existing is None:
                plan.append(Rename(row, entry, value, 'add'))
            else:
                cloud_value = _to_str(existing.get('value')) or ''
                plan.append(Rename(row, entry, value,
                                   'same' if cloud_value == value else 'conflict', cloud_value))
    return plan


def rename_entries(entries: list[Entry], renames: dict[str, list[str]]) -> list[Entry]:
    """YAML entries under their new names (a split copies the value to every new name).

    When an old and a new entry land on the same (name, level, service), the one with a value
    wins (e.g. a dumped old variable over the unset compose entry of its new name).
    """
    out: dict[tuple[str, str, str], Entry] = {}
    for e in entries:
        for name in renames.get(e.name, [e.name]):
            new = dataclasses.replace(e, name=name, secret=e.secret or is_secret(name))
            if new.key not in out or (out[new.key].value is None and new.value is not None):
                out[new.key] = new
    return list(out.values())


# --------------------------------------------------------------------------- balena CLI

Runner = Callable[..., subprocess.CompletedProcess]


class BalenaCli:
    """Thin wrapper over the balena CLI (`balena env list/set/rm`, `balena device list`)."""

    def __init__(self, runner: Runner = subprocess.run, exe: str = 'balena'):
        self._runner = runner
        self._exe = exe

    def _run(self, args: list[str], env_extra: dict[str, str] | None = None) -> str:
        env = {**os.environ, **env_extra} if env_extra else None
        try:
            proc = self._runner([self._exe, *args], capture_output=True, text=True, env=env)
        except FileNotFoundError as exc:
            raise BalenaError('balena CLI not found; install balena-cli and run '
                              '`balena login`') from exc
        if proc.returncode != 0:
            message = (proc.stderr or proc.stdout or '').strip()
            raise BalenaError(f'balena {" ".join(args[:2])} failed: {message}')
        return proc.stdout

    def check_login(self) -> str:
        return self._run(['whoami']).strip()

    def devices(self, fleet: str) -> list[dict]:
        return json.loads(self._run(['device', 'list', '--fleet', fleet, '--json']) or '[]')

    def list_vars(self, device: str | None, fleet: str) -> list[dict]:
        target = ['--device', device] if device else ['--fleet', fleet]
        return json.loads(self._run(['env', 'list', '--json', *target]) or '[]')

    def set_var(self, entry: Entry, value: str, device: str | None, fleet: str) -> None:
        """Set one variable. The value travels in the child's environment, not its argv."""
        if entry.level == 'device':
            if not device:
                raise BalenaError(f'{entry.name}: device-level variable but no device selected')
            target = ['--device', device]
        else:
            target = ['--fleet', fleet]
        service = ['--service', entry.service] if entry.service != ALL else []
        self._run(['env', 'set', entry.name, *target, *service, '--quiet'],
                  env_extra={entry.name: value})

    def remove_var(self, row: dict) -> None:
        _, level, service = row_key(row)
        flags = (['--device'] if level == 'device' else []) + \
                (['--service'] if service != ALL else [])
        self._run(['env', 'rm', str(row['id']), *flags, '--yes'])


def resolve_device(cli: BalenaCli, fleet: str, device: str | None) -> tuple[str, str]:
    """(uuid, name) of `device` (UUID, UUID prefix or name); the only device if None."""
    devices = cli.devices(fleet)
    if device is None:
        if len(devices) == 1:
            return devices[0]['uuid'], devices[0]['device_name']
        raise BalenaError(f'fleet {fleet} has {len(devices)} devices; pick one with --device')
    matches = [d for d in devices
               if d['device_name'] == device
               or (UUID_RE.match(device) and d['uuid'].startswith(device))]
    if len(matches) != 1:
        raise BalenaError(f'device {device!r}: {len(matches)} matches in fleet {fleet}')
    return matches[0]['uuid'], matches[0]['device_name']


# --------------------------------------------------------------------------- actions

def mask(entry_name: str, value: str | None) -> str:
    if value is None:
        return '-'
    return '••••••' if is_secret(entry_name) else repr(value) if value == '' else value


def scope(level: str, service: str) -> str:
    return f'{level}/{"all" if service == ALL else service}'


def cell(text: str, width: int = 16) -> str:
    return (text if len(text) <= width else text[:width - 1] + '…').ljust(width)


def print_changes(changes: list[Change], extra: list[dict], verbose: bool = False) -> None:
    pending = [c for c in changes if c.action != 'same']
    for c in pending if not verbose else changes:
        e = c.entry
        arrow = f'{mask(e.name, c.cloud_value)} -> {mask(e.name, e.value)}'
        print(f'  {c.action:<6} {e.name:<36} {scope(e.level, e.service):<30} {arrow}')
    same = len(changes) - len(pending)
    print(f'  {len(pending)} to write, {same} already equal'
          + (f', {len(extra)} on balenaCloud but not in the file:' if extra else ''))
    for r in extra:
        name, level, service = row_key(r)
        print(f'  cloud  {name:<36} {scope(level, service):<30} {mask(name, r.get("value"))}')


def show(config: Config, rows: list[dict] | None) -> None:
    cloud = {row_key(r): r for r in rows or []}
    current = None
    print(f'  {"name":<36} {"scope":<30} {"file":<16} {"cloud":<16} default')
    for e in config.entries:
        group = group_of(e.name)
        if group != current:
            print(f'\n  {group}')
            current = group
        row = cloud.get(e.key)
        cloud_value = mask(e.name, _to_str(row.get('value'))) if row else '-'
        file_value = '(secret)' if e.secret else mask(e.name, e.value)
        print(f'  {e.name:<36} {scope(e.level, e.service):<30} {cell(file_value)} '
              f'{cell(cloud_value)} {mask(e.name, e.default)}')


def write(cli: BalenaCli, config: Config, device: str | None, entries: list[Entry],
          assume_yes: bool, dry_run: bool) -> int:
    rows = cli.list_vars(device, config.fleet)
    changes, extra = diff(entries, rows)
    print_changes(changes, extra)
    pending = [c for c in changes if c.action != 'same']
    for warning in scope_warnings(entries):
        print(f'  ! {warning}')
    if not pending or dry_run:
        return 0
    print('  Each change restarts the containers that receive the variable '
          '(rover-a1-platform: ~15-30 s, web bridges down meanwhile).')
    if not assume_yes and not confirm(f'Write {len(pending)} variable(s) to balenaCloud?'):
        print('  Nothing written.')
        return 0
    failures = 0
    for c in pending:
        try:
            cli.set_var(c.entry, c.entry.value, device, config.fleet)
            print(f'  set    {c.entry.name} ({scope(c.entry.level, c.entry.service)})')
        except BalenaError as exc:
            failures += 1
            print(f'  FAILED {c.entry.name}: {exc}', file=sys.stderr)
    return 1 if failures else 0


def migrate(cli: BalenaCli, config: Config, device: str | None, renames: dict[str, list[str]],
            assume_yes: bool, dry_run: bool) -> tuple[int, bool]:
    """Set the new names of the renamed variables on balenaCloud, then remove the old ones.

    Returns (exit code, whether the YAML entries should be renamed). Nothing is removed unless
    every new variable of that old row is in place (set now, or already equal).
    """
    rows = cli.list_vars(device, config.fleet)
    plan = plan_renames(rows, renames)
    old_rows = {row_key(r.row): r.row for r in plan}
    if not plan:
        print('  No old variable names on balenaCloud; nothing to migrate.')
        return 0, True
    for r in plan:
        old = row_key(r.row)
        arrow = (f'{mask(r.entry.name, r.cloud_value)} (kept, differs from '
                 f'{mask(old[0], r.value)})' if r.action == 'conflict'
                 else mask(old[0], r.value))
        print(f'  {r.action:<8} {old[0]:<34} -> {r.entry.name:<40} '
              f'{scope(r.entry.level, r.entry.service):<30} {arrow}')
    todo = [r for r in plan if r.action == 'add']
    conflicts = [r for r in plan if r.action == 'conflict']
    kept = {row_key(r.row) for r in conflicts}
    print(f'  {len(todo)} to set, {len(plan) - len(todo) - len(conflicts)} already in place, '
          f'{len(conflicts)} conflict(s), {len(old_rows) - len(kept)} old variable(s) to remove')
    if conflicts:
        print('  ! A conflict keeps the new variable as it is and the old one in place; '
              'resolve it by hand (menu: Remove / Edit), then run migrate again.')
    if dry_run:
        return 0, False
    print('  Each change restarts the containers that receive the variable.')
    if todo and (assume_yes or confirm(f'Set {len(todo)} new variable(s) on balenaCloud?')):
        failed: set[tuple[str, str, str]] = set()
        for r in todo:
            try:
                cli.set_var(r.entry, r.value, device, config.fleet)
                print(f'  set    {r.entry.name} ({scope(r.entry.level, r.entry.service)})')
            except BalenaError as exc:
                failed.add(row_key(r.row))
                print(f'  FAILED {r.entry.name}: {exc}', file=sys.stderr)
    elif todo:
        print('  Nothing set; old variables kept.')
        return 0, False
    else:
        failed = set()
    blocked = failed | kept
    removable = [row for key, row in old_rows.items() if key not in blocked]
    if removable and (assume_yes or confirm(
            f'Remove the {len(removable)} old variable(s) from balenaCloud?')):
        for row in removable:
            try:
                cli.remove_var(row)
                print(f'  removed {row["name"]} ({scope(*row_key(row)[1:])})')
            except BalenaError as exc:
                failed.add(row_key(row))
                print(f'  FAILED removing {row["name"]}: {exc}', file=sys.stderr)
    return (1 if failed else 0), True


# --------------------------------------------------------------------------- interactive

def ask(prompt: str, default: str | None = None) -> str:
    suffix = f' [{default}]' if default not in (None, '') else ''
    answer = input(f'{prompt}{suffix}: ').strip()
    return answer if answer else (default or '')


def confirm(prompt: str, default: bool = False) -> bool:
    answer = input(f'{prompt} [{"Y/n" if default else "y/N"}]: ').strip().lower()
    return default if not answer else answer in ('y', 'yes')


def choose(items: list[str], prompt: str) -> int | None:
    for i, item in enumerate(items, 1):
        print(f'  {i:>3}) {item}')
    answer = input(f'{prompt} (number, Enter = back): ').strip()
    if answer.isdigit() and 1 <= int(answer) <= len(items):
        return int(answer) - 1
    return None


class Menu:
    def __init__(self, cli: BalenaCli, path: Path, compose: Path, config: Config,
                 services: list[str]):
        self.cli = cli
        self.path = path
        self.compose = compose
        self.config = config
        self.services = services
        self.device_uuid: str | None = None
        self.device_name: str | None = None

    # -- helpers
    def target(self) -> str | None:
        """Resolve the device lazily, so offline editing works without the CLI."""
        if self.device_uuid is None:
            self.device_uuid, self.device_name = resolve_device(
                self.cli, self.config.fleet, self.config.device)
        return self.device_uuid

    def rows(self) -> list[dict]:
        return self.cli.list_vars(self.target(), self.config.fleet)

    def save(self) -> None:
        save_config(self.path, self.config)
        print(f'  Saved {self.path}')

    def header(self) -> str:
        device = (f'{self.device_name} ({self.device_uuid[:7]})' if self.device_uuid
                  else self.config.device or 'device not resolved')
        return f'Rover A1 balena env - {device} - fleet {self.config.fleet} - {self.path.name}'

    def pick_entry(self, entries: list[Entry]) -> Entry | None:
        groups = list(dict.fromkeys(group_of(e.name) for e in entries))
        g = choose(groups, 'Group')
        if g is None:
            return None
        in_group = [e for e in entries if group_of(e.name) == groups[g]]
        i = choose([f'{e.name:<36} {scope(e.level, e.service):<30} '
                    f'{"(secret)" if e.secret else mask(e.name, e.value)}' for e in in_group],
                   'Variable')
        return None if i is None else in_group[i]

    def ask_scope(self, entry: Entry) -> tuple[str, str]:
        level = ask('Level (device/fleet)', entry.level)
        if level not in LEVELS:
            print(f'  Unknown level {level!r}; keeping {entry.level}')
            level = entry.level
        print(f'  Services: * (all), {", ".join(self.services)}')
        service = ask('Service', entry.service)
        if service != ALL and service not in self.services:
            print(f'  Unknown service {service!r}; keeping {entry.service}')
            service = entry.service
        return level, service

    # -- actions
    def do_show(self) -> None:
        show(self.config, self.rows())

    def do_dump(self) -> None:
        # Start from the unset compose list, so the file mirrors the cloud exactly.
        fresh, _ = load_compose(self.compose)
        self.config.entries = overlay_cloud(fresh, self.rows())
        self.config.device = self.target() or self.config.device
        if confirm(f'Overwrite {self.path} with the balenaCloud values?', default=True):
            self.save()

    def do_diff(self) -> None:
        changes, extra = diff(self.config.entries, self.rows())
        print_changes(changes, extra, verbose=confirm('List unchanged entries too?'))

    def do_write(self) -> None:
        write(self.cli, self.config, self.target(), self.config.entries,
              assume_yes=False, dry_run=False)

    def do_edit(self) -> None:
        entry = self.pick_entry(self.config.entries)
        if entry is None:
            return
        if entry.secret:
            print('  Secrets are not stored in the file; use "Set a secret".')
            return
        print(f'  {entry.name}: value {mask(entry.name, entry.value)}, '
              f'default {mask(entry.name, entry.default)}, {scope(entry.level, entry.service)}')
        value = ask('New value (Enter = keep, "-" = unset/not managed)',
                    entry.value if entry.value is not None else None)
        level, service = self.ask_scope(entry)
        new = dataclasses.replace(entry, value=None if value in ('-', '') else value,
                                  level=level, service=service)
        if new.key != entry.key and any(e.key == new.key for e in self.config.entries):
            print(f'  {new.name} already has an entry for {scope(level, service)}; edit that one.')
            return
        if new.key != entry.key and confirm('Keep the original scope as a separate entry?'):
            self.config.entries.append(new)
        else:
            self.config.entries[self.config.entries.index(entry)] = new
        self.config.entries = sort_entries(self.config.entries, self.config.entries)
        for warning in scope_warnings([new]):
            print(f'  ! {warning}')
        self.save()

    def do_secret(self) -> None:
        secrets = [e for e in self.config.entries if e.secret]
        i = choose([f'{e.name:<36} {scope(e.level, e.service)}' for e in secrets], 'Secret')
        if i is None:
            return
        entry = secrets[i]
        level, service = self.ask_scope(entry)
        entry = dataclasses.replace(entry, level=level, service=service)
        value = getpass.getpass(f'{entry.name}: ')
        if not value or value != getpass.getpass('Repeat: '):
            print('  Empty or not matching; nothing set.')
            return
        if confirm(f'Set {entry.name} on {scope(level, service)}?', default=True):
            self.cli.set_var(entry, value, self.target(), self.config.fleet)
            print(f'  set    {entry.name}')

    def do_remove(self) -> None:
        rows = sorted(self.rows(), key=row_key)
        i = choose([f'{r["name"]:<36} {scope(*row_key(r)[1:]):<30} '
                    f'{mask(r["name"], _to_str(r.get("value")))}' for r in rows],
                   'Remove')
        if i is None:
            return
        row = rows[i]
        key = row_key(row)
        if not confirm(f'Remove {key[0]} ({scope(*key[1:])}) from balenaCloud?'):
            return
        self.cli.remove_var(row)
        print(f'  removed {key[0]}')
        entry = next((e for e in self.config.entries if e.key == key), None)
        if entry is not None and entry.value is not None and confirm(
                'Unset it in the YAML too (otherwise the next write sets it again)?', True):
            entry.value = None
            self.save()

    def do_migrate(self) -> None:
        renames = load_renames(DEFAULT_RENAMES)
        _, rename_yaml = migrate(self.cli, self.config, self.target(), renames,
                                 assume_yes=False, dry_run=False)
        if rename_yaml:
            fresh, self.services = load_compose(self.compose)
            renamed = rename_entries(self.config.entries, renames)
            self.config.entries = merge_entries(renamed, fresh)
            self.save()

    def do_regenerate(self) -> None:
        fresh, self.services = load_compose(self.compose)
        self.config.entries = merge_entries(self.config.entries, fresh)
        self.save()

    def do_target(self) -> None:
        self.config.fleet = ask('Fleet slug', self.config.fleet)
        devices = self.cli.devices(self.config.fleet)
        i = choose([f'{d["device_name"]:<20} {d["uuid"][:7]}  '
                    f'{"online" if d.get("is_online") else "offline"}' for d in devices],
                   'Device')
        if i is None:
            return
        self.config.device = devices[i]['uuid']
        self.device_uuid, self.device_name = devices[i]['uuid'], devices[i]['device_name']
        self.save()

    def run(self) -> int:
        actions = [
            ('Show variables (file vs balenaCloud)', self.do_show),
            ('Dump balenaCloud -> YAML', self.do_dump),
            ('Diff YAML vs balenaCloud', self.do_diff),
            ('Write YAML -> balenaCloud', self.do_write),
            ('Edit one variable in the YAML', self.do_edit),
            ('Set a secret (straight to balenaCloud)', self.do_secret),
            ('Remove a balenaCloud variable', self.do_remove),
            ('Regenerate YAML from docker-compose.yml (keeps your values)', self.do_regenerate),
            ('Migrate old variable names on balenaCloud (env_renames.yaml)', self.do_migrate),
            ('Change device / fleet', self.do_target),
        ]
        while True:
            try:
                self.target()
            except BalenaError as exc:
                print(f'  ! {exc}')
            print(f'\n{self.header()}')
            for i, (label, _) in enumerate(actions, 1):
                print(f'  {i}) {label}')
            print('  q) Quit')
            try:
                answer = input('> ').strip().lower()
                if answer in ('q', 'quit', 'exit'):
                    return 0
                if answer.isdigit() and 1 <= int(answer) <= len(actions):
                    actions[int(answer) - 1][1]()
            except BalenaError as exc:
                print(f'  ! {exc}')
            except (EOFError, KeyboardInterrupt):
                print()
                return 0


# --------------------------------------------------------------------------- main

def parse_args(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=__doc__.split('\n\n')[0],
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog='Without a command the interactive menu starts.')
    parser.add_argument('--file', type=Path, default=DEFAULT_FILE, help='variables YAML')
    parser.add_argument('--compose', type=Path, default=DEFAULT_COMPOSE,
                        help='docker-compose.yml to read the variable list from')
    parser.add_argument('--fleet', help='fleet slug (overrides the YAML)')
    parser.add_argument('--device', help='device UUID, UUID prefix or name (overrides the YAML)')
    sub = parser.add_subparsers(dest='command')
    sub.add_parser('menu', help='interactive menu (default)')
    sub.add_parser('init', help='(re)generate the YAML from docker-compose.yml')
    sub.add_parser('show', help='table of file and balenaCloud values')
    sub.add_parser('dump', help='write the balenaCloud values into the YAML')
    sub.add_parser('diff', help='compare the YAML with balenaCloud')
    write_parser = sub.add_parser('write', help='set the changed YAML entries on balenaCloud')
    write_parser.add_argument('--yes', action='store_true', help='do not ask for confirmation')
    write_parser.add_argument('--dry-run', action='store_true', help='only show the changes')
    migrate_parser = sub.add_parser(
        'migrate', help='rename old variable names on balenaCloud (set new, then remove old)')
    migrate_parser.add_argument('--yes', action='store_true', help='do not ask for confirmation')
    migrate_parser.add_argument('--dry-run', action='store_true', help='only show the plan')
    migrate_parser.add_argument('--renames', type=Path, default=DEFAULT_RENAMES,
                                help='old -> new names (YAML)')
    return parser.parse_args(argv)


def main(argv: list[str] | None = None, cli: BalenaCli | None = None) -> int:
    args = parse_args(argv)
    cli = cli or BalenaCli()
    fresh, services = load_compose(args.compose)

    if args.file.exists():
        config = load_config(args.file)
    else:
        config = Config(DEFAULT_FLEET, None, fresh)
    config.fleet = args.fleet or config.fleet
    config.device = args.device or config.device
    command = args.command or 'menu'

    try:
        if command == 'init':
            config.entries = merge_entries(config.entries if args.file.exists() else [], fresh)
            save_config(args.file, config)
            print(f'Wrote {len(config.entries)} entries to {args.file}')
            return 0
        if command == 'menu':
            if not sys.stdin.isatty():
                print('The menu needs a terminal; use a subcommand (see --help).',
                      file=sys.stderr)
                return 2
            if shutil.which('balena') is None:
                print('! balena CLI not found: only offline editing works.')
            return Menu(cli, args.file, args.compose, config, services).run()

        device = resolve_device(cli, config.fleet, config.device)[0]
        if command == 'show':
            show(config, cli.list_vars(device, config.fleet))
        elif command == 'dump':
            config.entries = overlay_cloud(fresh, cli.list_vars(device, config.fleet))
            config.device = device or config.device
            save_config(args.file, config)
            print(f'Wrote {len(config.entries)} entries to {args.file}')
        elif command == 'diff':
            print_changes(*diff(config.entries, cli.list_vars(device, config.fleet)))
        elif command == 'write':
            return write(cli, config, device, config.entries, args.yes, args.dry_run)
        elif command == 'migrate':
            renames = load_renames(args.renames)
            code, rename_yaml = migrate(cli, config, device, renames, args.yes, args.dry_run)
            if rename_yaml and args.file.exists():
                config.entries = merge_entries(rename_entries(config.entries, renames), fresh)
                save_config(args.file, config)
                print(f'Renamed the entries in {args.file}')
            return code
        return 0
    except BalenaError as exc:
        print(f'error: {exc}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
