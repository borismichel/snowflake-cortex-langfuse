import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('builder',ROOT/'tools/build_coco_package.py')
builder=importlib.util.module_from_spec(spec);spec.loader.exec_module(builder)

class Package(unittest.TestCase):
    def fixture(self, extra=None, dirty=False):
        data={'VERSION':b'1.2.0\n','LICENSE':b'MIT\n','sql/02d_migration_v12.sql':b'-- migration\n',
              'deploy/coco/02_CONFIG.template.json':b'{"exporter_version":"1.2.0"}',
              '.env':b'PRIVATE','docs/assets/image.png':b'BINARY'}
        data.update(extra or {})
        def git(*args):
            if args[0]=='status':return b' M README.md' if dirty else b''
            if args[0]=='rev-parse':return b'a'*40
            if args[0]=='ls-tree':return '\n'.join(data).encode()
            return data[args[1].split(':',1)[1]]
        return git
    def test_pins_source_excludes_private_and_produces_reproducible_zip(self):
        with tempfile.TemporaryDirectory() as a,tempfile.TemporaryDirectory() as b,patch.object(builder,'git',self.fixture()):
            contents=builder.build(a);builder.build(b)
            self.assertNotIn('reference/.env',contents)
            self.assertNotIn('reference/docs/assets/image.png',contents)
            self.assertEqual(json.loads(contents['02_CONFIG.template.json'])['source_commit'],'a'*40)
            for line in contents['SHA256SUMS'].decode().splitlines():
                sha,name=line.split('  ',1);self.assertEqual(sha,hashlib.sha256(contents[name]).hexdigest())
            name='coco-snowflake-langfuse-v1.2.0.zip'
            self.assertEqual((Path(a)/name).read_bytes(),(Path(b)/name).read_bytes())
    def test_upgrade_has_its_own_interview_and_artifact_names(self):
        extra={'deploy/coco/01_COCO_RUNBOOK.md':b'fresh install',
               'deploy/coco-upgrade/01_COCO_RUNBOOK.md':b'preserve existing state',
               'deploy/coco-upgrade/02_CONFIG.template.json':b'{"exporter_version":"1.2.0","mode":"upgrade"}'}
        with tempfile.TemporaryDirectory() as d,patch.object(builder,'git',self.fixture(extra)):
            contents=builder.build(d,mode='upgrade')
            self.assertEqual(contents['01_COCO_RUNBOOK.md'],b'preserve existing state')
            self.assertEqual(json.loads(contents['SOURCE.json'])['mode'],'upgrade')
            self.assertTrue((Path(d)/'COCO_UPDATE.txt').exists())
            self.assertTrue((Path(d)/'coco-snowflake-langfuse-v1.2.0-upgrade.zip').exists())
            self.assertFalse((Path(d)/'COCO_UPLOAD.txt').exists())
    def test_unknown_mode_fails_without_artifacts(self):
        with tempfile.TemporaryDirectory() as d,patch.object(builder,'git',self.fixture()):
            with self.assertRaises(SystemExit):builder.build(d,mode='unsupported')
            self.assertEqual(list(Path(d).iterdir()),[])
    def test_dirty_worktree_fails_before_writing(self):
        with tempfile.TemporaryDirectory() as d,patch.object(builder,'git',self.fixture(dirty=True)):
            with self.assertRaises(SystemExit):builder.build(d)
            self.assertEqual(list(Path(d).iterdir()),[])
    def test_keys_in_allowlisted_source_are_rejected(self):
        fake=b'sk-lf-'+b'0'*8+b'-'+b'0'*24
        with tempfile.TemporaryDirectory() as d,patch.object(builder,'git',self.fixture({'docs/LEAK.md':fake})):
            with self.assertRaises(SystemExit):builder.build(d)
            self.assertEqual(list(Path(d).iterdir()),[])
