# --- Markdown rendering ---

const _md_mime = MIME"text/markdown"()

# Fallback: any non-Node value renders as its string representation
Base.show(io::IO, ::MIME"text/markdown", val) = print(io, string(val))

# Strings pass through as-is
Base.show(io::IO, ::MIME"text/markdown", val::AbstractString) = print(io, val)

# Arrays: render each element as siblings, the way a node's children render
Base.show(io::IO, m::MIME"text/markdown", val::AbstractArray) = _md_show(io, m, val)

# Block boundaries. Containers (div, nav, main, ...) mix inline runs and block
# elements, so a block can follow inline text on the same line
# (`[link](/)# Title`). Markdown is written through `_MDStream`, which records
# how the output so far ends; a block that would start mid-line first closes
# the inline run as a paragraph. One stream spans a whole top-level `show` and
# carries the ids that the document's in-page links point at.
mutable struct _MDStream{T<:IO} <: IO
    io::T
    newlines::Int  # trailing '\n' count, capped at 2; 2 = start of output
    open::Bool     # the line so far is only a block prefix or inline opener
    lazy::Bool     # a list item or block container just ended
    blocks::Int    # block elements started, or containers that split content
    inline::Int    # depth of content that must stay one paragraph
    line::Int      # depth of content that must stay one line (a heading)
    code::Int      # depth of code spans
    breaks::Int    # `<br>`s waiting for the content they precede
    item::Int      # depth of list items being written
    items::Int     # list items written so far
    number::Union{Nothing,Int}  # next `<ol>` item number; nothing outside an `<ol>`
    last_list::Symbol  # kind (:ul/:ol) of a list that just ended, else :none
    lang::String   # language of the enclosing content; "" = not declared
    targets::Set{String}  # ids that in-page links of the document point at
    anchor::Bool   # the output so far ends with an id anchor `[]{#…}`
    probe::Bool    # stop a layout probe as soon as a block is found
end
_MDStream(io::IO; inline=0, line=0, code=0, item=0, lang="", targets=Set{String}(), probe=false) =
    _MDStream(io, 2, false, false, 0, inline, line, code, 0, item, 0, nothing, :none, lang, targets, false, probe)

# Foreign show methods are evaluated once per occurrence while discovering
# links. Capture writes and Node emissions separately: nodes must still render
# in their final block/list/table/language context, not into an early string.
# Everything captured belongs to this render; neither input nodes nor a global
# object cache are mutated. Context-dependent foreign output is replayed only
# when every IO property it inspected still has the same value.
struct _MDRecorded
    original::Any
    parts::Vector{Any}
    reads::Vector{Tuple{Any,Any,Any}}
end
struct _MDContext
    value::Any
    context::IOContext
end
struct _MDRecorder{T<:IO} <: IO
    context::T
    buffer::IOBuffer
    parts::Vector{Any}
    reads::Vector{Tuple{Any,Any,Any}}
end
_MDRecorder(io) = _MDRecorder(io, IOBuffer(), Any[], Tuple{Any,Any,Any}[])
Base.write(io::_MDRecorder, b::UInt8) = write(io.buffer, b)
Base.unsafe_write(io::_MDRecorder, p::Ptr{UInt8}, n::UInt) = unsafe_write(io.buffer, p, n)
function Base.get(io::_MDRecorder, key, default)
    value = get(io.context, key, default)
    push!(io.reads, (key, default, value))
    value
end
function _md_flush_recording(io::_MDRecorder)
    position(io.buffer) == 0 || push!(io.parts, String(take!(io.buffer)))
    nothing
end
_md_recorder(io) = nothing
_md_recorder(io::_MDRecorder) = io
_md_recorder(io::IOContext) = _md_recorder(io.io)
function _md_record(io, m, x)
    recorder = _MDRecorder(io)
    show(recorder, m, x)
    _md_flush_recording(recorder)
    _MDRecorded(x, recorder.parts, recorder.reads)
end
function Base.show(io::IO, m::MIME"text/markdown", x::_MDRecorded)
    if all(((key, default, value),) -> isequal(get(io, key, default), value), x.reads)
        foreach(part -> show(io, m, part), x.parts)
    else
        show(io, m, x.original)
    end
end
Base.show(io::IO, m::MIME"text/markdown", x::_MDContext) = show(IOContext(io, x.context), m, x.value)

function _md_show(io, m, x)
    recorder = _md_recorder(io)
    if recorder !== nothing
        _md_flush_recording(recorder)
        push!(recorder.parts, io isa IOContext ? _MDContext(x, io) : x)
        return nothing
    end
    targets = Set{String}()
    prepared = get(io, :md_verbatim, false) || get(io, :md_scan, false) ? x :
        _md_prepare(io, m, x, targets)
    _md_emit(_MDStream(io; targets), m, prepared)
end
_md_show(io::_MDStream, m, x) = _md_emit(io, m, x)
_md_emit(s, m, n::Node) = _md_node(s, m, n)
_md_emit(s, m, xs::AbstractArray) = foreach(x -> _md_child(s, m, x), xs)

function _md_prepare(io, m, n::Node, targets)
    targets !== nothing && tag(n) === :a &&
        _md_push_target!(targets, get(attrs(n), :href, nothing))
    kids = children(n)
    prepared = nothing
    for (i, child) in enumerate(kids)
        value = _md_prepare(io, m, child, targets)
        if value !== child
            prepared === nothing && (prepared = copy(kids))
            prepared[i] = value
        end
    end
    prepared === nothing ? n : Node(tag(n), attrs(n), prepared)
end
_md_prepare(io, m, xs::AbstractArray, targets) = map(x -> _md_prepare(io, m, x, targets), xs)
_md_prepare(io, m, x::Number, targets) = x
_md_prepare(io, m, x::AbstractString, targets) =
    (targets === nothing || _md_scan_targets!(targets, x); x)
function _md_prepare(io, m, x::_MDContext, targets)
    _MDContext(_md_prepare(IOContext(io, x.context), m, x.value, targets), x.context)
end
function _md_prepare(io, m, x, targets)
    recording = _md_record(io, m, x)
    prepared = _MDRecorded(x, _md_prepare(io, m, recording.parts, nothing), recording.reads)
    # Scan the combined output: a foreign renderer can build one link across
    # several writes and nested nodes. Nested recordings are prepared without
    # scanning, so each outer foreign subtree is replayed only once here.
    if targets !== nothing
        text = sprint(show, m, prepared; context=IOContext(io, :md_scan => true))
        _md_scan_targets!(targets, text)
    end
    prepared
end

struct _MDBlockFound <: Exception end
function _md_count_block(s::_MDStream)
    s.probe && throw(_MDBlockFound())
    s.blocks += 1
    nothing
end

Base.get(s::_MDStream, key, default) = get(s.io, key, default)

# Content written right after a list item would continue it lazily, and content
# after a block container belongs to a new paragraph, so anything but the next
# item starts after a blank line.
function _md_before_write!(s::_MDStream, byte::UInt8, all_newlines::Bool)
    if s.lazy && byte != UInt8('\n')
        s.lazy = false
        s.newlines < 2 && (_md_count_block(s); write(s.io, "\n"^(2 - s.newlines)))
    end
    s.breaks > 0 && _md_write_breaks!(s, byte, all_newlines)
end
# A `<br>` is written with the content after it. Line endings alone end the
# block, where HTML shows no break either, so the waiting breaks are dropped.
# Otherwise each is a hard line break, a `\` ending the line; a code span,
# which cannot hold one, is closed around them, and a heading, which is one
# line, gets a space.
function _md_write_breaks!(s::_MDStream, byte::UInt8, all_newlines::Bool)
    n, s.breaks = s.breaks, 0
    all_newlines && return
    if s.line > 0
        write(s.io, ' ')
    elseif s.code > 0
        write(s.io, '`', "\\\n"^n, '`')
    else
        # content that starts with its own line ending needs only the last `\`
        write(s.io, "\\\n"^(n - 1), byte == UInt8('\n') ? "\\" : "\\\n")
    end
    nothing
end
function _md_after_write!(s::_MDStream, trailing::Int, all_newlines::Bool)
    s.newlines = min(2, all_newlines ? s.newlines + trailing : trailing)
    s.open = false
    s.anchor = false
    all_newlines || (s.last_list = :none)
end
# Whitespace-only text between elements carries no content: it neither ends a
# list item nor starts an inline run.
_md_blank(byte::UInt8) = byte == UInt8(' ') || byte == UInt8('\t')
function Base.write(s::_MDStream, b::UInt8)
    _md_blank(b) && return write(s.io, b)
    newline = b == UInt8('\n')
    _md_before_write!(s, b, newline)
    n = write(s.io, b)
    _md_after_write!(s, Int(newline), newline)
    n
end
function Base.unsafe_write(s::_MDStream, p::Ptr{UInt8}, n::UInt)
    all(i -> _md_blank(unsafe_load(p, i)), 1:n) && return unsafe_write(s.io, p, n)
    trailing = 0
    while trailing < n && unsafe_load(p, n - trailing) == UInt8('\n')
        trailing += 1
    end
    _md_before_write!(s, unsafe_load(p), trailing == n)
    written = unsafe_write(s.io, p, n)
    _md_after_write!(s, trailing, trailing == n)
    written
end

# Start a block element on its own line. Content that ends mid-line is an
# inline run, closed here as a paragraph by `close` (less for a block that
# opens with its own newlines); a block right after a prefix (`- `, `## `) or
# inline opener (`**`, `[`) stays inline as before.
function _md_block_start(s::_MDStream, close="\n\n")
    _md_count_block(s)
    _md_close_inline(s, close)
    nothing
end
# Close an inline run that ends mid-line; returns whether there was one.
_md_close_inline(s::_MDStream, close="\n\n") = s.newlines == 0 && !s.open && (print(s, close); true)
# Write a block prefix or inline opener that the element's content follows.
_md_open(s::_MDStream, prefix) = (print(s, prefix); s.open = true; nothing)
# Write an inline closer (`**`, `](…)`). A closer cannot start a line, so a
# `<br>` waiting before it is written after it.
_md_close(s::_MDStream, parts...) =
    (n = s.breaks; s.breaks = 0; print(s, parts...); s.breaks = n; nothing)
_md_next_list_item(s::_MDStream) = (s.lazy = false; nothing)
_md_end_list_item(s::_MDStream) = (s.lazy = true; nothing)
# Finish a block whose content may end mid-line.
_md_end_line(s::_MDStream) = (s.newlines == 0 && println(s); nothing)
# End the output so far with a blank line (unless it is still empty).
_md_blank_line(s::_MDStream) = (s.newlines < 2 && print(s, "\n"^(2 - s.newlines)); nothing)

# A block container (div, nav, ...) is a paragraph boundary: inline text before
# it is closed as a paragraph, and content after it starts a new one. It adds no
# trailing blank line of its own, so nested containers and the end of output
# stay as they are. Inside content that must stay one paragraph (an inline
# element, a heading, a figure caption) it is transparent.
_md_container_start(s::_MDStream) =
    (s.inline == 0 && _md_close_inline(s) && _md_count_block(s); nothing)
_md_container_end(s::_MDStream) = (s.inline == 0 && (s.lazy = true; s.breaks = 0); nothing)
_md_container(s::_MDStream, m, node) =
    (_md_container_start(s); _md_recurse(s, m, node); _md_container_end(s))
# Recurse into content that must stay one paragraph.
_md_inline_recurse(s::_MDStream, m, node) =
    (s.inline += 1; _md_recurse(s, m, node); s.inline -= 1; nothing)

# Node: dispatch by tag via _md(io, m, node, ::Val{tag}), with the node's own
# id and language written as its kind places them (see `_md_attrs`)
Base.show(io::IO, m::MIME"text/markdown", n::Node) = _md_show(io, m, n)
function _md_node(s::_MDStream, m, n::Node)
    v = Val(tag(n))
    id, lang = _md_link_id(s, n), _md_lang_change(s, n)
    isnothing(id) && isnothing(lang) && return _md(s, m, n, v)
    _md_attrs(s, m, n, v, id, lang, _md_attr_kind(v))
end

# Language of parts. An element whose `lang` differs from the enclosing
# language is written in a Pandoc language scope, which Quarto carries into its
# output (Typst `set text(lang: …)`, LaTeX `otherlanguage`): a block becomes a
# fenced div `::: {lang="en"}`, inline content a bracketed span
# `[…]{lang="en"}`. A block where a fence would break the line (inside inline
# content, a list item or a table cell) becomes a span too. `<html lang>` is the
# document language, which Quarto takes from its own `lang:` setting, so it
# writes nothing. Inside a `<pre>` body every child stays verbatim.
_md_declared_lang(n::Node) = (l = get(attrs(n), :lang, nothing);
    l === nothing || l === false || isempty(string(l)) ? nothing : string(l))
_md_same_lang(a, b) = lowercase(a) == lowercase(b)
function _md_lang_change(s::_MDStream, n::Node)
    lang = _md_declared_lang(n)
    isnothing(lang) || get(s, :md_verbatim, false) || _md_same_lang(lang, s.lang) ? nothing : lang
end
# The language a table row or cell inherits: its own, else its section's.
_md_own_lang(n::Node, lang) = something(_md_declared_lang(n), lang)

# Element ids. An element's `id` is written only when an in-page link of the
# same document points at it (`[…](#id)`): most ids in an HTMX page name
# hx-swap targets, not places in the document, and Markdown without in-page
# links stays as it was. Quarto stops on a link to a missing label, so every
# such id is written where Pandoc keeps it as a Typst label:
# - a block element: a fenced div `::: {#id}`, which also carries the element's
#   language (`::: {#id lang="en"}`);
# - a heading: `## Title {#id}`; a section or article: on the heading that opens
#   it, Pandoc's own model of a section, else as a block;
# - anything else, and a block where a fence would break the line: an empty
#   anchor span `[]{#id}` in front of the element. Pandoc's Typst writer drops
#   an image's own id, and Typst keeps one label per position (a span that ends
#   where an enclosing labelled span ends loses its label), so an id never goes
#   on a span around content, and two anchors in a row are kept apart by a
#   zero-width space.
# An id the `#` shorthand cannot spell is written `{id="…"}`.

# Link targets are collected by preparation from both Node links and literal
# Markdown writes. The prepared tree shares all unchanged input nodes.
function _md_push_target!(t, href)
    h = string(something(href, ""))
    startswith(h, '#') && length(h) > 1 && push!(t, h[nextind(h, 1):end])
    t
end
_md_scan_targets!(t, text) = (for mt in eachmatch(r"\]\(#([^\s)]+)", text); push!(t, mt[1]); end; t)

# The id of `n` to write: its `id`, when a link of the document points at it.
function _md_link_id(s::_MDStream, n::Node)
    id = get(attrs(n), :id, nothing)
    (id === nothing || id === false) && return nothing
    id = string(id)
    id in s.targets ? id : nothing
end
_md_link_ids(s::_MDStream, n::Node) = (id = _md_link_id(s, n); isnothing(id) ? String[] : [id])

# An empty anchor span in front of what follows. A block prefix or inline
# opener written just before it (`- `, `## `) stays open, so the element's own
# content still follows on that line.
_md_anchor(s::_MDStream, ::Nothing) = nothing
function _md_anchor(s::_MDStream, id::AbstractString)
    open = s.open
    s.anchor && print(s, '\u200b')
    print(s, "[]", _md_attr_block(id))
    s.open = open
    s.anchor = true
    nothing
end

# Inside inline content or a table cell, block markup is plain text.
_md_inline_context(s::_MDStream) = s.inline > 0 || get(s, :md_table_cell, false)
# There, and in a list item, a fenced div would break the line.
_md_span_context(s::_MDStream) = _md_inline_context(s) || s.item > 0

# How an element's own id and language are written.
_md_attr_kind(::Val) = Val(:inline)
_md_attr_kind(::Val{:html}) = Val(:document)
_md_attr_kind(::Val{:li}) = Val(:item)        # the item writes them after its marker
_md_attr_kind(::Val{:figure}) = Val(:figure)  # the figure writes its own id
for lvl in 1:6
    @eval _md_attr_kind(::Val{$(QuoteNode(Symbol("h$lvl")))}) = Val(:heading)
end
for t in (:article, :section)
    @eval _md_attr_kind(::Val{$(QuoteNode(t))}) = Val(:section)
end
for t in (:br, :hr, :head, :script, :style, :meta, :link, :button)
    @eval _md_attr_kind(::Val{$(QuoteNode(t))}) = Val(:none)  # no language scope
end

_md_attrs(s, m, n, v, id, lang, ::Val{:none}) = (_md_anchor(s, id); _md(s, m, n, v))
_md_attrs(s, m, n, v, id, lang, ::Val{:document}) =
    _md_in_lang(t -> _md_attrs(t, m, n, v, id, nothing, Val(:block)), s, lang)
_md_attrs(s, m, n, v, id, lang, ::Val{:item}) = _md(s, m, n, v; id, lang)
_md_attrs(s, m, n, v, id, lang, ::Val{:figure}) = _md_attrs(s, m, n, v, nothing, lang, Val(:block))
_md_attrs(s, m, n, v, id, lang, ::Val{:inline}) =
    (_md_anchor(s, id); _md_lang_span(t -> _md(t, m, n, v), s, lang))
function _md_attrs(s, m, n, v, id, lang, ::Val{:block})
    isnothing(id) && isnothing(lang) && return _md(s, m, n, v)
    _md_span_context(s) && return _md_attrs(s, m, n, v, id, lang, Val(:inline))
    _md_fenced_div(t -> _md(t, m, n, v), s, id, lang)
end
# A heading keeps its id on its line wherever it is a heading, which it is not
# inside inline content, a table cell or a language span.
function _md_attrs(s, m, n, v, id, lang, ::Val{:heading})
    if _md_inline_context(s) || (!isnothing(lang) && _md_span_context(s))
        return _md_attrs(s, m, n, v, id, lang, Val(:inline))
    end
    heading(t) = _md(t, m, n, v; id)
    isnothing(lang) ? heading(s) : _md_fenced_div(heading, s, nothing, lang)
end
# A section's id goes on the heading that opens it, unless that heading
# writes an id of its own; else the section is a block.
function _md_attrs(s, m, n, v, id, lang, ::Val{:section})
    i = isnothing(id) || _md_inline_context(s) ? nothing : _md_opening_heading(s, n)
    isnothing(i) && return _md_attrs(s, m, n, v, id, lang, Val(:block))
    kids = copy(children(n))
    kids[i] = kids[i](; id)
    _md_attrs(s, m, Node(tag(n), attrs(n), kids), v, nothing, lang, Val(:block))
end
# The index of the heading that is `n`'s first child, if it writes no id of its own.
function _md_opening_heading(s, n)
    for (i, c) in enumerate(children(n))
        c isa AbstractString && all(isspace, c) && continue
        return c isa Node && _md_attr_kind(Val(tag(c))) === Val(:heading) &&
            isnothing(_md_link_id(s, c)) ? i : nothing
    end
    nothing
end

function _md_in_lang(f, s::_MDStream, lang)
    prev = s.lang
    s.lang = lang
    f(s)
    s.lang = prev
    nothing
end
_md_in_lang(f, s::_MDStream, ::Nothing) = f(s)
function _md_fenced_div(f, s::_MDStream, id, lang)
    _md_block_start(s)
    _md_blank_line(s)
    println(s, "::: ", _md_attr_block(id, :lang => lang))
    println(s)
    _md_in_lang(f, s, lang)
    _md_end_line(s)
    println(s, ":::")
    print(s, "\n")
end
# The span's content renders into its own buffer, so the leading and trailing
# line breaks of a block inside it stay outside the brackets. The brackets
# leave no trace in Typst, so an anchor on either side of them is adjacent to
# one inside.
_md_lang_span(f, s::_MDStream, ::Nothing) = f(s)
function _md_lang_span(f, s::_MDStream, lang)
    buf = IOBuffer()
    t = _MDStream(IOContext(buf, s.io); inline=s.inline + 1, line=s.line, code=s.code,
                  item=s.item, lang, targets=s.targets, probe=s.probe)
    t.anchor = s.anchor
    f(t)
    s.blocks += t.blocks
    text = strip(String(take!(buf)), '\n')
    if !isempty(text)
        print(s, _md_lang_span_text(text, lang))
        s.anchor = t.anchor
    end
    s.breaks += t.breaks  # a break that ends the span is written after it
    nothing
end
_md_lang_span_text(text, lang) = string("[", text, "]", _md_attr_block(nothing, :lang => lang))

# A Pandoc attribute block, `{#id lang="en"}`: the id, written `id="…"` when the
# `#` shorthand cannot spell it (letters, digits and `_ . : -`), then each
# `key => value` that is not `nothing`.
function _md_attr_block(id, pairs::Pair...)
    parts = String[]
    isnothing(id) ||
        push!(parts, occursin(r"^[\p{L}\p{N}_.:-]+$", id) ? "#" * id : "id=" * _md_attr_value(id))
    for (k, v) in pairs
        isnothing(v) || push!(parts, string(k, "=", _md_attr_value(v)))
    end
    string("{", join(parts, " "), "}")
end
# A quoted Pandoc attribute value; a line break becomes a space, so the
# attribute stays on its line (a heading, a table row).
_md_attr_value(v) =
    string('"', replace(string(v), '\\' => "\\\\", '"' => "\\\"", r"\r\n?|\n" => " "), '"')

# Default: recurse transparently (unknown tags fall here)
_md(io, m, node::Node, ::Val) = _md_recurse(io, m, node)

"""
    HTMX.markdown_block(x) -> Bool

Whether a non-`Node` value `x` is a block in Markdown, as a `div` is. Among a
node's children (or a vector's elements), a block starts on its own line —
inline text before it is closed as a paragraph — and whatever follows it starts
a new paragraph. Otherwise `x`'s `show(io, MIME"text/markdown"(), x)` output is
spliced into the running line, as inline text is. Defaults to `false`; declare
it for a type whose HTML is a block element, so its siblings do not run into it:

```julia
HTMX.markdown_block(::MyCard) = true
```

A `Node` is a block or not by its tag; this function is not consulted for it.
"""
markdown_block(x) = false
markdown_block(x::_MDRecorded) = markdown_block(x.original)

# Recurse into children as if the node were transparent
_md_recurse(io, m, node) = for c in children(node)
    _md_child(io, m, c)
end
# One child among its siblings. Outside a Markdown stream (a `<pre>` body)
# children are written verbatim.
_md_child(io, m, c) = show(io, m, c)
_md_child(io::_MDStream, m, c) = markdown_block(c) ?
    (_md_container_start(io); show(io, m, c); _md_container_end(io)) : show(io, m, c)

# Inline formatting — written straight to io (no intermediate strings). These
# fire for inline elements everywhere EXCEPT inside <pre>: its handler recurses
# into the <code> child's own children, so _md is never dispatched on <code>
# there and no backticks leak into the fenced block. Their content stays one
# paragraph (a `div` inside a link card stays inside the link text).
for t in (:strong, :b)
    @eval _md(io, m, node::Node, ::Val{$(QuoteNode(t))}) =
        (_md_open(io, "**"); _md_inline_recurse(io, m, node); _md_close(io, "**"))
end
for t in (:em, :i)
    @eval _md(io, m, node::Node, ::Val{$(QuoteNode(t))}) =
        (_md_open(io, "*"); _md_inline_recurse(io, m, node); _md_close(io, "*"))
end
_md(io, m, node::Node, ::Val{:code}) =
    (_md_open(io, "`"); io.code += 1; _md_inline_recurse(io, m, node); io.code -= 1; _md_close(io, "`"))
# An `<a>` that names no target is no link in Markdown. Without `href` (an
# htmx-only `h.a("x"; hx_get=…)`) HTML has it represent its contents, and an
# empty or bare `#` href is the usual placeholder on a script-driven link. It
# renders its content like a `span` would, never as `[x]()` or `[x](#)`, which
# Pandoc's Typst writer turns into links Typst refuses.
_md_no_target(href) = href === nothing || href === false || (href isa AbstractString && href in ("", "#"))
function _md(io, m, node::Node, ::Val{:a})
    href = get(attrs(node), :href, nothing)
    _md_no_target(href) && return _md_recurse(io, m, node)
    _md_open(io, "["); _md_inline_recurse(io, m, node); _md_close(io, "](", href, ")")
end
# A line break waits for the content after it (see `_md_write_breaks!`). Inside
# a table cell a newline would end the row, so the break stays inline HTML; a
# `<pre>` body keeps it verbatim.
_md(io, m, node::Node, ::Val{:br}) =
    get(io, :md_table_cell, false) ? print(io, "<br>") :
    get(io, :md_verbatim, false) ? print(io, "\n") : (io.breaks += 1; nothing)

# Headings h1..h6: one line, so their content stays one paragraph, ending in
# the heading's id when it writes one
for lvl in 1:6
    @eval _md(io, m, node::Node, ::Val{$(QuoteNode(Symbol("h$lvl")))}; id=nothing) =
        (_md_block_start(io); _md_open(io, $("#"^lvl * " "));
         io.line += 1; _md_inline_recurse(io, m, node); io.line -= 1;
         isnothing(id) || _md_close(io, " ", _md_attr_block(id)); println(io))
end

# Other containers: recurse transparently (inline elements, and table
# sections, whose rows place their own blocks)
for t in (:head, :span, :thead, :tbody, :tr, :summary, :label)
    @eval _md(io, m, node::Node, ::Val{$(QuoteNode(t))}) = _md_recurse(io, m, node)
end

# Lists: items place their own blocks; an `<ol>` numbers them from its `start`.
# A list that directly follows another list starts after a blank line (else
# CommonMark reads `3. b` right after `- a` as continuation text), and one of
# the same kind also after a `<!-- -->` line: without it Pandoc and CommonMark
# read the two as one list (a change of bullet character does not split a
# Pandoc list).
_md(io, m, node::Node, ::Val{:ul}) = _md_list(io, m, node, :ul, nothing)
_md(io, m, node::Node, ::Val{:ol}) = _md_list(io, m, node, :ol, _md_list_start(node))
function _md_list(s::_MDStream, m, node, kind, number)
    if s.last_list !== :none
        _md_blank_line(s)
        s.last_list === kind && print(s, "<!-- -->\n\n")
    end
    prev, items = s.number, s.items
    s.number = number
    _md_recurse(s, m, node)
    s.number = prev
    s.items > items && (s.last_list = kind)
    nothing
end
function _md_list_start(node)
    v = get(attrs(node), :start, nothing)
    (v === nothing || v === false) && return 1
    n = v isa Integer ? v : tryparse(Int, strip(string(v)))
    n isa Integer && 0 <= n <= 999_999_999 || throw(ArgumentError(
        "<ol start=$(repr(v))> has no Markdown form: a list number is an integer from 0 to 999999999"))
    Int(n)
end
# The marker of the next list item: `- `, or `<number>. ` inside an `<ol>`.
function _md_item_marker(s::_MDStream)
    isnothing(s.number) && return "- "
    n = s.number
    s.number = n + 1
    string(n, ". ")
end

# Block containers (block elements in HTML): recurse as a paragraph boundary
const _MD_CONTAINERS = (:div, :main, :body, :html, :form, :nav, :footer, :aside,
                        :address, :fieldset, :hgroup, :dialog, :dl, :dt, :dd)
for t in _MD_CONTAINERS
    @eval _md(io, m, node::Node, ::Val{$(QuoteNode(t))}) = _md_container(io, m, node)
end

# Block elements whose own id and language scope are a fenced div (see `_md_attrs`)
for t in (_MD_CONTAINERS..., :details, :header, :p, :title, :pre, :blockquote,
          :figcaption, :table, :ul, :ol)
    t === :html || @eval _md_attr_kind(::Val{$(QuoteNode(t))}) = Val(:block)
end

# <details>: a block container that skips the <summary> toggle label
function _md(io, m, node::Node, ::Val{:details})
    _md_container_start(io)
    for c in children(node)
        c isa Node && tag(c) === :summary && continue
        _md_child(io, m, c)
    end
    _md_container_end(io)
end

# Semantic blocks: emit a leading `---` divider so an agent reader can see
# where each block starts. Only leading (not trailing), so adjacent blocks
# produce a single divider between them rather than doubled.
for t in (:article, :section)
    @eval _md(io, m, node::Node, ::Val{$(QuoteNode(t))}) =
        (_md_block_start(io, "\n"); println(io); println(io, "---"); println(io); _md_recurse(io, m, node); println(io))
end

# <header> is the label/title of its surrounding block — an inline-only header
# renders as a level-3 heading so the structure is legible to an agent reader.
# A header holding its own blocks (a heading, nav, paragraph) renders them
# unchanged: a `### ` prefix would glue them into one heading line.
function _md(io, m, node::Node, ::Val{:header})
    _md_block_start(io)
    if _md_has_blocks(io, m, node)
        _md_recurse(io, m, node)
        _md_end_line(io)
    else
        _md_open(io, "### "); io.line += 1; _md_recurse(io, m, node); io.line -= 1; println(io)
    end
end

# Whether rendering `node`'s children starts any block element.
function _md_has_blocks(s::_MDStream, m, node)
    probe = _MDStream(IOContext(devnull, s.io); lang=s.lang, targets=s.targets, probe=true)
    try
        _md_recurse(probe, m, node)
        false
    catch err
        err isa _MDBlockFound || rethrow()
        true
    end
end

# Non-content tags: skip
for t in (:script, :style, :meta, :link, :button)
    @eval _md(io, m, node::Node, ::Val{$(QuoteNode(t))}) = nothing
end

# Block leaves
_md(io, m, node::Node, ::Val{:p}) =
    (_md_block_start(io); _md_recurse(io, m, node); println(io); println(io))
# A list item's own id and language are an anchor and a span after its marker,
# so the item stays in its list.
function _md(io, m, node::Node, ::Val{:li}; id=nothing, lang=nothing)
    _md_next_list_item(io); _md_block_start(io); _md_open(io, _md_item_marker(io))
    io.item += 1
    io.items += 1
    _md_anchor(io, id)
    _md_lang_span(t -> _md_recurse(t, m, node), io, lang)
    io.item -= 1
    println(io); _md_end_list_item(io)
end
# Fence for a <pre> block: CommonMark requires the opening/closing fence to be
# longer than any backtick run inside, so a body containing its own fenced
# block survives as one code block instead of closing the outer fence early.
function _md_fence(text)
    longest = 0
    for mt in eachmatch(r"`+", text)
        longest = max(longest, length(mt.match))
    end
    repeat("`", max(3, longest + 1))
end

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
    buf = IOBuffer()
    _md_recurse(IOContext(buf, :md_verbatim => true), m, isnothing(code_node) ? node : code_node)
    body = String(take!(buf))
    fence = _md_fence(body)
    _md_block_start(io)
    println(io, fence, lang)
    print(io, body)
    println(io)
    println(io, fence)
end
_md(io, m, node::Node, ::Val{:hr})    = (_md_block_start(io); println(io, "---"))
_md(io, m, node::Node, ::Val{:table}) = _table_to_markdown(io, node)

# <title> → top-level heading (so a full page with <head><title>X</title></head> renders as "# X")
_md(io, m, node::Node, ::Val{:title}) =
    (_md_block_start(io); _md_open(io, "# "); io.line += 1; _md_inline_recurse(io, m, node); io.line -= 1; println(io))

# <blockquote> → "> "-prefixed lines
function _md(io, m, node::Node, ::Val{:blockquote})
    buf = IOBuffer()
    _md_recurse(_MDStream(buf; lang=io.lang, targets=io.targets), m, node)
    inner = rstrip(String(take!(buf)), '\n')
    isempty(inner) && return
    _md_block_start(io)
    for line in split(inner, '\n')
        println(io, "> ", line)
    end
    println(io)
end

# <img> → ![](src){alt="…"}, inline as in HTML. Its alt text is a Pandoc
# attribute, not the image description: a described image alone in its
# paragraph is a Pandoc implicit figure, whose caption Quarto takes from the
# description while the image itself loses its alt text (a PDF/UA build then
# fails). GFM and Julia Markdown show the attribute as text. Its id is an anchor
# in front of it, since Pandoc's Typst writer drops an image's own id.
function _md(io, m, node::Node, ::Val{:img})
    a = attrs(node)
    src = get(a, :src, "")
    isempty(src) && return
    print(io, "![](", src, ")")
    alt = get(a, :alt, nothing)
    (alt === nothing || alt === false) || print(io, _md_attr_block(nothing, :alt => alt))
end

# <figure> → Quarto fenced div.  Blank lines before/after guarantee
# block-level parsing by Pandoc; the blank line after the opening fence keeps
# a first child that cannot interrupt a paragraph (a pipe table) its own block
# wherever the fence is not a div opener (GFM).  Pandoc opens a div only on a
# fence with attributes — a bare `:::` always closes — so an id-less figure
# opens with an empty attribute block `::: {}`; that also nests it correctly
# around identified child figures.  Children are recursed with blank-line
# separation (required for Quarto subfigures).  <figcaption> is moved
# to the final paragraph — Quarto treats the last block inside a
# `::: {#fig-…}` div as the displayed caption — and its block containers
# stay transparent there, so a caption laid out in divs is still that one
# paragraph.  Nested <figure> nodes recurse into their own `:::` blocks
# (Quarto subfigures).
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
    _md_block_start(io, "")
    print(io, "\n\n")
    println(io, "::: ", _md_attr_block(isnothing(id) ? nothing : string(id)))
    println(io)
    for (i, c) in enumerate(content)
        i > 1 && (_md_end_line(io); println(io))
        _md_child(io, m, c)
    end
    if !isnothing(caption_node)
        _md_end_line(io)
        println(io)
        _md_figure_caption(io, m, caption_node)
        println(io)
    end
    _md_end_line(io)
    println(io, ":::")
    print(io, "\n")
end
# The caption stays one paragraph, so its own id and language are an anchor
# and a span.
function _md_figure_caption(io, m, caption)
    _md_anchor(io, _md_link_id(io, caption))
    _md_lang_span(t -> _md_inline_recurse(t, m, caption), io, _md_lang_change(io, caption))
end

# A <figcaption> placed outside a figure (in a custom layout) is a block whose
# content is still one paragraph, as inside a figure.
_md(io, m, node::Node, ::Val{:figcaption}) =
    (_md_container_start(io); _md_inline_recurse(io, m, node); _md_container_end(io))

# A table child is either a row itself (`<tr>` directly under `<table>`, which
# browsers wrap in an implicit `<tbody>`) or a section whose `<tr>` children
# are the rows; `caption`/`colgroup` hold no `tr` and so contribute no rows.
# Each row is collected with the language it inherits from its section and the
# ids it writes. A section's ids are collected as an entry without a row, so
# they are anchored at the next cell, as a row's are.
_collect_table_rows!(rows, s, ::Any, lang) = nothing
_collect_table_rows!(rows, s, c::Node, lang) =
    _collect_table_rows!(rows, s, c, _md_own_lang(c, lang), Val(tag(c)))
_collect_table_rows!(rows, s, row::Node, lang, ::Val{:tr}) = push!(rows, (row, lang, _md_link_ids(s, row)))
function _collect_table_rows!(rows, s, section::Node, lang, ::Val)
    ids = _md_link_ids(s, section)
    isempty(ids) || push!(rows, (nothing, lang, ids))
    for row in children(section)
        row isa Node && tag(row) === :tr && push!(rows, (row, _md_own_lang(row, lang), _md_link_ids(s, row)))
    end
end

# A table row is one line: a cell renders `<br>` as inline HTML (see `_md` for
# `:br`), folds any other line break (block content, multi-line text, a hard
# break `\` with its line ending) into `<br>`, and escapes `|` so it cannot
# split the cell, including inside code.
# The cell's children share one stream, so blocks among them are delimited.
# A cell whose language (its own, else its row's) differs from the table's is
# a language span. The ids waiting in `anchors` (its section's and row's) and
# its own are anchors at its start.
_push_cell_text!(cells, s, ::Any, lang, anchors) = nothing
function _push_cell_text!(cells, s::_MDStream, c::Node, lang, anchors)
    lang = _md_own_lang(c, lang)
    append!(anchors, _md_link_ids(s, c))
    prefix = _md_cell_text(t -> foreach(id -> _md_anchor(t, id), anchors), s, lang, false)
    text = _md_cell_text(t -> _md_recurse(t, _md_mime, c), s, lang, !isempty(anchors))
    empty!(anchors)
    push!(cells, prefix * (isempty(text) || _md_same_lang(lang, s.lang) ? text : _md_lang_span_text(text, lang)))
end
function _md_cell_text(f, s::_MDStream, lang, anchor)
    buf = IOBuffer()
    t = _MDStream(IOContext(buf, :md_table_cell => true); lang, targets=s.targets)
    t.anchor = anchor
    f(t)
    replace(replace(strip(String(take!(buf))), r"(?:\\\n|\s*\n)\s*" => "<br>"), "|" => "\\|")
end

function _table_to_markdown(io::_MDStream, table::Node)
    rows = Tuple{Union{Node,Nothing},String,Vector{String}}[]
    for section in children(table)
        _collect_table_rows!(rows, io, section, io.lang)
    end
    anchors = String[]  # ids waiting for the next cell
    written = 0
    for (row, lang, ids) in rows
        append!(anchors, ids)
        isnothing(row) && continue
        written == 0 && _md_block_start(io)
        cells = String[]
        for c in children(row)
            _push_cell_text!(cells, io, c, lang, anchors)
        end
        println(io, "| ", join(cells, " | "), " |")
        (written += 1) == 1 && println(io, "| ", join(fill("---", length(cells)), " | "), " |")
    end
    written > 0 && println(io)
    foreach(id -> _md_anchor(io, id), anchors)  # ids that no cell came after
end
