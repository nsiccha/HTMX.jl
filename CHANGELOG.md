# Changelog

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
