# HTMX.jl

`HTMX.jl` is a thin Julia layer on top of [Cobweb.jl](https://github.com/JuliaWeb/Cobweb.jl) for building HTML for [HTMX](https://htmx.org)- and [Hyperscript](https://hyperscript.org)-powered apps.

The package is intentionally small. It exposes:

- [`h`](#building-html-with-h) — the `h.tag(...)` builder for HTML nodes
- [`Node`](#the-node-type) — an immutable wrapper around `Cobweb.Node`
- [`auto`](#converting-arbitrary-values-to-html) — convert arbitrary Julia values to HTML strings, with HTMX out-of-band-swap support
- [`HyperscriptString`](#embedding-hyperscript-with-_) and [`@__str`](#embedding-hyperscript-with-_) — embed Hyperscript snippets into the `_` attribute
- [Two-way Markdown ↔ HTML conversion](#markdown-rendering): `show(io, MIME"text/markdown"(), node)` and [`md_to_node`](#building-html-from-markdown)

## Building HTML with `h`

Use `h.tagname(...)` (preferred) or `h(:tagname, ...)` to build nodes.

```julia
using HTMX

h.div(class="container")(
    h.h1("Hello, HTMX!"),
    h.p("This is a paragraph."),
)
```

Keyword arguments become HTML attributes. **Underscores are converted to hyphens**, so HTMX/Alpine attributes are written naturally:

```julia
h.button(hx_get="/click", hx_target="#out", hx_swap="outerHTML")("Click me")
# <button hx-get="/click" hx-target="#out" hx-swap="outerHTML">Click me</button>
```

Attribute values are rendered as follows:

| Value          | Rendering                                           |
|----------------|-----------------------------------------------------|
| `nothing`      | omitted                                             |
| `false`        | omitted                                             |
| `true`         | rendered as `name="true"` (browsers treat as true) |
| anything else  | converted via `string(v)`                            |

```julia
h.input(type="checkbox", checked=true, disabled=false, name="ok")
# <input type="checkbox" checked="true" name="ok">
```

Positional arguments (after the keywords) become children. Vector-valued positional arguments are flattened, so you can splice lists directly:

```julia
items = ["apple", "banana", "cherry"]
h.ul([h.li(it) for it in items])   # no need for `...`
```

## The `Node` type

`Node` is an immutable wrapper around a `Cobweb.Node`. Calling a node returns a **new** node with extra children and merged attributes — the original is unchanged:

```julia
base = h.div(class="card")
with_body = base(h.p("body"))           # new node with body
themed   = base(class="card dark")      # new node, attribute merged
```

`Node`s are renderable as `text/html`, so `show(io, MIME"text/html"(), n)` produces a string ready to send to a browser. This is what most web frameworks (e.g. HTMXObjects.jl/Oxygen) call when serializing a response.

## Converting arbitrary values to HTML

`auto(x; wrap)` converts a Julia value to an HTML string, applying `wrap` to the final result. It handles:

- `AbstractString` — passed through to `wrap`
- `AbstractArray` — elements are recursively `auto`'d and joined with newlines
- `Pair(content, id)` — wrapped in an HTMX [out-of-band swap](https://htmx.org/attributes/hx-swap-oob/) `<div id=… hx-swap-oob="true">`. If `content` is itself a `Node`, the `id` and `hx-swap-oob` attribute are merged into it directly.
- Anything else — rendered via `repr("text/html", x)`

```julia
auto("<b>raw</b>"; wrap=identity)
# "<b>raw</b>"

auto([h.li("one"), h.li("two")]; wrap=string)
# "<li>one</li>\n<li>two</li>"

auto(h.span("new value") => "live-value"; wrap=string)
# <span id="live-value" hx-swap-oob="true">new value</span>
```

### Table-element OOB-swap fix

Browsers' `innerHTML` parser silently strips bare `<tr>`/`<td>`/`<th>`/`<thead>`/`<tbody>`/`<tfoot>`/`<caption>`/`<colgroup>`/`<col>` elements that lack proper parent context. When the OOB content is one of these, `auto` automatically wraps it in a `<template>`, which HTMX understands and unwraps on swap:

```julia
auto(h.tr(h.td("row 5")) => "row-5"; wrap=string)
# <template><tr id="row-5" hx-swap-oob="true"><td>row 5</td></tr></template>
```

## Embedding Hyperscript with `_"..."`

[Hyperscript](https://hyperscript.org/) snippets normally live in the `_` attribute (e.g. `<button _="on click toggle .hidden on #menu">`). Because `_` is not a valid Julia kwarg name, HTMX.jl exposes a string subtype `HyperscriptString` and a `_"..."` literal macro for it:

```julia
h.button("Toggle menu",
    _"on click toggle .hidden on #menu",
    _"on mouseenter add .hover end",
)
```

When rendered, all `HyperscriptString` children are pulled out of the children list and concatenated (newline-separated) into the `_` attribute:

```html
<button _="on click toggle .hidden on #menu
on mouseenter add .hover end">Toggle menu</button>
```

`HyperscriptString` is a subtype of `AbstractString`, so it works with `*`, `string(...)`, and any Julia function expecting a string. Concatenation via `*` of two `HyperscriptString`s preserves the type.

## Markdown rendering

`Node`s are renderable as both `text/html` **and** `text/markdown`. The Markdown rendering walks the node tree and emits per-tag Markdown (handy for piping a generated page through an LLM, agent, or `Markdown.parse` consumer):

```julia
node = h.article(
    h.header("Notes"),
    h.h2("Today"),
    h.ul(h.li("first"), h.li("second")),
    h.p("a paragraph"),
)
sprint(show, MIME"text/markdown"(), node)
# ---
#
# ### Notes
# ## Today
# - first
# - second
# a paragraph
```

Notable conversions:

| HTML tag                        | Markdown                  |
|---------------------------------|---------------------------|
| `h1`–`h6`                       | `#` … `######` headings   |
| `p`                             | paragraph                 |
| `ul` / `ol` + `li`              | `- item` lines            |
| `pre`                           | fenced code block         |
| `blockquote`                    | `> ` prefixed lines       |
| `table` + `thead`/`tbody`/`tr`  | pipe-style Markdown table |
| `img` / `figure`                | `![alt](src)`             |
| `a`                             | `[text](href)`            |
| `strong`/`b`, `em`/`i`, `code`  | `**…**`, `*…*`, `` `…` `` |
| `article`, `section`            | wrapped in `---` dividers |
| `header`                        | rendered as `### `        |
| `script`, `style`, `meta`, `link` | skipped                 |

Unknown tags fall through transparently (their text content is printed).

## Building HTML from Markdown

`md_to_node(s)` converts a Markdown string (or a parsed `Markdown.MD` AST) to `h.*` nodes. This is the inverse of the rendering above and is useful for embedding user-authored Markdown inside an HTMX page:

```julia
md_to_node("**bold** and `code`")
# h.div(h.p(h.strong("bold"), " and ", h.code("code")))

import Markdown
md_to_node(Markdown.parse("""
# Title
- one
- two
"""))
```

Supported Markdown constructs:

- Paragraphs, headings (`#` … `######`), bold, italic, inline `code`
- Fenced code blocks (rendered as `<pre><code>`; fenced with a language → wrapped in `<pre>`)
- Links, images
- Lists (ordered and unordered) and blockquotes
- Tables (with column alignment preserved via inline `style="text-align:…"`)
- Horizontal rules (`---`)
- LaTeX math (rendered as `$$…$$`, suitable for KaTeX/MathJax)

## Putting it together

A small "live counter" snippet using `h`, `auto`, and an OOB swap pair:

```julia
function counter_response(n::Int)
    body = h.div(id="counter")(string(n), h.button(hx_post="/inc", hx_target="#counter")("+"))
    extra = h.span(string(n)) => "counter-mirror"      # OOB-swapped mirror
    auto([body, extra]; wrap=string)
end
```

## See also

- [Cobweb.jl](https://github.com/JuliaWeb/Cobweb.jl) — the underlying HTML node library
- [HTMXObjects.jl](https://github.com/nsiccha/HTMXObjects.jl) — Oxygen + HTMX app scaffolding built on top of HTMX.jl
- [HTMX](https://htmx.org/) — the HTMX project
- [Hyperscript](https://hyperscript.org/) — the `_` attribute scripting language
- [API Reference](api) — auto-generated from docstrings
