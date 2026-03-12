module HTMX

import Cobweb
export auto, h, Node, @__str

auto(x; wrap) = wrap(repr("text/html", x))
auto(x::AbstractString; wrap) = wrap(x)
auto(x::AbstractArray; wrap) = wrap(join(auto.(x; wrap=identity), "\n"))
auto((content, id)::Pair; wrap) = auto(h.div(id=id, hx_swap_oob="true")(content); wrap)

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
macro __str(ex)
    :($HyperscriptString($(esc(Meta.parse("\"$ex\"")))))
end
_flatten(args) = mapreduce(a -> isa(a, AbstractVector) ? a : [a], vcat, args; init=Any[])

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
h(tag, args...; kwargs...) = Node(tag, args...; kwargs...)
Base.getproperty(::typeof(h), tag::Symbol) = (args...; kwargs...)->h(tag, args...; kwargs...)

end # module HTMX
