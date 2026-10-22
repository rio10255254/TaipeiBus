#!/usr/bin/env python3
"""Validate the corpus, or turn a real device XCTest JSON attachment into CSV."""
import argparse
import csv
import json
from datetime import datetime
from pathlib import Path

FIELDS = ('destination', 'origin', 'preference', 'time')
ROOT = Path(__file__).resolve().parent


def validate_corpus():
    corpus = json.loads((ROOT / 'journey-corpus.json').read_text())
    cases = corpus['cases']
    assert corpus['schemaVersion'] == 1 and 50 <= len(cases) <= 100
    assert len({row['id'] for row in cases}) == len(cases)
    for row in cases:
        assert 0 < len(row['text']) <= 600
        assert row['scenario'] in {'standard', 'none', 'twoHomes', 'twoOffices', 'named'}
        datetime.fromisoformat(row['now'].replace('Z', '+00:00'))
        assert isinstance(row['expectsQuestion'], bool) and isinstance(row['requiresSavedTool'], bool)
        expectations = [row['expected']]
        if 'followUp' in row:
            assert row['expectsQuestion'] and row['followUp']['optionContains']
            expectations.append(row['followUp']['expected'])
        for expected in expectations:
            assert set(expected) == set(FIELDS)
            assert all(isinstance(expected[key], list) for key in ('destination', 'origin'))
            assert expected['preference'] in {'balanced', 'faster', 'lessWalking', 'fewerTransfers', 'confirm'}
            if expected['time'] not in {'none', 'confirm'}:
                datetime.fromisoformat(expected['time'].replace('Z', '+00:00'))
    for phrase in ('快一點', '臺', '台', '北車', '回家', '明天 9 點前', '從公司到'):
        assert any(phrase in row['text'] for row in cases), phrase
    return corpus


def summarize(report_path, csv_path):
    report = json.loads(report_path.read_text())
    assert report['device'].startswith('iPhone'), 'Expected a physical iPhone report'
    assert report['source']['sourceSHA256'] and report['promptVersion']
    cases = report['cases']
    corpus = validate_corpus()
    assert {row['id'] for row in cases} == {row['id'] for row in corpus['cases']}, 'Incomplete or different corpus'
    with csv_path.open('w', newline='', encoding='utf-8-sig') as output:
        writer = csv.DictWriter(output, fieldnames=['id', 'text', *FIELDS, 'fieldAccuracy', 'questionCorrect',
            'savedToolCorrect', 'elapsedSeconds', 'error', 'observed', 'selectedOption', 'followUpObserved', 'followUpCorrect', 'toolCalls'])
        writer.writeheader()
        for row in cases:
            writer.writerow({
                'id': row['id'], 'text': row['text'],
                **{field: int(row['fieldCorrect'].get(field, False)) for field in FIELDS},
                **{key: row.get(key, '') for key in ('fieldAccuracy', 'questionCorrect', 'savedToolCorrect', 'elapsedSeconds', 'error', 'selectedOption')},
                **{key: json.dumps(row.get(key), ensure_ascii=False) for key in ('observed', 'followUpObserved', 'followUpCorrect', 'toolCalls')},
            })
    for field in FIELDS:
        correct = sum(row['fieldCorrect'].get(field, False) for row in cases)
        print(f'{field}: {correct}/{len(cases)} ({correct / len(cases):.1%})')
    print(f'CSV: {csv_path}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('report', nargs='?', type=Path)
    parser.add_argument('--csv', type=Path, default=Path('journey-device-results.csv'))
    args = parser.parse_args()
    corpus = validate_corpus()
    if args.report:
        summarize(args.report, args.csv)
    else:
        print(f"Corpus validated: {len(corpus['cases'])} utterances. No model inference or accuracy measured.")
