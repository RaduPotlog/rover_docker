"""Run the router-side shell (backup, watchdog, rollback) under a POSIX sh with stubbed tools."""

import os
import re
import subprocess
from pathlib import Path

import pytest

from uplink_manager.infrastructure.ssh_router import (
    SshRouter, reload_commands, rollback_script)

TX = '20260928-231500'


@pytest.fixture
def root(tmp_path):
    for d in ('etc/config', 'etc/init.d', 'tmp', 'bin'):
        (tmp_path / d).mkdir(parents=True)
    for p in ('wireless', 'network', 'firewall'):
        (tmp_path / 'etc/config' / p).write_text(f'{p} original\n')
    calls = tmp_path / 'calls'
    stub = f'#!/bin/sh\necho "$(basename $0) $*" >> {calls}\n'
    for tool in ('uci', 'wifi'):
        (tmp_path / 'bin' / tool).write_text(stub)
    for svc in ('network', 'firewall'):
        (tmp_path / 'etc/init.d' / svc).write_text(stub)
    for f in list((tmp_path / 'bin').iterdir()) + list((tmp_path / 'etc/init.d').iterdir()):
        f.chmod(0o755)
    return tmp_path


def rooted(script: str, root: Path) -> str:
    # One pass, so the (itself /tmp-based) root is not rewritten again.
    return re.sub(r'(?<![\w.-])/(etc|tmp)/', lambda m: f'{root}/{m.group(1)}/', script)


def sh(cmd: str, root: Path, stdin: str | None = None):
    env = {'PATH': f'{root}/bin:/usr/bin:/bin'}
    return subprocess.run(['sh', '-c', cmd], input=stdin, env=env, capture_output=True,
                          text=True, timeout=20, check=True)


def begin(root: Path, watchdog_s: int = 3600):
    cmd = SshRouter._begin_cmd(TX, 'wireless network firewall mwan3', watchdog_s)
    sh(rooted(cmd, root), root, stdin=rooted(rollback_script(TX), root))


def test_backup_then_rollback_restores_and_reloads(root):
    begin(root)
    assert (root / f'etc/netui-backup/{TX}/wireless').read_text() == 'wireless original\n'
    assert not (root / f'etc/netui-backup/{TX}/mwan3').exists()  # absent package skipped
    (root / 'etc/config/wireless').write_text('wireless CHANGED\n')

    sh(f'sh {root}/tmp/netui-rollback-{TX}.sh now', root)

    assert (root / 'etc/config/wireless').read_text() == 'wireless original\n'
    assert (root / f'tmp/netui-rolledback-{TX}').exists()
    calls = (root / 'calls').read_text()
    assert 'wifi reload' in calls and 'firewall reload' in calls
    assert 'network reload' not in calls  # network config was untouched
    assert 'restored: wireless' in (root / f'tmp/netui-rollback-{TX}.log').read_text()


def test_confirm_beats_watchdog(root):
    begin(root)
    (root / 'etc/config/firewall').write_text('firewall NEW\n')
    os.mkdir(root / f'tmp/netui-done-{TX}')  # what confirm() does on the router
    sh(f'sh {root}/tmp/netui-rollback-{TX}.sh watchdog', root)
    assert (root / 'etc/config/firewall').read_text() == 'firewall NEW\n'
    assert (root / f'tmp/netui-skipped-{TX}').exists()


def test_second_rollback_is_noop(root):
    begin(root)
    sh(f'sh {root}/tmp/netui-rollback-{TX}.sh now', root)
    (root / 'calls').write_text('')
    sh(f'sh {root}/tmp/netui-rollback-{TX}.sh watchdog', root)
    assert (root / 'calls').read_text() == ''


def test_old_backups_pruned(root):
    for i in range(7):
        (root / f'etc/netui-backup/20260101-00000{i}').mkdir(parents=True)
    begin(root)
    kept = sorted(p.name for p in (root / 'etc/netui-backup').iterdir())
    assert len(kept) == 5 and TX in kept


def test_reload_order():
    assert reload_commands(['wireless']) == ['wifi reload || wifi up',
                                             '/etc/init.d/firewall reload']
    assert reload_commands(['firewall']) == ['/etc/init.d/firewall reload']
    assert reload_commands(['network', 'mwan3'])[0] == '/etc/init.d/network reload'
