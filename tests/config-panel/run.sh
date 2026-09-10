#!/usr/bin/env bash
#
# Tests for the archive-to-options logic embedded in scripts/config, which drives the
# "Restore backups" panel. The python program is extracted from the config script and run
# against a fixture, so no Borg repository, no network and no YunoHost install are needed.
#
# Requirements: python3 with PyYAML.
#
#   tests/config-panel/run.sh

set -Eeuo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$here/../.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Pull the embedded program out of scripts/config so the tests exercise the shipped code
awk '/^read -r -d .* _archive_py/ { found = 1; next } found && /^PYEOF$/ { exit } found' \
    "$repo_root/scripts/config" > "$work/archive.py"
[[ -s "$work/archive.py" ]] || { echo "could not extract _archive_py from scripts/config" >&2; exit 1; }

# A repository as borg would report it. Note auto_rspamd-2026-09-07T21:55:00: its name says the 7th
# while borg renders `time` on the 8th, because the producing server runs behind UTC. That skew is
# what a naive implementation gets wrong, so it is baked into the fixture.
cat > "$work/archives.json" << 'EOF'
{
  "archives": [
    {"name": "auto_conf-2026-09-07T13:11:49",   "time": "2026-09-07T20:11:53.000000"},
    {"name": "auto_conf-2026-09-08T00:00:19",   "time": "2026-09-08T07:00:23.000000"},
    {"name": "auto_data-2026-09-08T00:00:54",   "time": "2026-09-08T07:00:57.000000"},
    {"name": "auto_rspamd-2026-09-07T21:55:00", "time": "2026-09-08T04:55:04.000000"},
    {"name": "auto_rspamd-2026-09-08T00:13:04", "time": "2026-09-08T07:13:08.000000"},
    {"name": "auto_nextcloud-2026-09-08T00:08:56", "time": "2026-09-08T07:09:00.000000"},
    {"name": "before_upgrade-2026-09-06T10:00:00", "time": "2026-09-06T17:00:04.000000"}
  ]
}
EOF

failures=0
pass() { echo "  ok   - $*"; }
fail() { echo "  FAIL - $*" >&2; failures=$((failures + 1)); }

run_mode() { python3 "$work/archive.py" "$1" < "$work/archives.json"; }

echo "# Component selector"
if python3 - "$(run_mode components)" << 'EOF' 
import sys, yaml
d = yaml.safe_load(sys.argv[1])
choices, value = d["choices"], d["value"]
# system parts first, then apps alphabetically, then anything not named auto_*
assert choices == ["conf", "data", "nextcloud", "rspamd", "before_upgrade"], choices
assert value.split(",") == choices, "every component must start selected: " + value
EOF
then pass "all components preselected, system parts first"; else fail "components mode"; fi

echo "# Date selector"
if python3 - "$(run_mode dates)" << 'EOF' 
import sys, yaml
d = yaml.safe_load(sys.argv[1])
assert d["choices"] == ["2026-09-08", "2026-09-07", "2026-09-06"], d["choices"]
assert d["value"] == "", d["value"]
EOF
then pass "dates come from archive names, newest first, none preselected"; else fail "dates mode"; fi

echo "# Resolution of components x dates"
resolve() { SELECTED_COMPONENTS="$1" SELECTED_DATES="$2" python3 "$work/archive.py" resolve < "$work/archives.json"; }

expect_eq() {
    local description="$1" got="$2" want="$3"
    if [[ "$got" == "$want" ]]; then pass "$description"; else fail "$description (got: ${got:-<empty>})"; fi
}

expect_eq "a date matches the name, not borg's UTC time field (regression)" \
    "$(resolve rspamd 2026-09-08)" "auto_rspamd-2026-09-08T00:13:04"

expect_eq "the UTC-skewed archive is reachable under the date in its name" \
    "$(resolve rspamd 2026-09-07)" "auto_rspamd-2026-09-07T21:55:00"

expect_eq "several components for one date, system parts in order" \
    "$(resolve conf,data 2026-09-08 | tr '\n' ' ')" \
    "auto_conf-2026-09-08T00:00:19 auto_data-2026-09-08T00:00:54 "

expect_eq "several dates for one component" "$(resolve conf 2026-09-07,2026-09-08 | wc -l)" "2"

expect_eq "a combination with no archive resolves to nothing" "$(resolve nextcloud 2026-09-06)" ""

expect_eq "no component selected resolves to nothing" "$(resolve '' 2026-09-08)" ""

expect_eq "no date selected resolves to nothing" "$(resolve conf '')" ""

echo "# Empty repository"
echo '{"archives": []}' > "$work/archives.json"
if python3 - "$(run_mode components)" "$(run_mode dates)" << 'EOF' 
import sys, yaml
comp, dates = yaml.safe_load(sys.argv[1]), yaml.safe_load(sys.argv[2])
assert comp == {"value": "", "choices": []}, comp
assert dates == {"value": "", "choices": []}, dates
EOF
then pass "an empty repository yields empty selectors, not an error"; else fail "empty repository"; fi

echo
if (( failures > 0 )); then
    echo "$failures check(s) FAILED" >&2
    exit 1
fi
echo "All checks passed"
