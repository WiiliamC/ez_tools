# ez_tools

A collection of utility tools for Linux systems.

## mp4_to_gif.sh

Converts an MP4 video to a looping GIF with FFmpeg. The frame rate defaults to
15 FPS, while the source resolution is preserved unless `--resolution` is
specified. Existing output files are not overwritten unless `--overwrite` is
used.

```bash
./mp4_to_gif.sh video.mp4
./mp4_to_gif.sh --resolution 640x360 --fps 12 video.mp4 preview.gif
./mp4_to_gif.sh --overwrite video.mp4 existing.gif
```

## install_fcitx5_pinyin.sh

Installs Ubuntu/Debian's Fcitx5 packages and configures built-in Pinyin, Baidu
cloud candidates (second candidate), prediction, and the Material black theme.
Run it as the logged-in desktop user, not through `sudo`:

```bash
./install_fcitx5_pinyin.sh          # same as install
./install_fcitx5_pinyin.sh status
./install_fcitx5_pinyin.sh help
fcitx5-config-qt                    # optional GUI configuration
```

Log out and back in after installation. Cloud Pinyin sends lookup queries to
Baidu; use the Fcitx5 GUI or remove the cloud settings if that is unsuitable.

## safe_ssh.sh

Creates isolated, public-key-only SSH access profiles. Server management is
limited to Ubuntu/Debian systems using systemd and OpenSSH. It never edits
unrelated SSH configuration. Client keys are managed directly in the remote
`~/.ssh/authorized_keys`, preserving unrelated keys, options, and comments.
Before each actual add or removal it permanently saves the prior file under
remote `~/.safe_ssh/backup/` (or creates a private `.absent` marker when the
file did not exist). Repeating an already-applied operation creates no backup.

```bash
# 1. On the client, as the login user (never through sudo), install a dedicated
# key using existing SSH access.
./safe_ssh.sh client_add home alice@ssh.example.com --port 2222
./safe_ssh.sh client_add home alice@ssh.example.com \
  --port 2222 --bootstrap-identity ~/.ssh/existing_key

# 2. Prove that the dedicated key can connect without fallback authentication.
./safe_ssh.sh client_test home

# 3. Optionally, back on the server, require public-key authentication. Only do
# this after the separate client_test above has succeeded. Confirm the warning
# with an exact lowercase y; disabling password and keyboard-interactive
# authentication can lock you out.
sudo ./safe_ssh.sh server_on

sudo ./safe_ssh.sh server_status
sudo ./safe_ssh.sh server_off
./safe_ssh.sh client_status
./safe_ssh.sh client_status home
./safe_ssh.sh client_delete home
./safe_ssh.sh client_delete home --local-only
```

Each client name gets its own unencrypted Ed25519 key, dedicated `known_hosts`,
metadata, and `Host NAME` snippet under
`${XDG_CONFIG_HOME:-$HOME/.config}/safe_ssh/`. The one marked `Include` at the
top of `~/.ssh/config` exposes those aliases without changing unrelated hosts
or identity selection. First use asks you to confirm the host key. A later host
key mismatch is refused and is never automatically replaced.

`client_status` reports `ready`, `local-only`, `host-key-error`, `unreachable`,
or `unauthorized` so local configuration failures can be distinguished from
network and authentication failures.

`client_add` uses your existing SSH access to install the new public key. It
refuses a name already defined explicitly in your `~/.ssh/config` or its
included files, so it never silently takes over an existing SSH alias.
An `Include` inside a `Match` block is rejected because its applicability
cannot be checked safely without executing the conditional configuration.
`client_test` separately verifies that the dedicated identity works with
public-key authentication only. Repeating the same name and target is safe;
reusing a name for another target is refused. `client_delete` revokes the exact
public key remotely before deleting local files, so local recovery state is
retained if revocation fails. If initial authorization never succeeded and the
target cannot be reached, `client_delete NAME --local-only` explicitly removes
only the local profile without attempting remote revocation.

`server_on` does not inspect `AuthorizedKeysFile`, local key files, or attempt
an SSH login. Verifying a separate public-key-only client login before enabling
the policy is the operator's responsibility. The first enable requires an exact
lowercase `y`; any other response or end-of-input cancels without changing the
configuration or reloading SSH. Repeating `server_on` after the managed policy
is effectively enabled is idempotent and does not prompt again.

Upgrade note: there is no automatic migration from older `server_prepare`
installations. Re-run each client profile with `client_add`, verify it with
`client_test`, run `sudo ./safe_ssh.sh server_off` to remove the legacy managed
drop-in, then optionally run the new `server_on`. `server_status` reports old
prepared/enabled managed drop-ins as `legacy`; `server_on` will not overwrite
them.

The aliases work with standard tools:

```bash
ssh home
scp ./backup.tar home:/srv/backups/
rclone copy ./photos :sftp:/data/photos \
  --sftp-host ssh.example.com \
  --sftp-user alice \
  --sftp-port 2222 \
  --sftp-key-file ~/.config/safe_ssh/clients/home/id_ed25519 \
  --sftp-known-hosts-file ~/.config/safe_ssh/clients/home/known_hosts
```

### Windows client

Run `safe_ssh_client.ps1` in PowerShell as the Windows login user, not as
Administrator. If the OpenSSH client is unavailable, install it from Windows
Optional Features or run this once in an Administrator PowerShell:

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0
```

Generate or reuse the named key and local SSH alias (this does not connect to
or modify the server):

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\safe_ssh_client.ps1 `
  home alice@ssh.example.com -Port 2222
```

When prompted, press Enter twice to leave the new key's passphrase empty,
then append the complete public-key line printed by the script as one new line
to that Linux user's `~/.ssh/authorized_keys` without overwriting its existing
keys. On the server, set the usual permissions:

```bash
chmod 700 ~/.ssh
chmod 600 ~/.ssh/authorized_keys
```

Then use the alias. Verify the server's host-key fingerprint before accepting
it on the first connection:

```powershell
ssh home
```

Every `safe_ssh.sh` invocation writes a complete private log under the
initiating user's `~/.safe_ssh/logs/`. With `sudo`, that user and home are
resolved from `SUDO_USER` via the passwd database. Logs contain phases, command
output, rollback and exit status, but redact secrets and record only key type
and fingerprint.

## publish_ssh_by_cpolar.sh

`publish_ssh_by_cpolar.sh` uses cpolar's installed `cpolar.service`; it does
not start a separate foreground process or manage a PID file. Before enabling
the service, it validates `/usr/local/etc/cpolar/cpolar.yml` with
`cpolar list -config=...` and requires the following named tunnel. Add it to
the existing configuration,
preserving its existing `authtoken` rather than copying it into commands or
documentation:

```yaml
tunnels:
  ssh:
    proto: tcp
    addr: "22"
```

Then run the no-argument wrapper on the SSH server. It enables and restarts
`cpolar.service` (with `sudo` when needed), so configuration changes take
effect even if the service is already active:

```bash
./publish_ssh_by_cpolar.sh
systemctl status cpolar
journalctl -u cpolar
sudo tail -f /var/log/cpolar/access.log
```

Use the public hostname and port shown by cpolar as the `USER@HOST` and
`--port` values:

```bash
./safe_ssh.sh client_add tunneled alice@example.cpolar.cn --port 12345
ssh tunneled
```

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
./review_untill_satisfied.sh --resume /path/to/original-run.log
./review_untill_satisfied.sh --repo ../my-project/ --resume
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

Every new log has private `.state.json`, `.review.json`, and `.events.jsonl`
sidecars. They preserve loop/phase checkpoints, structured review output, the
raw Codex event stream, and the Codex session needed to continue a failed or
interrupted phase. `--resume LOG` appends to that original log. Bare `--resume`
selects the newest incomplete run for the repository (and searches `--log-dir`
when one is provided). Logs created before these sidecars were introduced
cannot be resumed.

Resume rejects repository changes made after the saved checkpoint by default.
Use `--allow-worktree-changes` only after checking that the drift is expected.
The saved service tier is always reused, so `--fast` is not accepted on resume.
`--max-loops` may keep or increase the original total, but never reduce it; an
exhausted run requires a larger total before it can continue. Each run is
locked so only one process can resume it at a time.

If Codex emits a structured stdout error event whose message contains `request
timed out`, the current review or fix phase is stopped immediately and the
script exits with status `124`. The failed phase, captured session, and
worktree checkpoint remain resumable with `--resume`; this avoids waiting for
Codex's internal reconnect attempts.

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

Manages TCP port forwarding rules on Linux with `iptables` DNAT/MASQUERADE. The target may be an IPv4 address or a host from the invoking user's SSH configuration.

```bash
sudo ./port_forward.sh add <local_port> <target_host> <target_port>
sudo ./port_forward.sh remove <local_port>
sudo ./port_forward.sh list
sudo ./port_forward.sh flush
```

Example:

```bash
sudo ./port_forward.sh add 8080 10.0.0.5 80
sudo ./port_forward.sh add 8080 ms5090 80
```

These examples forward TCP traffic received by the forwarding server on port `8080` to port `80` on the target. For an SSH host such as `ms5090`, the script runs `ssh -G` as the user who invoked `sudo`, reads its `HostName`, and resolves it to a fixed IPv4 address before creating the rules. `User`, `Port`, and identity settings from SSH configuration are not used, and aliases that require `ProxyJump` or `ProxyCommand` are rejected because this is not an SSH tunnel. The script enables IPv4 forwarding when needed and tags its `iptables` rules so `list`, `remove`, and `flush` only operate on rules it manages.

Lifecycle:

The forwarding rules do not expire on their own and are not tied to the script process after `add` finishes. They remain active while the corresponding `iptables` rules and IPv4 forwarding setting remain in place. SSH host names are resolved only when a rule is added, so later SSH configuration or DNS changes do not update existing rules; `list` shows the IPv4 address actually stored in iptables.

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
# Optionally restart an already-running app-server daemon after verification:
./fix_codex_for_ubuntu.sh --restart-daemon
```

Useful when Codex fails to start or run commands because unprivileged user namespaces are restricted by AppArmor. The script locates the installed Codex native binary, writes `/etc/apparmor.d/codex-native`, validates and reloads the profile, and prints the current user namespace settings.

For Codex releases that use Bubblewrap, the profile grants `userns` to Codex and exact `ix` execution rules for an executable `bwrap` found on `PATH` and/or `codex-resources/bwrap` beside the resolved native binary. It does not install a global Bubblewrap profile or change kernel user-namespace sysctls. The script then checks `codex sandbox -- /usr/bin/true` as the invoking non-root user (using `SUDO_USER` when run through `sudo`); a direct root invocation warns that this check is not meaningful.

Requires `sudo` when not run as root. By default it leaves the app-server daemon running and prints restart guidance. `--restart-daemon` restarts only a daemon already reported as running, and only after sandbox verification succeeds. Run `./fix_codex_for_ubuntu.sh --help` for usage.

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
