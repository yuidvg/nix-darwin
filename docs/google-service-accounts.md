# Google service accounts

For personal/work user OAuth, see [gws user accounts](gws-user-accounts.md).

Personal account bindings live in `personal.nix`. JSON keys are encrypted as
individual string values in `secrets.yaml`; Home Manager's sops-nix decrypts them
to user-owned runtime files with mode `0600`. Private keys never enter Nix source
or the Nix store.

| Identity | Service account | SOPS key / runtime filename | Command |
| --- | --- | --- | --- |
| agent | `agent-0@agent-499711.iam.gserviceaccount.com` | `google_service_account_agent` | `with-google-agent COMMAND ...` |
| inventory | `viewer@inventory-project-0.iam.gserviceaccount.com` | `google_service_account_inventory_viewer` | `with-google-inventory COMMAND ...` |

The runtime directory is `~/.config/sops-nix/secrets/`. The exported variables
`GOOGLE_AGENT_CREDENTIALS_FILE` and `GOOGLE_INVENTORY_CREDENTIALS_FILE` contain
the corresponding paths, not the key contents.

## Project development shells (recommended)

nix-darwin provides static shell profiles at
`~/.config/google-service-accounts/agent.env` and `inventory.env`. Each contains
only exported paths/project/account settings and clears conflicting overrides;
the private key stays in the SOPS runtime file. Profiles are generated once in
`personal.nix` and shared with the command wrappers.

In the consuming project's `pkgs.mkShell`:

```nix
shellHook = ''
  source "$HOME/.config/google-service-accounts/inventory.env" || exit 1
  if [ ! -r "$GOOGLE_APPLICATION_CREDENTIALS" ]; then
    echo "Inventory credentials unavailable; activate nix-darwin first." >&2
    exit 1
  fi
'';
```

This selects inventory when entering `nix develop`. To load it on directory
entry and restore the previous environment on exit, use the existing direnv
integration with a project `.envrc`:

```sh
watch_file "$HOME/.config/google-service-accounts/inventory.env"
use flake
```

Run `direnv allow` in that project. `watch_file` also invalidates nix-direnv's
cached environment when the generated profile changes. `nix develop` alone
keeps its selected identity until the shell exits, regardless of directory
changes. Project files choose the identity; nix-darwin owns its local binding.
The profiles use POSIX shell syntax, suitable for Bash/Zsh and direnv; Fish
users can use direnv or the wrappers instead of sourcing them directly.

Profiles change only environment variables (including per-identity cache
paths), not shell options or the current shell's umask. They do not prevent
programs from accessing other keys readable by the same user.

## Select an identity for one command

```sh
with-google-inventory gcloud config list
with-google-inventory gws sheets spreadsheets get --params '{"spreadsheetId":"SHEET_ID"}'
with-google-inventory python3 analysis.py

with-google-agent gws drive files list --params '{"pageSize":5}'
```

The profiles set `GOOGLE_APPLICATION_CREDENTIALS` for Google SDKs,
`GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE` for gws, and
`CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE` for gcloud. The project and account are
selected along with the key. Higher-priority inherited access-token and
impersonation overrides are cleared so they cannot silently select another
identity.

Mutable gcloud configuration and gws caches live separately under
`~/.config/gcloud-service-accounts/<identity>/` and
`~/.config/gws-service-accounts/<identity>/`. When used through a wrapper, the settings apply only to the
child command. Regular gcloud keeps its existing human login; regular gws keeps
the agent account as its default. There is no global
`GOOGLE_APPLICATION_CREDENTIALS` override.

The existing runtime filename `google_workspace_credentials` remains a
compatibility entry for MYODAI scripts that use that path directly. It decrypts
the same `google_service_account_agent` value; it does not contain an independent
copy of the encrypted key or select the inventory account.

The identity names describe which account is used, rather than which CLI first
used it. This lets one key serve gws, gcloud, and SDKs while keeping account
selection explicit. The viewer account's actual access is determined by Google
IAM and individual Drive/Sheets shares; the wrapper does not add permissions.

Drive and Sheets APIs must be enabled in the key's Google Cloud project for gws
to call those services. Both are enabled for `inventory-project-0`. Key creation,
API enablement, and organization policies are Google Cloud state; this Nix
configuration manages local key deployment and command selection.

## Import or replace a JSON key

Check `client_email` and `project_id` against the table before importing.
Pass secret contents through stdin, not shell arguments. For example:

```sh
python3 - /secure/path/to/inventory-key.json <<'PY'
import json, subprocess, sys
from pathlib import Path

credential = json.loads(Path(sys.argv[1]).read_text())
assert credential['type'] == 'service_account'
assert credential['client_email'] == 'viewer@inventory-project-0.iam.gserviceaccount.com'
assert credential['project_id'] == 'inventory-project-0'
assert credential.get('private_key')
subprocess.run(
    ['sops', 'set', '--value-stdin', 'secrets.yaml',
     '["google_service_account_inventory_viewer"]'],
    input=json.dumps(json.dumps(credential)), text=True, check=True,
)
PY
```

Rotate one identity at a time; leave the other encrypted values and auth caches
intact. Never add the downloaded plaintext JSON file to Git.

## Validate and activate

```sh
nix fmt personal.nix
nix build '.#darwinConfigurations.Yuis-MacBook-Pro.system' --no-link --print-out-paths
./apply
```

After activation, open a new shell and verify the selected identity without
printing a token or private key:

```sh
with-google-inventory gcloud config list --format='value(core.account,core.project,auth.credential_file_override)'
with-google-inventory gws auth status
```

These checks show the selected configuration. A successful read of the intended
API resource is a separate check of key validity and access.

References: [gcloud authentication](https://docs.cloud.google.com/sdk/docs/authenticate)
and [gws authentication/configuration](https://github.com/googleworkspace/cli).
