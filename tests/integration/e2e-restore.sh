#!/usr/bin/env bash
#
# End-to-end test of the "Retrieve backup" feature, to run as root on a DISPOSABLE YunoHost server
# (a fresh VM). It installs apps, creates Borg backups, removes an app and restores it from a retrieved
# backup: never run it on a server you care about.
#
# Environment variables:
#   BORG_YNH_SOURCE   What to install borg from: a local checkout or a git URL (default: this checkout)
#   TEST_APP          App to back up, remove and restore (default: hextris, small and self-contained)
#   TEST_DOMAIN       Domain to install TEST_APP on (default: the main domain)
#   BORG_TEST_REPO    Local Borg repository directory (default: /home/yunohost.app/borg-e2e-repo)
#
#   sudo tests/integration/e2e-restore.sh

set -Eeuo pipefail

[[ $EUID -eq 0 ]] || { echo "Run this script as root" >&2; exit 1; }
[[ -f /etc/yunohost/installed ]] || { echo "YunoHost is not post-installed" >&2; exit 1; }

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
source=${BORG_YNH_SOURCE:-$here}
test_app=${TEST_APP:-hextris}
domain=${TEST_DOMAIN:-$(yunohost domain main-domain --output-as json | jq -r '.current_main_domain')}
repo=${BORG_TEST_REPO:-/home/yunohost.app/borg-e2e-repo}
borg_app="borg"
marker="borg_ynh e2e marker $(date +%s)"

step() { echo; echo "==> $*"; }
die() { echo "FAILED: $*" >&2; exit 1; }
installed() { yunohost app list --output-as json | jq -e --arg id "$1" '.apps[] | select(.id == $id)' > /dev/null; }

step "Installing borg from $source (local repository $repo)"
if ! installed "$borg_app"; then
    yunohost app install "$source" --force \
        --args "repository=$repo&passphrase=e2e-passphrase&conf=1&data=0&apps=all&on_calendar=Daily&mailalert=never"
fi
borg_install_dir=$(yunohost app setting "$borg_app" install_dir)
retrieve_backup="$borg_install_dir/retrieve-backup"
[[ -x "$retrieve_backup" ]] || die "$retrieve_backup is missing"

step "Installing $test_app and writing identifiable data"
if ! installed "$test_app"; then
    yunohost app install "$test_app" --force --args "domain=$domain&path=/$test_app&init_main_permission=visitors"
fi
app_install_dir=$(yunohost app setting "$test_app" install_dir)
echo "$marker" > "$app_install_dir/e2e-marker.txt"

step "Running the Borg backup (systemd service)"
systemctl start "$borg_app.service"
state=$(yunohost app setting "$borg_app" state)
[[ "$state" == "successful" ]] || die "backup state is '$state' (see /var/log/$borg_app/)"

step "Listing the archives"
archives_json=$("$retrieve_backup" list)
archive=$(jq -r --arg prefix "auto_${test_app}-" '.archives | map(select(.name | startswith($prefix))) | sort_by(.time) | last | .name' <<< "$archives_json")
[[ -n "$archive" && "$archive" != "null" ]] || die "no archive of $test_app found in $(jq -c '.archives[].name' <<< "$archives_json")"
echo "Archive of $test_app: $archive"
"$retrieve_backup" choices - <<< "$archives_json" | grep -F "$archive" > /dev/null || die "the archive is missing from the config panel choices"

step "Simulating data loss"
rm -f "$app_install_dir/e2e-marker.txt"

step "Retrieving the archive through the config panel action"
yunohost app action run "$borg_app" restore.retrieve.retrieve_backup --args "restore_archive=$archive"
local_name=${archive//:/-}
yunohost backup list --output-as json | jq -e --arg name "$local_name" '.archives | index($name)' > /dev/null \
    || die "$local_name is not listed by 'yunohost backup list'"
yunohost backup info "$local_name" --with-details --output-as json | jq -e --arg app "$test_app" '.apps[$app]' > /dev/null \
    || die "'yunohost backup info $local_name' does not list $test_app"
echo "Local backup: $local_name"

step "Retrieving it again must fail without touching the existing local backup"
checksum=$(sha256sum "/home/yunohost.backup/archives/$local_name.tar")
if yunohost app action run "$borg_app" restore.retrieve.retrieve_backup --args "restore_archive=$archive"; then
    die "the duplicate retrieval should have failed"
fi
[[ "$checksum" == "$(sha256sum "/home/yunohost.backup/archives/$local_name.tar")" ]] || die "the existing local backup was modified"

step "Retrieving the system configuration archive from the command line"
conf_archive=$(jq -r '.archives | map(select(.name | startswith("auto_conf-"))) | sort_by(.time) | last | .name' <<< "$archives_json")
[[ -n "$conf_archive" && "$conf_archive" != "null" ]] || die "no auto_conf archive found"
"$retrieve_backup" retrieve "$conf_archive"
yunohost backup info "${conf_archive//:/-}" --with-details --output-as json | jq -e '.system | length > 0' > /dev/null \
    || die "'yunohost backup info' does not list system parts for ${conf_archive//:/-}"

step "Restoring $test_app from the retrieved backup (the app is removed first, as YunoHost requires)"
yunohost app remove "$test_app"
yunohost backup restore "$local_name" --apps "$test_app"
installed "$test_app" || die "$test_app is not installed after the restore"
restored=$(cat "$app_install_dir/e2e-marker.txt" 2> /dev/null || true)
[[ "$restored" == "$marker" ]] || die "the marker file was not restored (got '$restored')"

step "SUCCESS"
echo "Retrieved backups left in /home/yunohost.backup/archives/: $local_name, ${conf_archive//:/-}"
echo "Clean up with: yunohost backup delete $local_name; yunohost backup delete ${conf_archive//:/-}"
