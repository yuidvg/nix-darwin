"""Offline boundary tests; every credential and CLI is fake."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/gws-isolated.py'

class Isolation(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.cwd = self.root / 'caller with spaces'
        self.cwd.mkdir()
        (self.root / '.env').write_text('GOOGLE_WORKSPACE_CLI_TOKEN=parent-poison\n')
        (self.cwd / '.env').write_text('GOOGLE_WORKSPACE_CLI_CREDENTIALS_FILE=poison\n')
        self.stub = self.root / 'fake-gws'
        self.stub.write_text('#!' + sys.executable + '\n' + '''import os, sys, json
from pathlib import Path
if sys.argv[1:] == ['auth', 'export']:
    sys.exit(1 if Path(os.environ['GOOGLE_WORKSPACE_CLI_CONFIG_DIR'], 'credentials.enc').read_text() == 'broken' else 0)
print(json.dumps({'args':sys.argv[1:], 'cwd':os.getcwd(), 'env':dict(os.environ)}))
''')
        self.stub.chmod(0o700)
        self.env = dict(os.environ, HOME=str(self.root), KEEP_ME='unchanged',
                        GOOGLE_WORKSPACE_CLI_TOKEN='poison',
                        GOOGLE_WORKSPACE_CLI_CLIENT_SECRET='poison',
                        GOOGLE_APPLICATION_CREDENTIALS='poison',
                        CLOUDSDK_CORE_PROJECT='poison')
        adc = self.root / '.config/gcloud'
        adc.mkdir(parents=True)
        (adc / 'application_default_credentials.json').write_text('{}')

    def run_cli(self, identity, *args):
        return subprocess.run([sys.executable, str(SCRIPT), str(self.stub),
                               str(self.root / identity), *args], cwd=self.cwd,
                              env=self.env, text=True, capture_output=True)

    def credential(self, identity):
        directory = self.root / identity
        directory.mkdir()
        (directory / 'credentials.json').write_text(json.dumps(dict(
            type='authorized_user', client_id='fake', client_secret='fake', refresh_token='fake')))
        return directory

    def test_arguments_environment_and_identity_separation(self):
        outputs = []
        for name in ('personal', 'work'):
            self.credential(name)
            result = self.run_cli(name, 'drive', '--upload', './file with spaces', '--params', '{"a":"b c"}')
            self.assertEqual(result.returncode, 0, result.stderr)
            output = json.loads(result.stdout)
            self.assertEqual(output['args'][2], './file with spaces')
            self.assertEqual(output['args'][4], '{"a":"b c"}')
            self.assertEqual(output['cwd'], str(self.cwd.resolve()))
            self.assertEqual(output['env']['KEEP_ME'], 'unchanged')
            self.assertNotIn('GOOGLE_APPLICATION_CREDENTIALS', output['env'])
            self.assertNotIn('GOOGLE_WORKSPACE_CLI_TOKEN', output['env'])
            self.assertNotIn('GOOGLE_WORKSPACE_CLI_CLIENT_SECRET', output['env'])
            self.assertNotIn('CLOUDSDK_CORE_PROJECT', output['env'])
            self.assertEqual(output['env']['GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND'], 'file')
            outputs.append(output['env']['GOOGLE_WORKSPACE_CLI_CONFIG_DIR'])
        self.assertNotEqual(*outputs)
        self.assertEqual(self.env['GOOGLE_WORKSPACE_CLI_TOKEN'], 'poison')

    def test_missing_stops_despite_adc(self):
        self.assertNotEqual(self.run_cli('missing', 'drive', 'files', 'list').returncode, 0)

    def test_corrupt_encrypted_preserved_no_plaintext_fallback(self):
        directory = self.credential('work')
        (directory / 'credentials.enc').write_text('broken')
        (directory / '.encryption_key').write_text('fake')
        result = self.run_cli('work', 'drive', 'files', 'list')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((directory / 'credentials.enc').read_text(), 'broken')
        self.assertEqual(result.stdout, '')

    def test_login_requires_local_client(self):
        self.assertNotEqual(self.run_cli('work', 'auth', 'login').returncode, 0)
        directory = self.root / 'work'
        directory.mkdir()
        (directory / 'client_secret.json').write_text('{}')
        self.assertEqual(self.run_cli('work', 'auth', 'login', '--scopes', 'example').returncode, 0)

    def test_invalid_plain_oauth_stops(self):
        directory = self.credential('work')
        (directory / 'credentials.json').write_text('{broken')
        result = self.run_cli('work', 'drive', 'files', 'list')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')

    def test_help_without_login_and_setup_blocked(self):
        self.assertEqual(self.run_cli('work', '--help').returncode, 0)
        self.assertNotEqual(self.run_cli('work', 'auth', 'setup').returncode, 0)

@unittest.skipUnless(os.environ.get('GWS_ISOLATED_BINARY'), 'set GWS_ISOLATED_BINARY to test the built binary')
class RealBinary(unittest.TestCase):
    def test_dotenv_is_ignored_in_current_and_parent_directories(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            selected = root / 'selected'
            selected.mkdir()
            child = root / 'child'
            child.mkdir()
            env = {k: v for k, v in os.environ.items()
                   if not k.startswith(('GOOGLE_', 'CLOUDSDK_', 'GCLOUD_'))}
            env.update(HOME=temp, GOOGLE_WORKSPACE_CLI_CONFIG_DIR=str(selected),
                       GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND='file')
            for dotenv in (root / '.env', child / '.env'):
                dotenv.write_text('GOOGLE_WORKSPACE_CLI_TOKEN=poison\nGOOGLE_WORKSPACE_CLI_CLIENT_ID=poison\nGOOGLE_WORKSPACE_CLI_CLIENT_SECRET=poison\n')
                result = subprocess.run([os.environ['GWS_ISOLATED_BINARY'], 'auth', 'status'],
                                        cwd=child, env=env, text=True, capture_output=True, timeout=15)
                self.assertEqual(result.returncode, 0, result.stderr)
                status = json.loads(result.stdout)
                self.assertEqual(status['credential_source'], 'none')
                self.assertFalse(status.get('token_env_var', False))
                self.assertEqual(status['encrypted_credentials'], str(selected / 'credentials.enc'))

    def test_corrupt_export_fails_without_deleting_file(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            encrypted = directory / 'credentials.enc'
            encrypted.write_bytes(b'broken')
            env = dict(os.environ, GOOGLE_WORKSPACE_CLI_CONFIG_DIR=temp,
                       GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND='file')
            result = subprocess.run([os.environ['GWS_ISOLATED_BINARY'], 'auth', 'export'],
                                    env=env, text=True, capture_output=True, timeout=15)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(encrypted.read_bytes(), b'broken')

if __name__ == '__main__':
    unittest.main()
