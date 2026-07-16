# HTMX.jl

[![Dev Docs](https://img.shields.io/badge/docs-dev-blue.svg)](https://nsiccha.github.io/HTMX.jl/dev/)
[![CI](https://github.com/nsiccha/HTMX.jl/actions/workflows/test.yml/badge.svg)](https://github.com/nsiccha/HTMX.jl/actions/workflows/test.yml)

A small Julia interface for building HTMX-powered HTML with an owned, immutable
node primitive.

## Features

- **Tag-based builder**: build HTML elements with `h.div(...)`, `h.span(...)`, etc.
- **Safe HTML rendering**: text children and attribute values are escaped by default; complete trusted markup can opt out explicitly with `Raw(...)`
- **Hyperscript literals**: use `_"..."` string macros to embed [Hyperscript](https://hyperscript.org/) snippets into the `_` attribute
- **`auto` helper**: convenient utilities for out-of-band (OOB) swaps, including the `<template>` workaround for table elements
- **Markdown round-trip**: `show(io, MIME"text/markdown"(), node)` and `md_to_node(s)` convert between `h.*` trees and Markdown

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/nsiccha/HTMX.jl")
```

## Related packages

- [DynamicObjects.jl](https://github.com/nsiccha/DynamicObjects.jl) -- lazy/cached property system used alongside HTMX.jl
