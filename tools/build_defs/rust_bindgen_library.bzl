# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is dual-licensed under either the MIT license found in the
# LICENSE-MIT file in the root directory of this source tree or the Apache
# License, Version 2.0 found in the LICENSE-APACHE file in the root directory
# of this source tree. You may select, at your option, one of the
# above-listed licenses.

load("@prelude//cxx:preprocessor.bzl", "CPreprocessorInfo")

def _rust_bindgen_impl(ctx: AnalysisContext) -> list[Provider]:
    # Collect preprocessor args from cpp_deps
    cpp_args = cmd_args()
    for dep in ctx.attrs.cpp_deps:
        info = dep.get(CPreprocessorInfo)
        if info and info.set:
            cpp_args.add(info.set.project_as_args("args"))

    # Build the bindgen command
    out = ctx.actions.declare_output(ctx.attrs.cxx_bridge)
    cmd = cmd_args(ctx.attrs._bindgen[RunInfo])
    cmd.add("--header", ctx.attrs.header)
    cmd.add("--out", out.as_output())

    for f in ctx.attrs.allowlist_funcs:
        cmd.add("--allowlist-function", f)
    for t in ctx.attrs.allowlist_types:
        cmd.add("--allowlist-type", t)
    for v in ctx.attrs.allowlist_vars:
        cmd.add("--allowlist-var", v)
    for o in ctx.attrs.opaque_types:
        cmd.add("--opaque-type", o)

    if ctx.attrs.enable_cxx_namespaces:
        cmd.add("--enable-cxx-namespaces")

    # Add generate flags
    if "types" in ctx.attrs.generate:
        cmd.add("--generate-types")
    if "functions" in ctx.attrs.generate:
        cmd.add("--generate-functions")
    if "methods" in ctx.attrs.generate:
        cmd.add("--generate-methods")
    if "vars" in ctx.attrs.generate:
        cmd.add("--generate-vars")

    cmd.add("--", "-x", "c++", "-std=c++20", "-stdlib=libc++")
    cmd.add(cpp_args)

    ctx.actions.run(cmd, category = "bindgen")
    return [DefaultInfo(default_output = out)]

_rust_bindgen = rule(
    impl = _rust_bindgen_impl,
    attrs = {
        "allowlist_funcs": attrs.list(attrs.string(), default = []),
        "allowlist_types": attrs.list(attrs.string(), default = []),
        "allowlist_vars": attrs.list(attrs.string(), default = []),
        "cpp_deps": attrs.list(attrs.dep(), default = []),
        "cxx_bridge": attrs.string(default = "bindings.rs"),
        "enable_cxx_namespaces": attrs.bool(default = False),
        "generate": attrs.list(attrs.string(), default = []),
        "header": attrs.source(),
        "opaque_types": attrs.list(attrs.string(), default = []),
        "_bindgen": attrs.exec_dep(default = "fbsource//third-party/rust/bindgen:bindgen"),
    },
)

def rust_bindgen_library(name: str, header: str, **kwargs):
    kwargs.pop("include_dirs", None)

    cpp_deps = kwargs.pop("cpp_deps", [])
    src_includes = kwargs.pop("src_includes", [])
    cxx_bridge_filename = kwargs.pop("cxx_bridge", "bindings.rs")
    cxx_namespaces = kwargs.pop("cxx_namespaces", False)
    generate = kwargs.pop("generate", [])

    _rust_bindgen(
        name = name + "--bindings.rs",
        header = header,
        cpp_deps = cpp_deps,
        cxx_bridge = cxx_bridge_filename,
        allowlist_funcs = kwargs.pop("allowlist_funcs", []),
        allowlist_types = kwargs.pop("allowlist_types", []),
        allowlist_vars = kwargs.pop("allowlist_vars", []),
        opaque_types = kwargs.pop("opaque_types", []),
        enable_cxx_namespaces = cxx_namespaces,
        generate = generate,
        visibility = [],
    )

    # Map the generated bindings and any src_includes into the crate
    mapped_srcs = {
        ":{}--bindings.rs".format(name): cxx_bridge_filename,
    }
    for src in src_includes:
        # Map each src_include, preserving its basename
        basename = src.split("/")[-1]
        mapped_srcs[src] = "src/{}".format(basename)

    _rust_library(
        name = name,
        mapped_srcs = mapped_srcs,
        deps = cpp_deps + kwargs.pop("deps", []),
        env = {"OUT_DIR": "."},
        visibility = kwargs.pop("visibility", []),
    )

def _buck_genrule(*args, **kwargs):
    # This is unused in FB
    kwargs.pop("flavor_config", None)
    if "out" not in kwargs and "outs" not in kwargs:
        kwargs["out"] = "out"
    existing_labels = kwargs.get("labels", [])

    # This hides these targets from being built by Pyre, which is beneficial as
    # the majority of genrules in Antlir are related to image compilation and
    # thus require root, which Pyre builds do not have
    if "no_pyre" not in existing_labels:
        kwargs["labels"] = existing_labels + ["no_pyre"]
    _wrap_internal(native.cxx_genrule, args, kwargs)

def _get_visibility(visibility = None):
    # """
    # Antlir build outputs should not be visible outside of antlir by default.
    # This helps prevent our abstractions from leaking into other codebases as
    # Antlir becomes more widely adopted.
    # """
    # package = native.package_name()

    # # packages in antlir/staging are only allowed to be used by other targets in
    # # antlir/staging
    # if package == "antlir/staging" or package.startswith("antlir/staging/"):
    #     return ["//antlir/staging/...", "//bot_generated/antlir/staging/..."]

    if visibility:
        return visibility

    # if it's a consumer of antlir macros outside of antlir, default to public
    return ["PUBLIC"]

def _rust_library(*, name: str, **kwargs):
    unittests = kwargs.pop("unittests", True)
    if unittests:
        _rust_unittest(name = name + "-unittests", **kwargs)
    kwargs["name"] = name
    kwargs.pop("autocargo", None)
    kwargs.pop("link_style", None)
    _wrap_internal(native.rust_library, [], kwargs)

def _rust_unittest(*args, **kwargs):
    kwargs.pop("nodefaultlibs", None)
    kwargs.pop("allocator", None)
    _wrap_internal(native.rust_test, args, kwargs)

def _wrap_internal(fn, args, kwargs):
    """
    Wrap a build target rule with some default attributes.
    """

    label_arg = "labels"

    # Callers outside of this module can specify  `label_arg`, in which
    # case it's read-only, so generate a new list with its contents.
    # We pull off both `labels` and `tags` just to make sure that we get both
    # and then recombine them into the expected arg name.
    kwargs[label_arg] = kwargs.pop("labels", []) + kwargs.pop("tags", [])

    # Antlir build outputs should not be visible outside of antlir by default. This
    # helps prevent our abstractions from leaking into other codebases as Antlir
    # becomes more widely adopted.
    kwargs["visibility"] = _get_visibility(kwargs.pop("visibility", []))

    fn(*args, **kwargs)
