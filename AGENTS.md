# Repository Instructions

This is a public open-source repository. Treat every Git-tracked file and the
entire commit history as publicly accessible.

## Privacy and secrets

- Never add credentials or private data to Git, including API tokens, passwords,
  private keys, cookies, authentication headers, personal filesystem paths,
  private hostnames or IP addresses, account identifiers, and unredacted logs.
- Do not commit local configuration, generated runtime state, `.env` files, SSH
  material, or logs that may contain commands, paths, endpoints, or user data.
- Use clearly fictional placeholders and reserved example domains or addresses
  in documentation and tests.
- Review staged changes and relevant generated files for sensitive data before
  committing or pushing. Remember that deleting a secret in a later commit does
  not remove it from Git history.
- If sensitive data is found in Git, do not repeat its value in reports or
  comments. Revoke or rotate credentials first, then remove the data from the
  current tree and, when necessary, rewrite the affected history.

The repository author's name and email address are intentionally public and may
appear in Git metadata, documentation, and license attribution.
