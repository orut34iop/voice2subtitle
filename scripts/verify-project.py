#!/usr/bin/env python3
"""Ensure both build systems include the same sources and the Xcode scheme actually runs tests."""
from pathlib import Path
import json
import subprocess
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parent.parent
project = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(root / 'v2s.xcodeproj/project.pbxproj')]))
objects = project['objects']
app = next(o for o in objects.values() if o.get('isa') == 'PBXNativeTarget' and o.get('name') == 'v2s')
test_id, tests = next((i, o) for i, o in objects.items() if o.get('isa') == 'PBXNativeTarget' and o.get('name') == 'v2sTests')

def filenames(target):
    return {Path(objects[objects[file]['fileRef']]['path']).name
            for phase in target['buildPhases'] if objects[phase]['isa'] == 'PBXSourcesBuildPhase'
            for file in objects[phase]['files']}

expected_sources = {p.name for p in (root / 'Sources/V2SApp').rglob('*.swift')}
expected_tests = {p.name for p in (root / 'Tests/V2STests').glob('*.swift')}
assert filenames(app) == expected_sources, f'App source mismatch: {filenames(app) ^ expected_sources}'
assert filenames(tests) == expected_tests, f'Test source mismatch: {filenames(tests) ^ expected_tests}'
scheme = ET.parse(root / 'v2s.xcodeproj/xcshareddata/xcschemes/v2s.xcscheme')
assert any(ref.get('BlueprintIdentifier') == test_id for ref in scheme.findall('.//TestableReference[@skipped="NO"]/BuildableReference'))
assert scheme.find('.//TestAction/EnvironmentVariables/EnvironmentVariable[@key="V2S_TESTING"][@value="1"]') is not None
print(f'Xcode and SwiftPM: {len(expected_sources)} app sources, {len(expected_tests)} test files; test host isolated.')
