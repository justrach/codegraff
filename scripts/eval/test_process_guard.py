import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from process_guard import run

@unittest.skipUnless(os.name == 'posix', 'POSIX fixture process groups')
class ProcessGuardTests(unittest.TestCase):
    def test_inherited_pipe_cannot_extend_timeout(self):
        with tempfile.TemporaryDirectory() as temp:
            marker = Path(temp)/'child'
            child = "import os,time,pathlib;pathlib.Path('child').write_text(str(os.getpid()));time.sleep(60)"
            parent = "import subprocess,sys;subprocess.Popen([sys.executable,'-c',sys.argv[1]])"
            start = time.monotonic()
            with self.assertRaises(subprocess.TimeoutExpired):
                run([sys.executable,'-c',parent,child],cwd=temp,capture_output=True,timeout=1)
            self.assertLess(time.monotonic()-start,4)
            self.assertTrue(marker.exists())
            state = subprocess.run(['ps','-o','stat=','-p',marker.read_text()],capture_output=True,text=True,timeout=2).stdout.strip()
            self.assertTrue(not state or state.startswith('Z'),state)

    def test_success_and_failure_still_propagate(self):
        self.assertEqual(run([sys.executable,'-c',"print('ok')"],capture_output=True,text=True).stdout,'ok\n')
        with self.assertRaises(subprocess.CalledProcessError):
            run([sys.executable,'-c','raise SystemExit(3)'],check=True)

if __name__ == '__main__': unittest.main()
