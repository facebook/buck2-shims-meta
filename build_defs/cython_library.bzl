# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is dual-licensed under either the MIT license found in the
# LICENSE-MIT file in the root directory of this source tree or the Apache
# License, Version 2.0 found in the LICENSE-APACHE file in the root directory
# of this source tree. You may select, at your option, one of the
# above-listed licenses.

load("@fbsource//tools/build_defs:platform_defs.bzl", "APPLE", "CXX", "MACOSX", "WINDOWS")

CYTHON_DEFAULT_PLATFORMS = (CXX, WINDOWS, APPLE)
CYTHON_DEFAULT_APPLE_SDKS = (MACOSX,)

# Provider to pass .pxd files between cython_library targets
CythonLibraryInfo = provider(fields = [
    "pxd_files",  # dict: {target_path: artifact} where target_path is like "folly/executor.pxd"
    "package",    # string: package name (e.g., "folly")
])

# Rule 1: Package .pxd files for use by other cython targets
def _cython_pxd_library_impl(ctx: AnalysisContext) -> list[Provider]:
    package = ctx.attrs.package or ""

    # Collect .pxd files from this target's headers
    # Map them to their target path (stripping "/python" if present)
    my_pxd_files = {}
    for header in ctx.attrs.headers:
        if header.basename.endswith(".pxd"):
            # Files at folly/python/executor.pxd should appear as folly/executor.pxd
            source_path = header.short_path

            if package and "/python/" in source_path:
                # Strip the /python/ part: folly/python/executor.pxd -> folly/executor.pxd
                parts = source_path.split("/python/")
                target_path = parts[0] + "/" + parts[1]
            elif package:
                # If no /python/ in path, use package/basename
                target_path = package + "/" + header.basename
            else:
                # No package, use as-is
                target_path = header.basename

            my_pxd_files[target_path] = header

    # Collect .pxd files from dependencies
    all_pxd_files = dict(my_pxd_files)
    for dep in ctx.attrs.deps:
        if CythonLibraryInfo in dep:
            all_pxd_files.update(dep[CythonLibraryInfo].pxd_files)

    return [
        DefaultInfo(),  # No outputs, just provider info
        CythonLibraryInfo(
            pxd_files = all_pxd_files,
            package = package,
        ),
    ]

_cython_pxd_library = rule(
    impl = _cython_pxd_library_impl,
    attrs = {
        "headers": attrs.list(attrs.source(), default = []),
        "deps": attrs.list(attrs.dep(), default = []),
        "package": attrs.option(attrs.string(), default = None),
    },
)

# Rule 2: Compile .pyx to .cpp + _api.h
def _cython_compile_impl(ctx: AnalysisContext) -> list[Provider]:
    if len(ctx.attrs.srcs) != 1:
        fail("_cython_compile requires exactly one .pyx file, got: {}".format(ctx.attrs.srcs))

    pyx_file = ctx.attrs.srcs[0]

    # Collect all .pxd files from dependencies for Cython imports
    all_pxd_files = {}
    for dep in ctx.attrs.deps:
        if CythonLibraryInfo in dep:
            all_pxd_files.update(dep[CythonLibraryInfo].pxd_files)

    # Create symlinked directory with proper structure for Cython imports
    # This maps folly/python/executor.pxd -> folly/executor.pxd etc.
    pxd_dir = ctx.actions.symlinked_dir(
        "__pxd_tree",
        all_pxd_files,
    )

    # Main output: .cpp file
    cpp_output = ctx.actions.declare_output(pyx_file.basename.replace(".pyx", ".cpp"))

    # API header outputs as sub-targets
    # Declare as simple filenames - path mapping handled by exported_headers
    sub_targets = {}
    api_outputs = []
    for module_name in ctx.attrs.api:
        api_header = ctx.actions.declare_output(module_name + "_api.h")
        sub_targets[module_name + "_api_h"] = [DefaultInfo(default_output = api_header)]
        api_outputs.append(api_header)

    # Run Cython - single invocation produces .cpp and all _api.h files
    # Specify module name explicitly so API imports use correct package
    pkg = ctx.attrs.package or ""
    module_base = pyx_file.basename.replace(".pyx", "")
    full_module_name = (pkg + "." + module_base) if pkg else module_base

    ctx.actions.run(
        cmd_args([
            "python3", "-m", "cython", "--cplus", "-3",
            "-I", pxd_dir,
            "--module-name", full_module_name,
            "-o", cpp_output.as_output(),
            pyx_file,
        ], hidden = [h.as_output() for h in api_outputs]),
        category = "cython_compile",
    )

    return [
        DefaultInfo(
            default_output = cpp_output,
            sub_targets = sub_targets,
        ),
    ]

_cython_compile = rule(
    impl = _cython_compile_impl,
    attrs = {
        "srcs": attrs.list(attrs.source()),
        "api": attrs.list(attrs.string(), default = []),
        "deps": attrs.list(attrs.dep(), default = []),
        "package": attrs.option(attrs.string(), default = None),
    },
)

# Macro: Orchestrates the rules to create a cython_library
def cython_library(
        name,
        srcs = [],
        headers = [],
        api = [],
        cpp_deps = [],
        package = None,
        deps = [],
        tests = [],
        types = [],
        header_namespace = None,
        visibility = ["PUBLIC"],
        **kwargs):
    """
    Build a Cython extension module.

    Supports three modes:
    1. Header-only: Only headers, no srcs (exports .pxd files)
    2. Binary-only: Has srcs, no api (compiles .pyx to extension)
    3. Binary+header: Has srcs and api (compiles and generates API header)

    Args:
        name: Target name
        srcs: List of .pyx source files
        headers: List of .pxd header files
        api: List of module names that generate C API headers
        cpp_deps: C++ dependencies
        package: Python package name (e.g., "folly")
        deps: Python/Cython dependencies
        tests: Test targets (ignored, for compatibility)
        types: Type stub files (ignored, for compatibility)
        header_namespace: Header namespace for C++ headers (passed to cxx_library)
        visibility: Visibility settings
    """

    # Separate .h files (C++ headers) from .pxd files (Cython headers)
    # Both can appear in the headers parameter
    cpp_headers = []
    pxd_only_headers = []
    if type(headers) == type({}):
        # Dict form: {"name.pxd": "path", "name.h": "path"}
        for key, value in headers.items():
            if key.endswith(".h"):
                cpp_headers.append(value)
            else:
                pxd_only_headers.append(value)
    else:
        # List form: ["name.pxd", "name.h"]
        for h in headers:
            if h.endswith(".h"):
                cpp_headers.append(h)
            else:
                pxd_only_headers.append(h)

    # Always create the .pxd package rule for dependencies to consume
    # Convert deps to their __pxd variants for proper .pxd file propagation
    pxd_deps_list = [":" + name + "__pxd"]
    cython_pxd_deps = []
    for dep in deps:
        # Add __pxd suffix to local deps (":foo" -> ":foo__pxd")
        # Keep external deps as-is ("//path:target" stays "//path:target")
        if dep.startswith(":"):
            cython_pxd_deps.append(dep + "__pxd")
        else:
            # For external deps, assume they follow the same pattern
            cython_pxd_deps.append(dep + "__pxd")

    _cython_pxd_library(
        name = name + "__pxd",
        headers = headers,
        package = package,
        deps = cython_pxd_deps,
        visibility = visibility,  # Use same visibility as main target
    )

    if srcs:
        # Compile .pyx to .cpp + _api.h
        _cython_compile(
            name = name + "__cython",
            srcs = srcs,
            api = api,
            package = package,
            deps = pxd_deps_list + cython_pxd_deps,
            visibility = [],
        )

        # Prepare headers dict for cxx_library
        exported_headers = {}
        if api:
            # Add API headers to exports
            for module_name in api:
                # Map to package/python/module_api.h
                if package:
                    header_path = package + "/python/" + module_name + "_api.h"
                else:
                    header_path = module_name + "_api.h"
                exported_headers[header_path] = ":{}__cython[{}_api_h]".format(name, module_name)

                # Create backwards-compat alias target: name__module_api.h
                # This is a cxx_library that re-exports the header with proper path mapping
                # It depends on __cython (not main target) to avoid circular deps
                # Set header_namespace="" to prevent Buck2 from prepending package path
                native.cxx_library(
                    name = "{name}__{module}_api.h".format(name = name, module = module_name),
                    exported_headers = {header_path: ":{}__cython[{}_api_h]".format(name, module_name)},
                    header_namespace = "",
                    visibility = visibility,
                )

        # Main target: C++ library wrapping the compiled Cython code
        # Always add Python as a dependency since Cython-generated code needs Python.h
        # Also add deps because those might be cython_library targets providing C++ headers
        # Use exported_deps so headers from cpp_deps are transitively available to dependents
        all_cpp_deps = cpp_deps + deps + ["fbsource//third-party/python:python"]

        # Add C++ headers from the headers parameter to exported_headers
        for h in cpp_headers:
            exported_headers[h] = h

        cxx_kwargs = {
            "name": name,
            "srcs": [":{}__cython".format(name)],
            "exported_headers": exported_headers,
            "exported_deps": all_cpp_deps,
            "visibility": visibility,
        }
        if header_namespace != None:
            cxx_kwargs["header_namespace"] = header_namespace

        native.cxx_library(**cxx_kwargs)
    else:
        # Header-only mode: create a cxx_library that re-exports cpp_deps and deps
        # Use exported_deps so dependents can access the C++ headers/libraries
        native.cxx_library(
            name = name,
            exported_deps = cpp_deps + deps,
            visibility = visibility,
        )

    # For compatibility, create a python_library (ignored for now)
    # python_library(name = name + "__py", visibility = [])
