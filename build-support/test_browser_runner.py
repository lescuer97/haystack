"""Fake-mint readiness contract without launching a browser or mint."""
import importlib.util
import io
from pathlib import Path
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location("browser_runner", Path(__file__).with_name("run-browser-tests.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class BrowserRunnerTests(unittest.TestCase):
    def test_bare_local_root_is_forwarded_and_mint_is_cleaned_up(self):
        mint = mock.Mock(stdout=io.StringIO(
            "starting fake mint\nLocal fake mint ready: http://127.0.0.1:18787/ (TEST FUNDS ONLY)\n"))
        with mock.patch.object(runner.sys, "argv", ["runner", "--mint", "mint", "--directory", ".", "--runner", "test.mjs"]), \
             mock.patch.object(runner.shutil, "which", return_value="available"), \
             mock.patch.object(runner.subprocess, "Popen", return_value=mint), \
             mock.patch.object(runner.subprocess, "run") as run:
            runner.main()
        run.assert_called_once_with(
            ["node", str(Path("test.mjs").resolve()), "http://127.0.0.1:18787/"],
            check=True, timeout=300)
        mint.terminate.assert_called_once_with()
        mint.wait.assert_called_once_with(timeout=10)


if __name__ == "__main__":
    unittest.main()
