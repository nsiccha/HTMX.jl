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
function auto(xs::AbstractArray; wrap)
    io = IOBuffer()
    buffer = IOBuffer()
    first = true
    for x in xs
        first || print(io, '\n')
        _auto_write(io, buffer, x)
        first = false
    end
    wrap(String(take!(io)))
end

# Keep public auto dispatch for foreign values, pairs and nested arrays. Nodes
# reuse one staging buffer instead of allocating a repr string for each item.
# Reset it for each node so foreign HTML children still see the same stream
# position as in an independent repr call, including after a shorter item.
_auto_write(io, buffer, x) = print(io, auto(x; wrap=identity))
function _auto_write(io, buffer, x::Node)
    truncate(buffer, 0)
    seekstart(buffer)
    show(buffer, MIME"text/html"(), x)
    seekstart(buffer)
    write(io, buffer)
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
