## Reminder regarding the passphrase

The passphrase is the only way to decrypt your backups. You should make sure to keep it safe in some place "outside" your server to cover the scenario where your server is destroyed for some reason.

## Testing that backup work as expected

At this step your backup should run at the scheduled time. Note that the first backup can take very long, as much data has to be copied through ssh. Following backups are incremental: only newly generated data since last backup will be copied.

If you want to test correct Borg Apps setup before scheduled time, you can start a backup manually from the command line:

```bash
systemctl start borg
```

Once the backup completes, you can check that a backup is listed in `Web Admin > Applications > Borg > Restore backups`, under *All archives in the repository*.

If you have a shell session, you will find more details on borg execution logs in `/var/log/borg/borg.log`

## Manually running `borg` commands

The config panel's *Restore backups* tab lists the recently created backup archives, under *All archives in the repository*.

However, you may want to manually inspect that the backups are indeed made regularly and contain the expected content.

First, open a shell session logged in as "borg":

```bash
yunohost app shell borg # Or borg__2, borg__3, ... check your borg client app ids using `yunohost app list`
```

Then run for example:

- List archives: `borg list | less`
- List files from a specific archive: `borg list "::ARCHIVE_NAME" | less`
- View archive info: `borg info "::ARCHIVE_NAME"`
- Verify data integrity: `borg check "::ARCHIVE_NAME" --verify-data`

## Restoring archives from Borg

Restoring happens in two steps: a Borg archive is first *retrieved*, that is copied to the local backups of YunoHost (`/home/yunohost.backup/archives/`), then it is restored with the classic YunoHost backup restore workflow. Nothing is restored during the retrieval, and existing local backups are never overwritten.

### From the webadmin

In `Web Admin > Applications > Borg > Restore backups`, choose the components and the dates you want, then click *Retrieve backups*. Every archive matching that combination is retrieved. All components start selected, so choosing a single date retrieves that whole night; remove the ones you don't need to narrow it down. Once done, the backups are listed in `Web Admin > Backups > Local storage`, where you restore them as usual.

Note that the dates come from the archive names, which carry the local time of the server that made the backup. That is the same string you see in the archive list, but it can differ from UTC.

### From the command line

As root (replace `BORG_APP` by `borg`, or `borg__2`, `borg__3`, ...):

```bash
# List the archives of the repository (JSON)
/var/www/BORG_APP/retrieve-backup list
# Retrieve one of them
/var/www/BORG_APP/retrieve-backup retrieve ARCHIVE_NAME
```

The same action is available through the config panel API, which is handy for scripting:

```bash
yunohost app action run BORG_APP restore.retrieve.retrieve_backup \
    --args "restore_components=nextcloud,conf&restore_dates=2026-09-08"
```

The local backup gets the name of the Borg archive, except that the characters YunoHost does not accept in backup names are replaced (typically the colons of the timestamp: `auto_nextcloud-2026-09-08T03:17:00` becomes `auto_nextcloud-2026-09-08T03-17-00`). Then restore using the classic workflow:
- from the command line: `yunohost backup restore LOCAL_NAME`
- or in the webadmin > Backups

Alternatively, the export can still be done by hand with `borg export-tar` (which is what the retrieval does, along with a few checks):

```bash
/var/www/BORG_APP/wrapper/borg export-tar "::ARCHIVE_NAME" /home/yunohost.backup/archives/LOCAL_NAME.tar
```

### Restoring the "source+config" of the app, and its data separately

For apps containing a large amount of data, restoring *everything* all at once is not practical because of the space and time it will take. Instead you may want to first restore the "core" (the source, configuration, etc) of the app, - and *then* the data.

First, borg can export a .tar archive but ignore the path corresponding to the app's data. For example, to export a tar archive for Nextcloud, but without its data:

```bash
/var/www/BORG_APP/wrapper/borg export-tar --exclude apps/nextcloud/backup/home/yunohost.app "::ARCHIVE_NAME" /home/yunohost.backup/archives/ARCHIVE_NAME.tar
```

Then extract Nextcloud's data directly into the right location, **without** going through the classic YunoHost backup restore process:

```bash
cd /home/yunohost.app/
/var/www/BORG_APP/wrapper/borg extract "$repository::ARCHIVE_NAME" apps/nextcloud/backup/home/yunohost.app/
mv apps/nextcloud/backup/home/yunohost.app/nextcloud ./
rm -r apps
```

## Excluding folders from backups

You may exclude a folder and its subfolders from being backed up by adding an empty file named `.nobackup` in it.
For example (replace `/PATH/TO/FOLDER-TO-EXCLUDE` with the actual path):
```bash
touch /PATH/TO/FOLDER-TO-EXCLUDE/.nobackup
```

## Support for remote-path (custom borg executable on remote server)

In particular cases, one may need to specify a custom borg executable to be run on the remote server (borg supports this through the `--remote-path` commandline option / `BORG_REMOTE_PATH` env variable - see <https://borgbackup.readthedocs.io/en/stable/usage/general.html>).

If needed, the path to the borg executable can be configured by setting its value in the optional *Remote borg command (remote-path)* entry of the configuration panel.
