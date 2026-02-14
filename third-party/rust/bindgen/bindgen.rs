/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

use std::fs;
use std::path::PathBuf;

use anyhow::Context;
use anyhow::Error;
use anyhow::Result;
use bindgen::builder;
use clap::Parser;

#[derive(Debug, Parser)]
struct Args {
    #[clap(long)]
    header: String,
    #[clap(long)]
    out: PathBuf,
    #[clap(long)]
    allowlist_function: Vec<String>,
    #[clap(long)]
    allowlist_type: Vec<String>,
    #[clap(long)]
    allowlist_var: Vec<String>,
    #[clap(long)]
    opaque_type: Vec<String>,
    /// Enable C++ namespaces (creates nested Rust modules)
    #[clap(long)]
    enable_cxx_namespaces: bool,
    /// Generate types (enabled by default)
    #[clap(long)]
    generate_types: bool,
    /// Generate functions
    #[clap(long)]
    generate_functions: bool,
    /// Generate methods
    #[clap(long)]
    generate_methods: bool,
    /// Generate variables
    #[clap(long)]
    generate_vars: bool,
    /// Additional clang arguments (everything after --)
    #[clap(last = true)]
    clang_args: Vec<String>,
}

/// Expand @file response files into their contents
fn expand_response_files(args: &[String]) -> Result<Vec<String>> {
    let mut result = Vec::new();
    for arg in args {
        if let Some(path) = arg.strip_prefix('@') {
            let contents = fs::read_to_string(path)
                .with_context(|| format!("reading response file {}", path))?;
            let parsed = shlex::split(&contents)
                .ok_or_else(|| Error::msg(format!("invalid shell syntax in {}", path)))?;
            result.extend(parsed);
        } else {
            result.push(arg.clone());
        }
    }
    Ok(result)
}

fn main() -> Result<()> {
    let args = Args::parse();

    clang_sys::load()
        .map_err(Error::msg)
        .context("while loading libclang")?;

    let mut b = builder().header(&args.header);

    for f in &args.allowlist_function {
        b = b.allowlist_function(f);
    }
    for t in &args.allowlist_type {
        b = b.allowlist_type(t);
    }
    for v in &args.allowlist_var {
        b = b.allowlist_var(v);
    }
    for o in &args.opaque_type {
        b = b.opaque_type(o);
    }

    if args.enable_cxx_namespaces {
        b = b.enable_cxx_namespaces();
    }

    // Configure what to generate (default is everything)
    use bindgen::CodegenConfig;
    let mut codegen = CodegenConfig::empty();
    if args.generate_types {
        codegen |= CodegenConfig::TYPES;
    }
    if args.generate_functions {
        codegen |= CodegenConfig::FUNCTIONS;
    }
    if args.generate_methods {
        codegen |= CodegenConfig::METHODS;
    }
    if args.generate_vars {
        codegen |= CodegenConfig::VARS;
    }
    // If nothing specified, generate everything
    if codegen.is_empty() {
        codegen = CodegenConfig::all();
    }
    b = b.with_codegen_config(codegen);

    let expanded_clang_args = expand_response_files(&args.clang_args)?;
    if !expanded_clang_args.is_empty() {
        b = b.clang_args(&expanded_clang_args);
    }

    let bindings = b.generate()?;

    bindings.write_to_file(&args.out)?;
    Ok(())
}
