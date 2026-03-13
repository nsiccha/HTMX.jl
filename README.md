# HTMX.jl

[![Dev Docs](https://img.shields.io/badge/docs-dev-blue.svg)](https://nsiccha.github.io/HTMX.jl/dev/)
[![CI](https://github.com/nsiccha/HTMX.jl/actions/workflows/test.yml/badge.svg)](https://github.com/nsiccha/HTMX.jl/actions/workflows/test.yml)

A Julia interface for building HTMX-powered HTML using hyperscript syntax, backed by [Cobweb.jl](https://github.com/JuliaComputing/Cobweb.jl).

## Features

- **Hyperscript syntax**: build HTML elements with `h.div(...)`, `h.span(...)`, etc.
- **Hyperscript strings**: use `_"..."` string macros for inline element creation
- **`auto` helper**: convenient utilities for out-of-band (OOB) swaps

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/nsiccha/HTMX.jl")
```

## Related packages

- [DynamicObjects.jl](https://github.com/nsiccha/DynamicObjects.jl) -- lazy/cached property system used alongside HTMX.jl
