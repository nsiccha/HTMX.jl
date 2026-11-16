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
struct _MDTargets
    links::Set{String}  # ids that in-page links of the document point at
    met::Union{Nothing,Set{String}}  # ids met but not written, while links may be missing
end
_MDTargets() = _MDTargets(Set{String}(), nothing)
# A `<details>`' label waiting for its body's first content (see `_md_write_labels!`),
# with the place it is written in: the depths and language where the `<details>` started.
struct _MDLabel
    summary::Node
    inline::Int
    line::Int
    code::Int
    item::Int
    lang::String
end
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
    targets::_MDTargets  # ids that in-page links of the document point at
    anchor::Bool   # the output so far ends with an id anchor `[]{#…}`
    probe::Bool    # stop a layout probe as soon as a block is found
    placed::Bool   # the line being written is known: the output starts one, or the stream has written
    labels::Union{Nothing,Vector{_MDLabel}}  # `<details>` labels waiting for content, outermost first
end
_MDStream(io::IO; inline=0, line=0, code=0, item=0, lang="", targets=_MDTargets(), probe=false, placed=false) =
    _MDStream(io, 2, false, false, 0, inline, line, code, 0, item, 0, nothing, :none, lang, targets, false, probe,
              placed, nothing)
# Labels are rare, so a stream holds a vector of them only once a `<details>` needs one.
_md_label_count(s::_MDStream) = isnothing(s.labels) ? 0 : length(s.labels)

# A value of any other type renders through its own `show`, called on the
# stream while the document is written, and the nodes it prints render inside
# that call. So whatever the `show` holds while it prints (a counter, a scoped
# value, a check that it was handed the stream) applies to them, and they take
# their final block/list/table/language context.
#
# An element's id is written when an in-page link of the document points at it,
# so the links must be known before the elements are. A tree of nodes, strings
# and numbers names its links itself (`_md_collect_links!`). Any other value can
# write more, known only once its `show` has run: a tree holding one is rendered
# into a held buffer, whose links are then read, and when one points at an
# element id the render met without writing it, the tree renders once more
# with every link known. A `show` thus runs once per occurrence while the
# document is written, twice in that case, and once more inside a `<header>`,
# whose layout is probed (`_md_has_blocks`).
function _md_show(io, m, x)
    get(io, :md_verbatim, false) && return _md_emit(_MDStream(io), m, x)
    links = Set{String}()
    _md_collect_links!(links, x) ||
        return _md_emit(_MDStream(io; targets=_MDTargets(links, nothing), placed=!_md_writes_to_stream(io)), m, x)
    targets = _MDTargets(links, Set{String}())
    text, ends = _md_render_held(io, m, x, targets)
    found = _md_scan_targets!(Set{String}(), text)
    if any(in(found), targets.met)
        union!(links, found)
        text, ends = _md_render_held(io, m, x, targets)
    end
    _md_release(io, text, ends)
end
_md_show(io::_MDStream, m, x) = _md_emit(io, m, x)
_md_emit(s, m, n::Node) = _md_node(s, m, n)
_md_emit(s, m, xs::AbstractArray) = foreach(x -> _md_child(s, m, x), xs)

# The Markdown stream that writes to `io` go to, if any: a `show` may hand the
# stream on wrapped in an `IOContext`.
_md_stream(io) = nothing
_md_stream(s::_MDStream) = s
_md_stream(io::IOContext) = _md_stream(io.io)

# The links a tree names itself: the `href`s of its `<a>` nodes and the `](#…)`
# links in its strings. Returns whether the tree holds a value of another type.
function _md_collect_links!(links, n::Node)
    tag(n) === :a && _md_push_target!(links, get(attrs(n), :href, nothing))
    _md_collect_links!(links, children(n))
end
function _md_collect_links!(links, xs::AbstractArray)
    other = false
    for x in xs
        other |= _md_collect_links!(links, x)
    end
    other
end
_md_collect_links!(links, ::Number) = false
_md_collect_links!(links, x::AbstractString) = (_md_scan_targets!(links, x); false)
_md_collect_links!(links, x) = true

# Render into a held buffer. Written on to a Markdown stream (a `show` that
# wraps the stream in an `IOContext` and prints a node into it), the output
# keeps the boundaries of its writes, so that stream sees the same writes as
# if it had been streamed and places its block boundaries the same way.
function _md_render_held(io, m, x, targets)
    if _md_writes_to_stream(io)
        held = _MDHeld(IOBuffer(), Int[])
        _md_emit(_MDStream(IOContext(held, io); targets), m, x)
        String(take!(held.buffer)), held.ends
    else
        buffer = IOBuffer()
        _md_emit(_MDStream(IOContext(buffer, io); targets, placed=true), m, x)
        String(take!(buffer)), nothing
    end
end
_md_writes_to_stream(io) = !isnothing(_md_stream(io))
struct _MDHeld <: IO
    buffer::IOBuffer
    ends::Vector{Int}  # the output's length after each write
end
Base.write(io::_MDHeld, b::UInt8) = (n = write(io.buffer, b); push!(io.ends, position(io.buffer)); n)
Base.unsafe_write(io::_MDHeld, p::Ptr{UInt8}, n::UInt) =
    (k = unsafe_write(io.buffer, p, n); push!(io.ends, position(io.buffer)); k)
_md_release(io, text, ::Nothing) = (write(io, text); nothing)
function _md_release(io, text, ends::Vector{Int})
    start = 1
    GC.@preserve text for stop in ends
        stop >= start && unsafe_write(io, pointer(text, start), UInt(stop - start + 1))
        start = stop + 1
    end
    nothing
end

_md_count_block(s::_MDStream) = (s.blocks += 1; nothing)
# A layout probe stops looking once it has found a block (see `_md_has_blocks`).
_md_found(io) = false
_md_found(s::_MDStream) = s.probe && s.blocks > 0

Base.get(s::_MDStream, key, default) = get(s.io, key, default)

# Content written right after a list item would continue it lazily, and content
# after a block container belongs to a new paragraph, so anything but the next
# item starts after a blank line. It goes in front of the first write that holds
# content, and the line endings that write opens with (`leading`) count toward
# it: a value's `show` that opens a block with its own line endings and prints
# the rest in further writes settles the boundary there, so nothing is written
# into its later writes. `leading` is `nothing` for a write of line endings and
# blanks only, which leaves the boundary waiting. A `<details>` label waiting
# for its body is written first, in front of that content.
function _md_before_write!(s::_MDStream, byte::UInt8, all_newlines::Bool, leading::Union{Nothing,Int})
    _md_label_count(s) == 0 || isnothing(leading) || _md_write_labels!(s)
    if s.lazy && !isnothing(leading)
        s.lazy = false
        short = 2 - s.newlines - leading
        short > 0 && (_md_count_block(s); write(s.io, "\n"^short))
    end
    s.breaks > 0 && _md_write_breaks!(s, byte, all_newlines)
end
# The line endings a write opens with, before its first byte of content (blanks
# between them included), or `nothing` when it holds no content.
function _md_opening_newlines(p::Ptr{UInt8}, n::UInt)
    count = 0
    for i in 1:n
        b = unsafe_load(p, i)
        if b == UInt8('\n')
            count += 1
        elseif !_md_blank(b)
            return count
        end
    end
    nothing
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
    s.placed = true
    all_newlines || (s.last_list = :none)
end
# Whitespace-only text between elements carries no content: it neither ends a
# list item nor starts an inline run. As a node's text it is left out at the
# start of a line (see `_md_indent_text`).
_md_blank(byte::UInt8) = byte == UInt8(' ') || byte == UInt8('\t')
_md_blank(c::AbstractChar) = c == ' ' || c == '\t'
function Base.write(s::_MDStream, b::UInt8)
    _md_blank(b) && return write(s.io, b)
    newline = b == UInt8('\n')
    _md_before_write!(s, b, newline, newline ? nothing : 0)
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
    first = unsafe_load(p)
    # only a pending boundary (or a label, which leaves one) needs the opening
    # line endings counted
    leading = (s.lazy || _md_label_count(s) > 0) && first == UInt8('\n') ? _md_opening_newlines(p, n) : 0
    _md_before_write!(s, first, trailing == n, leading)
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

# Link targets come from the tree's `<a>` nodes and strings, and from the
# Markdown other values write (see `_md_show`).
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
    id in s.targets.links && return id
    isnothing(s.targets.met) || push!(s.targets.met, id)
    nothing
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
    _md_fenced_div(t -> _md(t, m, n, v), s, _md_attr_block(id, :lang => lang), lang)
end
# A heading keeps its id on its line wherever it is a heading, which it is not
# inside inline content, a table cell or a language span.
function _md_attrs(s, m, n, v, id, lang, ::Val{:heading})
    if _md_inline_context(s) || (!isnothing(lang) && _md_span_context(s))
        return _md_attrs(s, m, n, v, id, lang, Val(:inline))
    end
    heading(t) = _md(t, m, n, v; id)
    isnothing(lang) ? heading(s) : _md_fenced_div(heading, s, _md_attr_block(nothing, :lang => lang), lang)
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
# A fenced div with the attribute block `attrs`, whose content `f` writes in
# the language `lang` (`nothing`: the enclosing one).
function _md_fenced_div(f, s::_MDStream, attrs::AbstractString, lang)
    _md_block_start(s)
    _md_found(s) && return
    _md_blank_line(s)
    println(s, "::: ", attrs)
    println(s)
    _md_in_lang(f, s, lang)
    _md_end_line(s)
    println(s, ":::")
    print(s, "\n")
end
# A bracketed span `[…]` with the attribute block `attrs`, written only when
# its content is not empty. The content renders into its own buffer, so the
# leading and trailing line breaks of a block inside it stay outside the
# brackets. The brackets leave no trace in Typst, so an anchor on either side
# of them is adjacent to one inside.
function _md_span(f, s::_MDStream, attrs::AbstractString, lang)
    buf = IOBuffer()
    t = _MDStream(IOContext(buf, s.io); inline=s.inline + 1, line=s.line, code=s.code,
                  item=s.item, lang=something(lang, s.lang), targets=s.targets, probe=s.probe)
    t.anchor = s.anchor
    f(t)
    s.blocks += t.blocks
    text = strip(String(take!(buf)), '\n')
    if !isempty(text)
        print(s, _md_span_text(text, attrs))
        s.anchor = t.anchor
    end
    s.breaks += t.breaks  # a break that ends the span is written after it
    nothing
end
_md_lang_span(f, s::_MDStream, ::Nothing) = f(s)
_md_lang_span(f, s::_MDStream, lang) = _md_span(f, s, _md_attr_block(nothing, :lang => lang), lang)
_md_span_text(text, attrs) = string("[", text, "]", attrs)
_md_lang_span_text(text, lang) = _md_span_text(text, _md_attr_block(nothing, :lang => lang))

# A Pandoc attribute block, `{#id .class lang="en"}`: the id, written `id="…"`
# when the `#` shorthand cannot spell it (letters, digits and `_ . : -`); the
# classes, written as one `class="…"` when a `.` cannot spell one of them (it
# must also start with a letter); then each `key => value` that is not
# `nothing`.
const _MD_ID = r"^[\p{L}\p{N}_.:-]+$"
const _MD_CLASS = r"^\p{L}[\p{L}\p{N}_.:-]*$"
_md_attr_block(id, pairs::Pair...) = _md_attr_block(id, (), pairs...)
function _md_attr_block(id, classes, pairs::Pair...)
    parts = String[]
    isnothing(id) || push!(parts, occursin(_MD_ID, id) ? "#" * id : "id=" * _md_attr_value(id))
    if all(c -> occursin(_MD_CLASS, c), classes)
        foreach(c -> push!(parts, "." * c), classes)
    else
        push!(parts, "class=" * _md_attr_value(join(classes, " ")))
    end
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

"""
    HTMX.markdown_div(f, io; id=nothing, class=nothing, attributes...)

Write a Pandoc div from a value's `show(io, MIME"text/markdown"(), x)`: a fenced
div `::: {#id .class key="value"}` whose content `f(io)` writes. The div starts
a paragraph of its own (inline text before it is closed as a paragraph), a
blank line follows its opening fence, and its closing `:::` stands on a line
of its own, followed by a blank line. A `Node` that `f` prints renders inside
the div, in its context.

```julia
function Base.show(io::IO, m::MIME"text/markdown", x::Note)
    HTMX.markdown_div(io; class="note") do io
        show(io, m, h.p(x.text))
    end
end
```

`repr("text/markdown", h.div("before", Note("text"), "after"))` is then
`"before\\n\\n::: {.note}\\n\\ntext\\n\\n:::\\n\\nafter"`.

The attribute block holds, in this order:

- `id`: `#id`, or `id="…"` when the `#` shorthand cannot spell it (letters,
  digits and `_ . : -`);
- `class`: space-separated class names, as in HTML, each written `.name`, or
  all of them as one `class="…"` when a name does not start with a letter or
  holds other characters;
- every other keyword argument as `key="value"`, in the given order, with
  underscores in its name becoming hyphens (`custom_style="Note"` writes
  `custom-style="Note"`); `nothing` and `false` leave it out and `true` writes
  `"true"`, as for a `Node` attribute. `lang` also makes the content's
  language that one, so a node inside with the same `lang` declares no scope
  of its own.

Where a fence would break the line (inside inline content such as a link,
emphasis or a heading, inside a table cell, or inside a list item) the div is
written as a span `[…]{#id .class key="value"}` holding the content in one
paragraph, as HTMX writes an element's own `id` and `lang` there; an empty span
is left out. A paragraph in it is set off by a line break, as in any content
that must stay one paragraph: a hard break `\\` + newline, a space in a
heading, `<br>` in a table cell. Inside a `<pre>` body `f(io)` writes verbatim, with neither.
[`HTMX.markdown_block_context`](@ref) tells which of these applies, for a
`show` that writes other content in a span.

`io` need not be HTMX's Markdown stream. At top level
(`repr("text/markdown", x)`) `markdown_div` starts one, as rendering a `Node`
does, and `f` receives it; HTMX's stream wrapped in an `IOContext` is used
through the wrapper, and `f` receives the wrapper with its properties. The
`show` therefore never needs to know HTMX's stream type. `f` runs once per
`markdown_div` call. At top level it runs a second time when its own output
holds the only in-page link to an element id it prints, as a value's `show`
does among a node's children; there the `show` is called again instead.
"""
function markdown_div(f, io::IO; id=nothing, class=nothing, attributes...)
    get(io, :md_verbatim, false) && return (f(io); nothing)
    pairs = Pair{Symbol,String}[]
    lang = nothing
    for (k, v) in attributes
        (v === nothing || v === false) && continue
        key = _attr_symbol(k)
        value = v === true ? "true" : string(v)
        key === :lang && !isempty(value) && (lang = value)
        push!(pairs, key => value)
    end
    classes = class === nothing || class === false ? String[] : split(string(class))
    attrs = _md_attr_block(id === nothing || id === false ? nothing : string(id), classes, pairs...)
    div = _MDDiv(f, attrs, lang)
    s = _md_stream(io)
    isnothing(s) ? _md_show(io, _md_mime, div) : _md_div(s, io, div)
    nothing
end

"""
    HTMX.markdown_block_context(io) -> Bool

Whether a block can start where a value's `show(io, MIME"text/markdown"(), x)`
writes, so that [`HTMX.markdown_div`](@ref) writes a fenced div there. It is
`true` at top level and among the children of a block container (`div`,
`article`, `figure`, `blockquote`, …). It is `false` inside inline content (a
link, emphasis, a heading), a table cell or a list item, where a fence would
break the line and `markdown_div` writes a span, and inside a `<pre>` body,
where its content is written verbatim.
"""
function markdown_block_context(io::IO)
    get(io, :md_verbatim, false) && return false
    s = _md_stream(io)
    isnothing(s) || !_md_span_context(s)
end

# A div that `markdown_div` writes: its content, attribute block and language.
struct _MDDiv{F}
    f::F
    attrs::String
    lang::Union{Nothing,String}
end
# At top level `markdown_div` renders like a value among a node's children.
_md_emit(s::_MDStream, m, d::_MDDiv) = _md_div(s, s, d)
# `io` is `s` or an `IOContext` around it; `f` receives that, or around a span's
# own stream, a wrapper with the same properties.
function _md_div(s::_MDStream, io, d::_MDDiv)
    _md_span_context(s) ?
        _md_span(t -> d.f(io === s ? t : IOContext(t, io)), s, d.attrs, d.lang) :
        _md_fenced_div(_ -> d.f(io), s, d.attrs, d.lang)
end

# Recurse into children as if the node were transparent
_md_recurse(io, m, node) = for c in children(node)
    _md_found(io) && break
    _md_child(io, m, c)
end
# One child among its siblings. Outside a Markdown stream (a `<pre>` body)
# children are written verbatim.
_md_child(io, m, c) = show(io, m, c)
function _md_child(io::_MDStream, m, c)
    c isa AbstractString && _md_indent_text(io, c) && return
    markdown_block(c) ? (_md_container_start(io); show(io, m, c); _md_container_end(io)) : show(io, m, c)
end
# Whether text of only blanks would indent the next line. Mid-line it separates
# the inline content around it and is written; at the start of a line Markdown
# reads it as indentation (` ::: {.note}` opens no fenced div, four blanks start
# an indented code block), so there it is left out. A stream that cannot see the
# line its output starts on (a span's content, a render nested in another
# stream's output) writes it until it has written something itself. A `<pre>`
# body keeps it, and so does a value's own `show`, whose blanks are Markdown.
_md_indent_text(s::_MDStream, c::AbstractString) =
    s.placed && s.newlines > 0 && !isempty(c) && all(_md_blank, c) && !get(s, :md_verbatim, false)

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

# <details>: a block container whose first <summary> is its label. Markdown has
# no viewport to collapse into, so the label is a paragraph of its own, bold
# (a summary holding a heading or other blocks writes them as they are), and the
# whole body follows it. The label waits on the stream for the body's first
# content, so a disclosure with nothing to open (its body writes nothing) writes
# nothing, its label included. A later <summary> is body content, as in HTML; in
# a <pre> body the summary is plain text in its place.
function _md(io, m, node::Node, ::Val{:details})
    kids = children(node)
    i = findfirst(c -> c isa Node && tag(c) === :summary, kids)
    (isnothing(i) || get(io, :md_verbatim, false)) && return _md_container(io, m, node)
    _md_container_start(io)
    n = _md_label_count(io)
    isnothing(io.labels) && (io.labels = _MDLabel[])
    push!(io.labels, _MDLabel(kids[i], io.inline, io.line, io.code, io.item, io.lang))
    for (j, c) in enumerate(kids)
        j == i && continue
        _md_found(io) && break
        _md_child(io, m, c)
    end
    _md_label_count(io) > n && pop!(io.labels)  # the body wrote nothing
    _md_container_end(io)
end

# Write the labels waiting for content, outermost first. Each is written where
# its `<details>` started: a bold paragraph, set off by a line break where a
# blank line would break the line (inline content, a list item, a table cell),
# else followed by the paragraph boundary a block container leaves. Inside a
# layout probe a label is a block.
function _md_write_labels!(s::_MDStream)
    labels, s.labels = s.labels, nothing
    for l in labels
        s.probe ? _md_count_block(s) : _md_write_label!(s, l)
    end
    nothing
end
function _md_write_label!(s::_MDStream, l::_MDLabel)
    layout = _md_label_layout(s, l)
    layout === :none && return
    # a `<br>` the body opens with waits for the content after the label
    state = (s.inline, s.line, s.code, s.item, s.lang, s.breaks)
    s.inline, s.line, s.code, s.item, s.lang, s.breaks = l.inline, l.line, l.code, l.item, l.lang, 0
    summary = l.summary
    if layout === :blocks
        _md_node(s, _md_mime, Node(:div, attrs(summary), children(summary)))
    elseif _md_span_context(s)
        _md_count_block(s)
        _md_inline_break!(s)
        _md_node(s, _md_mime, Node(:strong, attrs(summary), children(summary)))
        _md_inline_break!(s)
    else
        _md_container_start(s)
        _md_node(s, _md_mime, Node(:strong, attrs(summary), children(summary)))
        _md_container_end(s)
    end
    s.inline, s.line, s.code, s.item, s.lang = state
    s.breaks += last(state)
    nothing
end
# How a label reads: `:none` when its summary writes nothing, `:blocks` when it
# starts a block (a heading), else `:inline`. The summary is probed as a
# header's content is (`_md_has_blocks`), into a sink that notes whether
# anything but blanks and line endings was written.
function _md_label_layout(s::_MDStream, l::_MDLabel)
    sink = _MDSink(false)
    probe = _MDStream(IOContext(sink, s.io); lang=l.lang, targets=s.targets, probe=true)
    _md_recurse(probe, _md_mime, l.summary)
    probe.blocks > 0 ? :blocks : sink.content ? :inline : :none
end
mutable struct _MDSink <: IO
    content::Bool  # whether anything but blanks and line endings was written
end
_md_content_byte(b::UInt8) = !(_md_blank(b) || b == UInt8('\n') || b == UInt8('\r'))
Base.write(io::_MDSink, b::UInt8) = (io.content |= _md_content_byte(b); 1)
function Base.unsafe_write(io::_MDSink, p::Ptr{UInt8}, n::UInt)
    io.content || (io.content = any(i -> _md_content_byte(unsafe_load(p, i)), 1:n))
    Int(n)
end

# Semantic blocks: emit a leading `---` divider so an agent reader can see
# where each block starts. Only leading (not trailing), so adjacent blocks
# produce a single divider between them rather than doubled. With seams
# switched off (`with_markdown_seams`) they are written as a `div` is.
const _MD_SEAMS = ScopedValue(true)

"""
    HTMX.markdown_seams() -> Bool

Whether Markdown written here puts a `---` seam before each `<article>` and
`<section>`: `true` (the default) unless [`HTMX.with_markdown_seams`](@ref)
switched it off around the current call.
"""
markdown_seams() = _MD_SEAMS[]

"""
    HTMX.with_markdown_seams(f, on::Bool)

Call `f()` with the `---` seam that Markdown writes before each `<article>` and
`<section>` switched on or off, and return its result. With `on = false` an
`<article>` or `<section>` is written as a `<div>` is, a paragraph boundary
with no line of its own, so a document turned into a PDF (Pandoc reads `---`
as a horizontal rule) shows no rule there. Its linked `id` still goes on the
heading that opens it (`## Title {#id}`), else on a fenced div, and a `lang`
of its own still becomes a fenced div. An `<hr>` still writes `---`.

The setting is a scoped value: every Markdown render inside `f`, a fresh
`repr("text/markdown", x)` in a value's own `show` included, and every task
`f` starts, sees it until `f` returns. A nested `with_markdown_seams(g, true)`
switches the seam back on inside `g`.
"""
with_markdown_seams(f, on::Bool) = with(f, _MD_SEAMS => on)

for t in (:article, :section)
    @eval _md(io, m, node::Node, ::Val{$(QuoteNode(t))}) =
        markdown_seams() ? _md_seam(io, m, node) : _md_container(io, m, node)
end
_md_seam(io, m, node) =
    (_md_block_start(io, "\n"); println(io); println(io, "---"); println(io); _md_recurse(io, m, node); println(io))

# <header> is the label/title of its surrounding block — an inline-only header
# renders as a level-3 heading so the structure is legible to an agent reader.
# A header holding its own blocks (a heading, nav, paragraph) renders them
# unchanged: a `### ` prefix would glue them into one heading line.
function _md(io, m, node::Node, ::Val{:header})
    _md_block_start(io)
    _md_found(io) && return  # inside a probe, a header is a block
    if _md_has_blocks(io, m, node)
        _md_recurse(io, m, node)
        _md_end_line(io)
    else
        _md_open(io, "### "); io.line += 1; _md_recurse(io, m, node); io.line -= 1; println(io)
    end
end

# Whether rendering `node`'s children starts any block element. The probe
# renders them into nothing and stops at the first block: a probing stream
# renders no further children, and a header inside it is a block without a
# probe of its own, so nested headers are probed once each, not exponentially
# often. It needs no exception, so a value's `show` that catches exceptions
# cannot hide a block from it.
function _md_has_blocks(s::_MDStream, m, node)
    probe = _MDStream(IOContext(devnull, s.io); lang=s.lang, targets=s.targets, probe=true)
    _md_recurse(probe, m, node)
    probe.blocks > 0
end

# Non-content tags: skip
for t in (:script, :style, :meta, :link, :button)
    @eval _md(io, m, node::Node, ::Val{$(QuoteNode(t))}) = nothing
end

# Block leaves
# Inside content that must stay one paragraph (an inline element, a heading, a
# figure caption, a span), a blank line would end it, so a paragraph is set off
# by a line break instead, written as a `<br>` is there: a hard break, a space
# in a heading, `<br>` in a table cell. Like a `<br>`, it is written only
# between content.
function _md(io, m, node::Node, ::Val{:p})
    io.inline > 0 || return (_md_block_start(io); _md_recurse(io, m, node); println(io); println(io))
    _md_count_block(io)
    _md_inline_break!(io)
    _md_recurse(io, m, node)
    _md_inline_break!(io)
end
# A line break waiting after content that ends mid-line, unless one already waits.
_md_inline_break!(s::_MDStream) = (s.newlines == 0 && !s.open && (s.breaks = max(s.breaks, 1)); nothing)
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
    _md_recurse(_MDStream(buf; lang=io.lang, targets=io.targets, placed=true), m, node)
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
    _md_found(io) && return
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
# A table's rows, in the order they are written. Each entry is a row with the
# language it inherits from its section, the ids it writes and its row group:
# a section, or a run of rows directly under `<table>` (which browsers wrap in
# an implicit `<tbody>`). A row span stops at the end of its group, as in
# HTML. `caption`/`colgroup` hold no `tr` and so contribute no rows. A
# section's ids are an entry without a row, so they are anchored at the next
# cell, as a row's are. The header is every `<thead>` row, written first; a
# table without one is headed by its first row. Returns the entries and the
# number of header rows.
const _MDTableEntry = Tuple{Union{Node,Nothing},String,Vector{String},Int}
function _md_table_rows(s::_MDStream, table::Node)
    head, rest = _MDTableEntry[], _MDTableEntry[]
    group, bare, nhead = 0, false, 0
    for c in children(table)
        c isa Node || continue
        lang = _md_own_lang(c, s.lang)
        if tag(c) === :tr
            bare || (group += 1; bare = true)
            push!(rest, (c, lang, _md_link_ids(s, c), group))
            continue
        end
        group += 1
        bare = false
        into = tag(c) === :thead ? head : rest
        ids = _md_link_ids(s, c)
        isempty(ids) || push!(into, (nothing, lang, ids, group))
        for row in children(c)
            row isa Node && tag(row) === :tr || continue
            push!(into, (row, _md_own_lang(row, lang), _md_link_ids(s, row), group))
            into === head && (nhead += 1)
        end
    end
    entries = append!(head, rest)
    nhead == 0 && any(e -> !isnothing(e[1]), entries) && (nhead = 1)
    entries, nhead
end

# A cell's `colspan` or `rowspan`, as HTML reads it: a non-number, or a
# `colspan` below 1, counts as 1, and `rowspan="0"` runs to the end of its
# row group.
function _md_span_attr(c::Node, key::Symbol)
    v = get(attrs(c), key, nothing)
    n = v === nothing || v === false ? nothing : tryparse(Int, strip(string(v)))
    key === :rowspan ? (n === nothing || n < 0 ? 1 : n == 0 ? typemax(Int) : min(n, 65534)) :
        (n === nothing || n < 1 ? 1 : min(n, 1000))
end

# A table cell's Markdown: its anchors (`prefix`) and its text, kept apart so
# that a header cell over several columns anchors only the first. The text is
# one line: a cell renders `<br>` as inline HTML (see `_md` for `:br`), folds
# any other line break (block content, multi-line text, a hard break `\` with
# its line ending) into `<br>`, and escapes `|` so it cannot split the cell,
# including inside code.
# The cell's children share one stream, so blocks among them are delimited.
# A cell whose language (its own, else its row's) differs from the table's is
# a language span. The ids waiting in `anchors` (its section's and row's) and
# its own are anchors at its start.
struct _MDTableCell
    prefix::String
    text::String
    row::Int
    col::Int
    rows::Int
    cols::Int
end
_md_cell_md(c::_MDTableCell) = isempty(c.prefix) ? c.text : c.prefix * c.text
function _md_table_cell(s::_MDStream, c::Node, lang, anchors)
    lang = _md_own_lang(c, lang)
    append!(anchors, _md_link_ids(s, c))
    prefix = isempty(anchors) ? "" :
        _md_cell_text(t -> foreach(id -> _md_anchor(t, id), anchors), s, lang, false)
    text = _md_cell_text(t -> _md_recurse(t, _md_mime, c), s, lang, !isempty(anchors))
    empty!(anchors)
    prefix, isempty(text) || _md_same_lang(lang, s.lang) ? text : _md_lang_span_text(text, lang)
end
function _md_cell_text(f, s::_MDStream, lang, anchor)
    buf = IOBuffer()
    t = _MDStream(IOContext(buf, :md_table_cell => true); lang, targets=s.targets)
    t.anchor = anchor
    f(t)
    replace(replace(strip(String(take!(buf))), r"(?:\\\n|\s*\n)\s*" => "<br>"), "|" => "\\|")
end

# A table laid out on its grid, as a browser lays it out: each cell takes the
# first free position of its row and covers `cols` × `rows` positions (a row
# span stops at the end of its row group). `slot[r][c]` is the cell covering
# row `r`, column `c`, or 0. The grid is as wide as its widest row. `anchors`
# holds ids that no cell came after.
struct _MDTableGrid
    cells::Vector{_MDTableCell}
    slot::Vector{Vector{Int}}
    head::Int
    anchors::Vector{String}
end
_md_grow!(v, n) = (k = length(v); k < n && fill!(view(resize!(v, n), k+1:n), 0); v)
function _md_table_grid(s::_MDStream, entries, nhead)
    groups = [e[4] for e in entries if !isnothing(e[1])]
    last = collect(eachindex(groups))  # the last row of each row's group
    for r in reverse(eachindex(groups))[2:end]
        groups[r] == groups[r+1] && (last[r] = last[r+1])
    end
    cells, slot = _MDTableCell[], [Int[] for _ in groups]
    anchors = String[]  # ids waiting for the next cell
    r = 0
    for (row, lang, ids, _) in entries
        append!(anchors, ids)
        isnothing(row) && continue
        r += 1
        col = 1
        for c in children(row)
            c isa Node || continue
            prefix, text = _md_table_cell(s, c, lang, anchors)
            while col <= length(slot[r]) && slot[r][col] != 0
                col += 1
            end
            nr, nc = min(_md_span_attr(c, :rowspan), last[r] - r + 1), _md_span_attr(c, :colspan)
            push!(cells, _MDTableCell(prefix, text, r, col, nr, nc))
            for rr in r:r+nr-1
                _md_grow!(slot[rr], col + nc - 1)
                fill!(view(slot[rr], col:col+nc-1), length(cells))
            end
            col += nc
        end
    end
    width = maximum(length, slot; init=0)
    foreach(v -> _md_grow!(v, width), slot)
    _MDTableGrid(cells, slot, nhead, anchors)
end

# A pipe table holds one header row and no spans. A table that fits it (no
# row wider than its first) is written as it always was, row by row: one cell
# per `<th>`/`<td>`, a short row short. Returns the ids no cell came after.
function _md_pipe_fits(entries, nhead)
    nhead == 1 || return false
    width = -1
    for (row, _, _, _) in entries
        isnothing(row) && continue
        n = 0
        for c in children(row)
            c isa Node || continue
            _md_span_attr(c, :colspan) == 1 && _md_span_attr(c, :rowspan) == 1 || return false
            n += 1
        end
        width < 0 ? (width = n) : n <= width || return false
    end
    true
end
_md_pipe_row(io, cells) = println(io, "| ", join(cells, " | "), " |")
function _md_pipe_table(io::_MDStream, entries)
    anchors = String[]  # ids waiting for the next cell
    written = 0
    for (row, lang, ids, _) in entries
        append!(anchors, ids)
        isnothing(row) && continue
        cells = String[]
        for c in children(row)
            c isa Node || continue
            prefix, text = _md_table_cell(io, c, lang, anchors)
            push!(cells, isempty(prefix) ? text : prefix * text)
        end
        _md_pipe_row(io, cells)
        (written += 1) == 1 && _md_pipe_row(io, fill("---", length(cells)))
    end
    anchors
end

# Any other table, by default, is one pipe table on the full grid, so every
# reader (GFM, Pandoc, Julia `Markdown`) keeps each cell in its column. Each
# column's header joins the header cells over it, top to bottom, with " / "
# (`Group A / Column 1`), a cell spanning header rows counted once and empty
# ones skipped; a header cell's anchors go in its first column only. A body
# cell is written at its first position, and the positions it spans are empty
# cells, which `md_to_node` reads back as a colspan. A header cell does not
# run into the body.
function _md_flat_table(io::_MDStream, g::_MDTableGrid)
    width = isempty(g.slot) ? 0 : length(g.slot[1])
    header = map(1:width) do col
        prefixes, texts, seen = String[], String[], 0
        for r in 1:g.head
            id = g.slot[r][col]
            (id == 0 || id == seen) && continue
            seen = id
            c = g.cells[id]
            c.col == col && !isempty(c.prefix) && push!(prefixes, c.prefix)
            isempty(c.text) || push!(texts, c.text)
        end
        join(prefixes, '​') * join(texts, " / ")
    end
    _md_pipe_row(io, header)
    _md_pipe_row(io, fill("---", width))
    for r in g.head+1:length(g.slot)
        _md_pipe_row(io, map(1:width) do col
            id = g.slot[r][col]
            c = id == 0 ? nothing : g.cells[id]
            isnothing(c) || c.row != r || c.col != col ? "" : _md_cell_md(c)
        end)
    end
end

# Inside `with_markdown_grid_tables(f, true)` such a table is a Pandoc grid
# table instead, which keeps the header rows and the spans: header rows above
# a `+===+` rule, a span drawn as one box, columns padded to their widest cell
# by display width. A grid cell is block content in Pandoc, so a cell that
# opens like a block (a list marker, `#`, `>`, a rule, a fence or a link
# definition) gets its first marker escaped: a cell `-` would be an empty
# bullet list, `1. Liga` a numbered one.
const _MD_GRID_TABLES = ScopedValue(false)

"""
    HTMX.markdown_grid_tables() -> Bool

Whether Markdown written here spells a table that a pipe table cannot hold (a
header of several rows, a `colspan` or `rowspan`, a row wider than the header)
as a Pandoc grid table: `false` (the default) unless
[`HTMX.with_markdown_grid_tables`](@ref) switched it on around the current call.
"""
markdown_grid_tables() = _MD_GRID_TABLES[]

"""
    HTMX.with_markdown_grid_tables(f, on::Bool)

Call `f()` with Pandoc grid tables switched on or off, and return its result.

A table that a pipe table can hold (one header row, no `colspan` or `rowspan`
above 1, no row wider than the header) is a pipe table either way. Any other
table is, by default, one pipe table on its full column grid: each column's
header joins the header cells over it with `" / "` (`Group A / Column 1`), and
the positions a body cell spans are empty cells, so GFM, Pandoc and Julia's
`Markdown` all keep every cell in its column. With `on = true` it is a Pandoc
grid table instead, with every header row and every span as in the HTML, which
Pandoc (and so Quarto, for a PDF) reads but GFM and Julia's `Markdown` show as
text.

The setting is a scoped value: every Markdown render inside `f`, a fresh
`repr("text/markdown", x)` in a value's own `show` included, and every task
`f` starts, sees it until `f` returns. A nested
`with_markdown_grid_tables(g, false)` switches it back off inside `g`.
"""
with_markdown_grid_tables(f, on::Bool) = with(f, _MD_GRID_TABLES => on)

const _MD_GRID_LIST_NUMBER = r"^(\(?(?:[0-9]{1,9}|[a-zA-Z]|[ivxlcdmIVXLCDM]+|#))([.)])(?=\s|$)"
const _MD_GRID_BLOCK_START = r"^(?:[-+>]|\*(?=\s|$)|(?:\*\s*){3,}$|(?:_\s*){3,}$|#{1,6}(?=\s|$)|~~~|```|\[[^\]]*\]:)"
function _md_grid_text(c::_MDTableCell)
    text = replace(_md_cell_md(c), '\t' => ' ')
    m = match(_MD_GRID_LIST_NUMBER, text)
    m === nothing || return string(m[1], '\\', m[2], SubString(text, ncodeunits(m.match) + 1))
    occursin(_MD_GRID_BLOCK_START, text) ? "\\" * text : text
end
function _md_grid_table(io::_MDStream, g::_MDTableGrid)
    nrows = length(g.slot)
    width = nrows == 0 ? 0 : length(g.slot[1])
    texts = map(_md_grid_text, g.cells)
    # the cell drawn at row r, column col: a header cell stops at the header
    own(r, col) = (id = g.slot[r][col]; id != 0 && g.cells[id].row <= g.head < r ? 0 : id)
    w = ones(Int, width)
    for (id, c) in enumerate(g.cells)
        c.cols == 1 && (w[c.col] = max(w[c.col], textwidth(texts[id])))
    end
    for id in sortperm(g.cells; by=c -> c.cols)
        c = g.cells[id]
        c.cols > 1 || continue
        span = c.col:min(c.col + c.cols - 1, width)
        need = textwidth(texts[id]) - (sum(w[span]) + 3 * (length(span) - 1))
        need > 0 && (w[last(span)] += need)
    end
    # the rule above row b (`=` under the header): a span running on from row
    # b-1 leaves a gap
    function rule(b)
        a = b - 1
        ch = a == g.head ? '=' : '-'  # a table with no body ends in it
        on(col) = 1 <= a && b <= nrows && own(a, col) != 0 && own(a, col) == own(b, col)
        line = IOBuffer()
        for col in 1:width
            print(line, col == 1 ? (on(1) ? '|' : '+') :
                on(col - 1) && on(col) ? (own(a, col - 1) == own(a, col) ? ' ' : '|') : '+')
            print(line, (on(col) ? ' ' : ch)^(w[col] + 2))
        end
        print(line, width > 0 && on(width) ? '|' : '+')
        println(io, String(take!(line)))
    end
    for r in 1:nrows
        rule(r)
        line = IOBuffer()
        print(line, '|')
        col = 1
        while col <= width
            id = own(r, col)
            stop = col
            while id != 0 && stop < width && own(r, stop + 1) == id
                stop += 1
            end
            text = id != 0 && g.cells[id].row == r ? texts[id] : ""
            span = sum(w[col:stop]) + 3 * (stop - col)
            print(line, ' ', text, ' '^(span - textwidth(text)), " |")
            col = stop + 1
        end
        println(io, String(take!(line)))
    end
    rule(nrows + 1)
end

function _table_to_markdown(io::_MDStream, table::Node)
    entries, nhead = _md_table_rows(io, table)
    if nhead > 0
        _md_block_start(io)
        _md_found(io) && return
        if _md_pipe_fits(entries, nhead)
            anchors = _md_pipe_table(io, entries)
        else
            g = _md_table_grid(io, entries, nhead)
            markdown_grid_tables() ? _md_grid_table(io, g) : _md_flat_table(io, g)
            anchors = g.anchors
        end
        println(io)
    else
        anchors = reduce(vcat, (e[3] for e in entries); init=String[])
    end
    foreach(id -> _md_anchor(io, id), anchors)  # ids that no cell came after
end
