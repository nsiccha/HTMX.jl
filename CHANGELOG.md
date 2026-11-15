# Changelog

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
