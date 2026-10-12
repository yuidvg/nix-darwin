"""Launch a patched gws with an identity-local OAuth configuration and cache."""
import json
import subprocess
import os
from pathlib import Path
import sys


def launch(binary, directory, args):
    directory = Path(directory)
    help_only = not args or any(arg in ("--help", "-h", "--version", "-V") for arg in args)
    login = args[:2] == ["auth", "login"]
    if args[:2] == ["auth", "setup"]:
        sys.exit("Use a Desktop OAuth client_secret.json in the selected config directory; auth setup is disabled to avoid shared gcloud state.")
    if not help_only and not login:
        if not any((directory / name).is_file() for name in ("credentials.enc", "credentials.json")):
            sys.exit(f"No login in {directory}. Install client_secret.json there, then run this command with auth login and explicitly chosen scopes.")
    if login and not help_only and not (directory / "client_secret.json").is_file():
        sys.exit(f"Missing OAuth client configuration: {directory / 'client_secret.json'}")
    env = dict(os.environ)
    for key in list(env):
        if key.startswith(("GOOGLE_WORKSPACE_", "CLOUDSDK_", "GOOGLE_CLOUD_", "GCLOUD_")) or key == "GOOGLE_APPLICATION_CREDENTIALS":
            del env[key]
    env["GOOGLE_WORKSPACE_CLI_CONFIG_DIR"] = str(directory)
    env["GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND"] = "file"
    if not help_only and not login:
        if (directory / "credentials.enc").is_file():
            # This path decrypts without deleting a corrupt file or refreshing tokens.
            result = subprocess.run([binary, "auth", "export"], env=env,
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if result.returncode:
                sys.exit(f"Cannot decrypt credentials in {directory}; files were preserved. Repair this account before retrying.")
        else:
            try:
                credential = json.loads((directory / "credentials.json").read_text())
                if not all(isinstance(credential.get(k), str) and credential[k]
                           for k in ("client_id", "client_secret", "refresh_token")):
                    raise ValueError()
            except (OSError, ValueError, AttributeError):
                sys.exit(f"Invalid OAuth credentials in {directory}; no fallback attempted.")
    os.umask(0o077)
    # No chdir, shell interpolation, or changes to the parent process.
    os.execve(binary, [binary, *args], env)


if __name__ == "__main__":
    launch(sys.argv[1], sys.argv[2], sys.argv[3:])
