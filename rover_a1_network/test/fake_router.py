"""In-memory router: uci state + a tiny model of association / DHCP / NAT."""

from __future__ import annotations

from pathlib import Path

from uplink_manager.application.ports import RouterError, RouterGateway
from uplink_manager.domain.invariants import UplinkSettings, uplink_sta, zone
from uplink_manager.domain.runtime import UplinkRuntime
from uplink_manager.domain.uci import UciCmd, parse_uci_show
from uplink_manager.domain.wifi import WifiNetwork


def parse_batch(batch: str) -> list[UciCmd]:
    """Inverse of UciCmd.render, enough for the commands the domain emits."""
    import shlex
    cmds = []
    for line in batch.splitlines():
        op, rest = line.split(' ', 1)
        if '=' in rest:
            path, raw = rest.split('=', 1)
            value = shlex.split(raw)[0] if raw else ''
        else:
            path, value = rest, None
        parts = path.split('.')
        cmds.append(UciCmd(op, parts[0], parts[1], parts[2] if len(parts) > 2 else None, value))
    return cmds


class FakeRouter(RouterGateway):
    def __init__(self, fixture: Path, networks: dict[str, str] | None = None,
                 settings: UplinkSettings = UplinkSettings()):
        self.snap = parse_uci_show(fixture.read_text())
        self.st = settings
        # SSID → the only key that associates ('' for open networks).
        self.networks = networks if networks is not None else {'Orange-Tekwill': '<REDACTED>'}
        self.backups: dict[str, object] = {}
        self.done: set[str] = set()
        self.log: list[str] = []
        self.pending = ''
        self.fail_apply = False

    def show(self, packages):
        snap = self.snap.copy()
        snap.packages = {k: v for k, v in snap.packages.items() if k in packages}
        return snap

    def pending_changes(self, packages):
        return self.pending

    def scan(self):
        return [WifiNetwork(s, '00:00:00:00:00:0%d' % i, 6, -60, 'psk2', 'WPA2 PSK', 'radio0')
                for i, s in enumerate(self.networks)]

    def runtime(self, iface):
        sta = uplink_sta(self.snap, self.st)
        rt = UplinkRuntime(iface)
        if sta is None or sta.get('disabled') == '1':
            return rt
        ssid, key = sta.get('ssid'), sta.get('key', '')
        if ssid not in self.networks or (self.networks[ssid] and self.networks[ssid] != key):
            return rt
        rt.ssid, rt.up, rt.ipv4, rt.device, rt.internet = ssid, True, '10.0.0.5', 'wlan0-3', True
        z = zone(self.snap, self.st.uplink_zone)
        rt.masquerade = bool(z and iface in z.words('network') and z.get('masq') == '1')
        return rt

    def begin(self, tx, packages, watchdog_s):
        self.backups[tx] = self.snap.copy()
        self.log.append(f'begin {tx}')

    def apply(self, tx, batch, packages):
        if self.fail_apply:
            raise RouterError('uci: Invalid argument')
        self.snap = self.snap.apply(parse_batch(batch))
        self.log.append(f'apply {tx} {",".join(packages)}')

    def confirm(self, tx):
        self.done.add(tx)
        self.log.append(f'confirm {tx}')

    def rollback(self, tx):
        if tx in self.done:
            return
        self.done.add(tx)
        self.snap = self.backups[tx]
        self.log.append(f'rollback {tx}')
