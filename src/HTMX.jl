"""
    HTMX

Lightweight HTML builder. Owns a small immutable HTML [`Node`](@ref) primitive
and renders it to HTML and Markdown.

# Exports
- [`h`](@ref) — tag-based HTML node builder (`h.div(...)`, `h.p("text")`)
- [`Node`](@ref) — immutable HTML node (`tag` / `attrs` / `children`)
- [`Raw`](@ref) — explicit wrapper for complete, trusted HTML/JS/CSS bytes
- [`auto`](@ref) — convert arbitrary values to HTML response strings
- [`@__str`](@ref) — string literal macro for [`HyperscriptString`](@ref)
- [`md_to_node`](@ref) — Markdown string/AST → `h.*` nodes

# Public, not exported
For a value's own `show(io, MIME"text/markdown"(), x)`:
- [`HTMX.markdown_block`](@ref) — declare that a type is a block in Markdown
- [`HTMX.markdown_div`](@ref) — write a Pandoc div (`::: {.class}`) around content
- [`HTMX.markdown_block_context`](@ref) — whether a block can start there

For Markdown output:
- [`HTMX.with_markdown_seams`](@ref) — switch the `---` before `<article>`/`<section>` on or off
- [`HTMX.markdown_seams`](@ref) — whether that seam is on
- [`HTMX.with_markdown_grid_tables`](@ref) — write a table a pipe table cannot hold as a Pandoc grid table
- [`HTMX.markdown_grid_tables`](@ref) — whether grid tables are on
"""
module HTMX

import Markdown
using OrderedCollections: OrderedDict
using ScopedValues: ScopedValue, with
export auto, h, Node, Raw, @__str, md_to_node
# `public` is Julia 1.11 syntax; on 1.10 these are documented as public.
@static if VERSION >= v"1.11.0-DEV.469"
    eval(Meta.parse("public markdown_block, markdown_div, markdown_block_context, markdown_seams, with_markdown_seams, markdown_grid_tables, with_markdown_grid_tables"))
end


include("nodes.jl")
include("html.jl")
include("auto.jl")
include("markdown.jl")
include("hxml.jl")
include("parser.jl")
include("precompile.jl")

end # module HTMX
