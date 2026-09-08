import importlib.util
from datetime import datetime
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('build_metadata', Path(__file__).parents[2] / 'scripts/build-metadata.py')
metadata = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metadata)

class FrozenTime(datetime):
    @classmethod
    def now(cls):
        return cls(2026, 9, 8, 15, 45)

class BuildMetadataTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.project = Path(self.directory.name) / 'project.pbxproj'
        self.source = Path(self.directory.name) / 'AppModel.swift'
        self.project.write_text('CURRENT_PROJECT_VERSION = 202607141338;\nMARKETING_VERSION = 0.3.32;\n' * 2)
        self.source.write_text('static let buildNumber = "202607070949"\nstatic let marketingVersion = "0.3.32"')
        for name, value in [('PROJECT', self.project), ('SOURCE', self.source), ('datetime', FrozenTime)]:
            patcher = patch.object(metadata, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def run_metadata(self, *args):
        with patch('sys.argv', ['build-metadata.py', *args]):
            metadata.main()

    def test_mismatch_is_rejected(self):
        with self.assertRaisesRegex(SystemExit, 'build numbers differ'):
            self.run_metadata()

    def test_stamp_uses_clock_and_synchronizes_all_configurations(self):
        self.run_metadata('--stamp', '--version', '0.4.0')
        self.assertEqual(self.project.read_text().count('CURRENT_PROJECT_VERSION = 202609081545;'), 2)
        self.assertIn('static let buildNumber = "202609081545"', self.source.read_text())
        self.run_metadata('--version', '0.4.0')
        with self.assertRaisesRegex(SystemExit, 'Tag and app versions differ'):
            self.run_metadata('--version', '0.4.1')

    def test_stamp_never_increments_an_old_timestamp(self):
        self.run_metadata('--stamp')
        self.assertNotIn('202607141339', self.project.read_text())
        self.assertIn('202609081545', self.project.read_text())

if __name__ == '__main__':
    unittest.main()
