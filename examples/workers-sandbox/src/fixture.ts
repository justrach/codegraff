// Synthetic task only: no local repository or user data enters the sandbox.
export const implementation = String.raw`def subtract_intervals(allowed, blocked):
    allowed.sort()
    return [(a, b) for a, b in allowed
            if a != b and not any(a <= start < b for start, end in blocked)]
`;

export const tests = String.raw`import copy
import random
import unittest
from intervals import subtract_intervals


def oracle(allowed, blocked):
    points = {x for start, end in allowed for x in range(start, end)}
    points -= {x for start, end in blocked for x in range(start, end)}
    result = []
    for x in sorted(points):
        if result and result[-1][1] == x:
            result[-1] = (result[-1][0], x + 1)
        else:
            result.append((x, x + 1))
    return result


class IntervalTests(unittest.TestCase):
    def check_case(self, allowed, blocked, expected=None):
        before = copy.deepcopy((allowed, blocked))
        answer = subtract_intervals(allowed, blocked)
        self.assertEqual(answer, oracle(*before) if expected is None else expected)
        self.assertEqual((allowed, blocked), before, 'inputs were mutated')
        self.assertTrue(all(a < b for a, b in answer))
        self.assertTrue(all(answer[i][1] < answer[i + 1][0]
                            for i in range(len(answer) - 1)))

    def test_empty(self):
        self.check_case([], [])
        self.check_case([], [(1, 3)])
        self.check_case([(1, 1)], [(2, 2)])

    def test_partial_and_nested(self):
        self.check_case([(0, 10)], [(3, 7)], [(0, 3), (7, 10)])
        self.check_case([(0, 10)], [(2, 3), (7, 8), (1, 9)], [(0, 1), (9, 10)])
        self.check_case([(0, 10)], [(-1, 20)], [])

    def test_normalization(self):
        self.check_case([(4, 10), (0, 4), (2, 8)], [(8, 9), (3, 5), (4, 7)])
        self.check_case([(4, 6), (-9, -2), (1, 5)], [(-5, 2), (3, 4)])

    def test_touching_boundaries(self):
        self.check_case([(0, 5)], [(-4, 0), (5, 8)], [(0, 5)])
        self.check_case([(0, 3), (3, 6)], [(2, 3), (3, 4)], [(0, 2), (4, 6)])

    def test_invalid_input(self):
        for allowed, blocked in [([(4, 1)], []), ([], [(3, -1)]), ([(0, 9)], [(8, 2)])]:
            with self.assertRaises(ValueError):
                subtract_intervals(allowed, blocked)

    def test_no_mutation(self):
        self.check_case([(8, 12), (0, 10)], [(4, 9), (1, 2)])

    def test_randomized(self):
        rng = random.Random(462)
        for case in range(2000):
            def intervals():
                return [tuple(sorted((rng.randrange(-25, 26), rng.randrange(-25, 26))))
                        for _ in range(rng.randrange(10))]
            self.check_case(intervals(), intervals())


if __name__ == '__main__':
    import sys
    result = unittest.TextTestRunner(verbosity=1).run(unittest.defaultTestLoader.loadTestsFromTestCase(IntervalTests))
    print('RANDOMIZED_CASES=2000' if result.wasSuccessful() else 'BASELINE_OR_REPAIR_FAILED')
    sys.exit(0 if result.wasSuccessful() else 1)
`;

export const task = `Repair intervals.py in /tmp/graff-task. Implement subtract_intervals(allowed, blocked) for half-open integer intervals: normalize unsorted, overlapping and touching input intervals, subtract the union of blockers, and return sorted disjoint nonempty intervals. Ignore empty intervals, reject reversed intervals with ValueError, and never mutate inputs. Use sandbox_exec to inspect files, run tests, edit intervals.py, and rerun python3 test_intervals.py. Do not modify tests or install dependencies. You have at most 8 model steps, commands must complete within 30 seconds, and output must stay concise. Finish only after the existing tests pass, then summarize the fix. The workspace is disposable; no credentials are available inside it.`;
