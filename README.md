# ez_tools

A collection of utility tools for Linux systems.

## until_success.sh
 
Repeatedly executes a command until it succeeds.
 
```bash
./until_success.sh <command>
```
 
Useful when a command may temporarily fail (e.g., network issues, service not ready) but will eventually succeed.

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
