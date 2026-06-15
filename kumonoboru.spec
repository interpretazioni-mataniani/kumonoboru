Name:           kumonoboru
Version:        1.0.1
Release:        1%{?dist}
Summary:        Restic backup wrapper with Prometheus textfile reporting
License:        MIT
BuildArch:      noarch
Requires:       bash
Requires:       restic

Source0:        kumonoboru.sh
Source1:        kumonoboru.service
Source2:        kumonoboru.timer
Source3:        kumonoboru-prune.service
Source4:        kumonoboru-prune.timer

%description
Kumonoboru wraps Restic for B2 cloud backups. It checks repository locks,
backs up configured paths, verifies integrity, and prunes old snapshots.
Backup status is written to a Prometheus textfile collector metric
(system_backup) for alerting.

Credentials and repository list are configured via /etc/kumonoboru/.

%install
install -Dm755 %{SOURCE0} %{buildroot}%{_bindir}/kumonoboru
install -Dm644 %{SOURCE1} %{buildroot}/usr/lib/systemd/system/kumonoboru.service
install -Dm644 %{SOURCE2} %{buildroot}/usr/lib/systemd/system/kumonoboru.timer
install -Dm644 %{SOURCE3} %{buildroot}/usr/lib/systemd/system/kumonoboru-prune.service
install -Dm644 %{SOURCE4} %{buildroot}/usr/lib/systemd/system/kumonoboru-prune.timer
install -dm750 %{buildroot}%{_sysconfdir}/kumonoboru

%post
if [ $1 -eq 1 ]; then
    systemctl daemon-reload 2>/dev/null || :
    systemctl enable kumonoboru.timer kumonoboru-prune.timer 2>/dev/null || :
fi

%preun
if [ $1 -eq 0 ]; then
    systemctl stop kumonoboru.timer kumonoboru-prune.timer 2>/dev/null || :
    systemctl disable kumonoboru.timer kumonoboru-prune.timer 2>/dev/null || :
fi

%postun
systemctl daemon-reload 2>/dev/null || :

%files
%{_bindir}/kumonoboru
/usr/lib/systemd/system/kumonoboru.service
/usr/lib/systemd/system/kumonoboru.timer
/usr/lib/systemd/system/kumonoboru-prune.service
/usr/lib/systemd/system/kumonoboru-prune.timer
%dir %attr(750, root, root) %{_sysconfdir}/kumonoboru

%changelog
* Mon Jun 15 2026 Matan Horovitz - 1.0.1-1
- Fix repository file path: use $REPO_FILE consistently instead of hardcoded .kumonoboru
- Replace %systemd_* macros with plain systemctl calls for portability

* Mon Jun 15 2026 Matan Horovitz - 1.0.0-1
- Initial package
