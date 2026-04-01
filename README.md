# ez_tools

A collection of utility tools for Linux systems.

## until_success.sh

Repeatedly executes a command until it succeeds.

```bash
./until_success.sh <command>
```

Useful when a command may temporarily fail (e.g., network issues, service not ready) but will eventually succeed.
