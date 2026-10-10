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
"""Unit tests of balena_env.py; the balena CLI is replaced by a recording fake."""

import json
import subprocess
import sys
from pathlib import Path

import pytest
import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))

import balena_env as be  # noqa: E402

UUID = '765bd2999c7aece20c35c2fad2275a8c'
FLEET = 'g_potlog_radu/rovera1'

COMPOSE = {
    'services': {
        'rover-a1-zenoh-router': {'environment': {
            'ROVER_NAMESPACE': 'rover', 'ROVER_ZENOH_MODE': 'client', 'ROVER_NAV_MAP': None}},
        'rover-a1-platform': {'environment': {
            'ROVER_NAMESPACE': 'rover', 'ROVER_ZENOH_MODE': 'peer', 'ROVER_NAV_MAP': None,
            'ROVER_DRIVE_PASSWORD': None}},
        'rover-a1-sensors': {'environment': {
            'ROVER_NAMESPACE': 'rover', 'ROVER_ZENOH_MODE': 'client', 'ROVER_NAV_MAP': None,
            'ROVER_CAMERA_FPS': '15', 'ROVER_USE_CAMERA': False}},
        'rover-a1-network': {'environment': {
            'ROVER_NETWORK_ENABLE': 'true', 'NETUI_PORT': '5080', 'NETUI_PASSWORD': None}},
    }
}


def entries():
    return {e.key: e for e in be.entries_from_compose(COMPOSE)}


def row(name, value, device=UUID, service='*', id_=1):
    r = {'id': id_, 'name': name, 'value': value, 'fleet': FLEET, 'serviceName': service}
    if device is not None:
        r['deviceUUID'] = device
    return r


class FakeRunner:
    """Records calls; answers `env list` / `device list` from canned JSON."""

    def __init__(self, rows=(), devices=None, fail=False):
        self.rows = list(rows)
        self.devices = devices or [{'uuid': UUID, 'device_name': 'rovera1-001'}]
        self.fail = fail
        self.calls = []

    def __call__(self, argv, capture_output, text, env):
        self.calls.append((argv, env))
        out = ''
        if argv[1:3] == ['env', 'list']:
            out = json.dumps(self.rows)
        elif argv[1:3] == ['device', 'list']:
            out = json.dumps(self.devices)
        return subprocess.CompletedProcess(argv, 1 if self.fail else 0, out, 'boom')


# ------------------------------------------------------------------ compose parsing

def test_shared_variable_is_all_services_with_majority_default():
    e = entries()
    assert e[('ROVER_ZENOH_MODE', 'device', '*')].default == 'client'
    assert e[('ROVER_ZENOH_MODE', 'device', 'rover-a1-platform')].default == 'peer'
    assert ('ROVER_ZENOH_MODE', 'device', 'rover-a1-sensors') not in e


def test_network_only_variables_are_scoped_to_the_network_service():
    e = entries()
    assert ('ROVER_NETWORK_ENABLE', 'device', 'rover-a1-network') in e
    assert ('NETUI_PORT', 'device', 'rover-a1-network') in e
    # Declared by one ROS service only, but part of the shared ROVER_* list: all services.
    assert ('ROVER_CAMERA_FPS', 'device', '*') in e


def test_values_start_unset_and_defaults_are_strings():
    e = entries()
    assert all(x.value is None for x in e.values())
    assert e[('ROVER_USE_CAMERA', 'device', '*')].default == 'false'
    assert e[('ROVER_NAV_MAP', 'device', '*')].default is None


def test_secrets_and_extras():
    e = entries()
    assert e[('NETUI_PASSWORD', 'device', 'rover-a1-network')].secret
    assert e[('ROVER_DRIVE_PASSWORD', 'device', '*')].secret
    assert e[('ROVER_LAN_IP', 'device', '*')].default == '192.168.1.201'


# ------------------------------------------------------------------ YAML file

def test_merge_keeps_user_values_scopes_and_extra_entries():
    fresh = be.entries_from_compose(COMPOSE)
    old = [be.Entry('ROVER_NAMESPACE', 'r2', 'stale', level='fleet'),
           be.Entry('ROVER_NAV_MAP', '/maps/a.yaml', service='rover-a1-sensors'),
           be.Entry('GONE_UNSET'),
           be.Entry('GONE_SET', 'x')]
    merged = {e.key: e for e in be.merge_entries(old, fresh)}
    assert merged[('ROVER_NAMESPACE', 'fleet', '*')].value == 'r2'
    assert merged[('ROVER_NAMESPACE', 'fleet', '*')].default == 'rover'
    assert ('ROVER_NAMESPACE', 'device', '*') not in merged
    assert merged[('ROVER_NAV_MAP', 'device', 'rover-a1-sensors')].value == '/maps/a.yaml'
    assert ('ROVER_NAV_MAP', 'device', '*') in merged
    assert ('GONE_SET', 'device', '*') in merged
    assert ('GONE_UNSET', 'device', '*') not in merged


def test_save_load_roundtrip_never_stores_secrets(tmp_path):
    path = tmp_path / 'env.yaml'
    items = be.entries_from_compose(COMPOSE)
    items.append(be.Entry('ROVER_USE_CAMERA', 'true', service='rover-a1-sensors'))
    items[0].value = 'true'  # YAML must keep it a string
    secret = next(e for e in items if e.name == 'NETUI_PASSWORD')
    secret.value = 'hunter2'
    be.save_config(path, be.Config(FLEET, UUID, items))
    assert 'hunter2' not in path.read_text()
    loaded = be.load_config(path)
    assert loaded.device == UUID
    assert {e.key: e.value for e in loaded.entries}[items[0].key] == 'true'
    assert len(loaded.entries) == len(items)


def test_load_rejects_duplicates_and_bad_levels(tmp_path):
    path = tmp_path / 'env.yaml'
    path.write_text(yaml.safe_dump({'variables': [{'name': 'A'}, {'name': 'A'}]}))
    with pytest.raises(ValueError, match='duplicate'):
        be.load_config(path)
    path.write_text(yaml.safe_dump({'variables': [{'name': 'A', 'level': 'app'}]}))
    with pytest.raises(ValueError, match='level'):
        be.load_config(path)


def test_yaml_booleans_and_numbers_become_balena_strings(tmp_path):
    path = tmp_path / 'env.yaml'
    path.write_text('variables:\n  - {name: A, value: true}\n  - {name: B, value: 1.5}\n')
    assert [e.value for e in be.load_config(path).entries] == ['true', '1.5']


# ------------------------------------------------------------------ cloud <-> file

def test_row_key_levels():
    assert be.row_key(row('A', '1')) == ('A', 'device', '*')
    assert be.row_key(row('A', '1', device='*')) == ('A', 'fleet', '*')
    assert be.row_key(row('A', '1', device=None, service='svc')) == ('A', 'fleet', 'svc')


def test_overlay_cloud_fills_values_retargets_level_and_appends_unknown():
    rows = [row('ROVER_ZENOH_MODE', 'peer', service='rover-a1-platform'),
            row('ROVER_NAMESPACE', 'r2', device='*'),
            row('NETUI_PASSWORD', 'hunter2', service='rover-a1-network'),
            row('START_SSHD', '1', device='*')]
    out = {e.key: e for e in be.overlay_cloud(be.entries_from_compose(COMPOSE), rows)}
    assert out[('ROVER_ZENOH_MODE', 'device', 'rover-a1-platform')].value == 'peer'
    assert out[('ROVER_NAMESPACE', 'fleet', '*')].value == 'r2'
    assert ('ROVER_NAMESPACE', 'device', '*') not in out
    assert out[('NETUI_PASSWORD', 'device', 'rover-a1-network')].value is None
    assert out[('START_SSHD', 'fleet', '*')].value == '1'


def test_diff_add_update_same_and_extra():
    items = [be.Entry('A', '1'), be.Entry('B', '2'), be.Entry('C', '3', level='fleet'),
             be.Entry('D')]
    rows = [row('B', '2'), row('C', 'old', device='*'), row('E', '5')]
    changes, extra = be.diff(items, rows)
    assert [(c.entry.name, c.action) for c in changes] == [
        ('A', 'add'), ('B', 'same'), ('C', 'update')]
    assert [r['name'] for r in extra] == ['E']


def test_scope_warnings_for_multi_reader_variables():
    assert be.scope_warnings([be.Entry('ROVER_USE_GPS', 'true', service='rover-a1-sensors')])
    assert not be.scope_warnings([be.Entry('ROVER_USE_GPS', 'true')])


# ------------------------------------------------------------------ balena CLI wrapper

def test_set_var_passes_the_value_in_the_environment_not_argv():
    runner = FakeRunner()
    cli = be.BalenaCli(runner)
    cli.set_var(be.Entry('NETUI_PASSWORD', service='rover-a1-network'), 's3cret', UUID, FLEET)
    argv, env = runner.calls[0]
    assert argv == ['balena', 'env', 'set', 'NETUI_PASSWORD', '--device', UUID,
                    '--service', 'rover-a1-network', '--quiet']
    assert 's3cret' not in argv
    assert env['NETUI_PASSWORD'] == 's3cret'


def test_set_var_fleet_level_and_device_required():
    runner = FakeRunner()
    cli = be.BalenaCli(runner)
    cli.set_var(be.Entry('A', level='fleet'), '1', None, FLEET)
    assert runner.calls[0][0] == ['balena', 'env', 'set', 'A', '--fleet', FLEET, '--quiet']
    with pytest.raises(be.BalenaError, match='no device'):
        cli.set_var(be.Entry('A'), '1', None, FLEET)


@pytest.mark.parametrize('device, service, flags', [
    (UUID, '*', ['--device']),
    (UUID, 'svc', ['--device', '--service']),
    ('*', '*', []),
    (None, 'svc', ['--service']),
])
def test_remove_var_flags(device, service, flags):
    runner = FakeRunner()
    be.BalenaCli(runner).remove_var(row('A', '1', device=device, service=service, id_=42))
    assert runner.calls[0][0] == ['balena', 'env', 'rm', '42', *flags, '--yes']


def test_cli_error_does_not_leak_the_value():
    runner = FakeRunner(fail=True)
    with pytest.raises(be.BalenaError) as exc:
        be.BalenaCli(runner).set_var(be.Entry('P_PASSWORD'), 's3cret', UUID, FLEET)
    assert 's3cret' not in str(exc.value)


def test_resolve_device_by_name_prefix_or_only_device():
    cli = be.BalenaCli(FakeRunner())
    assert be.resolve_device(cli, FLEET, 'rovera1-001')[0] == UUID
    assert be.resolve_device(cli, FLEET, '765bd29')[0] == UUID
    assert be.resolve_device(cli, FLEET, None)[1] == 'rovera1-001'
    with pytest.raises(be.BalenaError):
        be.resolve_device(cli, FLEET, 'nope')


# ------------------------------------------------------------------ subcommands

def compose_file(tmp_path):
    path = tmp_path / 'docker-compose.yml'
    path.write_text(yaml.safe_dump(COMPOSE))
    return path


def test_write_dry_run_sets_nothing(tmp_path):
    env_file = tmp_path / 'env.yaml'
    items = be.entries_from_compose(COMPOSE) + [be.Entry('X', '1')]
    be.save_config(env_file, be.Config(FLEET, UUID, items))
    runner = FakeRunner()
    args = ['--file', str(env_file), '--compose', str(compose_file(tmp_path)), 'write', '--dry-run']
    assert be.main(args, be.BalenaCli(runner)) == 0
    assert not [c for c in runner.calls if c[0][1:3] == ['env', 'set']]


def test_write_yes_sets_only_changed_entries(tmp_path):
    env_file = tmp_path / 'env.yaml'
    items = [be.Entry('X', '1'), be.Entry('Y', '2'), be.Entry('Z')]
    be.save_config(env_file, be.Config(FLEET, UUID, items))
    runner = FakeRunner(rows=[row('Y', '2')])
    args = ['--file', str(env_file), '--compose', str(compose_file(tmp_path)), 'write', '--yes']
    assert be.main(args, be.BalenaCli(runner)) == 0
    sets = [c[0][3] for c in runner.calls if c[0][1:3] == ['env', 'set']]
    assert sets == ['X']


def test_dump_then_diff_is_clean(tmp_path, capsys):
    env_file = tmp_path / 'env.yaml'
    rows = [row('ROVER_ZENOH_MODE', 'peer', service='rover-a1-platform'),
            row('ROVER_CAMERA_FPS', '6'), row('START_SSHD', '1', device='*')]
    cli = be.BalenaCli(FakeRunner(rows=rows))
    base = ['--file', str(env_file), '--compose', str(compose_file(tmp_path)),
            '--device', 'rovera1-001']
    assert be.main([*base, 'dump'], cli) == 0
    capsys.readouterr()
    assert be.main([*base, 'diff'], cli) == 0
    assert '0 to write, 3 already equal' in capsys.readouterr().out
