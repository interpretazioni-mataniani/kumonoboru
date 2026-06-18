# Kumonoboru
雲上る — "to rise up in the clouds"

Restic backup wrapper for Backblaze B2. Checks repository locks, runs backups, verifies integrity, and prunes old snapshots on a schedule. Writes results to a Prometheus textfile metric (`system_backup`) so node_exporter can expose them for alerting.

## Deployment

In the `everything-but-the-bagle` project, kumonoboru is deployed as an RPM via the `mkdocs` Ansible role (`tasks/backup.yml`). Credentials are provisioned from Ansible vault to `/etc/kumonoboru/env`. The systemd timers are enabled automatically by the RPM `%post` scriptlet.

For standalone deployment (outside ebtb), see `kumonoboru.yaml`.

## Configuration

Both files live under `/etc/kumonoboru/` (directory created with mode 0750 by the RPM).

**`/etc/kumonoboru/env`** — credentials (mode 0600):
```
B2_ACCOUNT_ID=...
B2_ACCOUNT_KEY=...
RESTIC_PASSWORD=...
```

**`/etc/kumonoboru/repositories`** — one repo per line (mode 0640):
```
# B2-bucket-name    local path to back up
my-bucket           /opt/ebtb
```
Blank lines and `#` comments are skipped.

## Systemd units

| Unit | Schedule | What it does |
|------|----------|--------------|
| `kumonoboru.timer` | daily | Back up all configured repositories |
| `kumonoboru-prune.timer` | monthly | Prune snapshots (keep 7d / 4w / 12m) and run integrity check |

## Operations

**Check timer status:**
```bash
systemctl status kumonoboru.timer kumonoboru-prune.timer
systemctl list-timers kumonoboru*
```

**Run a backup manually:**
```bash
systemctl start kumonoboru.service
# or with a specific repository:
/usr/bin/kumonoboru --repository my-bucket
```

**View logs:**
```bash
journalctl -u kumonoboru.service -n 50
journalctl -u kumonoboru-prune.service -n 50
```

**Check last backup result via Prometheus:**
```promql
system_backup{name="my-bucket"}
```

## Monitoring

Kumonoboru writes to `/var/lib/node_exporter/textfile_collector/kumonoboru.prom`, which node_exporter picks up via its textfile collector. The metric `system_backup{name="<repo>"}` carries the following status codes:

| Value | Meaning |
|-------|---------|
| 0 | Backup succeeded |
| 1 | Backup failed |
| 2 | Integrity check passed |
| 3 | Prune succeeded |
| -1 | Repository already in use — backup skipped |
| -2 | Integrity check failed (data may be corrupted) |
| -3 | Prune failed |

The `.prom` file is removed 2 minutes after the script exits, giving Prometheus time to scrape it. Example alert rules are in `prometheus-alerts.yaml`.

## CLI flags

```
-r / --repository <name>   Only process the named repository
-l / --limit <Kbps>        Cap upload and download bandwidth
-c / --clean               Force a prune run instead of a backup
-v / --verbose             Enable debug output
-h / --help                Print usage
```

## Dependencies
- `restic` — backup engine
- `okoru` — logging library (RPM dependency, installed automatically)
