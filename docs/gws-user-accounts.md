# Personal and work Google Workspace accounts

`gws-personal` uses `~/.config/gws-personal`; `gws-work` uses
`~/.config/gws-work` (intended login: `nishimura@diverge.jp`). Each directory owns
its OAuth client configuration, encrypted credentials, file encryption key,
token cache, and discovery cache. The names select directories, not Google
identities: verify the email after consent, especially when the browser has
multiple accounts signed in.

Regular `gws`, its service-account default, `with-google-agent`, and
`with-google-inventory` retain their existing behavior. These two wrappers
use a private build of gws 0.22.5; it is not installed as the default `gws`.
They preserve the working directory, arguments (including relative paths),
and unrelated environment variables. They clear inherited Google Workspace,
Cloud SDK, project, and ADC selectors in the child process only.

## Why a private build

In upstream 0.22.5, `.env` is loaded from the caller's directory or its parents,
so merely unsetting variables lets another identity be reintroduced. Upstream
also deletes undecryptable credentials and falls back to plaintext/ADC. The
small version-checked patch in `packages/gws-isolated`:

- Disables dotenv loading, retaining the original working directory.
- Accepts credentials only from the selected config directory, with encrypted
  credentials taking priority; no inherited token/file or common ADC fallback.
- Stops on decryption failure without deleting credentials or token caches.
- Resolves OAuth clients and quota projects only from local `client_secret.json`.

The wrapper checks missing/invalid OAuth files and performs a non-refreshing
export check for encrypted credentials, discarding its output. Errors stop
before running the requested API command. `auth setup` is disabled because it
uses shared gcloud state. `GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file` is fixed.
No secret is evaluated by Nix or stored in the Nix store. Upgrading gws requires
reviewing the patch and tests; the version assertion intentionally stops an
unreviewed upgrade.

## First authorization (user action)

1. Choose the services and permissions needed for each account. Obtain a Google
   Desktop OAuth client appropriate to that account and enable only the needed
   APIs in its project. Put the downloaded client configuration directly at the
   corresponding `~/.config/gws-personal/client_secret.json` or
   `~/.config/gws-work/client_secret.json`, with directory mode `0700` and file
   mode `0600`. Do not copy existing service-account keys or shared auth caches.
2. Run the chosen wrapper's `auth login` only after agreeing to those scopes.
   For Gmail reading, for example (not a requirement for Sheets-only usage):

   ```sh
   gws-work auth login --scopes https://www.googleapis.com/auth/gmail.readonly
   ```

   Select `nishimura@diverge.jp` in the browser. For the personal account use
   `gws-personal` and select the intended personal email. Avoid `--full` when
   read access suffices. Sheets reading instead needs
   `https://www.googleapis.com/auth/spreadsheets.readonly`; add Drive scopes
   only when Drive operations are required. Do not authorize services you do
   not intend to use.
3. After consent, verify the actual identity with a read API permitted by those
   scopes. For the Gmail example:

   ```sh
   gws-work gmail users getProfile --params '{"userId":"me"}'
   gws-personal gmail users getProfile --params '{"userId":"me"}'
   ```

   Confirm `emailAddress` matches the intended account before using other
   commands. For another service, choose an identity read supported by the
   authorized scopes; do not add Gmail just to run this example. `auth status`
   can also report live user information where scopes permit it.

OAuth authorization and real-email verification have not been performed by
this implementation task. Existing keys/configurations are not migrated.
Applying nix-darwin is a separate action, after a successful build:

```sh
./apply
```

## Validation

```sh
python3 tests/test_gws_isolated.py
nix fmt modules/shared-scripts.nix packages/gws-isolated/default.nix
nix build '.#darwinConfigurations.Yuis-MacBook-Pro.system' --no-link --print-out-paths
nix build '.#darwinConfigurations.Yuis-MacBook-Pro.system' --dry-run
```

The patched Rust package runs focused `isolated_` tests: inherited token/file
and ADC rejection, quota-project isolation, corrupt-encrypted-file preservation,
and local OAuth loading. Other upstream tests that explicitly require ADC
fallback are not applicable to this private variant; the regular package is
unchanged. Python tests use fake credentials and a stub CLI to verify argument,
working-directory, environment, and account-directory boundaries. These are
not a substitute for the post-consent identity read.

Reference: upstream [v0.22.5 auth implementation](https://github.com/googleworkspace/cli/blob/v0.22.5/crates/google-workspace-cli/src/auth.rs)
and [startup dotenv loading](https://github.com/googleworkspace/cli/blob/v0.22.5/crates/google-workspace-cli/src/main.rs).
