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
