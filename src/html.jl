# HTML entity escaping for `&`, `"`, `'`, `<`, `>` (formerly `Cobweb.escape`).
const _ESCAPE_PAIRS = ('&' => "&amp;", '"' => "&quot;", '\'' => "&#39;", '<' => "&lt;", '>' => "&gt;")
escape(x::AbstractString) = replace(x, _ESCAPE_PAIRS...)
_escape(io::IO, x::AbstractString, pairs) = replace(io, x, pairs...)
_html_escape(io::IO, x::AbstractString) = _escape(io, x, _ESCAPE_PAIRS)

function Base.show(io::IO, m::MIME"text/html", n::Node)
    a, kids = attrs(n), children(n)
    has_script = any(c -> c isa HyperscriptString, kids)
    print(io, '<', tag(n))
    for (k, v) in a
        # A normalized `_` attribute is moved to the end, unless the exact-
        # parts constructor supplied an existing `_` slot to replace.
        k === :(-) && continue
        if k === :(_)
            _html_hyperscript(io, a, kids, has_script)
            continue
        end
        # Omit string-valued "false" ONLY for true boolean attributes; for
        # enumerated/ARIA attributes "false" is meaningful and must render.
        v == "false" && k in _BOOLEAN_ATTRS && continue
        print(io, ' ', k, '=', '"')
        _html_escape(io, string(v))
        print(io, '"')
    end
    !haskey(a, :(_)) && (haskey(a, :(-)) || has_script) &&
        _html_hyperscript(io, a, kids, has_script)
    print(io, '>')
    for child in kids
        _html_child(io, m, child)
    end
    tag(n) in VOID_ELEMENTS || print(io, "</", tag(n), '>')
end

# Each fragment goes straight to the destination, so concatenation is linear
# and rendering never mutates the node's attributes or children.
function _html_hyperscript(io, a, kids, has_script)
    print(io, " _=\"")
    _html_escape(io, string(get(a, :(-), get(a, :(_), ""))))
    if has_script
        for c in kids
            c isa HyperscriptString || continue
            print(io, '\n')
            _html_escape(io, c)
        end
    end
    print(io, '"')
end
_html_child(io, m, child::Node) = show(io, m, child)
_html_child(io, m, ::HyperscriptString) = nothing
_html_child(io, m, child) = showable(m, child) ? show(io, m, child) : _html_escape(io, string(child))
