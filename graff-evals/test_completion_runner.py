"""The completion suite must not turn infrastructure failure into a pass."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import time
from unittest.mock import patch

ROOT=Path(__file__).resolve().parent
sys.path.insert(0,str(ROOT))
spec=importlib.util.spec_from_file_location('completion_runner',ROOT/'run.py')
runner=importlib.util.module_from_spec(spec);spec.loader.exec_module(runner)


class CompletionTests(unittest.TestCase):
    def test_strict_setup_stops_before_candidate(self):
        with tempfile.TemporaryDirectory() as tmp:
            task={'setup':['exit 7'],'strict_setup':True}
            with self.assertRaises(subprocess.CalledProcessError):
                runner.materialize(task,str(Path(tmp)/'exam'))

    def score(self,code,check='exit 0',timeout=5):
        with tempfile.TemporaryDirectory() as tmp, patch.object(runner,'SANDBOX_DIR',tmp):
            harness={'cmd':[sys.executable,'-c',code],'answer':'stdout','usage':''}
            task={'id':'fixture','suite':'completion','prompt':'fixture','check':check,'requires_clean_exit':True,'timeout_s':timeout}
            return runner.one_run('fixture',harness,task,'none',1)

    def test_green_artifacts_do_not_excuse_nonzero_exit(self):
        result=self.score('raise SystemExit(3)')
        self.assertTrue(result['artifact_ok']);self.assertFalse(result['outcome_ok'])

    def test_green_artifacts_do_not_excuse_timeout(self):
        result=self.score('import time; time.sleep(5)',timeout=.1)
        self.assertTrue(result['artifact_ok']);self.assertTrue(result['timed_out']);self.assertFalse(result['outcome_ok'])

    def test_unterminated_output_cannot_block_deadline(self):
        started=time.monotonic()
        result=self.score('import time; print("partial",end="",flush=True); time.sleep(5)',timeout=.1)
        self.assertTrue(result['timed_out']);self.assertLess(time.monotonic()-started,2)

    def test_process_pwd_matches_exam(self):
        result=self.score('import os; assert os.path.samefile(os.getcwd(), os.environ["PWD"])')
        self.assertTrue(result['outcome_ok'])

    def test_clean_exit_requires_green_artifacts(self):
        self.assertFalse(self.score('print("done")',check='exit 1')['outcome_ok'])
        self.assertTrue(self.score('print("done")')['outcome_ok'])

if __name__=='__main__':unittest.main()
