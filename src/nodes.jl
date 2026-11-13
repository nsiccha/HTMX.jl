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
_push_flat!(out, a::AbstractVector) = append!(out, a)
# A vector that can hold `nothing`: append it, then close the gaps in the
# appended tail in place (`out` is `_flatten`'s own fresh buffer).
function _push_flat!(out, a::AbstractVector{>:Nothing})
    n = length(out)
    append!(out, a)
    for i in n+1:length(out)
        c = out[i]
        isnothing(c) || (out[n += 1] = c)
    end
    resize!(out, n)
end
_push_flat!(out, a) = push!(out, a)
_push_flat!(out, ::Nothing) = out
# Flatten one level of positional children in linear time: a vector argument
# splices its elements in order, anything else becomes one child. (Folding
# `vcat` across the arguments instead is quadratic in the child count.) A
# `nothing` child, or a `nothing` element of a vector, is no child at all, as a
# `nothing` attribute is no attribute: `cond ? h.p("x") : nothing` leaves the
# paragraph out instead of writing the text "nothing".
function _flatten(args)
    out = Any[]
    for a in args
        _push_flat!(out, a)
    end
    out
end

function _attributes!(out, kwargs)
    for (k, v) in kwargs
        v === nothing || v === false ||
            (out[_attr_symbol(k)] = v === true ? "true" : string(v))
    end
    out
end

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
value as truthy). Positional arguments become children. An `AbstractVector`
argument is flattened one level: its elements become children in order, so a
long child list can be passed as one vector instead of splatted. A `nothing`
child (or vector element) is dropped, as a `nothing` attribute is, so an
optional child is written `cond ? h.p("x") : nothing`.

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
         _attributes!(OrderedDict{Symbol,Any}(), kwargs),
         _flatten(args))

# Call syntax appends children / merges attributes, returning a NEW node
# (the original's vectors and dict are left untouched).
(n::Node)(args...; kwargs...) =
    Node(tag(n),
         _attributes!(copy(attrs(n)), kwargs),
         vcat(children(n), _flatten(args)))

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
become children. An `AbstractVector` argument is flattened one level: its
elements become children in order, so a long child list can be passed as one
vector instead of splatted. A `nothing` child (or vector element) is dropped,
so `cond ? h.p("x") : nothing` writes the paragraph or nothing. Attributes set
to `nothing` or `false` are omitted; `true` renders as `name="true"` (browsers
treat the quoted value as truthy).
"""
h(tag, args...; kwargs...) = Node(tag, args...; kwargs...)
Base.getproperty(::typeof(h), tag::Symbol) = (args...; kwargs...)->h(tag, args...; kwargs...)
