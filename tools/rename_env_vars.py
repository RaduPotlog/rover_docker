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
"""Rename the rover's deployment variables in a source tree, from tools/env_renames.yaml.

    rename_env_vars.py <dir>...           # rewrite old names in place, print what changed
    rename_env_vars.py --check <dir>...   # list old names still present; exit 1 if any

Only whole names are replaced (ROVER_DRIVE_PORT, never the ROVER_DRIVE_MODE_..._HPP_ include
guards), in text files outside build/, install/, log/, .git/ and node_modules/; C/C++ sources
are skipped (their ROVER_* tokens are include guards and macros). A name that splits into
several (ROVER_ZENOH_MODE) is only reported: each container reads its own, so it is a hand edit.
--check also reports wildcard / brace forms of old prefixes (ROVER_LIDAR_*,
ROVER_AMCL_INITIAL_POSE_{X,Y,YAW}), which no whole-name replace can reach.

Lines between a line containing "env-renames:begin" and one containing "env-renames:end" are
left alone and not reported: that is where the old names are meant to stay (README migration
table, balena_env.py migrate tests). env_renames.yaml and this script are skipped altogether.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

import yaml

MAP_FILE = Path(__file__).with_name('env_renames.yaml')
SKIP_DIRS = {'build', 'install', 'log', '.git', 'node_modules', 'dist', '__pycache__'}
SKIP_SUFFIXES = {'.hpp', '.cpp', '.h', '.hh', '.cc', '.png', '.jpg', '.jpeg', '.gif', '.ico',
                 '.pdf', '.stl', '.dae', '.slx', '.mat', '.mldatx', '.sldprt', '.sldasm',
                 '.zip', '.gz', '.onnx', '.db3', '.mcap', '.pgm', '.woff', '.woff2', '.ttf'}
# The map and this script must keep the old names.
SKIP_FILES = {MAP_FILE.resolve(), Path(__file__).resolve()}
BEGIN, END = 'env-renames:begin', 'env-renames:end'

# Old prefixes written as a wildcard or brace list: ROVER_DRIVE_*, ROVER_{GPS,IMU}_*,
# ROVER_AMCL_INITIAL_POSE_{X,Y,YAW}, ROVER_FOXGLOVE_*_WHITELIST.
OLD_PATTERN_RE = re.compile(
    r'(?<![A-Za-z0-9_])ROVER_('
    r'(DRIVE|LIDAR|IMU|GPS|CAMERA|AMCL_INITIAL_POSE|FOXGLOVE|START|NAV|USE)_[*{]'
    r'|\{(GPS|IMU|LIDAR|CAMERA)'
    r'|(GPS|IMU|LIDAR|CAMERA)_(LOCALIZATION|ORIENTATION)_?(\*|\{|`|\b(?!_))'
    r')')


def load_renames(path: Path = MAP_FILE) -> dict[str, str | list[str]]:
    return yaml.safe_load(path.read_text())['renames']


def name_re(names: list[str]) -> re.Pattern:
    alternatives = '|'.join(sorted(map(re.escape, names), key=len, reverse=True))
    return re.compile(rf'(?<![A-Za-z0-9_])({alternatives})(?![A-Za-z0-9_])')


def text_files(roots: list[Path]):
    for root in roots:
        if root.is_file():
            yield root, root.read_text(encoding='utf-8')
            continue
        for path in sorted(root.rglob('*')):
            if any(part in SKIP_DIRS for part in path.relative_to(root).parts):
                continue
            if not path.is_file() or path.is_symlink():
                continue
            if path.suffix.lower() in SKIP_SUFFIXES or path.resolve() in SKIP_FILES:
                continue
            try:
                text = path.read_text(encoding='utf-8')
            except (UnicodeDecodeError, OSError):
                continue
            yield path, text


def protected_lines(lines: list[str]) -> set[int]:
    protected, inside = set(), False
    for i, line in enumerate(lines):
        if BEGIN in line:
            inside = True
        if inside:
            protected.add(i)
        if END in line:
            inside = False
    return protected


def process(path: Path, text: str, renames: dict, check: bool) -> list[str]:
    """Return report lines; rewrite the file unless check."""
    simple = {old: new for old, new in renames.items() if isinstance(new, str)}
    split = [old for old, new in renames.items() if not isinstance(new, str)]
    simple_re, split_re = name_re(list(simple)), name_re(split)

    lines = text.splitlines(keepends=True)
    skip = protected_lines(lines)
    report, changed = [], False
    for i, line in enumerate(lines):
        if i in skip:
            continue
        where = f'{path}:{i + 1}'
        for m in split_re.finditer(line):
            report.append(f'{where}: {m.group(1)} (split, edit by hand)')
        if check:
            report.extend(f'{where}: {m.group(1)}' for m in simple_re.finditer(line))
        else:
            new_line = simple_re.sub(lambda m: simple[m.group(1)], line)
            if new_line != line:
                lines[i], changed = new_line, True
        report.extend(f'{where}: {m.group(0)}... (wildcard/brace form, edit by hand)'
                      for m in OLD_PATTERN_RE.finditer(lines[i]))
    if changed:
        path.write_text(''.join(lines), encoding='utf-8')
        report.insert(0, f'{path}: rewritten')
    return report


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--check', action='store_true', help='report only, change nothing')
    parser.add_argument('--map', type=Path, default=MAP_FILE, help='rename map (YAML)')
    parser.add_argument('roots', nargs='+', type=Path)
    args = parser.parse_args(argv)

    renames = load_renames(args.map)
    leftovers = 0
    for path, text in text_files(args.roots):
        for line in process(path, text, renames, args.check):
            print(line)
            leftovers += not line.endswith(': rewritten')
    if args.check:
        print(f'{leftovers} old name(s) left' if leftovers else 'no old names left')
    return 1 if args.check and leftovers else 0


if __name__ == '__main__':
    sys.exit(main())
