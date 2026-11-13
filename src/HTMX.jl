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
"""
module HTMX

import Markdown
using OrderedCollections: OrderedDict
export auto, h, Node, Raw, @__str, md_to_node


include("nodes.jl")
include("html.jl")
include("auto.jl")
include("markdown.jl")
include("hxml.jl")
include("parser.jl")
include("precompile.jl")

end # module HTMX
