#!/usr/bin/env python3
"""Stamp and verify the app's single build identity before any build or release."""
import argparse
from datetime import datetime
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent.parent
PROJECT = ROOT / 'v2s.xcodeproj/project.pbxproj'
SOURCE = ROOT / 'Sources/V2SApp/App/AppModel.swift'

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--stamp', action='store_true')
    parser.add_argument('--version')
    args = parser.parse_args()
    project, source = PROJECT.read_text(), SOURCE.read_text()
    if args.version and not re.fullmatch(r'\d+\.\d+\.\d+', args.version):
        parser.error('version must be x.y.z')
    if args.stamp:
        build = datetime.now().strftime('%Y%m%d%H%M')
        project = re.sub(r'CURRENT_PROJECT_VERSION = [^;]+;', f'CURRENT_PROJECT_VERSION = {build};', project)
        source = re.sub(r'static let buildNumber = "[^"]+"', f'static let buildNumber = "{build}"', source)
        if args.version:
            project = re.sub(r'MARKETING_VERSION = [^;]+;', f'MARKETING_VERSION = {args.version};', project)
            source = re.sub(r'static let marketingVersion = "[^"]+"', f'static let marketingVersion = "{args.version}"', source)
        PROJECT.write_text(project)
        SOURCE.write_text(source)
    build = re.search(r'static let buildNumber = "([^"]+)"', source).group(1)
    version = re.search(r'static let marketingVersion = "([^"]+)"', source).group(1)
    if len(build) != 12 or datetime.strptime(build, '%Y%m%d%H%M').strftime('%Y%m%d%H%M') != build:
        raise SystemExit('Invalid build timestamp')
    if set(re.findall(r'CURRENT_PROJECT_VERSION = ([^;]+);', project)) != {build}:
        raise SystemExit('Xcode and AppModel build numbers differ')
    if set(re.findall(r'MARKETING_VERSION = ([^;]+);', project)) != {version}:
        raise SystemExit('Xcode and AppModel marketing versions differ')
    if args.version and version != args.version:
        raise SystemExit('Tag and app versions differ')
    print(f'v{version} ({build})')

if __name__ == '__main__':
    main()
