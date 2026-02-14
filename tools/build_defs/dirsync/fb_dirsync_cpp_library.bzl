# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is dual-licensed under either the MIT license found in the
# LICENSE-MIT file in the root directory of this source tree or the Apache
# License, Version 2.0 found in the LICENSE-APACHE file in the root directory
# of this source tree. You may select, at your option, one of the
# above-listed licenses.

load("@fbcode_macros//build_defs:build_file_migration.bzl", "fbcode_target", "non_fbcode_target")
load("@fbcode_macros//build_defs:cpp_library.bzl", "cpp_library")
load("@fbsource//tools/build_defs:fb_xplat_cxx_library.bzl", "fb_xplat_cxx_library")

def fb_dirsync_cpp_library(**kwargs):
    fbcode_args = {k:v for k,v in kwargs.items() if k not in [
        "use_raw_headers",
        "xplat_impl",
    ]}
    fbcode_target(
        _kind = cpp_library,
        **fbcode_args,
    )

    non_fbcode_target(
        _kind = fb_xplat_cxx_library,
        **kwargs,
    )
