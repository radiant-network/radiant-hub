"""Failures of a Cypress report (JUnit XML, mochawesome JSON or HTML), secrets redacted.

Reports carry request bodies (test account, client_secret) and presigned URLs in clear:
only the failure message and the cypress/ stack lines may leave this script.
"""
import html
import json
import re
import sys
import xml.etree.ElementTree as ET
from collections import Counter

REDACT = [
    (re.compile(r'(?i)bearer\s+[A-Za-z0-9._\-]+'), 'Bearer <redacted>'),
    (re.compile(r'eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+'), '<jwt>'),
    (re.compile(r'(https?://[^\s"\'<>?]+)\?[^\s"\'<>]*'), r'\1?<query>'),
    (re.compile(r'(?i)(password|secret|token|X-Amz-[A-Za-z]+)=[^\s&"\']+'), r'\1=<redacted>'),
    (re.compile(r'(?i)"(password|client_secret|access_token|refresh_token|id_token)"\s*:\s*"[^"]*"'), r'"\1":"<redacted>"'),
]


def redact(s):
    for rx, rep in REDACT:
        s = rx.sub(rep, s)
    return s


def stack_of(text):
    lines = [l.strip() for l in (text or '').splitlines()]
    return [redact(l) for l in lines if l.startswith('at ') and 'cypress/' in l and '__cypress/' not in l][:4]


def from_junit(path):
    tests, file_of = [], None
    for suite in ET.parse(path).getroot().iter('testsuite'):
        # mocha-junit-reporter: the suite carrying `file` precedes the suites of that spec
        if suite.get('file'):
            file_of = suite.get('file')
            continue
        for tc in suite.iter('testcase'):
            f = tc.find('failure')
            if f is None:
                f = tc.find('error')
            tests.append({
                'file': file_of, 'test': tc.get('name'), 'time': tc.get('time'), 'at': suite.get('timestamp'),
                'skipped': tc.find('skipped') is not None, 'failed': f is not None,
                'msg': (f.get('message') or '') if f is not None else '',
                'stack': stack_of(f.text) if f is not None else [],
            })
    stamps = sorted(t['at'] for t in tests if t['at'])
    return tests, (stamps[0] if stamps else None), (stamps[-1] if stamps else None)


def from_mochawesome(data):
    tests = []

    def walk(suite, file_of):
        for t in suite.get('tests', []):
            err = t.get('err') or {}
            tests.append({
                'file': file_of, 'test': t.get('fullTitle') or t.get('title'),
                'time': f"{(t.get('duration') or 0) / 1000:.3f}", 'at': None,
                'skipped': bool(t.get('pending') or t.get('skipped')), 'failed': t.get('state') == 'failed',
                'msg': err.get('message') or '', 'stack': stack_of(err.get('estack')),
            })
        for s in suite.get('suites', []):
            walk(s, file_of)

    for result in data.get('results', []):
        walk(result, result.get('file') or result.get('fullFile'))
    stats = data.get('stats', {})
    return tests, stats.get('start'), stats.get('end')


def load(path):
    if path.endswith('.xml'):
        return from_junit(path)
    with open(path, encoding='utf-8') as fh:
        text = fh.read()
    if path.endswith('.html'):
        # marge embeds the mochawesome JSON, HTML-escaped, in a data-raw attribute
        m = re.search(r'data-raw="([^"]*)"', text)
        if not m:
            sys.exit('no data-raw attribute: not a mochawesome HTML report')
        text = html.unescape(m.group(1))
    return from_mochawesome(json.loads(text))


tests, start, end = load(sys.argv[1])
failures = [t for t in tests if t['failed']]
print(f"total={len(tests)} failed={len(failures)} skipped={sum(t['skipped'] for t in tests)} start={start} end={end}")
print('--- failures by spec')
for spec, n in Counter(t['file'] for t in failures).most_common():
    print(f'{n}  {spec}')
print('--- details')
for i, t in enumerate(failures, 1):
    msg = re.sub(r'\s+', ' ', redact(t['msg'].strip()))[:600]
    at = f" at {t['at']}" if t['at'] else ''
    print(f"\n[{i}] {t['file']}\n    test: {t['test']} ({t['time']}s{at})\n    msg: {msg}")
    for s in t['stack']:
        print(f'      {s}')
