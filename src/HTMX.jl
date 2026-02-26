module HTMX

import Cobweb
export auto

auto(x; wrap=html) = wrap(repr("text/html", x))
auto(x::AbstractArray; wrap=html) = wrap(join(auto.(x; wrap=identity), "\n"))
auto((content, target)::Pair; wrap=html) = auto(h.div(hx_swap_oob=target)(content); wrap)
struct Node
    parent::Cobweb.Node
    Node(n::Cobweb.Node) = new(n)
    Node(args...; kwargs...) = new(Cobweb.h(args...; kwargs...))
end
Base.parent(n::Node) = getfield(n, :parent)
(n::Node)(args...; kwargs...) = Node(parent(n)(args...; kwargs...))
Base.show(io, m::MIME"text/html", n::Node) = begin 
    attrs = Cobweb.attrs(parent(n))
    haskey(attrs, :(-)) && (attrs[:(_)] = pop!(attrs, :(-)))
    show(io, m, parent(n))
end
h(tag, args...; kwargs...) = Node(tag, args...; kwargs...)
Base.getproperty(::typeof(h), tag::Symbol) = (args...; kwargs...)->h(tag, args...; kwargs...)

end # module HTMX
