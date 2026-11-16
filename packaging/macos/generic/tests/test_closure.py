import importlib.util
import os
import plistlib
import struct
import sys
import tempfile
import unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from closure import ClosureError, audit, inventory, parse_macho, validate_bundle
from build import bounded_jobs, normalized_environment, freeze_helpers, copy_tree, run, BuildError

def string_command(kind,text):
    raw=text.encode()+b'\0'; size=(12+len(raw)+7)//8*8
    return struct.pack('<III',kind,size,12)+raw+b'\0'*(size-12-len(raw))

def macho(arch=0x100000c,minimum=(14<<16)|(4<<8),loads=(),rpaths=(),filetype=2):
    cmds=[struct.pack('<IIIIII',0x32,24,1,minimum,26<<16,0)]
    cmds += [string_command(0xc,p) for p in loads]
    cmds += [string_command(0x8000001c,p) for p in rpaths]
    return struct.pack('<8I',0xfeedfacf,arch,0,filetype,len(cmds),sum(map(len,cmds)),0,0)+b''.join(cmds)

class ClosureTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(); self.root=Path(self.tmp.name)
    def tearDown(self): self.tmp.cleanup()
    def put(self,name,data):
        p=self.root/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(data);p.chmod(0o644);return p
    def test_arm_minimum(self):
        self.put('bin/tool',macho())
        result=audit(self.root)
        self.assertEqual(result['minimum_macos'],'14.4.0');self.assertEqual(result['clean_machine_runtime'],'unverified')
    def test_highest_component_floor(self):
        self.put('one',macho());self.put('two',macho(minimum=15<<16))
        self.assertEqual(audit(self.root)['minimum_macos'],'15.0.0')
    def test_external_load_rejected(self):
        self.put('one',macho(loads=['/opt/homebrew/lib/a.dylib']))
        with self.assertRaises(ClosureError):audit(self.root)
    def test_system_prefix_traversal_rejected(self):
        self.put('one',macho(loads=['/usr/lib/../../tmp/injected.dylib']))
        with self.assertRaises(ClosureError):audit(self.root)
    def test_embedded_loader_environment_rejected(self):
        raw=macho();cmd=string_command(0x27,'DYLD_LIBRARY_PATH=/tmp/foreign')
        header=list(struct.unpack('<8I',raw[:32]));header[4]+=1;header[5]+=len(cmd)
        p=self.put('one',struct.pack('<8I',*header)+raw[32:]+cmd)
        with self.assertRaises(ClosureError):parse_macho(p)
    def test_missing_arm64_rejected(self):
        self.put('one',macho(arch=0x1000007))
        with self.assertRaises(ClosureError):audit(self.root)
    def test_system_load_permitted(self):
        self.put('one',macho(loads=['/usr/lib/libSystem.B.dylib']))
        self.assertEqual(audit(self.root)['static_status'],'passed')
    def test_loader_relative_dependency(self):
        self.put('bin/one',macho(loads=['@loader_path/../lib/two']))
        self.put('lib/two',macho(filetype=6))
        self.assertEqual(len(audit(self.root)['components']),2)
    def test_bare_loader_rpath_for_python_bundle(self):
        self.put('bin/one',macho(loads=['@rpath/two'],rpaths=['@loader_path']))
        self.put('bin/two',macho(filetype=6))
        self.assertEqual(len(audit(self.root)['components']),2)
    def test_unicode_space_loader_path(self):
        self.put('оператор с пробелами/bin/one',macho(loads=['@loader_path/../lib/два']))
        self.put('оператор с пробелами/lib/два',macho(filetype=6))
        self.assertEqual(len(audit(self.root)['components']),2)
    def test_external_rpath_rejected_even_unused(self):
        self.put('one',macho(rpaths=['/opt/homebrew/lib']))
        with self.assertRaises(ClosureError):audit(self.root)
    def test_contained_framework_links(self):
        self.put('Qt.framework/Versions/A/Qt',b'hi')
        (self.root/'Qt.framework/Versions/Current').symlink_to('A')
        (self.root/'Qt.framework/Qt').symlink_to('Versions/Current/Qt')
        self.assertEqual(len([x for x in inventory(self.root) if x['type']=='symlink']),2)
    def test_escaping_link_rejected(self):
        (self.root/'bad').symlink_to('../somewhere')
        with self.assertRaises(ClosureError):inventory(self.root)
    def test_case_collision_rejected(self):
        # APFS case-insensitive volumes cannot materialize this; same logic is exercised via Unicode when possible.
        self.put('One',b'1');self.put('one',b'2')
        if len(list(self.root.iterdir()))==1:self.skipTest('case-insensitive filesystem')
        with self.assertRaises(ClosureError):inventory(self.root)
    def test_world_writable_rejected(self):
        p=self.put('one',b'1');p.chmod(0o666)
        with self.assertRaises(ClosureError):inventory(self.root)
    def test_malformed_load_bounds(self):
        p=self.put('one',macho()[:-1])
        with self.assertRaises(ClosureError):parse_macho(p)
    def test_fat_missing_slice(self):
        raw=macho();data=struct.pack('>II',0xcafebabe,1)+struct.pack('>IIIII',0x100000c,0,4096,len(raw),12)+b'\0'*(4096-28)+raw
        p=self.put('one',data);self.assertEqual(parse_macho(p)[0]['arch'],'arm64')
    def test_metadata_empty_versions_rejected(self):
        p=self.root/'a.app/Contents';(p/'MacOS').mkdir(parents=True);(p/'MacOS/watchtower').write_bytes(b'')
        plist={'CFBundleIdentifier':'com.cilexvision.watchtower','CFBundleExecutable':'watchtower','CFBundleVersion':'','CFBundleShortVersionString':'1.2.3','CFBundleURLTypes':[{'CFBundleURLSchemes':['cilex']}]}
        with (p/'Info.plist').open('wb') as f:plistlib.dump(plist,f)
        with self.assertRaises(ClosureError):validate_bundle(p.parent)
    def test_environment_does_not_inherit_secrets(self):
        os.environ['GH_TOKEN']='test-secret';os.environ['DYLD_LIBRARY_PATH']='/bad'
        env=normalized_environment({},self.root,self.root)
        self.assertNotIn('GH_TOKEN',env);self.assertNotIn('DYLD_LIBRARY_PATH',env);self.assertEqual(env['PATH'],'/usr/bin:/bin:/usr/sbin:/sbin')
    def test_memory_bounded_jobs(self):
        self.assertEqual(bounded_jobs(8*1024**3,16),4);self.assertEqual(bounded_jobs(1024,16),1)
        with self.assertRaises(Exception):bounded_jobs(1024,16,0)
    def test_freezing_bootstrap_has_unique_stable_provenance(self):
        import shutil
        source=self.root/'source/generic';source.mkdir(parents=True)
        (source/'deploy.py').write_text('print("controller")\n')
        (source/'assets').mkdir()
        (source/'assets/install.tiff').write_bytes(b'fixture Retina artwork')
        entry=source.parent/'deploy-watchtower.sh';entry.write_text('#!/bin/bash\n');entry.chmod(0o755)
        first=self.root/'first/generic';first.parent.mkdir()
        original=freeze_helpers(source,first)
        self.assertEqual((first/'assets/install.tiff').read_bytes(),b'fixture Retina artwork')
        shutil.copy2(entry,first.parent/entry.name)
        second=self.root/'second';second.mkdir()
        repeated=freeze_helpers(first,second/'generic')
        self.assertEqual(original,repeated)
        self.assertEqual(len(repeated['files']),len({item['path'] for item in repeated['files']}))
    def test_staging_copy_normalizes_generated_group_write(self):
        source=self.root/'generated';source.mkdir()
        item=source/'Info.plist';item.write_text('compiler output');item.chmod(0o664)
        copy_tree(source,self.root/'staging')
        self.assertEqual(item.stat().st_mode & 0o777,0o664)
        self.assertEqual((self.root/'staging/Info.plist').stat().st_mode & 0o777,0o644)
        inventory(self.root/'staging')
    def test_command_log_bounds_keep_beginning_and_end(self):
        script='import os;os.write(1,b"BEGIN\\n"+b"x"*200000+b"\\nEND\\n")'
        text=run([sys.executable,'-I','-c',script],self.root,os.environ.copy(),self.root/'logs','noisy',log_limit=1024)
        self.assertTrue(text.startswith('BEGIN\n'));self.assertTrue(text.endswith('\nEND\n'))
        self.assertIn('deployment log truncated',text)
        self.assertLess((self.root/'logs/noisy.log').stat().st_size,1200)
    def test_command_log_keeps_small_output_exactly(self):
        text=run([sys.executable,'-I','-c','print("exact output")'],self.root,os.environ.copy(),self.root/'logs','small',log_limit=1024)
        self.assertEqual(text,'exact output\n')
    def test_command_timeout_is_bounded_and_keeps_diagnostics(self):
        import time
        started=time.monotonic()
        with self.assertRaisesRegex(BuildError,'timed out'):
            run([sys.executable,'-I','-c','import time;print("started",flush=True);time.sleep(10)'],self.root,os.environ.copy(),self.root/'logs','timeout',timeout=0.2)
        self.assertLess(time.monotonic()-started,3)
        self.assertIn('started',(self.root/'logs/timeout.log').read_text())

if __name__=='__main__': unittest.main()
