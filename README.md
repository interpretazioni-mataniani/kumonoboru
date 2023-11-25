# Kumonoboru 
Kumonoboru (雲上る - 'to rise up in the clouds' in Japanese) is a cloud backup script based on [Restic](https://github.com/restic/restic), imported from my home system.
It is scheduled and configured via an Ansible, and launched via Gitea CI.  Atarashi writes the output to a Prometheus file (`kumonoboru`.prom), which can then be picked up by a Prometheus instance to notify when containers are updated\fail to update. Some example alerts (`prometheus-alerts.yaml`) are included.
**This is a sanitized, non-functional template** you can modify and use as you see fit.

The script is currently configured to use B2 as a backend, and read the repository configuration (B2 repository name and the local filesystem path it backs up) from a file,
But can be easily modified to use different backends/configuration methods.

This repository consists of:
- `kumonoboru.sh` - the backup script itself
- `kumonoboru.service.j2` - systemd service template, configured via Ansible
- `kumonoboru.timer.j2` - systemd timer template, configured via Ansible
- `./gitea/workflows/kumonoboru.yaml` - Gitea Actions CI workflow which installs Ansible, and runs the `kumonoboru.yaml` playbook to configure Kumonoboru.

# Usage
Kumonoboru relies on three environment variables:
- `B2_ACCOUNT_ID` - your BackBlaze B2 Account ID
- `B2_ACCOUNT_KEY` - a valid BackBlaze B2 access key to your repository
- `RESTIC_PASSWORD` - the password to access your Restic repository

It also requires specifying your repositories in a file (`.kumonoboru` by default), followed by their path, such as:
```
# B2 Repo Name    Path
My-Repo           /home/me/my-repo
```

## As standalone script
Once previous requirements are met, Kumonoboru can run as-is, given that `restic` is installed.

## As Ansible pipeline
To deploy Kumonoboru over multiple systems, you'll need to provide several secrets:
1. A valid SSH key for Ansible to use to connect to target systems (`{{ SSH_PRIVATE_KEY }}`)
2. A sudo password for elevated privledges, if needed. If not - you'll need to set `become` to `no` in `kumonoboru.yaml`
3. An Ansible inventory file. I'm cloning it from another repository via an access token - you can do the same or simply provide it.


