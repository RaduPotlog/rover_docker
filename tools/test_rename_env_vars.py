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
"""Unit tests of rename_env_vars.py."""

# env-renames:begin - this file feeds the old names on purpose.

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import rename_env_vars as rn  # noqa: E402


def run(tmp_path, name, text, *flags):
    path = tmp_path / name
    path.write_text(text)
    code = rn.main([*flags, str(tmp_path)])
    return code, path.read_text()


def test_whole_names_only(tmp_path):
    text = ('export ROVER_DRIVE_PORT=5000 ${ROVER_START_DRIVE_MODE:-true}\n'
            '#ifndef ROVER_DRIVE_MODE_DOMAIN_DRIVE_MODE_HPP_\n'
            'ROVER_DRIVE_PORTS ROVER_NAVIGATION_X ROVER_GPS_INFRASTRUCTURE\n')
    code, out = run(tmp_path, 'a.sh', text)
    assert code == 0
    assert out == ('export ROVER_UI_PORT=5000 ${ROVER_ORCH_DRIVE_MODE:-true}\n'
                   '#ifndef ROVER_DRIVE_MODE_DOMAIN_DRIVE_MODE_HPP_\n'
                   'ROVER_DRIVE_PORTS ROVER_NAVIGATION_X ROVER_GPS_INFRASTRUCTURE\n')


def test_split_names_wildcards_and_markers_are_left_alone(tmp_path):
    text = ('mode=$ROVER_ZENOH_MODE\n'
            'see ROVER_LIDAR_* and ROVER_AMCL_INITIAL_POSE_{X,Y,YAW}\n'
            f'<!-- {rn.BEGIN} -->\n'
            '| ROVER_NAV_MAP | ROVER_ORCH_NAV_MAP |\n'
            f'<!-- {rn.END} -->\n')
    code, out = run(tmp_path, 'README.md', text)
    assert code == 0 and out == text


def test_cpp_sources_are_skipped(tmp_path):
    text = 'std::getenv("ROVER_NAMESPACE");\n'
    _, out = run(tmp_path, 'node.cpp', text)
    assert out == text


def test_check_reports_and_fails(tmp_path, capsys):
    code, out = run(tmp_path, 'launch.py', 'EnvironmentVariable("ROVER_USE_GPS")\n'
                    'mode=$ROVER_ZENOH_MODE ROVER_IMU_*\n', '--check')
    assert code == 1
    assert out.startswith('EnvironmentVariable("ROVER_USE_GPS")')  # unchanged
    report = capsys.readouterr().out
    assert 'ROVER_USE_GPS' in report and 'split' in report and 'wildcard' in report


def test_check_passes_on_new_names(tmp_path):
    code, _ = run(tmp_path, 'a.sh', 'ROVER_SYSTEM_USE_GPS ROVER_ZENOH_MODE_ORCH ROVER_UI_*\n',
                  '--check')
    assert code == 0

# env-renames:end
