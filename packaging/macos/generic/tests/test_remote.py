"""SSH construction and uncertain-outcome fixtures; no network or target writes."""
import json
import os
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest import mock
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import remote
from common import DeployError, RunRecord, atomic_json, digest


class RemoteTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix="remote Тест ")
        self.root=Path(self.tmp.name).resolve()
        self.known=self.root/"known hosts"; self.known.write_text("verified host fixture\n"); self.known.chmod(0o600)
        self.key=self.root/"private key"; self.key.write_text("fixture-only\n"); self.key.chmod(0o600)
        self.options={"target_host":"office-mac.local","ssh_user":"operator","desktop_user":"operator",
                      "expected_target_id":"a"*64,"ssh_known_hosts":str(self.known),"ssh_identity_file":str(self.key),
                      "package":str(self.root/"package.tar.gz"),"package_sha256":"b"*64,"dependencies":"manual"}
    def tearDown(self): self.tmp.cleanup()

    def test_explicit_authentication_and_strict_host_keys(self):
        info=remote.ssh_options(self.options)
        flags=info['flags']
        for value in ('BatchMode=yes','StrictHostKeyChecking=yes','ForwardAgent=no','IdentityAgent=none','IdentitiesOnly=yes','PasswordAuthentication=no'):
            self.assertIn(value,flags)
        self.assertIn('UserKnownHostsFile="'+str(self.known)+'"',flags)
        self.assertEqual(flags[:2],['-F','/dev/null'])
        self.assertNotIn('GH_TOKEN',info['env'])
        self.assertNotIn('GITHUB_TOKEN',info['env'])

    def test_missing_authentication_fails_without_prompt(self):
        options=dict(self.options); options.pop('ssh_identity_file')
        with self.assertRaises(DeployError) as error: remote.ssh_options(options)
        self.assertEqual(error.exception.finding,'remote.authentication')

    def test_unverified_host_key_fails(self):
        self.known.unlink()
        with self.assertRaises(DeployError) as error: remote.ssh_options(self.options)
        self.assertEqual(error.exception.finding,'remote.host_keys')

    def test_missing_target_identity_fails(self):
        options=dict(self.options); options.pop('expected_target_id')
        with self.assertRaises(DeployError) as error: remote.ssh_options(options)
        self.assertEqual(error.exception.finding,'remote.target_identity')

    def test_host_shell_injection_rejected(self):
        for value in ('host;uname','$(id)','-oProxyCommand=bad','user@host:/tmp'):
            with self.subTest(value=value),self.assertRaises(DeployError):
                remote.ssh_options(dict(self.options,target_host=value))

    def test_sftp_spaces_unicode_and_quotes_are_escaped(self):
        path='/Users/Оператор/Downloads/a "quoted" \\ package.tar.gz'
        quoted=remote.sftp_quote(path)
        self.assertEqual(quoted,'"/Users/Оператор/Downloads/a \\"quoted\\" \\\\ package.tar.gz"')
        with self.assertRaises(DeployError): remote.sftp_quote('/tmp/a\nput secret')

    def test_target_identity_mismatch_fails(self):
        info=remote.ssh_options(self.options)
        with mock.patch.object(remote,'ssh',return_value=types.SimpleNamespace(stdout='c'*64+'\n501\noperator\n/Users/operator\n')):
            with self.assertRaises(DeployError) as error: remote.probe(info)
        self.assertEqual(error.exception.finding,'remote.identity_changed')

    def test_probe_accepts_unicode_target_home(self):
        info=remote.ssh_options(self.options)
        with mock.patch.object(remote,'ssh',return_value=types.SimpleNamespace(stdout='a'*64+'\n501\noperator\n/Users/Оператор с пробелом\n')):
            result=remote.probe(info)
        self.assertEqual(result['home'],'/Users/Оператор с пробелом')

    def test_transfer_never_sends_github_secret(self):
        info=remote.ssh_options(self.options)
        with mock.patch.dict(os.environ,{'GH_TOKEN':'do-not-copy-fixture'}),mock.patch.object(remote,'command') as command:
            remote.transfer(info,self.root/'package with spaces.tar.gz','/Users/Оператор/Cache/package.tar.gz')
        args,kwargs=command.call_args
        self.assertEqual(args[0][0],'/usr/bin/sftp')
        self.assertNotIn('do-not-copy-fixture',repr((args,kwargs)))
        self.assertIn('put "',kwargs['input'])

    def record(self):
        return RunRecord(self.root/'runs',{'fixture':True},{'identity':'a'*64},'c'*64)

    def test_dryrun_makes_no_network_calls(self):
        record=self.record()
        with mock.patch.object(remote,'command') as command:
            result=remote.run(dict(self.options,dry_run=True),record)
        command.assert_not_called()
        self.assertEqual(result['installation'],'Planned')

    def test_offline_remote_request_refused_before_network(self):
        record=self.record()
        with mock.patch.object(remote,'command') as command:
            with self.assertRaises(DeployError) as error: remote.run(dict(self.options,dependencies='offline'),record)
        command.assert_not_called()
        self.assertEqual(error.exception.finding,'remote.offline')

    def test_alternate_account_blocked_before_network(self):
        record=self.record()
        with mock.patch.object(remote,'command') as command:
            with self.assertRaises(DeployError) as error: remote.run(dict(self.options,desktop_user='another'),record)
        command.assert_not_called()
        self.assertEqual(error.exception.finding,'remote.authorization')

    def uncertain_record(self):
        record=self.record(); record.data['remote_staging']='/Users/operator/Library/Caches/CilexWatchtower/Deploy/'+record.data['run_id']
        record.data['remote_execution_requested']=True
        # An outer controller may replace the phase; persistent execution flag wins.
        record.phase('complete')
        selected=remote.request_options(self.options)
        request={'schema_version':1,'run_id':record.data['run_id'],'target_id':'a'*64,'package_sha256':'b'*64,
                 'options_sha256':digest(selected),'options':selected}
        atomic_json(record.root/'remote-request.json',request)
        return record,request

    def test_resume_absent_result_never_reruns_install(self):
        record,request=self.uncertain_record()
        with mock.patch.object(remote,'probe',return_value={'target_id':'a'*64}),mock.patch.object(remote,'fetch_result',return_value=None),mock.patch.object(remote,'transfer') as transfer,mock.patch.object(remote,'ssh') as ssh:
            result=remote.run(self.options,record)
        transfer.assert_not_called(); ssh.assert_not_called()
        self.assertEqual(result['installation'],'Unknown')
        self.assertTrue(record.data['remote_execution_requested'])

    def test_resume_recovers_only_bound_result(self):
        record,request=self.uncertain_record()
        envelope={k:request[k] for k in ('run_id','target_id','package_sha256','options_sha256')}
        envelope.update(schema_version=1,result={'installation':'Installed','startup':'StartupUnverified','full_success':False})
        with mock.patch.object(remote,'probe',return_value={'target_id':'a'*64}),mock.patch.object(remote,'fetch_result',return_value=envelope),mock.patch.object(remote,'transfer') as transfer,mock.patch.object(remote,'ssh') as ssh:
            result=remote.run(self.options,record)
        transfer.assert_not_called(); ssh.assert_not_called()
        self.assertEqual(result['installation'],'Installed')
        self.assertFalse(result['full_success'])
        self.assertTrue((record.root/'remote-result.json').is_file())

    def test_resume_package_change_refused(self):
        record,request=self.uncertain_record()
        with mock.patch.object(remote,'probe',return_value={'target_id':'a'*64}),mock.patch.object(remote,'fetch_result') as fetch:
            with self.assertRaises(DeployError) as error: remote.run(dict(self.options,package_sha256='d'*64),record)
        fetch.assert_not_called()
        self.assertEqual(error.exception.finding,'remote.resume_binding')

    def test_cross_run_result_refused(self):
        request={'run_id':'expected','target_id':'a'*64,'package_sha256':'b'*64,'options_sha256':'c'*64}
        result=dict(request,schema_version=1,result={},run_id='other-run')
        with self.assertRaises(DeployError) as error: remote.checked_result(result,request)
        self.assertEqual(error.exception.finding,'remote.result_binding')

    def test_target_result_permissions_checked_before_read(self):
        info=remote.ssh_options(self.options)
        with mock.patch.object(remote,'ssh',return_value=types.SimpleNamespace(returncode=45,stdout='')) as ssh:
            with self.assertRaises(DeployError): remote.fetch_result(info,'/Users/operator/Cache/run')
        script=ssh.call_args.args[1]
        self.assertIn('[ ! -L "$p" ]',script)
        self.assertIn('= 600',script)
        self.assertIn('/usr/bin/id -u',script)

    def test_remote_request_does_not_accept_secrets_or_ssh_inputs(self):
        selected=remote.request_options(dict(self.options,gh_token='never-copy',ssh_private_key='secret',backend_url='https://backend.example'))
        self.assertNotIn('gh_token',selected)
        self.assertNotIn('ssh_private_key',selected)
        self.assertNotIn('ssh_user',selected)
        self.assertEqual(selected['backend_url'],'https://backend.example')
        self.assertTrue(selected['noninteractive'])

if __name__=='__main__': unittest.main()
