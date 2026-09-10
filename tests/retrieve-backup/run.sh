#!/usr/bin/env bash
#
# Tests of conf/retrieve-backup against a local Borg repository, without a YunoHost install.
# The `yunohost` CLI is replaced by tests/retrieve-backup/stubs/yunohost, which reproduces the
# archive discovery rules of YunoHost core (see the stub). Nothing is restored, and nothing is
# written outside of a temporary directory (plus the lock file in /run/lock).
#
# Requirements: borg (or BORG_BIN=/path/to/borg), python3 with PyYAML, jq, flock, numfmt, tar.
#
#   tests/retrieve-backup/run.sh

set -Eeuo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$here/../.." && pwd)
borg_bin=${BORG_BIN:-$(command -v borg || true)}
[[ -n "$borg_bin" ]] || { echo "borg not found: install it or set BORG_BIN" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

app="borg"
install_dir="$work/install"
archives="$work/archives"
export BORG_YNH_ARCHIVES_DIR="$archives"
export YNH_STUB_SETTINGS="$work/settings.json"
export PATH="$here/stubs:$PATH"
mkdir -p "$install_dir/venv/bin" "$archives"

#=================================================
# FIXTURES
#=================================================

# The script expects borg in the app's venv: wrap the real one, with fault injection for the tests
cat > "$install_dir/venv/bin/borg" << EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "export-tar" && -n "\${FAKE_BORG_FAIL_EXPORT:-}" ]]; then
    echo "partial content" > "\$3"
    echo "Simulated borg failure while exporting" >&2
    exit 2
fi
if [[ "\${1:-}" == "export-tar" && -n "\${FAKE_BORG_TRUNCATE_EXPORT:-}" ]]; then
    "$borg_bin" "\$@" || exit \$?
    truncate -s 1000 "\$3"
    exit 0
fi
exec "$borg_bin" "\$@"
EOF
chmod +x "$install_dir/venv/bin/borg"

cat > "$install_dir/.env" << EOF
BORG_PASSPHRASE='test passphrase'
BORG_REPO='$work/repo'
BORG_RELOCATED_REPO_ACCESS_IS_OK='yes'
BORG_RSH='ssh -i /nonexistent -oStrictHostKeyChecking=yes '
EOF
echo '{"server": ""}' > "$YNH_STUB_SETTINGS"

# Render the template the way ynh_config_add does
script="$work/retrieve-backup"
sed -e "s@__INSTALL_DIR__@$install_dir@g" -e "s@__APP__@$app@g" "$repo_root/conf/retrieve-backup" > "$script"
chmod +x "$script"

export BORG_PASSPHRASE='test passphrase' BORG_REPO="$work/repo"
# `borg create --timestamp` takes UTC while `borg list` displays local time: use UTC to keep the fixtures readable
export TZ=UTC
"$borg_bin" init -e repokey > /dev/null 2>&1

# A YunoHost backup of an app, as organized by YunoHost before the backup_method hook runs `borg create`
make_app_tree() {
    local dir="$1" ynh_app="$2" created_at="$3"
    mkdir -p "$dir/apps/$ynh_app/backup/var/www/$ynh_app" "$dir/apps/$ynh_app/settings/scripts" "$dir/hooks/restore"
    echo "content of $ynh_app at $created_at" > "$dir/apps/$ynh_app/backup/var/www/$ynh_app/index.html"
    printf '/var/www/%s,apps/%s/backup/var/www/%s\n' "$ynh_app" "$ynh_app" "$ynh_app" > "$dir/backup.csv"
    cat > "$dir/info.json" << EOF
{"description": "", "created_at": $created_at, "size": 1000, "apps": {"$ynh_app": {"version": "1.0~ynh1"}}, "system": {}, "from_yunohost_version": "12.1.40", "size_details": {"apps": {"$ynh_app": 1000}, "system": {}}}
EOF
}

make_system_tree() {
    local dir="$1" created_at="$2"
    mkdir -p "$dir/conf/ynh" "$dir/hooks/restore"
    echo "settings" > "$dir/conf/ynh/settings.yml"
    printf '/etc/yunohost/settings.yml,conf/ynh/settings.yml\n' > "$dir/backup.csv"
    cat > "$dir/info.json" << EOF
{"description": "", "created_at": $created_at, "size": 500, "apps": {}, "system": {"conf_ynh_settings": {"paths": ["/etc/yunohost/settings.yml"]}}, "from_yunohost_version": "12.1.40", "size_details": {"apps": {}, "system": {"conf_ynh_settings": 500}}}
EOF
}

create_archive() {
    local name="$1" time="$2" dir="$3"
    (cd "$dir" && "$borg_bin" create --timestamp "$time" "::$name" .)
}

make_app_tree "$work/hextris1" hextris 1756695600
create_archive "auto_hextris-2026-09-01T03:00:00" "2026-09-01T03:00:00" "$work/hextris1"
make_app_tree "$work/hextris2" hextris 1756782000
create_archive "auto_hextris-2026-09-02T03:00:00" "2026-09-02T03:00:00" "$work/hextris2"
make_app_tree "$work/wordpress" wordpress 1756782060
create_archive "auto_wordpress-2026-09-02T03:01:00" "2026-09-02T03:01:00" "$work/wordpress"
make_system_tree "$work/conf" 1756782300
create_archive "auto_conf-2026-09-02T03:05:00" "2026-09-02T03:05:00" "$work/conf"
make_app_tree "$work/manual" hextris 1754035200
create_archive "before_upgrade-2026-08-01T10:00:00" "2026-08-01T10:00:00" "$work/manual"
make_app_tree "$work/weird" hextris 1756868523
create_archive "weird name+with@chars-2026-09-03T01:02:03" "2026-09-03T01:02:03" "$work/weird"
long_name="auto_$(printf 'a%.0s' {1..40})-2026-09-03T01:02:03"
create_archive "$long_name" "2026-09-03T01:02:03" "$work/weird"
mkdir -p "$work/not_ynh/some/files" && echo "x" > "$work/not_ynh/some/files/f"
create_archive "not_yunohost-2026-09-02T04:00:00" "2026-09-02T04:00:00" "$work/not_ynh"

#=================================================
# TEST HELPERS
#=================================================

failures=0
pass() { echo "  ok   - $*"; }
fail() { echo "  FAIL - $*" >&2; failures=$((failures + 1)); }
check() {
    local description="$1"
    shift
    if "$@"; then pass "$description"; else fail "$description"; fi
}
no_leftovers() { [[ -z "$(find "$archives" -mindepth 1 -maxdepth 1 -name '.retrieve-*')" ]]; }
absent() { local f; for f in "$@"; do [[ ! -e "$f" && ! -L "$f" ]] || return 1; done; }
local_backups() { yunohost backup list --output-as json | jq -r '.archives[]'; }

# Runs the script, storing its exit code in $rc, stdout in $out and stderr in $err
run_script() {
    rc=0
    out=$("$script" "$@" 2> "$work/stderr") || rc=$?
    err=$(cat "$work/stderr")
}

#=================================================
# LISTING
#=================================================
echo "# Listing archives"

run_script list
check "list exits 0" test "$rc" -eq 0
check "list returns 8 archives as JSON" test "$(jq '.archives | length' <<< "$out")" -eq 8

#=================================================
# RETRIEVAL
#=================================================
echo "# Retrieving an app backup"

archive="auto_hextris-2026-09-02T03:00:00"
local_name="auto_hextris-2026-09-02T03-00-00"
run_script retrieve "$archive"
check "retrieve exits 0" test "$rc" -eq 0
check "retrieve prints the local name" grep -q "Backup '$local_name' is now available" <<< "$out"
check "the tar is in the archives directory" test -f "$archives/$local_name.tar"
check "the info.json sidecar is next to it" test -f "$archives/$local_name.info.json"
check "no temporary directory is left" no_leftovers
check "yunohost backup list shows the backup" grep -qx "$local_name" <(local_backups)
check "yunohost backup info reads it" test "$(yunohost backup info "$local_name" --output-as json | jq '.created_at')" -eq 1756782000
check "the tar has the YunoHost layout" bash -c "tar -tf '$archives/$local_name.tar' | grep -qx 'info.json' && tar -tf '$archives/$local_name.tar' | grep -qx 'backup.csv' && tar -tf '$archives/$local_name.tar' | grep -qx 'apps/hextris/backup/var/www/hextris/index.html'"
check "the sidecar matches the info.json inside the tar" test "$(tar -xOf "$archives/$local_name.tar" info.json | jq -S .)" == "$(jq -S . "$archives/$local_name.info.json")"

echo "# Retrieving a system backup"
run_script retrieve "auto_conf-2026-09-02T03:05:00"
check "retrieve exits 0" test "$rc" -eq 0
check "yunohost backup list shows it" grep -qx "auto_conf-2026-09-02T03-05-00" <(local_backups)

echo "# Duplicate local name"
checksum_before=$(sha256sum "$archives/$local_name.tar")
run_script retrieve "$archive"
check "retrieve fails" test "$rc" -ne 0
check "the error explains the name already exists" grep -q "already exists" <<< "$err"
check "the existing backup is untouched" test "$checksum_before" == "$(sha256sum "$archives/$local_name.tar")"
check "no temporary directory is left" no_leftovers

echo "# Local name sanitization"
run_script retrieve "weird name+with@chars-2026-09-03T01:02:03"
check "retrieve exits 0" test "$rc" -eq 0
check "unsupported characters are replaced" test -f "$archives/weird_name_with_chars-2026-09-03T01-02-03.tar"
run_script retrieve "$long_name"
check "retrieve exits 0" test "$rc" -eq 0
check "the local name is truncated to 50 characters" test -f "$archives/auto_$(printf 'a%.0s' {1..40})-2026.tar"

#=================================================
# FAILURES MUST NOT LEAVE A BROKEN LOCAL BACKUP
#=================================================
echo "# Archive that is not a YunoHost backup"
run_script retrieve "not_yunohost-2026-09-02T04:00:00"
check "retrieve fails" test "$rc" -ne 0
check "the error says it is not a YunoHost backup" grep -q "not a YunoHost backup" <<< "$err"
check "nothing is left in the archives directory" absent "$archives/not_yunohost-2026-09-02T04-00-00.tar" "$archives/not_yunohost-2026-09-02T04-00-00.info.json"
check "no temporary directory is left" no_leftovers

echo "# Unknown archive"
run_script retrieve "auto_nope-2026-09-02T04:00:00"
check "retrieve fails" test "$rc" -ne 0
check "borg's error is shown" grep -q "does not exist" <<< "$err"
check "nothing is left" absent "$archives/auto_nope-2026-09-02T04-00-00.tar" "$archives/auto_nope-2026-09-02T04-00-00.info.json"
check "no temporary directory is left" no_leftovers

echo "# Borg fails during the export"
FAKE_BORG_FAIL_EXPORT=1 run_script retrieve "auto_hextris-2026-09-01T03:00:00"
check "retrieve fails" test "$rc" -ne 0
check "borg's error is shown" grep -q "Simulated borg failure" <<< "$err"
check "nothing is left" absent "$archives/auto_hextris-2026-09-01T03-00-00.tar" "$archives/auto_hextris-2026-09-01T03-00-00.info.json"
check "no temporary directory is left" no_leftovers

echo "# Truncated export"
FAKE_BORG_TRUNCATE_EXPORT=1 run_script retrieve "auto_hextris-2026-09-01T03:00:00"
check "retrieve fails" test "$rc" -ne 0
check "the error says the archive is incomplete" grep -q "unreadable or incomplete" <<< "$err"
check "nothing is left" absent "$archives/auto_hextris-2026-09-01T03-00-00.tar" "$archives/auto_hextris-2026-09-01T03-00-00.info.json"
check "no temporary directory is left" no_leftovers

echo "# YunoHost does not recognize the result"
YNH_STUB_FAIL_INFO=1 run_script retrieve "auto_hextris-2026-09-01T03:00:00"
check "retrieve fails" test "$rc" -ne 0
check "the error says YunoHost does not recognize it" grep -q "does not recognize" <<< "$err"
check "the tar and sidecar have been removed" absent "$archives/auto_hextris-2026-09-01T03-00-00.tar" "$archives/auto_hextris-2026-09-01T03-00-00.info.json"
check "no temporary directory is left" no_leftovers

echo "# Not enough free space"
mkdir -p "$work/dfstub"
printf '#!/usr/bin/env bash\necho "Filesystem 1-blocks Used Available Capacity Mounted on"\necho "fake 100 90 10 90%% /"\n' > "$work/dfstub/df"
chmod +x "$work/dfstub/df"
PATH="$work/dfstub:$PATH" run_script retrieve "auto_hextris-2026-09-01T03:00:00"
check "retrieve fails" test "$rc" -ne 0
check "the error mentions free space" grep -q "Not enough free space" <<< "$err"
check "nothing is left" absent "$archives/auto_hextris-2026-09-01T03-00-00.tar"
check "no temporary directory is left" no_leftovers

echo "# Concurrent retrievals"
# Hold the lock for a while from another process (killing it early would leave the lock to its sleep child)
flock "/run/lock/borg-ynh-retrieve-backup.lock" sleep 2 &
locker=$!
sleep 0.5
run_script retrieve "auto_hextris-2026-09-01T03:00:00"
check "the second retrieval fails fast" test "$rc" -ne 0
check "the error says a retrieval is in progress" grep -q "already in progress" <<< "$err"
wait "$locker"

echo "# Leftovers of a killed retrieval are cleaned up"
mkdir -p "$archives/.retrieve-stale"
echo "junk" > "$archives/.retrieve-stale/old.tar"
run_script retrieve "auto_hextris-2026-09-01T03:00:00"
check "retrieve exits 0" test "$rc" -eq 0
check "the stale temporary directory is gone" absent "$archives/.retrieve-stale"
check "no temporary directory is left" no_leftovers

echo "# Interrupted retrieval"
"$script" retrieve "auto_wordpress-2026-09-02T03:01:00" > /dev/null 2>&1 &
script_pid=$!
# Give it time to create its temporary directory, then interrupt it like Ctrl+C would
sleep 1
kill -INT "$script_pid" 2> /dev/null || true
wait "$script_pid" 2> /dev/null || true
check "no temporary directory is left after an interruption" no_leftovers
# Depending on timing the retrieval may have completed before the signal: then it must be complete, otherwise absent
interrupted_ok() {
    if grep -qx "auto_wordpress-2026-09-02T03-01-00" <(local_backups); then
        test -f "$archives/auto_wordpress-2026-09-02T03-01-00.info.json"
    else
        absent "$archives/auto_wordpress-2026-09-02T03-01-00.info.json"
    fi
}
check "either a complete backup or nothing is left after an interruption" interrupted_ok

#=================================================
# RESULT
#=================================================
echo
echo "Local backups now known to YunoHost:"
local_backups | sed 's/^/  /'
echo
if (( failures > 0 )); then
    echo "$failures check(s) FAILED" >&2
    exit 1
fi
echo "All checks passed"
