#!/usr/bin/env python3
"""Small, dependency-free helpers matching cc-rs 1.11 environment semantics.

The native C dependencies are built by the pinned `cc` crate. These helpers
answer only two questions the build needs:

* which compiler command will cc-rs actually use, and
* which SDK override flags (`-isysroot` / `--sysroot`) will actually be passed.

They deliberately do not execute a shell and do not try to model the rest of
cc-rs. The precedence below mirrors `cc` 1.11.0's `target_envs`,
`getenv_with_target_prefixes` and `envflags`.
"""
from collections import namedtuple
import os
from pathlib import Path
import shlex

KNOWN_WRAPPERS = frozenset(
    ("ccache", "distcc", "sccache", "icecc", "cachepot", "buildcache", "kache")
)

ToolCommand = namedtuple("ToolCommand", "source raw compiler arguments wrapper")
SdkOverride = namedtuple("SdkOverride", "flag path source")


class NativeToolError(RuntimeError):
    pass


def _env_true(value):
    return value is not None and value not in ("0", "false", "no", "")


def target_env_names(name, rust_host, rust_target):
    """Return cc-rs' four lookup names, most specific first."""
    kind = "TARGET" if rust_host != rust_target else "HOST"
    target_u = rust_target.replace("-", "_").replace(".", "_")
    return [
        f"{name}_{rust_target}",
        f"{name}_{target_u}",
        f"{kind}_{name}",
        name,
    ]


def _is_known_wrapper(token, environ):
    stems = set(KNOWN_WRAPPERS)
    custom = environ.get("CC_KNOWN_WRAPPER_CUSTOM")
    if custom:
        stems.add(custom.lower())
    return Path(token).stem.lower() in stems


def parse_tool_command(raw, environ=None, source="CC"):
    """Parse a cc-rs tool value into the executable and compiler arguments.

    cc-rs first treats an existing path literally (so paths with spaces work),
    otherwise splits on whitespace. A leading known wrapper becomes the
    wrapper; the next token is the real compiler whose availability must be
    validated.
    """
    environ = {} if environ is None else environ
    text = raw.strip()
    if not text:
        return None
    if os.path.exists(text):
        return ToolCommand(source, raw, text, (), None)
    parts = text.split()
    if not parts:
        return None
    first = parts[0]
    if _is_known_wrapper(first, environ):
        if len(parts) < 2:
            raise NativeToolError(
                f"{source} names wrapper {first!r} without a compiler command"
            )
        return ToolCommand(source, raw, parts[1], tuple(parts[2:]), first)
    return ToolCommand(source, raw, first, tuple(parts[1:]), None)


def effective_tool(environ, name, rust_host, rust_target):
    """Return the command cc-rs will actually use, or None for its default."""
    for variable in target_env_names(name, rust_host, rust_target):
        if variable in environ:
            command = parse_tool_command(environ[variable], environ, variable)
            return command
    return None


def flag_settings(environ, name, rust_host, rust_target):
    """Return (variable, tokens) pairs in the order cc-rs combines them."""
    shell_escaped = _env_true(environ.get("CC_SHELL_ESCAPED_FLAGS"))
    settings = []
    for variable in reversed(target_env_names(name, rust_host, rust_target)):
        if variable in environ:
            raw = environ[variable]
            if shell_escaped:
                try:
                    tokens = shlex.split(raw)
                except ValueError as error:
                    raise NativeToolError(
                        f"{variable} could not be parsed as shell-escaped flags: {error}"
                    ) from error
            else:
                tokens = raw.split()
            settings.append((variable, tokens))
    return settings


def effective_flags(environ, name, rust_host, rust_target):
    flags = []
    for _variable, tokens in flag_settings(environ, name, rust_host, rust_target):
        flags.extend(tokens)
    return flags


def sdk_overrides(tokens, source):
    """Extract common Clang/GCC sysroot overrides from an argument list."""
    overrides = []
    index = 0
    while index < len(tokens):
        token = tokens[index]
        if token in ("-isysroot", "--sysroot"):
            if index + 1 >= len(tokens):
                raise NativeToolError(f"{source} has {token} without a path")
            path = tokens[index + 1]
            if not path:
                raise NativeToolError(f"{source} has {token} with an empty path")
            overrides.append(SdkOverride(token, path, source))
            index += 2
            continue
        if token.startswith("-isysroot"):
            path = token[len("-isysroot") :]
            if not path:
                raise NativeToolError(f"{source} has -isysroot with an empty path")
            overrides.append(SdkOverride("-isysroot", path, source))
        elif token.startswith("--sysroot="):
            path = token[len("--sysroot=") :]
            if not path:
                raise NativeToolError(f"{source} has --sysroot= with an empty path")
            overrides.append(SdkOverride("--sysroot=", path, source))
        index += 1
    return overrides


def check_sdk_overrides(overrides, sdk_path, realpath=os.path.realpath):
    """Reject effective sysroot flags that select a different SDK."""
    selected = realpath(Path(sdk_path))
    for override in overrides:
        path = override.path
        if not os.path.isabs(path):
            raise NativeToolError(
                f"{override.source} sets {override.flag} {path!r}, which is not "
                "an absolute path and cannot be validated against the selected SDK"
            )
        if realpath(Path(path)) != selected:
            raise NativeToolError(
                f"{override.source} sets {override.flag} {path!r}, which selects "
                f"a different SDK than the validated {sdk_path!r}. Unset that "
                "override or point it at the same SDK."
            )
    return realpath(Path(sdk_path))
