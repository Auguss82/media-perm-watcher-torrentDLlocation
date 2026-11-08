# media-perm-watcher

A Bash script that watches your media and download folders with `inotify` and automatically fixes **permissions and ownership** on files and directories as they appear. It is built for setups where tools like qBittorrent, rsync and Plex all touch the same folders and leave files with the wrong owner or mode, so Plex (or another service) can't read, move or delete them.

The script is called `watchplex.sh` and is meant to run as a systemd service.

## What it does

- Watches one or more base directories **recursively**, each with its own settings: directory mode, file mode, owner and group.
- Reacts to three kinds of events:
  - `close_write`: a file finishes being written (rsync, incremental copies)
  - `create`: a new file or directory appears by any method
  - `moved_to`: a file or directory is moved in atomically, as when qBittorrent moves a finished download to a category save path
- Runs a **full sweep at startup**, so anything missed while the service was down gets fixed.
- Skips temporary files, so it doesn't fight with tools that are still writing them.
- Retries failed fixes, restarts `inotifywait` if it dies, and refuses to start a second copy of itself.
- Logs to a rotating log file (and to standard output when run by hand), with four verbosity levels.

`attrib` events are deliberately **not** watched. Running `chmod` and `chown` triggers `attrib`, which would cause an endless loop.

## Requirements

- Linux with `inotify`
- Bash 4 or newer (the script uses associative arrays)
- `inotify-tools` (provides `inotifywait`)
- `find`, `chmod`, `chown` from coreutils/findutils
- Must run as **root** (or as a user allowed to `chown` the watched trees)

```
# Debian / Ubuntu
sudo apt install inotify-tools
```

## Installation

```
git clone https://github.com/Auguss82/media-perm-watcher-torrentDLlocation.git
cd media-perm-watcher-torrentDLlocation

sudo mkdir -p /opt/scripts/watchplex
sudo cp watchplex.sh /opt/scripts/watchplex/
sudo chmod +x /opt/scripts/watchplex/watchplex.sh
```

Create the lock file's directory (`/opt/scripts/watchplex` above) before the first run. The log directory is created automatically.

Edit the configuration block at the top of the script before starting it (see below), in particular `WATCH_CONFIG`.

## Configuration

Everything is set in variables at the top of `watchplex.sh`.

### Watched directories

```bash
declare -A WATCH_CONFIG
WATCH_CONFIG=(
    ["/dvr/qb"]="775:664:auguss82:auguss82"
    ["/dvr/plex"]="777:666:auguss82:auguss82"
)
```

Each entry is `"/base/directory" = "dir_perms:file_perms:owner:group"`. The example above sets directories to `775` and files to `664` under `/dvr/qb`, and `777`/`666` under `/dvr/plex`, both owned by `auguss82:auguss82`. **Change these to your own paths and user.** Every directory listed must exist, or the script refuses to start.

### Settings

| Variable | Default | Description |
|---|---|---|
| `LOGGING` | `true` | Master switch for writing the log file |
| `DRY_RUN` | `false` | Print what would be done without running `chmod` or `chown` |
| `LOG_LEVEL` | `INFO` | `ERROR`, `INFO`, `VERBOSE` or `DEBUG` (see below) |
| `LOG_DIR` | `/var/log/watchplex` | Log directory |
| `LOG_FILE` | `${LOG_DIR}/watchplex.log` | Log file |
| `LOG_MAX_BYTES` | `10485760` | Rotate the log when it reaches this size (10 MB) |
| `LOG_MAX_BACKUPS` | `1` | Number of rotated logs to keep |
| `EXCLUDE_PATHS` | empty | Path prefixes that are never touched |
| `SWEEP_ON_STARTUP` | `true` | Fix everything under each watch root when the script starts |
| `INOTIFY_EVENTS` | `close_write create moved_to` | Events to react to |
| `MAX_RETRIES` | `3` | Attempts per path before giving up |
| `RETRY_DELAY` | `5` | Seconds between attempts |
| `RESTART_DELAY` | `5` | Seconds before restarting `inotifywait` after it exits |
| `MAX_RESTART_ATTEMPTS` | `5` | Consecutive restarts before giving up (`0` = unlimited) |
| `LOCK_FILE` | `/opt/scripts/watchplex/watchplex.lock` | Prevents duplicate instances |

### Log levels

| Level | What you get |
|---|---|
| `ERROR` | Failures and retries only |
| `INFO` | Plus startup messages, sweep summaries and watch start |
| `VERBOSE` | Plus every file or directory that was fixed |
| `DEBUG` | Plus every raw inotify event, every skip, and each retry attempt |

### Excluding paths

Add path prefixes to `EXCLUDE_PATHS` to keep them out of both the event handler and the startup sweep. This is useful if a log file or another tool's output lives inside a watched folder and would otherwise trigger events.

```bash
EXCLUDE_PATHS=(
    "/dvr/qb/logs"
)
```

### Temporary file filter

These files are skipped so the script doesn't touch files that tools are still working on:

- names ending in a dot plus exactly six letters or digits (rsync temp files such as `file.mkv.aB3xY9`)
- hidden files whose names contain a second dot (such as `.file.mkv.tmp`)
- any path containing `::TMPNAME`

The patterns are the `TMPFILE_*` variables near the top of the script. Note that a real file whose name happens to end in a dot plus six letters or digits will also be skipped by the first rule.

## Running as a systemd service

The repository includes the unit file, `watchplex.service`. Copy it to `/etc/systemd/system/`:

```ini
[Unit]
Description=Plex Permissions Watcher
After=network.target local-fs.target
StartLimitIntervalSec=120
StartLimitBurst=5

[Service]
Type=simple
ExecStart=/opt/scripts/watchplex/watchplex.sh
Restart=on-failure
RestartSec=5
KillMode=control-group
User=root
Group=root
StandardOutput=null
StandardError=journal
SyslogIdentifier=watchplex

[Install]
WantedBy=multi-user.target
```

What the settings do:

- `Restart=on-failure` with `RestartSec=5` restarts the script 5 seconds after it exits with an error.
- `StartLimitIntervalSec=120` and `StartLimitBurst=5` stop systemd from restarting it if it fails more than 5 times within 2 minutes. If that happens, fix the cause and run `sudo systemctl reset-failed watchplex.service` before starting it again.
- `KillMode=control-group` stops the script **and** the `inotifywait` and other child processes it started when the service is stopped.
- `StandardOutput=null` discards standard output. The script prints every log line to standard output as well as to its log file, so the journal gets only what goes to standard error. **The log file is your main log** (see `LOG_DIR`).
- `SyslogIdentifier=watchplex` labels anything that does reach the journal.

Adjust the `ExecStart` path if you installed the script somewhere other than `/opt/scripts/watchplex/`.

Then enable and start it:

```
sudo cp watchplex.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now watchplex.service
```

Check on it:

```
systemctl status watchplex.service
tail -f /var/log/watchplex/watchplex.log
journalctl -t watchplex -f
```

If you want every log line in the journal as well, change `StandardOutput=null` to `StandardOutput=journal`. That doubles the logging, since the log file keeps being written too.

If your watched folders are on a network or external mount, make sure the service starts after that mount is available (`RequiresMountsFor=/dvr` in the `[Unit]` section is one way, or add `remote-fs.target` to `After=`).

## Testing

Before enabling the service, set `DRY_RUN=true` in the script and run it by hand as root. It will report what it would change without running `chmod` or `chown`. The settings are plain variables inside the script, so they have to be edited in the file; they are not read from the environment. Set `LOG_LEVEL="DEBUG"` while you check that events and skips behave as you expect, then switch back to `INFO`.

To confirm it is working, create a file in a watched folder and check the result:

```
touch /dvr/qb/test.txt
ls -l /dvr/qb/test.txt
```

## Troubleshooting

- **"Another instance is already running":** the lock file contains the PID of a live process. Stop the service before running the script by hand. A stale lock from a crashed run is cleaned up automatically.
- **Nothing happens on new files:** check that `inotify-tools` is installed, the watch directories exist, and the service is running as root. Read the log file, not just the journal, because `StandardOutput=null` hides most messages from the journal.
- **"No space left on device" from inotify, or events missing in huge trees:** raise the kernel watch limit, for example `sudo sysctl fs.inotify.max_user_watches=524288`.
- **A file was skipped:** it probably matched the temp-file filter (see above). Run with `LOG_LEVEL="DEBUG"` to see skip messages.
- **Repeated failures on a path:** after `MAX_RETRIES` attempts the script logs "manual intervention required" and moves on. Check ownership, immutable flags and read-only mounts.

## Notes and limitations

- A moved-in directory has its **whole tree** fixed, not just the top folder.
- The startup sweep changes **every** file and directory under each root (except excluded paths), so check `WATCH_CONFIG` carefully before the first run. Modes like `777` and `666` are very permissive. Use them only if you understand why you need them.
- The script only reacts to new, finished or moved-in files. It does not notice permission changes made later by other tools.
- If a watcher for one directory gives up after `MAX_RESTART_ATTEMPTS` restarts, it logs "giving up" and stays stopped while any others keep running. If every watcher gives up, the script exits normally, so `Restart=on-failure` will not restart it. Look for "giving up" in the log if events stop being handled.

## License

`[add your license here, for example MIT, and include a LICENSE file in the repository]`
