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

"""
    auto(x; wrap)

Convert `x` to an HTML string, applying `wrap` to the result. `wrap` is
mandatory — pass `wrap=string` (or `wrap=identity`) when calling directly;
web frameworks built on top of HTMX.jl typically inject their own wrapper.

- `AbstractString` — passed through to `wrap`
- `AbstractArray` — elements are recursively `auto`'d and joined with newlines
- `Pair(content, id)` — wrapped in an OOB-swap `div` with `hx-swap-oob="true"`
  (table elements like `<tr>` are additionally wrapped in `<template>` so HTMX
  can swap them past the browser's `innerHTML` parser)
- Anything else — rendered via `repr("text/html", x)`
"""
auto(x; wrap) = wrap(repr("text/html", x))
auto(x::AbstractString; wrap) = wrap(x)
auto(x::AbstractArray; wrap) = wrap(join(auto.(x; wrap=identity), "\n"))

"""
    HyperscriptString(s::AbstractString)

A string subtype that, when passed as a child to a [`Node`](@ref), is moved to the
`_` (hyperscript) HTML attribute instead of appearing as text content.

Multiple `HyperscriptString` children are concatenated with newlines in the `_` attribute.
Concatenation via `*` preserves the `HyperscriptString` type.

See also [`@__str`](@ref) for a literal constructor.
"""
struct HyperscriptString <: AbstractString
    data::String
end

# Normalize anything coming in
HyperscriptString(s::AbstractString) = HyperscriptString(String(s))

# Mandatory AbstractString interface — all delegated
Base.codeunit(s::HyperscriptString)                = UInt8
Base.ncodeunits(s::HyperscriptString)              = ncodeunits(s.data)
Base.codeunit(s::HyperscriptString, i::Integer)    = codeunit(s.data, i)
Base.isvalid(s::HyperscriptString, i::Integer)     = isvalid(s.data, i)
Base.iterate(s::HyperscriptString)                 = iterate(s.data)
Base.iterate(s::HyperscriptString, i::Integer)     = iterate(s.data, i)

Base.show(io::IO, s::HyperscriptString)  = show(io, s.data)
Base.print(io::IO, s::HyperscriptString) = print(io, s.data)
Base.String(s::HyperscriptString)        = s.data

Base.promote_rule(::Type{HyperscriptString}, ::Type{<:AbstractString}) = HyperscriptString
Base.convert(::Type{HyperscriptString}, s::AbstractString) = HyperscriptString(String(s))
Base.:*(a::HyperscriptString, b::HyperscriptString) = HyperscriptString(a.data * b.data)
"""
    @__str "text"

Create a [`HyperscriptString`](@ref) literal. Equivalent to `HyperscriptString("text")`.
"""
macro __str(ex)
    :($HyperscriptString($(esc(Meta.parse("\"$ex\"")))))
end
_as_flat(a::AbstractVector) = a
_as_flat(a) = [a]
_flatten(args) = mapreduce(_as_flat, vcat, args; init=Any[])

# filter! predicate: keep non-HyperscriptString children; absorb HyperscriptStrings into the `_` attr
_absorb_hyperscript!(attrs, tag::HyperscriptString) =
    (attrs[:(_)] = get(attrs, :(_), "") * "\n" * tag; false)
_absorb_hyperscript!(attrs, _) = true
_filter_attrs(kwargs) = (k => (v === true ? "true" : string(v)) for (k, v) in kwargs if v !== nothing && v !== false)

# True HTML boolean attributes: presence alone = true, so any value (incl.
# "false") renders the attribute as set. For these, a string "false" must be
# omitted — `selected="false"` would otherwise still select the option. This is
# scoped to genuine boolean attributes ONLY; enumerated/ARIA attributes like
# aria-expanded="false" are meaningful and must still render (see show loop).
const _BOOLEAN_ATTRS = Set{Symbol}((
    :allowfullscreen, :async, :autofocus, :autoplay, :checked, :controls,
    :default, :defer, :disabled, :formnovalidate, :hidden, :inert, :ismap,
    :itemscope, :loop, :multiple, :muted, :nomodule, :novalidate, :open,
    :playsinline, :readonly, :required, :reversed, :selected,
))

# ============================================================================
# Node — the owned HTML node primitive
# ----------------------------------------------------------------------------
# Formerly a thin wrapper around `Cobweb.Node`; HTMX.jl now owns the ~40-line
# primitive directly (one type, no wrapper layer). A `Node` is plain data —
# `tag::Symbol`, `attrs::OrderedDict`, `children::Vector` — which makes both the
# HTML/Markdown renderers below and any future `to_json` a straight structural
# walk. Self-rendering "special" widgets are NOT Nodes: they are distinct types
# that define `show(::MIME, x)` and splice in as children via `showable`/`show`.
# ============================================================================

# Void (self-closing) elements get no closing tag.
const VOID_ELEMENTS = Set{Symbol}((
    :area, :base, :br, :col, :command, :embed, :hr, :img, :input, :keygen,
    :link, :meta, :param, :source, :track, :wbr,
))

# Attribute names: underscores become hyphens (`hx_get` → `hx-get`). The
# hyperscript `_` kwarg therefore arrives as `-` and is remapped back to `_`
# during HTML rendering (see `show`).
_attr_symbol(k) = Symbol(replace(string(k), '_' => '-'))

# HTML entity escaping for `&`, `"`, `'`, `<`, `>` (formerly `Cobweb.escape`).
const _ESCAPE_PAIRS = ('&' => "&amp;", '"' => "&quot;", '\'' => "&#39;", '<' => "&lt;", '>' => "&gt;")
function escape(x::AbstractString)
    for pat in _ESCAPE_PAIRS
        x = replace(x, pat)
    end
    x
end

"""
    Raw(html::AbstractString)

Mark complete, trusted HTML/JS/CSS bytes for verbatim emission when used as an
HTML [`Node`](@ref) child. Ordinary strings are escaped by default; use `Raw`
only when the value is entirely server-owned and is already valid for its HTML
context.

`Raw` does not disable attribute-value escaping. It is not a substitute for
context-aware escaping of untrusted values interpolated into HTML, JavaScript,
or CSS.

# Example
```julia
h.div(Raw("<em>trusted markup</em>"))
h.script(Raw("console.log('trusted program')"))
```
"""
struct Raw
    html::String
end

Raw(html::AbstractString) = Raw(String(html))
Base.String(raw::Raw) = raw.html
Base.print(io::IO, raw::Raw) = print(io, raw.html)
Base.show(io::IO, ::MIME"text/html", raw::Raw) = print(io, raw.html)

"""
    Node(tag, children...; attributes...)

Immutable HTML node. Keyword arguments become HTML attributes (underscores are
converted to hyphens, e.g. `hx_get` → `hx-get`). Attributes set to `nothing` or
`false` are omitted; `true` renders as `name="true"` (browsers treat the quoted
value as truthy). Positional arguments become children.

Use call syntax to append children or merge attributes:

    node = h.div(class="container")
    node("child text")   # returns a new Node; original is unchanged

During HTML rendering, [`HyperscriptString`](@ref) children are moved to the `_`
attribute (for [hyperscript](https://hyperscript.org/)).

Ordinary child text and attribute values are HTML-escaped. Children that define
their own `show(::MIME"text/html", ...)` method render structurally; wrap only
complete, trusted literal markup or program text in [`Raw`](@ref).

The fields are read with [`tag`](@ref), [`attrs`](@ref) and [`children`](@ref).
"""
struct Node
    tag::Symbol
    attrs::OrderedDict{Symbol,Any}
    children::Vector{Any}
    # Canonical inner constructor: keys already hyphenated, types exact.
    Node(tag::Symbol, attrs::OrderedDict{Symbol,Any}, children::Vector{Any}) = new(tag, attrs, children)
end

# Field accessors (the public read surface; `n.attrs[k]` etc. also work).

"""
    tag(n::Node) -> Symbol

The element name of `n`, e.g. `:div` for `h.div(...)`.
"""
tag(n::Node)      = getfield(n, :tag)

"""
    attrs(n::Node) -> OrderedDict{Symbol,Any}

The attributes of `n`, in insertion order, with hyphenated keys (`:var"data-id"`).
The returned dictionary is the node's own field — copy it before mutating.
"""
attrs(n::Node)    = getfield(n, :attrs)

"""
    children(n::Node) -> Vector{Any}

The children of `n`, in document order. The returned vector is the node's own
field — copy it before mutating.
"""
children(n::Node) = getfield(n, :children)

# Normalizing 3-arg form: accepts any tag / dict / iterable of children and
# coerces to the canonical field types (hyphenating attribute keys). Used when
# rebuilding a node from already-extracted parts.
Node(tag, attrs::AbstractDict, children) =
    Node(Symbol(tag),
         OrderedDict{Symbol,Any}(_attr_symbol(k) => v for (k, v) in attrs),
         collect(Any, children))

# Builder form behind `h.tag(...)`: filters/stringifies kwargs into attributes
# and flattens positional children.
Node(tag, args...; kwargs...) =
    Node(Symbol(tag),
         OrderedDict{Symbol,Any}(_attr_symbol(k) => v for (k, v) in _filter_attrs(kwargs)),
         _flatten(args))

# Call syntax appends children / merges attributes, returning a NEW node
# (the original's vectors and dict are left untouched).
(n::Node)(args...; kwargs...) =
    Node(tag(n),
         merge(attrs(n), OrderedDict{Symbol,Any}(_attr_symbol(k) => v for (k, v) in _filter_attrs(kwargs))),
         vcat(children(n), _flatten(args)))

function Base.show(io::IO, m::MIME"text/html", n::Node)
    # Render off copies so the node itself is never mutated by hyperscript
    # absorption.
    a = copy(attrs(n))
    kids = copy(children(n))
    # `_` arrives hyphenated (see `_attr_symbol`); restore it for output.
    haskey(a, :(-)) && (a[:(_)] = pop!(a, :(-)))
    filter!(child -> _absorb_hyperscript!(a, child), kids)
    print(io, '<', tag(n))
    for (k, v) in a
        # Omit string-valued "false" ONLY for true boolean attributes; for
        # enumerated/ARIA attributes "false" is meaningful and must render.
        v == "false" && k in _BOOLEAN_ATTRS && continue
        print(io, ' ', k, '=', '"', escape(string(v)), '"')
    end
    print(io, '>')
    for child in kids
        showable("text/html", child) ? show(io, m, child) : print(io, escape(string(child)))
    end
    tag(n) in VOID_ELEMENTS || print(io, "</", tag(n), '>')
end

# Table elements (tr, td, th, thead, tbody, tfoot) are silently stripped by
# the browser's innerHTML parser when they lack proper parent context.
# Wrapping in <template> lets HTMX swap them correctly.
const _table_tags = Set([:tr, :td, :th, :thead, :tbody, :tfoot, :caption, :colgroup, :col])
_make_oob(content::Node, id) = content(; id, hx_swap_oob="true")
_make_oob(content, id) = h.div(id=id, hx_swap_oob="true")(content)
# Wrap an OOB swap in a <template> when the content is a table sub-element.
# Dispatched on Node vs anything else; non-Node content always passes through.
_template_if_table(content::Node, oob) =
    tag(content) in _table_tags ? h.template(oob) : oob
_template_if_table(_, oob) = oob
function auto((content, id)::Pair; wrap)
    oob = _template_if_table(content, _make_oob(content, id))
    auto(oob; wrap)
end
"""
    h(tag, children...; attributes...)
    h.tag(children...; attributes...)

Create an HTML [`Node`](@ref). The property-access form `h.div(...)` is the
standard way to build elements:

    h.div(class="container")(
        h.h1("Title"),
        h.p("Paragraph")
    )

Keyword arguments become attributes (underscores → hyphens). Positional arguments
become children. Attributes set to `nothing` or `false` are omitted; `true` renders
as `name="true"` (browsers treat the quoted value as truthy).
"""
h(tag, args...; kwargs...) = Node(tag, args...; kwargs...)
Base.getproperty(::typeof(h), tag::Symbol) = (args...; kwargs...)->h(tag, args...; kwargs...)

# --- Markdown rendering ---

const _md_mime = MIME"text/markdown"()

# Fallback: any non-Node value renders as its string representation
Base.show(io::IO, ::MIME"text/markdown", val) = print(io, string(val))

# Strings pass through as-is
Base.show(io::IO, ::MIME"text/markdown", val::AbstractString) = print(io, val)

# Arrays: render each element
Base.show(io::IO, m::MIME"text/markdown", val::AbstractArray) = foreach(v -> show(io, m, v), val)

# Node: dispatch by tag via _md(io, m, node, ::Val{tag})
Base.show(io::IO, m::MIME"text/markdown", n::Node) = _md(io, m, n, Val(tag(n)))

# Default: recurse transparently (unknown tags fall here)
_md(io, m, node::Node, ::Val) = _md_recurse(io, m, node)

# Recurse into children as if the node were transparent
_md_recurse(io, m, node) = for c in children(node)
    show(io, m, c)
end

# Inline formatting — written straight to io (no intermediate strings). These
# fire for inline elements everywhere EXCEPT inside <pre>: its handler recurses
# into the <code> child's own children, so _md is never dispatched on <code>
# there and no backticks leak into the fenced block.
for t in (:strong, :b)
    @eval _md(io, m, node::Node, ::Val{$(QuoteNode(t))}) =
        (print(io, "**"); _md_recurse(io, m, node); print(io, "**"))
end
for t in (:em, :i)
    @eval _md(io, m, node::Node, ::Val{$(QuoteNode(t))}) =
        (print(io, "*"); _md_recurse(io, m, node); print(io, "*"))
end
_md(io, m, node::Node, ::Val{:code}) =
    (print(io, "`"); _md_recurse(io, m, node); print(io, "`"))
_md(io, m, node::Node, ::Val{:a}) =
    (print(io, "["); _md_recurse(io, m, node); print(io, "](", get(attrs(node), :href, ""), ")"))
_md(io, m, node::Node, ::Val{:br}) = print(io, "\n")

# Headings h1..h6
for lvl in 1:6
    @eval _md(io, m, node::Node, ::Val{$(QuoteNode(Symbol("h$lvl")))}) =
        (print(io, $("#"^lvl * " ")); _md_recurse(io, m, node); println(io))
end

# Containers: recurse transparently
for t in (:div, :main, :body, :html, :head,
          :span, :ul, :ol, :thead, :tbody, :tr, :summary,
          :form, :label, :nav, :footer, :dl)
    @eval _md(io, m, node::Node, ::Val{$(QuoteNode(t))}) = _md_recurse(io, m, node)
end

# <details>: skip the <summary> toggle label, recurse the content
function _md(io, m, node::Node, ::Val{:details})
    for c in children(node)
        c isa Node && tag(c) === :summary && continue
        show(io, m, c)
    end
end

# Semantic blocks: emit a leading `---` divider so an agent reader can see
# where each block starts. Only leading (not trailing), so adjacent blocks
# produce a single divider between them rather than doubled.
for t in (:article, :section)
    @eval _md(io, m, node::Node, ::Val{$(QuoteNode(t))}) =
        (println(io); println(io, "---"); println(io); _md_recurse(io, m, node); println(io))
end

# <header> is the label/title of its surrounding block — render as a level-3
# heading so the structure is legible to an agent reader.
_md(io, m, node::Node, ::Val{:header}) = (print(io, "### "); _md_recurse(io, m, node); println(io))

# Non-content tags: skip
for t in (:script, :style, :meta, :link, :button)
    @eval _md(io, m, node::Node, ::Val{$(QuoteNode(t))}) = nothing
end

# Block leaves
_md(io, m, node::Node, ::Val{:p})     = (_md_recurse(io, m, node); println(io); println(io))
_md(io, m, node::Node, ::Val{:li})    = (print(io, "- "); _md_recurse(io, m, node); println(io))
function _md(io, m, node::Node, ::Val{:pre})
    lang = ""
    code_node = nothing
    for c in children(node)
        if c isa Node && tag(c) === :code
            code_node = c
            cls = get(attrs(c), :class, "")
            lm = match(r"language-(\S+)", string(cls))
            isnothing(lm) || (lang = lm[1])
            break
        end
    end
    println(io, "```", lang)
    _md_recurse(io, m, isnothing(code_node) ? node : code_node)
    println(io)
    println(io, "```")
end
_md(io, m, node::Node, ::Val{:hr})    = println(io, "---")
_md(io, m, node::Node, ::Val{:table}) = _table_to_markdown(io, node)

# <title> → top-level heading (so a full page with <head><title>X</title></head> renders as "# X")
_md(io, m, node::Node, ::Val{:title}) = (print(io, "# "); _md_recurse(io, m, node); println(io))

# <blockquote> → "> "-prefixed lines
function _md(io, m, node::Node, ::Val{:blockquote})
    buf = IOBuffer()
    _md_recurse(buf, m, node)
    inner = rstrip(String(take!(buf)), '\n')
    isempty(inner) && return
    for line in split(inner, '\n')
        println(io, "> ", line)
    end
    println(io)
end

# <img> → ![alt](src)
function _md(io, m, node::Node, ::Val{:img})
    a = attrs(node)
    src = get(a, :src, "")
    isempty(src) && return
    println(io, "![", get(a, :alt, ""), "](", src, ")")
end

# <figure> → Quarto fenced div.  Blank lines before/after guarantee
# block-level parsing by Pandoc.  Children are recursed with blank-line
# separation (required for Quarto subfigures).  <figcaption> is moved
# to the final paragraph — Quarto treats the last block inside a
# `::: {#fig-…}` div as the displayed caption.  Nested <figure> nodes
# recurse into their own `:::` blocks (Quarto subfigures).
function _md(io, m, node::Node, ::Val{:figure})
    a = attrs(node)
    id = get(a, :id, nothing)
    caption_node = nothing
    content = Any[]
    for c in children(node)
        if c isa Node && tag(c) === :figcaption
            caption_node = c
        else
            push!(content, c)
        end
    end
    print(io, "\n\n")
    println(io, isnothing(id) ? ":::" : "::: {#$id}")
    for (i, c) in enumerate(content)
        i > 1 && println(io)
        show(io, m, c)
    end
    if !isnothing(caption_node)
        println(io)
        _md_recurse(io, m, caption_node)
        println(io)
    end
    println(io, ":::")
    print(io, "\n")
end

_collect_table_rows!(rows, ::Any) = nothing
_collect_table_rows!(rows, section::Node) = for row in children(section)
    _push_tr!(rows, row)
end
_push_tr!(rows, ::Any) = nothing
_push_tr!(rows, r::Node) = string(tag(r)) == "tr" && push!(rows, r)

_push_cell_text!(cells, ::Any) = nothing
function _push_cell_text!(cells, c::Node)
    buf = IOBuffer()
    _md_recurse(buf, _md_mime, c)
    push!(cells, strip(String(take!(buf))))
end

function _table_to_markdown(io::IO, table::Node)
    rows = Node[]
    for section in children(table)
        _collect_table_rows!(rows, section)
    end
    isempty(rows) && return
    for (i, row) in enumerate(rows)
        cells = String[]
        for c in children(row)
            _push_cell_text!(cells, c)
        end
        println(io, "| ", join(cells, " | "), " |")
        if i == 1
            println(io, "| ", join(fill("---", length(cells)), " | "), " |")
        end
    end
    println(io)
end

# --- Markdown AST → h.* Node conversion ---

"""
    md_to_node(md)

Convert a markdown string or `Markdown.jl` AST into `h.*` HTML nodes.

# Example
```julia
md_to_node("**bold** and `code`")
md_to_node(Markdown.parse("**bold** and `code`"))
# both => h.div(h.p(h.strong("bold"), " and ", h.code("code")))
```
"""
md_to_node(s::AbstractString) = _md_to_node(Markdown.parse(s))
md_to_node(x) = _md_to_node(x)

# Internal recursive converter — handles Markdown AST nodes and string leaves
_md_to_node(s::AbstractString) = s
_md_to_node(md::Markdown.MD) = h.div(_md_to_node.(md.content)...)
_md_to_node(p::Markdown.Paragraph) = h.p(_md_to_node.(p.content)...)
_md_to_node(b::Markdown.Bold) = h.strong(_md_to_node.(b.text)...)
_md_to_node(i::Markdown.Italic) = h.em(_md_to_node.(i.text)...)
_md_to_node(c::Markdown.Code) = c.language == "" ? h.code(c.code) : h.pre(h.code(c.code))
_md_to_node(l::Markdown.Link) = h.a(href=l.url)(_md_to_node.(l.text)...)
_md_to_node(hdr::Markdown.Header{1}) = h.h1(_md_to_node.(hdr.text)...)
_md_to_node(hdr::Markdown.Header{2}) = h.h2(_md_to_node.(hdr.text)...)
_md_to_node(hdr::Markdown.Header{3}) = h.h3(_md_to_node.(hdr.text)...)
_md_to_node(hdr::Markdown.Header{4}) = h.h4(_md_to_node.(hdr.text)...)
_md_to_node(hdr::Markdown.Header{5}) = h.h5(_md_to_node.(hdr.text)...)
_md_to_node(hdr::Markdown.Header{6}) = h.h6(_md_to_node.(hdr.text)...)
_md_to_node(bq::Markdown.BlockQuote) = h.blockquote(_md_to_node.(bq.content)...)
_md_to_node(list::Markdown.List) = begin
    tag = list.ordered == -1 ? h.ul : h.ol
    tag([_li_for(item) for item in list.items]...)
end
_li_for(item) = begin
    info = _task_list_marker(item)
    info === nothing && return h.li(_md_to_node.(item)...)
    (checked, first_inline, rest_blocks) = info
    h.li(h.input(; type="checkbox", disabled=true,
                   checked = checked ? true : nothing),
         " ",
         _md_to_node.(first_inline)...,
         _md_to_node.(rest_blocks)...)
end
# GFM task-list detection: a list item whose first inline leaf starts with
# `[ ]`, `[x]`, or `[X]` (optionally followed by a space) renders as a
# disabled checkbox + the rest. Returns `(checked, first_inline_content,
# rest_blocks)` so the caller can splice the first paragraph's inlines
# directly beside the checkbox (no wrapping `<p>` that would force a line
# break) and render any trailing blocks normally.
_task_list_marker(item) = begin
    isempty(item) && return nothing
    first_block = item[1]
    first_block isa Markdown.Paragraph || return nothing
    content = first_block.content
    isempty(content) && return nothing
    leaf = content[1]
    leaf isa AbstractString || return nothing
    m = match(r"^\[([ xX])\][ \t]*(.*)$"s, leaf)
    m === nothing && return nothing
    checked = m.captures[1] != " "
    rest = String(m.captures[2])
    first_inline = isempty(rest) ? content[2:end] : vcat(Any[rest], content[2:end])
    (checked, first_inline, item[2:end])
end
_md_to_node(::Markdown.HorizontalRule) = h.hr()
_md_to_node(t::Markdown.Table) = begin
    align_attr(a::Symbol) = a === :l ? "left" :
                            a === :c ? "center" :
                            a === :r ? "right" : ""
    # MultiMarkdown colspan convention: an empty cell extends the preceding
    # non-empty cell rightward. `| A | B || D |` → B gets colspan=2 and the
    # empty cell is dropped. Leading empties (no preceding non-empty) stay
    # as plain empty cells.
    function collapse_empties(row)
        out = Tuple{Any, Int, Int}[]  # (content, colspan, first_col_idx)
        for (i, c) in enumerate(row)
            if isempty(c) && !isempty(out)
                (content, span, idx) = out[end]
                out[end] = (content, span + 1, idx)
            else
                push!(out, (c, 1, i))
            end
        end
        out
    end
    th_cell(content, a, i, span) = begin
        kids = _md_to_node.(content)
        al = align_attr(a)
        # Only single-column headers are click-to-sort. Spanning headers
        # (group labels) opt out — HTMXObjects' CSS already sets
        # `cursor: default` on `th[colspan]`. Guarded onclick so a click
        # without `sortable_table_js()` loaded is a silent no-op.
        onclick = span == 1 ? "if(window.sortTable)sortTable($(i-1),this)" : nothing
        cls     = span == 1 ? "u-pointer" : nothing
        colspan = span > 1 ? span : nothing
        h.th(; align=(al == "" ? nothing : al), colspan, onclick, class=cls)(kids...)
    end
    td_cell(content, a, span) = begin
        kids = _md_to_node.(content)
        al = align_attr(a)
        colspan = span > 1 ? span : nothing
        h.td(; align=(al == "" ? nothing : al), colspan)(kids...)
    end
    header, body = t.rows[1], @view t.rows[2:end]
    n_cols = length(header)
    # Master/detail auto-pairing. A body row that collapses to one cell of
    # `colspan=n_cols` (the natural output of `| stuff |||` in an n-col table)
    # is treated as a detail row and paired with the immediately preceding
    # primary, emitting matching `tr#row-<key>-<n>` / `tr#detail-<key>-<n>`
    # ids. HTMXObjects' `sortable_table_js()` already keeps such pairs glued
    # across sorts. Without that script the ids are inert. Per-table key
    # (hash of the parsed rows) keeps ids stable and collision-free across
    # multiple tables on a page. Only the first detail after a primary is
    # paired — `sortTable` looks up at most one companion per primary;
    # multi-companion support is a JS-side follow-up.
    body_collapsed = [collapse_empties(row) for row in body]
    is_full_span(cells) = length(cells) == 1 && cells[1][2] == n_cols
    row_ids = Vector{Union{String,Nothing}}(nothing, length(body_collapsed))
    if n_cols > 1
        key = string(hash(t.rows), base=16)
        pair_n = 0
        last_primary = 0
        for (i, cells) in enumerate(body_collapsed)
            if is_full_span(cells)
                if last_primary != 0 && row_ids[last_primary] === nothing
                    pair_n += 1
                    row_ids[last_primary] = "row-$key-$pair_n"
                    row_ids[i] = "detail-$key-$pair_n"
                end
            else
                last_primary = i
            end
        end
    end
    tr_for(i, cells) = begin
        children = [td_cell(c, get(t.align, idx, :l), span) for (c, span, idx) in cells]
        row_ids[i] === nothing ? h.tr(children...) : h.tr(; id=row_ids[i])(children...)
    end
    thead = h.thead(h.tr([th_cell(c, get(t.align, idx, :l), idx, span)
                          for (c, span, idx) in collapse_empties(header)]...))
    tbody = h.tbody([tr_for(i, cells) for (i, cells) in enumerate(body_collapsed)]...)
    h.table(; class="htmxo-sortable-table")(thead, tbody)
end
_md_to_node(l::Markdown.LaTeX) = "\$\$$(l.formula)\$\$"
_md_to_node(x) = string(x)

end # module HTMX
