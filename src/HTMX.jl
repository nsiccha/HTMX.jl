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
export auto, h, Node, @__str

"""
    auto(x; wrap=identity)

Convert `x` to an HTML string, applying `wrap` to the result.

- `AbstractString` — passed through to `wrap`
- `AbstractArray` — elements are recursively `auto`'d and joined with newlines
- `Pair(content, id)` — wrapped in an OOB-swap `div` with `hx-swap-oob="true"`
- Anything else — rendered via `repr("text/html", x)`
"""
auto(x; wrap) = wrap(repr("text/html", x))
auto(x::AbstractString; wrap) = wrap(x)
auto(x::AbstractArray; wrap) = wrap(join(auto.(x; wrap=identity), "\n"))
auto((content, id)::Pair; wrap) = auto(h.div(id=id, hx_swap_oob="true")(content); wrap)

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
_flatten(args) = mapreduce(a -> isa(a, AbstractVector) ? a : [a], vcat, args; init=Any[])
_filter_attrs(kwargs) = (k => (v === true ? "true" : string(v)) for (k, v) in kwargs if v !== nothing && v !== false)

"""
    Node(tag, children...; attributes...)

Immutable wrapper around `Cobweb.Node`. Keyword arguments become HTML attributes
(underscores are converted to hyphens, e.g. `hx_get` → `hx-get`). Attributes set
to `nothing` or `false` are omitted; `true` renders as a bare attribute. Positional
arguments become children.

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
    n = parent(n)
    n = Cobweb.Node(Cobweb.tag(n), copy(Cobweb.attrs(n)), copy(Cobweb.children(n))) 
    attrs = Cobweb.attrs(n)
    haskey(attrs, :(-)) && (attrs[:(_)] = pop!(attrs, :(-)))
    filter!(Cobweb.children(n)) do tag
        isa(tag, HyperscriptString) || return true
        attrs[:(_)] = get(attrs, :(_), "") * "\n" * tag
        return false
    end
    show(io, m, n)
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
as a bare attribute (e.g. `checked` not `checked="true"`).
"""
h(tag, args...; kwargs...) = Node(tag, args...; kwargs...)
Base.getproperty(::typeof(h), tag::Symbol) = (args...; kwargs...)->h(tag, args...; kwargs...)

# --- Markdown rendering ---

_unwrap(n::Node) = parent(n)
_unwrap(n) = n

# Collect all text content from a node tree (for inline rendering)
function _collect_text(n)
    n = _unwrap(n)
    n isa Cobweb.Node || return string(n)
    tag = string(Cobweb.tag(n))
    children_text = join(_collect_text.(Cobweb.children(n)))
    tag == "strong" || tag == "b" ? "**$(children_text)**" :
    tag == "em" || tag == "i" ? "*$(children_text)*" :
    tag == "code" ? "`$(children_text)`" :
    tag == "a" ? "[$(children_text)]($(get(Cobweb.attrs(n), :href, "")))" :
    tag == "br" ? "\n" :
    children_text
end

# Render a node tree as markdown lines
function _node_to_markdown(io::IO, n; depth=0)
    n = _unwrap(n)
    if !(n isa Cobweb.Node)
        print(io, string(n))
        return
    end
    tag = string(Cobweb.tag(n))
    children = Cobweb.children(n)

    if tag in ("h1", "h2", "h3", "h4", "h5", "h6")
        level = parse(Int, tag[2])
        println(io, "#"^level, " ", _collect_text(n))
    elseif tag == "p"
        println(io, _collect_text(n))
        println(io)
    elseif tag == "li"
        println(io, "- ", _collect_text(n))
    elseif tag == "pre"
        println(io, "```")
        println(io, _collect_text(n))
        println(io, "```")
    elseif tag == "hr"
        println(io, "---")
    elseif tag == "table"
        _table_to_markdown(io, n)
    elseif tag in ("div", "main", "section", "article", "body", "html", "head",
                    "span", "ul", "ol", "thead", "tbody", "tr", "details", "summary",
                    "form", "label", "nav", "header", "footer", "dl")
        for c in children
            _node_to_markdown(io, c)
        end
    elseif tag == "script" || tag == "style" || tag == "meta" || tag == "link"
        # skip non-content nodes
    else
        # Fallback: render inline text
        text = _collect_text(n)
        isempty(strip(text)) || println(io, text)
    end
end

function _table_to_markdown(io::IO, table)
    table = _unwrap(table)
    rows = Cobweb.Node[]
    for section in Cobweb.children(table)
        s = _unwrap(section)
        s isa Cobweb.Node || continue
        for row in Cobweb.children(s)
            r = _unwrap(row)
            r isa Cobweb.Node && string(Cobweb.tag(r)) == "tr" && push!(rows, r)
        end
    end
    isempty(rows) && return
    for (i, row) in enumerate(rows)
        cells = [_collect_text(c) for c in Cobweb.children(row) if _unwrap(c) isa Cobweb.Node]
        println(io, "| ", join(cells, " | "), " |")
        if i == 1
            println(io, "| ", join(fill("---", length(cells)), " | "), " |")
        end
    end
    println(io)
end

Base.show(io::IO, ::MIME"text/markdown", n::Node) = _node_to_markdown(io, n)

end # module HTMX
