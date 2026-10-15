import hashlib
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest import mock
import zipfile
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import dependencies as deps
from common import DeployError


class DependencyTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='Deps тест ')
        self.root=Path(self.tmp.name).resolve()
        self.payload=b'official fixture bytes'
        self.package={'id':'Fixture','version':'1.2.3','kind':'wheel','url':'https://files.pythonhosted.org/packages/fixture-1.2.3-py3-none-any.whl',
                      'sha256':hashlib.sha256(self.payload).hexdigest(),'download_bytes':len(self.payload)}
        self.options={'cache_dir':str(self.root/'cache'),'dependencies':'auto'}
    def tearDown(self): self.tmp.cleanup()

    def test_catalog_has_official_pinned_versions(self):
        data=deps.catalog()
        self.assertEqual(data['schema_version'],1)
        for package in data['packages']:
            self.assertEqual(len(package['sha256']),64)
            self.assertTrue(package['url'].startswith('https://'))
        self.assertIn('Wheel-pyinstaller',[p['id'] for p in data['packages']])

    def test_assessment_never_creates_directories_or_calls_network(self):
        before=list(self.root.rglob('*'))
        with mock.patch.object(deps,'inspect_toolchain',return_value={'state':'missing'}),mock.patch.object(deps,'command') as command:
            result=deps.assess(dict(self.options,mode='check'))
        command.assert_not_called()
        self.assertEqual(before,list(self.root.rglob('*')))
        self.assertTrue(result['read_only'])
        self.assertTrue(result['licenses'])
        self.assertTrue(result['missing'])

    def test_missing_toolchain_does_not_execute_developer_stub(self):
        with mock.patch.object(deps,'command',return_value=types.SimpleNamespace(returncode=2,stdout='',stderr='')) as command:
            result=deps.inspect_toolchain({})
        self.assertEqual(result['state'],'missing')
        self.assertEqual(command.call_count,1)
        self.assertEqual(command.call_args.args[0],['/usr/bin/xcode-select','-p'])

    def test_tools_json_preserves_python_venv_symlink(self):
        base=self.root/'base-python'; base.write_text('fixture'); base.chmod(0o755)
        venv=self.root/'venv/bin'; venv.mkdir(parents=True)
        python=venv/'python3'; python.symlink_to(base)
        config=self.root/'tools.json'; config.write_text(json.dumps({'tools':{'python':str(python)}}))
        tools,_=deps.selected_tools({'tools_json':str(config)})
        self.assertEqual(tools['python'],str(python))
        self.assertNotEqual(tools['python'],str(base))

    def test_installed_runtime_is_rejected_even_through_symlink(self):
        bundle=self.root/'watchtower.app/Contents/MacOS'; bundle.mkdir(parents=True)
        binary=bundle/'python'; binary.write_text('bad')
        alias=self.root/'selected-python'; alias.symlink_to(binary)
        with self.assertRaises(DeployError) as error: deps.selected_tools({'python':str(alias)})
        self.assertEqual(error.exception.finding,'dependencies.installed_runtime')

    def test_cache_hit_rehashed_and_network_not_called(self):
        path=deps.cache_file(self.package,self.options); path.parent.mkdir(parents=True); path.write_bytes(self.payload)
        with mock.patch.object(deps,'command') as command:
            self.assertEqual(deps.fetch(self.package,self.options),path)
        command.assert_not_called()

    def test_corrupt_cache_never_overridden(self):
        path=deps.cache_file(self.package,self.options); path.parent.mkdir(parents=True); path.write_bytes(b'corrupt')
        with mock.patch.object(deps,'command') as command:
            with self.assertRaises(DeployError) as error: deps.fetch(self.package,dict(self.options,accept_findings=['dependencies.cache_integrity']))
        command.assert_not_called()
        self.assertEqual(error.exception.finding,'dependencies.cache_integrity')
        self.assertEqual(path.read_bytes(),b'corrupt')

    def test_cached_symlink_rejected(self):
        path=deps.cache_file(self.package,self.options); path.parent.mkdir(parents=True)
        target=self.root/'target'; target.write_bytes(self.payload); path.symlink_to(target)
        with self.assertRaises(DeployError) as error: deps.fetch(self.package,self.options)
        self.assertEqual(error.exception.finding,'dependencies.cache_integrity')

    def test_offline_missing_precise_path_and_zero_network_writes(self):
        before=list(self.root.rglob('*'))
        with mock.patch.object(deps,'command') as command:
            with self.assertRaises(DeployError) as error: deps.fetch(self.package,dict(self.options,dependencies='offline'))
        command.assert_not_called()
        self.assertEqual(error.exception.finding,'dependencies.offline_missing')
        self.assertEqual(error.exception.details['missing_files'],[str(deps.cache_file(self.package,self.options))])
        self.assertEqual(before,list(self.root.rglob('*')))

    def test_manual_missing_does_not_download(self):
        with mock.patch.object(deps,'command') as command:
            with self.assertRaises(DeployError) as error: deps.fetch(self.package,dict(self.options,dependencies='manual'))
        command.assert_not_called()
        self.assertEqual(error.exception.finding,'dependencies.manual_missing')

    def fake_download(self,argv,**kwargs):
        Path(argv[argv.index('--output')+1]).write_bytes(self.payload)
        return types.SimpleNamespace(returncode=0,stdout='200',stderr='')

    def test_download_verified_before_cache_admission(self):
        with mock.patch.object(deps,'command',side_effect=self.fake_download) as command:
            path=deps.fetch(self.package,self.options)
        self.assertEqual(path.read_bytes(),self.payload)
        self.assertEqual(path.stat().st_mode & 0o777,0o600)
        args=command.call_args.args[0]
        self.assertIn('--proto-redir',args)
        self.assertNotIn('sh',args)
        self.assertTrue(command.call_args.kwargs['network'])

    def test_download_hash_mismatch_fails_and_retains_partial(self):
        def bad(argv,**kwargs):
            Path(argv[argv.index('--output')+1]).write_bytes(b'bad')
            return types.SimpleNamespace(returncode=0,stdout='200',stderr='')
        with mock.patch.object(deps,'command',side_effect=bad):
            with self.assertRaises(DeployError) as error: deps.fetch(self.package,self.options)
        self.assertEqual(error.exception.finding,'dependencies.download_integrity')
        self.assertFalse(deps.cache_file(self.package,self.options).exists())
        self.assertTrue(Path(error.exception.details['path']).exists())

    def test_network_retries_are_bounded(self):
        with mock.patch.object(deps,'command',return_value=types.SimpleNamespace(returncode=28,stdout='000',stderr='timeout')) as command,mock.patch.object(deps.time,'sleep'):
            with self.assertRaises(DeployError) as error: deps.fetch(self.package,self.options)
        self.assertEqual(command.call_count,3)
        self.assertEqual(error.exception.finding,'dependencies.download_connectivity')
        self.assertEqual(error.exception.details['attempts'],3)

    def test_tls_authorization_proxy_unavailable_are_distinct(self):
        cases=[(60,0,'tls'),(22,401,'authorization'),(5,0,'proxy'),(22,407,'proxy'),(22,404,'unavailable_version')]
        for code,status,expected in cases:
            with self.subTest(expected=expected): self.assertEqual(deps.download_failure(code,status),expected)

    def test_tls_failure_is_not_retried(self):
        with mock.patch.object(deps,'command',return_value=types.SimpleNamespace(returncode=60,stdout='000',stderr='cert')) as command:
            with self.assertRaises(DeployError) as error: deps.fetch(self.package,self.options)
        self.assertEqual(command.call_count,1)
        self.assertEqual(error.exception.finding,'dependencies.download_tls')

    def test_offline_missing_wheels_reported_together(self):
        other=dict(self.package,id='Wheel-other',url='https://files.pythonhosted.org/packages/other.whl')
        packages=[dict(self.package,id='Wheel-fixture'),other]
        with mock.patch.object(deps,'command') as command:
            with self.assertRaises(DeployError) as error: deps.provision_python('/python',packages,dict(self.options,dependencies='offline'),self.root)
        command.assert_not_called()
        self.assertEqual(len(error.exception.details['missing_files']),2)

    def test_zip_traversal_refused(self):
        archive=self.root/'ninja.zip'
        with zipfile.ZipFile(archive,'w') as z:
            z.writestr('../escape',b'bad')
        destination=self.root/'extracted'; destination.mkdir()
        with self.assertRaises(DeployError): deps.extract_ninja(archive,destination)
        self.assertFalse((self.root/'escape').exists())

    def test_zip_symlink_refused(self):
        archive=self.root/'ninja.zip'
        with zipfile.ZipFile(archive,'w') as z:
            entry=zipfile.ZipInfo('ninja'); entry.external_attr=(0o120777<<16); z.writestr(entry,'/outside')
        destination=self.root/'extracted'; destination.mkdir()
        with self.assertRaises(DeployError) as error: deps.extract_ninja(archive,destination)
        self.assertEqual(error.exception.finding,'dependencies.zip_entry')

    def fake_assessment(self):
        tools={}
        for name in deps.REQUIRED:
            path=self.root/name
            if name.endswith('_root') or name=='licenses_dir': path.mkdir()
            else: path.write_text('fixture'); path.chmod(0o755)
            tools[name]=str(path)
        return {'tools':tools,'profile':'fixture','toolchain':{'state':'present'},'findings':[],'observations':{},'licenses':['BSD'],
                'python_prepared':True,'python':{'isolated':True,'version':'3.13.0','versions':{}},'provenance':{},'plan':[],
                'production_security_blocked':True}

    def test_resolve_dryrun_does_not_write(self):
        assessment=self.fake_assessment()
        with mock.patch.object(deps,'assess',return_value=assessment),mock.patch.object(deps,'fetch') as fetch:
            result=deps.resolve({'dry_run':True},self.root/'does-not-exist')
        fetch.assert_not_called()
        self.assertFalse((self.root/'does-not-exist').exists())
        self.assertTrue(result['read_only'])

    def test_local_tool_receipt_requires_explicit_acceptance(self):
        assessment=self.fake_assessment()
        with mock.patch.object(deps,'assess',return_value=assessment):
            with self.assertRaises(DeployError) as error: deps.resolve({'tools_json':'selected.json','development':True},self.root/'run')
        self.assertEqual(error.exception.finding,deps.LOCAL_FINDING)

    def test_historical_python_production_is_not_overridable(self):
        assessment=self.fake_assessment()
        with mock.patch.object(deps,'assess',return_value=assessment):
            with self.assertRaises(DeployError) as error: deps.resolve({'tools_json':'selected.json','accept_findings':[deps.LOCAL_FINDING,'dependencies.python_security'],'accept_licenses':True},self.root/'run')
        self.assertEqual(error.exception.finding,'dependencies.python_security')

    def test_explicit_license_decision_required(self):
        assessment=self.fake_assessment()
        with mock.patch.object(deps,'assess',return_value=assessment):
            with self.assertRaises(DeployError) as error: deps.resolve({'tools_json':'selected.json','accept_findings':[deps.LOCAL_FINDING],'development':True},self.root/'run')
        self.assertEqual(error.exception.finding,'dependencies.licenses')

    def test_development_local_tools_get_exact_receipt(self):
        assessment=self.fake_assessment()
        options={'tools_json':'selected.json','accept_findings':[deps.LOCAL_FINDING],'development':True,'accept_licenses':True}
        with mock.patch.object(deps,'assess',return_value=assessment):
            result=deps.resolve(options,self.root/'run')
        self.assertEqual(result['tools'],assessment['tools'])
        self.assertTrue(result['production_security_blocked'])
        self.assertTrue(Path(result['evidence']).is_file())
        self.assertEqual(result['receipts'][0]['finding'],deps.LOCAL_FINDING)

if __name__=='__main__': unittest.main()
