# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under both the MIT license found in the
# LICENSE-MIT file in the root directory of this source tree and the Apache
# License, Version 2.0 found in the LICENSE-APACHE file in the root directory
# of this source tree.

load("@//third-party:defs.bzl", "system_library")

WINDOWS_CHOCOLATEY_CONSTRAINT = "//os:windows-chocolatey"

def boost_libs(libraries, header_only):
    _generate_windows_flag_files()

    system_library(
        name = "boost",
        packages = {
            "//os:linux-fedora": ["boost-devel"],
            "//os:linux-ubuntu": ["libboost-all-dev"],
            "//os:macos-homebrew": ["boost"],
        },
        exported_preprocessor_flags = _preprocessor_flags(),
    )

    for library in libraries:
        boost_library(library)

    for library in header_only:
        boost_header_library(library)

def boost_library(library: str):
    """Create a compiled boost library target (e.g., boost_system, boost_thread)."""
    system_library(
        name = "boost_{}".format(library),
        packages = {
            "//os:linux-fedora": ["boost-devel"],
            "//os:linux-ubuntu": ["libboost-{}-dev".format(library.replace("_", "-"))],
            "//os:macos-homebrew": ["boost"],
        },
        exported_preprocessor_flags = _preprocessor_flags(),
        exported_linker_flags = _linker_flags(library),
    )

def boost_header_library(library: str):
    """Create a header-only boost library target (e.g., boost_algorithm)."""
    system_library(
        name = "boost_{}".format(library),
        packages = {
            "//os:linux-fedora": ["boost-devel"],
            "//os:linux-ubuntu": ["libboost-dev"],
            "//os:macos-homebrew": ["boost"],
        },
        exported_preprocessor_flags = _preprocessor_flags(),
    )

def _generate_windows_flag_files():
    """Create genrules for detecting Chocolatey boost paths. Call once.

    Chocolatey's boost-msvc-14.3 installs to C:\\local\\boost_<version>.
    """
    native.genrule(
        name = "_boost__preproc_flags",
        out = "preproc_flags.txt",
        cmd = "for /f %i in ('dir /b C:\\local\\boost_* 2^>nul ^| sort /r') do @echo -IC:\\local\\%i > $OUT && exit /b",
        target_compatible_with = [WINDOWS_CHOCOLATEY_CONSTRAINT],
    )

    native.genrule(
        name = "_boost__linker_flags",
        out = "linker_flags.txt",
        cmd = "for /f %i in ('dir /b C:\\local\\boost_* 2^>nul ^| sort /r') do @echo -LC:\\local\\%i\\lib64-msvc-14.3 > $OUT && exit /b",
        target_compatible_with = [WINDOWS_CHOCOLATEY_CONSTRAINT],
    )

def _linker_flags(library: str):
    """Return linker flags select for a specific boost library.

    On Windows, MSVC auto-links via #pragma - we only need the -L path.
    On other platforms, we need explicit -lboost_{library}.
    """
    return select({
        WINDOWS_CHOCOLATEY_CONSTRAINT: ["@$(location :_boost__linker_flags)"],
        "DEFAULT": ["-lboost_{}".format(library)],
    })

def _preprocessor_flags():
    """Return preprocessor flags select. Same for all boost targets."""
    return select({
        WINDOWS_CHOCOLATEY_CONSTRAINT: ["@$(location :_boost__preproc_flags)"],
        "DEFAULT": [],
    })
