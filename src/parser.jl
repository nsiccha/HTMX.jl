# --- Markdown AST → h.* Node conversion ---

"""
    md_to_node(md)

Convert a markdown string or `Markdown.jl` AST into `h.*` HTML nodes.

Inline math uses MathJax's `\\(...\\)` delimiters; display math (including
fenced `math` blocks and standalone `Markdown.LaTeX` nodes) uses double-dollar
delimiters. Formula text is HTML-escaped like other ordinary node children.

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
# Markdown.LaTeX carries no inline/block flag, so inline-content containers
# select inline conversion while document/list/blockquote blocks keep display.
_md_inline_to_node(x) = _md_to_node(x)
_md_inline_to_node(l::Markdown.LaTeX) = "\\($(l.formula)\\)"

_md_to_node(s::AbstractString) = s
_md_to_node(md::Markdown.MD) = h.div(_md_to_node.(md.content))
_md_to_node(p::Markdown.Paragraph) = h.p(_md_inline_to_node.(p.content))
_md_to_node(b::Markdown.Bold) = h.strong(_md_inline_to_node.(b.text))
_md_to_node(i::Markdown.Italic) = h.em(_md_inline_to_node.(i.text))
_md_to_node(c::Markdown.Code) = c.language == "" ? h.code(c.code) : h.pre(h.code(c.code))
_md_to_node(l::Markdown.Link) = h.a(_md_inline_to_node.(l.text); href=l.url)
_md_to_node(::Markdown.LineBreak) = h.br()
for level in 1:6
    @eval _md_to_node(hdr::Markdown.Header{$level}) =
        h($(QuoteNode(Symbol("h$level"))), _md_inline_to_node.(hdr.text))
end
_md_to_node(bq::Markdown.BlockQuote) = h.blockquote(_md_to_node.(bq.content))
_md_to_node(list::Markdown.List) = begin
    tag = list.ordered == -1 ? h.ul : h.ol
    tag([_li_for(item) for item in list.items])
end
_li_for(item) = begin
    info = _task_list_marker(item)
    info === nothing && return h.li(_md_to_node.(item))
    (checked, first_inline, rest_blocks) = info
    h.li(h.input(; type="checkbox", disabled=true,
                   checked = checked ? true : nothing),
         " ",
         _md_inline_to_node.(first_inline),
         _md_to_node.(rest_blocks))
end
# GFM task-list detection: a list item whose first inline leaf starts with
# `[ ]`, `[x]`, or `[X]` (optionally followed by a space) renders as a
# disabled checkbox + the rest. Returns `(checked, first_inline_content,
# rest_blocks)` so the caller can splice the first paragraph's inlines
# directly beside the checkbox (no wrapping `<p>` that would force a line
# break) and render any trailing blocks normally.
_task_list_marker(item) = begin
    isempty(item) && return nothing
    first_block = item[1]
    first_block isa Markdown.Paragraph || return nothing
    content = first_block.content
    isempty(content) && return nothing
    leaf = content[1]
    leaf isa AbstractString || return nothing
    m = match(r"^\[([ xX])\][ \t]*(.*)$"s, leaf)
    m === nothing && return nothing
    checked = m.captures[1] != " "
    rest = String(m.captures[2])
    first_inline = isempty(rest) ? content[2:end] : vcat(Any[rest], content[2:end])
    (checked, first_inline, item[2:end])
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
        kids = _md_inline_to_node.(content)
        al = align_attr(a)
        # Only single-column headers are click-to-sort. Spanning headers
        # (group labels) opt out — HTMXObjects' CSS already sets
        # `cursor: default` on `th[colspan]`. Guarded onclick so a click
        # without `sortable_table_js()` loaded is a silent no-op.
        onclick = span == 1 ? "if(window.sortTable)sortTable($(i-1),this)" : nothing
        cls     = span == 1 ? "u-pointer" : nothing
        colspan = span > 1 ? span : nothing
        h.th(kids; align=(al == "" ? nothing : al), colspan, onclick, class=cls)
    end
    td_cell(content, a, span) = begin
        kids = _md_inline_to_node.(content)
        al = align_attr(a)
        colspan = span > 1 ? span : nothing
        h.td(kids; align=(al == "" ? nothing : al), colspan)
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
        h.tr(children; id=row_ids[i])
    end
    thead = h.thead(h.tr([th_cell(c, get(t.align, idx, :l), idx, span)
                          for (c, span, idx) in collapse_empties(header)]))
    tbody = h.tbody([tr_for(i, cells) for (i, cells) in enumerate(body_collapsed)])
    h.table(thead, tbody; class="htmxo-sortable-table")
end
_md_to_node(l::Markdown.LaTeX) = "\$\$$(l.formula)\$\$"
_md_to_node(x) = string(x)
