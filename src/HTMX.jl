"""
    HTMX

Lightweight HTML builder wrapping [Cobweb.jl](https://github.com/JuliaComputing/Cobweb.jl).

# Exports
- [`h`](@ref) — tag-based HTML node builder (`h.div(...)`, `h.p("text")`)
- [`Node`](@ref) — immutable wrapper around `Cobweb.Node`
- [`auto`](@ref) — convert arbitrary values to HTML response strings
- [`@__str`](@ref) — string literal macro for [`HyperscriptString`](@ref)
"""
module HTMX

import Cobweb
import Markdown
export auto, h, Node, @__str, md_to_node

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

"""
    Node(tag, children...; attributes...)

Immutable wrapper around `Cobweb.Node`. Keyword arguments become HTML attributes
(underscores are converted to hyphens, e.g. `hx_get` → `hx-get`). Attributes set
to `nothing` or `false` are omitted; `true` renders as `name="true"` (browsers
treat the quoted value as truthy). Positional arguments become children.

Use call syntax to append children or merge attributes:

    node = h.div(class="container")
    node("child text")   # returns a new Node; original is unchanged

During HTML rendering, [`HyperscriptString`](@ref) children are moved to the `_`
attribute (for [hyperscript](https://hyperscript.org/)).
"""
struct Node
    parent::Cobweb.Node
    Node(n::Cobweb.Node) = new(n)
    Node(tag, args...; kwargs...) = new(Cobweb.h(tag, _flatten(args)...; _filter_attrs(kwargs)...))
end
Base.parent(n::Node) = getfield(n, :parent)
(n::Node)(args...; kwargs...) = Node(parent(n)(_flatten(args)...; _filter_attrs(kwargs)...))
Base.show(io, m::MIME"text/html", n::Node) = begin
    cn = parent(n)
    cn = Cobweb.Node(Cobweb.tag(cn), copy(Cobweb.attrs(cn)), copy(Cobweb.children(cn)))
    attrs = Cobweb.attrs(cn)
    haskey(attrs, :(-)) && (attrs[:(_)] = pop!(attrs, :(-)))
    filter!(Cobweb.children(cn)) do tag
        _absorb_hyperscript!(attrs, tag)
    end
    # Write opening tag ourselves to avoid Cobweb's "true" → bare attribute behavior
    print(io, '<', Cobweb.tag(cn))
    for (k, v) in attrs
        v == "false" && continue
        print(io, ' ', k, '=', '"', v, '"')
    end
    print(io, '>')
    for child in Cobweb.children(cn)
        showable("text/html", child) ? show(io, m, child) : print(io, child)
    end
    Cobweb.tag(cn) in Cobweb.VOID_ELEMENTS || print(io, "</", Cobweb.tag(cn), '>')
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
    Cobweb.tag(parent(content)) in _table_tags ? h.template(oob) : oob
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

_unwrap(n::Node) = parent(n)
_unwrap(n) = n

# Collect all text content from a node tree (for inline rendering)
_collect_text(n) = _collect_text_node(_unwrap(n))
_collect_text_node(n) = string(n)
function _collect_text_node(n::Cobweb.Node)
    tag = string(Cobweb.tag(n))
    children_text = join(_collect_text.(Cobweb.children(n)))
    tag == "strong" || tag == "b" ? "**$(children_text)**" :
    tag == "em" || tag == "i" ? "*$(children_text)*" :
    tag == "code" ? "`$(children_text)`" :
    tag == "a" ? "[$(children_text)]($(get(Cobweb.attrs(n), :href, "")))" :
    tag == "br" ? "\n" :
    children_text
end

const _md_mime = MIME"text/markdown"()

# Fallback: any non-Node value renders as its string representation
Base.show(io::IO, ::MIME"text/markdown", val) = print(io, string(val))

# Strings pass through as-is
Base.show(io::IO, ::MIME"text/markdown", val::AbstractString) = print(io, val)

# Arrays: render each element
Base.show(io::IO, m::MIME"text/markdown", val::AbstractArray) = foreach(v -> show(io, m, v), val)

# Node: dispatch by tag via _md(io, m, node, ::Val{tag})
Base.show(io::IO, m::MIME"text/markdown", n::Node) = _md_dispatch(io, m, _unwrap(n))
_md_dispatch(io, m, node) = show(io, m, node)
_md_dispatch(io, m, node::Cobweb.Node) = _md(io, m, node, Val(Cobweb.tag(node)))

# Default: print collected text if non-empty (unknown tags fall here)
function _md(io, m, node::Cobweb.Node, ::Val)
    text = _collect_text(node)
    isempty(strip(text)) || println(io, text)
end

_wrap_for_show(c::Cobweb.Node) = Node(c)
_wrap_for_show(c) = c

# Recurse into children as if the node were transparent
_md_recurse(io, m, node) = for c in Cobweb.children(node)
    show(io, m, _wrap_for_show(_unwrap(c)))
end

# Headings h1..h6
for lvl in 1:6
    @eval _md(io, m, node::Cobweb.Node, ::Val{$(QuoteNode(Symbol("h$lvl")))}) =
        println(io, $("#"^lvl), " ", _collect_text(node))
end

# Containers: recurse transparently
for t in (:div, :main, :body, :html, :head,
          :span, :ul, :ol, :thead, :tbody, :tr, :details, :summary,
          :form, :label, :nav, :footer, :dl)
    @eval _md(io, m, node::Cobweb.Node, ::Val{$(QuoteNode(t))}) = _md_recurse(io, m, node)
end

# Semantic blocks: emit a leading `---` divider so an agent reader can see
# where each block starts. Only leading (not trailing), so adjacent blocks
# produce a single divider between them rather than doubled.
for t in (:article, :section)
    @eval _md(io, m, node::Cobweb.Node, ::Val{$(QuoteNode(t))}) =
        (println(io); println(io, "---"); println(io); _md_recurse(io, m, node); println(io))
end

# <header> is the label/title of its surrounding block — render as a level-3
# heading so the structure is legible to an agent reader.
_md(io, m, node::Cobweb.Node, ::Val{:header}) = println(io, "### ", _collect_text(node))

# Non-content tags: skip
for t in (:script, :style, :meta, :link)
    @eval _md(io, m, node::Cobweb.Node, ::Val{$(QuoteNode(t))}) = nothing
end

# Block leaves
_md(io, m, node::Cobweb.Node, ::Val{:p})     = (println(io, _collect_text(node)); println(io))
_md(io, m, node::Cobweb.Node, ::Val{:li})    = println(io, "- ", _collect_text(node))
_md(io, m, node::Cobweb.Node, ::Val{:pre})   = (println(io, "```"); println(io, _collect_text(node)); println(io, "```"))
_md(io, m, node::Cobweb.Node, ::Val{:hr})    = println(io, "---")
_md(io, m, node::Cobweb.Node, ::Val{:table}) = _table_to_markdown(io, node)

# <title> → top-level heading (so a full page with <head><title>X</title></head> renders as "# X")
_md(io, m, node::Cobweb.Node, ::Val{:title}) = println(io, "# ", _collect_text(node))

# <blockquote> → "> "-prefixed lines
function _md(io, m, node::Cobweb.Node, ::Val{:blockquote})
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
function _md(io, m, node::Cobweb.Node, ::Val{:img})
    attrs = Cobweb.attrs(node)
    src = get(attrs, :src, "")
    isempty(src) && return
    println(io, "![", get(attrs, :alt, ""), "](", src, ")")
end

# Per-child folds for figure/table parsing, dispatched on Cobweb.Node vs
# anything else (text nodes, strings, etc.). The non-Node fallback is the
# "skip" branch that the previous `_is_cobweb_node(...) || continue` guards
# encoded; control flow now lives at the method boundary.
_figure_visit(::Any, src, alt, caption) = (src, alt, caption)
_figure_visit(cn::Cobweb.Node, src, alt, caption) = begin
    t = Cobweb.tag(cn)
    if t === :img && isempty(src)
        a = Cobweb.attrs(cn)
        return (get(a, :src, ""), get(a, :alt, ""), caption)
    elseif t === :figcaption
        return (src, alt, _collect_text(cn))
    end
    (src, alt, caption)
end

# <figure><img><figcaption> → ![caption](src); fall back to recursion if no <img>
function _md(io, m, node::Cobweb.Node, ::Val{:figure})
    src = ""; alt = ""; caption = ""
    for c in Cobweb.children(node)
        src, alt, caption = _figure_visit(_unwrap(c), src, alt, caption)
    end
    isempty(src) && return _md_recurse(io, m, node)
    label = isempty(caption) ? alt : caption
    println(io, "![", label, "](", src, ")")
end

_collect_table_rows!(rows, ::Any) = nothing
_collect_table_rows!(rows, section::Cobweb.Node) = for row in Cobweb.children(section)
    _push_tr!(rows, _unwrap(row))
end
_push_tr!(rows, ::Any) = nothing
_push_tr!(rows, r::Cobweb.Node) = string(Cobweb.tag(r)) == "tr" && push!(rows, r)

_push_cell_text!(cells, ::Any) = nothing
_push_cell_text!(cells, c::Cobweb.Node) = push!(cells, _collect_text(c))

function _table_to_markdown(io::IO, table)
    table = _unwrap(table)
    rows = Cobweb.Node[]
    for section in Cobweb.children(table)
        _collect_table_rows!(rows, _unwrap(section))
    end
    isempty(rows) && return
    for (i, row) in enumerate(rows)
        cells = String[]
        for c in Cobweb.children(row)
            _push_cell_text!(cells, _unwrap(c))
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
_md_to_node(c::Markdown.Code) = c.language == "" ? h.code(Cobweb.escape(c.code)) : h.pre(h.code(Cobweb.escape(c.code)))
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
    tag([h.li(_md_to_node.(item)...) for item in list.items]...)
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
