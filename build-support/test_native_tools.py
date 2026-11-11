"""Contract tests for the pinned cc-rs 1.11 environment compatibility helpers."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    "native_tools", Path(__file__).with_name("native_tools.py")
)
native_tools = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native_tools)


class PrecedenceTests(unittest.TestCase):
    def test_native_uses_host_forms(self):
        self.assertEqual(
            native_tools.target_env_names(
                "CC", "aarch64-apple-darwin", "aarch64-apple-darwin"
            ),
            [
                "CC_aarch64-apple-darwin",
                "CC_aarch64_apple_darwin",
                "HOST_CC",
                "CC",
            ],
        )

    def test_cross_uses_target_forms(self):
        self.assertEqual(
            native_tools.target_env_names(
                "CC", "x86_64-unknown-linux-gnu", "x86_64-unknown-linux-musl"
            )[2],
            "TARGET_CC",
        )

    def test_hyphen_target_beats_underscore_target_kind_and_generic(self):
        environ = {
            "CC_x86_64-unknown-linux-gnu": "/hyphen/cc",
            "CC_x86_64_unknown_linux_gnu": "/underscore/cc",
            "HOST_CC": "/host/cc",
            "CC": "/generic/cc",
        }
        command = native_tools.effective_tool(
            environ, "CC", "x86_64-unknown-linux-gnu", "x86_64-unknown-linux-gnu"
        )
        self.assertEqual(command.source, "CC_x86_64-unknown-linux-gnu")
        self.assertEqual(command.compiler, "/hyphen/cc")

    def test_underscore_target_beats_host_and_generic(self):
        environ = {
            "CC_x86_64_unknown_linux_gnu": "/underscore/cc",
            "HOST_CC": "/host/cc",
            "CC": "/generic/cc",
        }
        command = native_tools.effective_tool(
            environ, "CC", "x86_64-unknown-linux-gnu", "x86_64-unknown-linux-gnu"
        )
        self.assertEqual(command.source, "CC_x86_64_unknown_linux_gnu")

    def test_kind_beats_generic_and_shadowed_generic_is_ignored(self):
        environ = {"TARGET_CC": "/target/cc", "CC": "/missing/cc"}
        command = native_tools.effective_tool(
            environ, "CC", "x86_64-unknown-linux-gnu", "x86_64-unknown-linux-musl"
        )
        self.assertEqual(command.source, "TARGET_CC")
        self.assertEqual(command.compiler, "/target/cc")

    def test_empty_selected_variable_shadows_lower_precedence(self):
        environ = {"CC_x86_64-unknown-linux-gnu": "  ", "CC": "/generic/cc"}
        self.assertIsNone(
            native_tools.effective_tool(
                environ,
                "CC",
                "x86_64-unknown-linux-gnu",
                "x86_64-unknown-linux-gnu",
            )
        )


class ToolParsingTests(unittest.TestCase):
    def test_exact_path_with_spaces_is_one_argument(self):
        with tempfile.TemporaryDirectory() as directory:
            compiler = Path(directory) / "my cc"
            compiler.write_text("#!/bin/sh\n", encoding="utf-8")
            command = native_tools.parse_tool_command(str(compiler), {})
            self.assertEqual(command.compiler, str(compiler))
            self.assertEqual(command.arguments, ())
            self.assertIsNone(command.wrapper)

    def test_known_wrapper_keeps_underlying_compiler_and_arguments(self):
        command = native_tools.parse_tool_command("sccache cc -m32", {})
        self.assertEqual(command.wrapper, "sccache")
        self.assertEqual(command.compiler, "cc")
        self.assertEqual(command.arguments, ("-m32",))

    def test_custom_wrapper_is_recognized_only_when_declared(self):
        # Without a declaration cc-rs treats the first token as the compiler.
        command = native_tools.parse_tool_command("mywrapper cc", {})
        self.assertIsNone(command.wrapper)
        self.assertEqual(command.compiler, "mywrapper")
        self.assertEqual(command.arguments, ("cc",))
        command = native_tools.parse_tool_command(
            "mywrapper cc", {"CC_KNOWN_WRAPPER_CUSTOM": "mywrapper"}
        )
        self.assertEqual(command.wrapper, "mywrapper")
        self.assertEqual(command.compiler, "cc")

    def test_wrapper_without_compiler_is_rejected(self):
        with self.assertRaisesRegex(native_tools.NativeToolError, "without a compiler"):
            native_tools.parse_tool_command("ccache", {})


class FlagTests(unittest.TestCase):
    def test_flags_combine_generic_then_kind_then_specific(self):
        environ = {
            "CFLAGS": "-generic",
            "HOST_CFLAGS": "-host",
            "CFLAGS_aarch64_apple_darwin": "-underscore",
            "CFLAGS_aarch64-apple-darwin": "-hyphen",
        }
        self.assertEqual(
            native_tools.effective_flags(
                environ, "CFLAGS", "aarch64-apple-darwin", "aarch64-apple-darwin"
            ),
            ["-generic", "-host", "-underscore", "-hyphen"],
        )

    def test_shell_escaped_flags_are_parsed_once(self):
        environ = {
            "CFLAGS": '-isysroot "/SDK with spaces"',
            "CC_SHELL_ESCAPED_FLAGS": "1",
        }
        self.assertEqual(
            native_tools.effective_flags(
                environ, "CFLAGS", "aarch64-apple-darwin", "aarch64-apple-darwin"
            ),
            ["-isysroot", "/SDK with spaces"],
        )

    def test_unclosed_shell_escaped_flags_are_rejected(self):
        with self.assertRaisesRegex(native_tools.NativeToolError, "could not be parsed"):
            native_tools.flag_settings(
                {"CFLAGS": '"unterminated', "CC_SHELL_ESCAPED_FLAGS": "1"},
                "CFLAGS",
                "aarch64-apple-darwin",
                "aarch64-apple-darwin",
            )


class SdkOverrideTests(unittest.TestCase):
    def test_recognizes_common_clang_and_gcc_forms(self):
        tokens = [
            "-isysroot",
            "/sdk-a",
            "-isysroot/sdk-b",
            "--sysroot=/sdk-c",
            "--sysroot",
            "/sdk-d",
        ]
        paths = [(o.flag, o.path) for o in native_tools.sdk_overrides(tokens, "CFLAGS")]
        self.assertEqual(
            paths,
            [
                ("-isysroot", "/sdk-a"),
                ("-isysroot", "/sdk-b"),
                ("--sysroot=", "/sdk-c"),
                ("--sysroot", "/sdk-d"),
            ],
        )

    def test_missing_and_empty_paths_are_malformed(self):
        for tokens in (["-isysroot"], ["--sysroot"], ["--sysroot="]):
            with self.subTest(tokens=tokens):
                with self.assertRaisesRegex(native_tools.NativeToolError, "empty path|without a path"):
                    native_tools.sdk_overrides(tokens, "CFLAGS")

    def test_same_canonical_sdk_is_allowed(self):
        with tempfile.TemporaryDirectory() as directory:
            sdk = Path(directory) / "MacOSX15.0.sdk"
            sdk.mkdir()
            overrides = native_tools.sdk_overrides(
                ["-isysroot", str(sdk), "--sysroot", str(sdk)], "CFLAGS"
            )
            native_tools.check_sdk_overrides(overrides, str(sdk))

    def test_different_sdk_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            sdk = Path(directory) / "MacOSX15.0.sdk"
            other = Path(directory) / "MacOSX14.0.sdk"
            sdk.mkdir()
            other.mkdir()
            overrides = native_tools.sdk_overrides(["-isysroot", str(other)], "CFLAGS")
            with self.assertRaisesRegex(native_tools.NativeToolError, "different SDK"):
                native_tools.check_sdk_overrides(overrides, str(sdk))

    def test_relative_override_is_rejected_clearly(self):
        with tempfile.TemporaryDirectory() as directory:
            overrides = native_tools.sdk_overrides(["-isysroot", "relative.sdk"], "CFLAGS")
            with self.assertRaisesRegex(native_tools.NativeToolError, "absolute"):
                native_tools.check_sdk_overrides(overrides, str(Path(directory)))


if __name__ == "__main__":
    unittest.main()
