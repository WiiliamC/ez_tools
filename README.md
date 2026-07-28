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

## review_untill_satisfied.sh

Runs Codex review/fix cycles against a Git repository until the review is
satisfied or the configured loop limit is reached.

```bash
./review_untill_satisfied.sh --repo ../my-project/
./review_untill_satisfied.sh --repo ../my-project/ --fast
```

The script explicitly uses the default Codex service tier, even if Fast is
enabled in user or project configuration. Pass `--fast` to use the Fast service
tier for both review and fix steps.

Logs default to
`${XDG_STATE_HOME:-$HOME/.local/state}/review_untill_satisfied/<repo>/logs/`.
The log directory is kept outside the target repository so review/fix agents
cannot treat the active log as a repository artifact or delete it. You can
override the location with `--log-dir PATH`, but the resolved path must remain
outside the target repository. Existing logs from older versions are not moved
or deleted automatically.

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

Task names may contain only letters, digits, underscore, dot, and hyphen. Times use 24-hour `HH:MM` format from `00:00` through `23:59`. Commands are stored as argument arrays, so shell syntax is interpreted only when you explicitly run a shell such as `bash -lc '...'`. Tasks run from the add-time working directory, so relative command paths and relative arguments are resolved from that directory at run time.

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

## csv_view.sh

Views CSV data as aligned terminal columns with horizontal scrolling.

```bash
./csv_view.sh <csv_file>
cat data.csv | ./csv_view.sh
```

Examples:

```bash
./csv_view.sh data.csv
cat data.csv | ./csv_view.sh
```

The script parses CSV with Python's standard `csv` module, aligns fields into terminal columns, and opens the output in `less -S`, so long rows stay on one line and can be scrolled horizontally.

## kill_process.sh

Finds processes whose full command line contains a keyword, shows the matching process information, and asks for confirmation before sending `TERM`.

```bash
./kill_process.sh <process_command_keyword>
```

Example:

```bash
./kill_process.sh "python -m service"
```

The script excludes its own process and ancestor shell/wrapper processes from matches. If no processes match, it prints a clear message and exits successfully. Only `y` or `yes` confirms termination.

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

Requires the Hugging Face `hf` CLI:

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

## install_gh_for_ubuntu.sh

Installs GitHub CLI `gh` on Ubuntu/Debian APT systems from the official GitHub CLI APT repository.

```bash
./install_gh_for_ubuntu.sh
./install_gh_for_ubuntu.sh install
./install_gh_for_ubuntu.sh status
./install_gh_for_ubuntu.sh help
```

`install` writes the official GitHub CLI keyring to `/etc/apt/keyrings/githubcli-archive-keyring.gpg`, writes `/etc/apt/sources.list.d/github-cli.list`, updates APT package lists, and installs `gh`.

Requires `sudo` when not run as root. The script installs `gh` only; run `gh auth login` separately if you want to authenticate.

## install_atlassian_mcp_for_codex.sh

Configures the official Atlassian Rovo MCP server in the current user's global Codex configuration, then starts the interactive OAuth login flow.

```bash
./install_atlassian_mcp_for_codex.sh
```

The script requires the `codex` CLI and configures the MCP server as `atlassian` using `https://mcp.atlassian.com/v1/mcp/authv2`. If an MCP server with that name already exists, the script exits without replacing it. Remove the existing entry explicitly before retrying if replacement is intended.

OAuth login normally opens a browser. Access may be restricted by your Atlassian organization's Rovo MCP, domain, or IP allowlist policies. If configuration succeeds but login fails, retry with:

```bash
codex mcp login atlassian
```

## config_earlyoom.sh

Installs and enables `earlyoom` on Ubuntu/Debian APT systems using the package defaults.

```bash
./config_earlyoom.sh
./config_earlyoom.sh install
./config_earlyoom.sh status
./config_earlyoom.sh help
```

`install` runs `apt-get update`, installs the `earlyoom` package, and enables/starts `earlyoom.service` through `systemctl`. It does not write `/etc/default/earlyoom` or systemd overrides, so the distribution package's default configuration remains active.

Requires `sudo` when not run as root.

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
