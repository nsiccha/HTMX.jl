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

"""
    Node(tag, children...; attributes...)

Immutable wrapper around `Cobweb.Node`. Keyword arguments become HTML attributes
(underscores are converted to hyphens, e.g. `hx_get` → `hx-get`). Positional
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
    Node(tag, args...; kwargs...) = new(Cobweb.h(tag, _flatten(args)...; kwargs...))
end
Base.parent(n::Node) = getfield(n, :parent)
(n::Node)(args...; kwargs...) = Node(parent(n)(_flatten(args)...; kwargs...))
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
become children. Boolean attribute `"true"` renders as a bare attribute; `"false"` is omitted.
"""
h(tag, args...; kwargs...) = Node(tag, args...; kwargs...)
Base.getproperty(::typeof(h), tag::Symbol) = (args...; kwargs...)->h(tag, args...; kwargs...)

end # module HTMX
