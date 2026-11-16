# Changelog

## 1.4.1

- In Markdown, a `<details>` keeps its `<summary>`. Before, the summary was
  dropped as a toggle label, so a disclosure's label (a table's title, a
  card's question) was missing from every Markdown read. Markdown has no
  viewport to collapse into, so a `<details>` now writes its first
  `<summary>` as a bold paragraph, `**Label**`, followed by its whole body,
  the way HTMXObjects' `SemanticDisclosure` writes its label. A summary
  holding a heading or other blocks writes them as they are; in a list item,
  a table cell or a link a line break sets the label off instead of a blank
  line. A `<details>` whose body writes nothing (nothing, a button, a form of
  controls only) still writes nothing, its label included. A later
  `<summary>` is body content, as in HTML. A value's `show` inside the label
  `<summary>` runs once more for its layout probe, as inside a `<header>`.

## 1.4.0

- In Markdown, a table that a pipe table cannot hold (a header of several
  rows, a `colspan` or `rowspan` above 1, a row wider than the header) keeps
  every cell in its column. Before, the first row was written as the header,
  spans were ignored and later header rows became body rows, so Pandoc
  dropped cells past the first row's width and a span moved the cells after
  it one column over, with no error. The table is now laid out on its full
  column grid and written as one pipe table: each column's header joins the
  header cells over it, top to bottom, with `" / "` (`Group A / Column 1`),
  and the positions a body cell spans are empty cells, which `md_to_node`
  reads back as a colspan. `<thead>` rows head the table wherever the section
  sits. A table a pipe table holds is written as before.
- Add `HTMX.with_markdown_grid_tables(f, on::Bool)` and
  `HTMX.markdown_grid_tables()` (public, not exported). Inside
  `with_markdown_grid_tables(f, true)` such a table is a Pandoc grid table
  instead, with every header row and span as in the HTML, for Markdown that
  Pandoc (so Quarto, for a PDF) reads; GFM and Julia's `Markdown` show a grid
  table as text. A grid cell that opens like a block (`-`, `1.`, `#`, `>`, …)
  gets that marker escaped. The setting is a scoped value, like
  `with_markdown_seams`; the default is off.

## 1.3.1

- In Markdown, the blank line that follows a list item or block container is
  written in front of the first write that holds content, and the line
  endings that write opens with count toward it. A value's `show` that opened
  a block with its own line endings and printed the rest in further writes
  got that blank line inside its second write:
  `print(io, "\n\n::: {.note data-name=\""); print(io, "cs-trend"); …` right
  after a `div` wrote `data-name="\n\ncs-trend"`. It now gets what one write
  of the same bytes gets. Text that opens with a single line ending right
  after a container now starts a new paragraph as well:
  `h.div(h.div("one"), "\ntwo")` renders `"one\n\ntwo"`, where it rendered
  `"one\ntwo"`, one paragraph.

## 1.3.0

- Add `HTMX.with_markdown_seams(f, on::Bool)` and `HTMX.markdown_seams()`
  (public, not exported). Inside `with_markdown_seams(f, false)` Markdown
  writes every `<article>` and `<section>` as a `<div>` is, without the
  leading `---` seam, which Pandoc reads as a horizontal rule in a PDF. A
  linked `id` still goes on the opening heading or a fenced div, a `lang`
  still becomes a fenced div, and an `<hr>` still writes `---`. The setting
  is a scoped value: every Markdown render inside `f` sees it, fresh renders
  in a value's own `show` and spawned tasks included, and a nested
  `with_markdown_seams(g, true)` switches the seam back on. The default is
  on, so output without the switch is unchanged.
- Depend on ScopedValues.jl (1.6), which uses `Base.ScopedValues` on Julia
  1.11 and newer.

## 1.2.1

- In Markdown, a `<p>` inside content that must stay one paragraph (a link or
  other inline element, a heading, a figure caption, the span
  `HTMX.markdown_div` writes in a list item, link, heading or table cell, an
  element's own `lang` span) is set off by a line break, written as a `<br>`
  is there: a hard break `\` + newline, a space in a heading, `<br>` in a
  table cell. It wrote a blank line, which ended the span, link, heading or
  caption around it: `- [*lbl*\n\nSECRET]{.x}` is now
  `- [*lbl*\` + newline + `SECRET]{.x}`.

## 1.2.0

- Add `HTMX.markdown_div` and `HTMX.markdown_block_context` (public, not
  exported) for a non-Node value's Markdown `show`: write a Pandoc div
  `::: {#id .class key="value"}` around content that starts a paragraph of its
  own, or a span where a fence would break the line (a table cell, a list
  item, inline content), and tell which applies, without HTMX's internal
  Markdown stream. `markdown_block`, `markdown_div` and
  `markdown_block_context` are declared `public` on Julia 1.11 and newer.
- Reuse buffers when converting node arrays to HTML, retaining custom `auto`
  dispatch for foreign values and nested arrays.
- Avoid rendering empty Markdown table anchor prefixes and stream HXML class
  tokens without intermediate vectors.
- Render a non-Node value's Markdown `show` while the document is written
  again, so the nodes it prints render inside that call: state it holds while
  printing applies to them, and a `show` that wraps itself in a node when not
  handed HTMX's stream no longer overflows the stack. It runs once per
  occurrence; a second render happens only when its output holds the only link
  to an element id. Header layout probes no longer use an exception.

## 1.1.1

- Require Julia 1.10 or newer for streaming string replacement.
- Stream HTML and HXML escaping without copying nodes or building escaped
  attribute strings; aggregate hyperscript fragments in linear time.
- Share attribute normalization and pass Markdown AST child vectors directly
  to constructors.
- Stop Markdown header layout probes at the first block and reuse foreign
  renderer output within a render, preserving context-dependent output.
- Precompile representative construction, serialization, and Markdown parsing
  paths. Organize the implementation by renderer and conversion stage.

## 1.1.0

- Add the `HTMX.markdown_block` trait for foreign Markdown children.
