import copy
import json
import unittest
from pathlib import Path
from score import score, percentile

CASES = json.loads((Path(__file__).parent / 'cases.json').read_text())


def row(case, **overrides):
    e = case['expected']
    value = {'variant': 'test', 'case_id': case['id'], 'operation': e['operation'],
             'time_scope': e['time_scope'], 'status': e['status'], 'returned_source_ids': e['source_ids'],
             'judgments': {'retrieval': True, 'evidence': True, 'spoken': True},
             'latency_ms': 1000, 'timeout': False, 'fallback': False}
    value.update(overrides)
    return value


class ScoringTest(unittest.TestCase):
    def test_timeout_is_miss_even_when_marked_correct(self):
        report = score(CASES, [row(CASES['cases'][0], timeout=True)])
        self.assertFalse(any(report['cases'][0]['stages'].values()))
        self.assertEqual(report['variants']['test']['grounded_answer_passes'], 0)

    def test_ineligible_source_fails_retrieval_and_evidence(self):
        case = next(c for c in CASES['cases'] if c['id'] == 'ineligible')
        result = score(CASES, [row(case, returned_source_ids=['x1'])])['cases'][0]
        self.assertEqual(result['bad_sources'], ['x1'])
        self.assertFalse(result['stages']['retrieval'])
        self.assertFalse(result['stages']['evidence'])

    def test_separate_stages_and_missing_cohort(self):
        case = CASES['cases'][0]
        result = score(CASES, [row(case, time_scope='previous', judgments={'retrieval': True, 'evidence': False, 'spoken': True})])
        self.assertTrue(result['cases'][0]['stages']['route'])
        self.assertFalse(result['cases'][0]['stages']['time_scope'])
        self.assertFalse(result['cases'][0]['stages']['evidence'])
        self.assertEqual(len(result['variants']['test']['missing_case_ids']), len(CASES['cases']) - 1)

    def test_reject_duplicate_and_bad_boolean(self):
        r = row(CASES['cases'][0])
        with self.assertRaises(ValueError): score(CASES, [r, copy.deepcopy(r)])
        with self.assertRaises(ValueError): score(CASES, [row(CASES['cases'][0], timeout='false')])

    def test_percentile_nearest_rank(self):
        self.assertEqual(percentile([1, 2, 3, 4, 5], .5), 3)
        self.assertEqual(percentile([1, 2, 3, 4, 5], .95), 5)
        self.assertIsNone(percentile([], .95))


if __name__ == '__main__': unittest.main()
