# ez_tools

A collection of utility tools for Linux systems.

## until_success.sh
 
Repeatedly executes a command until it succeeds.
 
```bash
./until_success.sh <command>
```
 
Useful when a command may temporarily fail (e.g., network issues, service not ready) but will eventually succeed.

## run_in_backend.sh

Runs a command in the background and redirects stdout/stderr to a log file.

```bash
./run_in_backend.sh <command> [args...] <log_file>
```

The last argument is treated as the log file path. For shell syntax such as pipes or redirection, run through a shell:

```bash
./run_in_backend.sh bash -lc 'npm run dev | cat' /tmp/dev.log
```

## daily_task.sh

Manages daily cron tasks for the current user.

```bash
./daily_task.sh add <task_name> <HH:MM> <command> [args...]
./daily_task.sh delete <task_name>
./daily_task.sh list
./daily_task.sh -h
```

Examples:

```bash
./daily_task.sh add backup 02:30 /usr/local/bin/backup --full
./daily_task.sh add shell_job 18:15 bash -lc 'date >> ~/daily.txt && echo done'
./daily_task.sh list
./daily_task.sh delete backup
```

Task names may contain only letters, digits, underscore, dot, and hyphen. Times use 24-hour `HH:MM` format from `00:00` through `23:59`. Commands are stored as argument arrays, so shell syntax is interpreted only when you explicitly run a shell such as `bash -lc '...'`.

The script tags its crontab entries with clear markers and only modifies those managed entries. Logs are appended under `~/.daily_task/logs/{task}/{YYYY-MM-DD}.log`.

## port_forward.sh

Manages TCP port forwarding rules on Linux with `iptables` DNAT/MASQUERADE.

```bash
sudo ./port_forward.sh add <local_port> <target_ip> <target_port>
sudo ./port_forward.sh remove <local_port>
sudo ./port_forward.sh list
sudo ./port_forward.sh flush
```

Example:

```bash
sudo ./port_forward.sh add 8080 10.0.0.5 80
```

This forwards TCP traffic received by the forwarding server on port `8080` to `10.0.0.5:80`. The script enables IPv4 forwarding when needed and tags its `iptables` rules so `list`, `remove`, and `flush` only operate on rules it manages.

Lifecycle:

The forwarding rules do not expire on their own and are not tied to the script process after `add` finishes. They remain active while the corresponding `iptables` rules and IPv4 forwarding setting remain in place.

Forwarding is closed when you run `remove <local_port>` for that port, run `flush` for all rules managed by this script, manually delete or replace the related `iptables` rules, disable IPv4 forwarding, or when another firewall manager such as `ufw` or `firewalld` reloads and rewrites the rules. The rules added by this script are not persisted with `iptables-save`, `netfilter-persistent`, or a systemd startup unit, so they usually do not survive a system reboot unless the host has separate `iptables` persistence configured.

## check_port.sh

Checks whether a TCP port is currently occupied by a listening process.

```bash
./check_port.sh <port>
```

Example:

```bash
./check_port.sh 8080
```

The script validates that the port is between `1` and `65535`, then reports whether it is available or in use. It uses `lsof`, `ss`, or `netstat`, depending on which command is available on the system.

## hf_mirror_download.sh

Downloads a Hugging Face model, dataset, or space through a mirror endpoint. Defaults to `https://hf-mirror.com`.

```bash
./hf_mirror_download.sh [options] <repo_id>
```

Examples:

```bash
./hf_mirror_download.sh Qwen/Qwen2.5-7B-Instruct
./hf_mirror_download.sh -o ./models/qwen -r main Qwen/Qwen2.5-7B-Instruct
./hf_mirror_download.sh --include '*.safetensors' --include '*.json' meta-llama/Llama-3.1-8B
```

Requires `huggingface-cli`:

```bash
python3 -m pip install -U huggingface_hub
```

## ez_cc_switch.sh

Manages model configurations for Claude Code and OpenCode.

```bash
./ez_cc_switch.sh {add|list|rm|edit|switch|sync-opencode} [args]
```

- `add <model> <url>`: Add or update a model configuration.
- `list`: List all saved models.
- `rm <model>`: Remove a model configuration.
- `edit <model> <url>`: Edit a model's URL.
- `switch <model>`: Switch Claude Code to the specified model.
- `sync-opencode`: Sync all models to OpenCode config.

## fix_codex_for_ubuntu.sh

Installs an AppArmor profile for the Codex native binary on Ubuntu/Debian-like systems.

```bash
./fix_codex_for_ubuntu.sh
```

Useful when Codex fails to start or run commands because unprivileged user namespaces are restricted by AppArmor. The script locates the installed Codex native binary, writes `/etc/apparmor.d/codex-native`, reloads the profile, and prints the current user namespace settings.

Requires `sudo` when not run as root. Restart Codex after running the script.

## kernel_auto_upgrade.sh

Manages kernel package auto-upgrades through Ubuntu/Debian `apt` and `unattended-upgrades` configuration.

```bash
./kernel_auto_upgrade.sh status
./kernel_auto_upgrade.sh disable
./kernel_auto_upgrade.sh enable
./kernel_auto_upgrade.sh help
```

`disable` writes `/etc/apt/apt.conf.d/52-disable-kernel-auto-upgrades` with:

```aptconf
Unattended-Upgrade::Package-Blacklist { "linux-"; };
```

This blocks unattended upgrades for packages matching `linux-` without disabling the system's overall security updates. `enable` removes only that managed file and leaves any other user-managed APT configuration unchanged. `status` reports whether the effective `Unattended-Upgrade::Package-Blacklist` contains `linux-`, and whether it was detected in the managed file or in non-managed APT configuration.

Requires `sudo` for `disable` and `enable` when not run as root.
