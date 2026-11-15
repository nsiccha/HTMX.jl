# Changelog

## Unreleased

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
