# HTMX.jl

A small, focused Julia package for building HTML — designed for [HTMX](https://htmx.org)- and [Hyperscript](https://hyperscript.org)-powered apps. It owns a compact immutable HTML node primitive and provides:

- a tag-based builder (`h.div(...)`, `h.button(...)`, …)
- ergonomic attribute syntax: `hx_get` → `hx-get`, `nothing`/`false` omitted, `true` as `"true"`
- escape-by-default text children and attribute values, with explicit `Raw(...)` for complete trusted markup or program bytes
- HTMX [out-of-band swap](https://htmx.org/attributes/hx-swap-oob/) helpers via [`auto`](#converting-arbitrary-julia-values-to-html), including the table-element `<template>` workaround
- `_"…"` literals for embedding Hyperscript snippets into the `_` attribute
- two-way HTML ↔ Markdown conversion (`show(io, MIME"text/markdown"(), node)` and [`md_to_node`](#building-html-from-markdown))

The package surface is intentionally tiny — six exports and two MIME renderers. If you want app scaffolding (routes, OOB helpers, app-level state), see [HTMXObjects.jl](https://github.com/nsiccha/HTMXObjects.jl), which builds on top.

## Cheat sheet

```julia
using HTMX                                            # exports h, Node, Raw, auto, @__str, md_to_node

h.div(class="card")(h.h1("Hello"), h.p("world"))      # build nodes
h.button(hx_get="/click", hx_target="#out")("Go")     # HTMX attributes (underscore→hyphen)
h.input(type="checkbox", checked=true, disabled=false) # nothing/false omitted; true → checked="true"
h.ul([h.li(x) for x in items])                        # vector children are flattened (no `...` needed)

h.button(_"on click toggle .open on #menu")("Menu")  # Hyperscript snippet → `_` attribute

auto(node;     wrap=string)                           # render as HTML string
auto(content => "out-id"; wrap=string)                # OOB swap target
auto([a, b];   wrap=string)                           # multiple nodes, joined with newlines

md_to_node("**bold**")                                # Markdown string → h.* tree
sprint(show, MIME"text/markdown"(), node)             # h.* tree → Markdown
```

## Building HTML with `h`

`h.tagname(args...; kwargs...)` (preferred) or `h(:tagname, args...; kwargs...)` returns a [`Node`](#the-node-type). Keyword arguments are attributes; positional arguments are children.

```julia
julia> h.div(class="container")(h.h1("Hello"), h.p("world"))
```
```html
<div class="container"><h1>Hello</h1><p>world</p></div>
```

### Attribute conventions

| You write     | Rendered as                   |
|---------------|-------------------------------|
| `hx_get="/x"` | `hx-get="/x"` (underscores → hyphens) |
| `attr=nothing`| omitted                       |
| `attr=false`  | omitted                       |
| `attr=true`   | `attr="true"` (browsers treat as truthy) |
| `attr=v`      | HTML-escaped `string(v)`           |

```julia
julia> h.input(type="checkbox", checked=true, disabled=false, value=42)
```
```html
<input type="checkbox" checked="true" value="42">
```

### Children

Positional arguments are children. Vector-valued positional arguments are flattened, so list comprehensions splice naturally:

```julia
items = ["apple", "banana", "cherry"]
h.ul([h.li(it) for it in items])
```
```html
<ul><li>apple</li><li>banana</li><li>cherry</li></ul>
```

Calling an existing node returns a **new** node with the additional children/attributes — the original is unchanged:

```julia
base    = h.div(class="card")
withbody = base(h.p("body"))            # new: <div class="card"><p>body</p></div>
themed   = base(class="card dark")      # new: <div class="card dark"></div>
```

### Escaping and trusted raw content

Ordinary text children and attribute values escape `&`, `"`, `'`, `<`, and `>`
when the node renders. Pass data directly; pre-escaping it would produce visible
entity text:

```julia
h.p("<b>A&B</b>")
# <p>&lt;b&gt;A&amp;B&lt;/b&gt;</p>

h.div(title="A & \"B\"")
# <div title="A &amp; &quot;B&quot;"></div>
```

Nested `Node`s and other values with their own `text/html` renderer remain
structural HTML. For complete server-owned markup, JavaScript, or CSS bytes,
use the exported `Raw` wrapper explicitly:

```julia
h.div(Raw("<em>trusted markup</em>"))
# <div><em>trusted markup</em></div>

h.script(Raw("if (a < b && ready) start()"))
# <script>if (a < b && ready) start()</script>
```

`Raw` is a trust assertion, not a sanitizer or a JavaScript/CSS-context
escaper. Never interpolate untrusted values into its payload. It only opts out
for node children; attribute values are always escaped.

### Void elements

Void HTML elements (`<input>`, `<br>`, `<img>`, `<meta>`, `<link>`, …) are rendered without a closing tag automatically.

## The `Node` type

`Node` is HTMX.jl's immutable `tag` / `attrs` / `children` primitive. Useful properties:

- **Renderable** as `text/html` — `show(io, MIME"text/html"(), n)` produces a string ready to send to the browser. Web frameworks like HTMXObjects.jl/Oxygen call this when serializing responses.
- **Renderable** as `text/markdown` — see [Markdown rendering](#rendering-html-as-markdown).
- **Callable** — `n(more_children...; more_attrs...)` returns a *new* node with the children appended and the attributes merged.
- **Inspectable** — `HTMX.tag(n)`, `HTMX.attrs(n)`, and `HTMX.children(n)` expose its plain data fields.

## Embedding Hyperscript with `_"…"`

[Hyperscript](https://hyperscript.org/) snippets normally live in the `_` attribute (e.g. `<button _="on click toggle .open on #menu">`). Because `_` is not a valid Julia kwarg name, HTMX.jl exposes a string subtype `HyperscriptString` and a `_"…"` literal macro for it.

Pass any number of `HyperscriptString` children to a node. They are pulled out of the children list at render time and concatenated (newline-separated) into the `_` attribute:

```julia
h.button("Toggle menu",
    _"on click toggle .open on #menu",
    _"on mouseenter add .hover end",
)
```
```html
<button _="on click toggle .open on #menu
on mouseenter add .hover end">Toggle menu</button>
```

`HyperscriptString` is a real `AbstractString`, so it works with `*`, `string(...)`, interpolation, and any function expecting a string. Concatenation via `*` of two `HyperscriptString`s preserves the type.

## Converting arbitrary Julia values to HTML

```julia
auto(x; wrap)
```

Convert `x` to an HTML string and apply `wrap` to the result. The `wrap` keyword is mandatory — use `wrap = string` (or `wrap = identity`) when calling directly; web frameworks built on top of HTMX.jl typically inject their own wrapper for things like flash messages or layout.

The `AbstractString` overload is an intentional direct-response pass-through; it
does not create a `Node` and therefore does not escape. Use `h.*` when rendering
data as HTML text.

| Input                 | Behaviour                                                                  |
|-----------------------|----------------------------------------------------------------------------|
| `AbstractString`      | passed straight to `wrap`                                                  |
| `AbstractArray`       | each element `auto`'d (with `wrap=identity`) and joined with newlines, then `wrap`'d once |
| `Pair(content, id)`   | wrapped as an HTMX out-of-band swap (see below)                            |
| anything else         | rendered via `repr("text/html", x)` — i.e. `Node`, anything with a custom `Base.show(io, ::MIME"text/html", x)`, etc. |

```julia
julia> auto("<b>raw</b>"; wrap=string)
"<b>raw</b>"

julia> auto([h.li("a"), h.li("b")]; wrap=string)
"<li>a</li>\n<li>b</li>"

julia> auto(h.div(h.p("hi")); wrap=string)
"<div><p>hi</p></div>"
```

### Out-of-band swaps

A `Pair(content, id)` produces an HTMX [`hx-swap-oob`](https://htmx.org/attributes/hx-swap-oob/) target — the perfect way to update an unrelated part of the page in the same response:

```julia
auto(h.span("42") => "live-counter"; wrap=string)
# <span id="live-counter" hx-swap-oob="true">42</span>
```

If `content` is a `Node`, the `id` and `hx-swap-oob` attributes are merged in directly. If it's anything else, it's wrapped in a `<div>`:

```julia
auto("just text" => "msg"; wrap=string)
# <div id="msg" hx-swap-oob="true">just text</div>
```

To swap *several* OOB targets at once, build an array of pairs (or pairs interleaved with regular nodes) and let `auto`'s array handling do the joining:

```julia
auto([primary_response,
      h.span("42") => "live-counter",
      h.span("ok") => "status"];
     wrap=string)
```

### Table-element OOB workaround

Browsers' `innerHTML` parser silently strips bare `<tr>`/`<td>`/`<th>`/`<thead>`/`<tbody>`/`<tfoot>`/`<caption>`/`<colgroup>`/`<col>` elements that lack a proper parent context. When the OOB content is one of these, `auto` automatically wraps it in a `<template>`, which HTMX understands and unwraps on swap:

```julia
auto(h.tr(h.td("row 5")) => "row-5"; wrap=string)
```
```html
<template><tr id="row-5" hx-swap-oob="true"><td>row 5</td></tr></template>
```

This is an easy thing to forget — that's why it's automatic.

## Markdown rendering

`Node`s are renderable both as `text/html` *and* as `text/markdown`. The latter walks the node tree and emits per-tag Markdown — useful for piping a generated page through an LLM, an agent, a `Markdown.parse` consumer, or any other Markdown-aware tool.

### Rendering HTML as Markdown

```julia
node = h.article(
    h.header("Notes"),
    h.h2("Today"),
    h.ul(h.li("first"), h.li("second")),
    h.p("a paragraph"),
)
print(sprint(show, MIME"text/markdown"(), node))
```
```text
---

### Notes
## Today
- first
- second
a paragraph
```

The `---` divider before `<article>`/`<section>` is intentional: it gives a Markdown reader a clear seam between semantic blocks. Conversion table:

| HTML tag                          | Markdown                  |
|-----------------------------------|---------------------------|
| `h1`–`h6`                         | `#` … `######` headings   |
| `p`                               | paragraph                 |
| `ul` / `ol` + `li`                | `- item` lines            |
| `pre`                             | fenced code block         |
| `blockquote`                      | `> ` prefixed lines       |
| `table` + `thead`/`tbody`/`tr`    | pipe-style Markdown table |
| `img` / `figure`                  | `![alt](src)`             |
| `a`                               | `[text](href)`            |
| `strong`/`b`, `em`/`i`, `code`    | `**…**`, `*…*`, `` `…` `` |
| `article`, `section`              | wrapped in `---` dividers |
| `header`                          | rendered as `### `        |
| `title`                           | `# `                      |
| `hr`                              | `---`                     |
| `script`, `style`, `meta`, `link` | skipped                   |
| Containers (`div`, `main`, `body`, `html`, `head`, `span`, `details`, `summary`, `form`, `label`, `nav`, `footer`, `dl`) | recurse transparently |

Unknown tags fall through transparently — their text content is printed.

### Building HTML from Markdown

`md_to_node(s)` is the inverse: a Markdown string (or a parsed `Markdown.MD` AST) becomes an `h.*` tree, perfect for embedding user-authored Markdown inside an HTMX page.

```julia
julia> md_to_node("**bold** and `code`")
```
```html
<div><p><strong>bold</strong> and <code>code</code></p></div>
```

```julia
import Markdown
md_to_node(Markdown.parse("""
# Title
- one
- two
"""))
```

Supported constructs:

- Paragraphs, headings (`#` … `######`), bold, italic, inline `code`
- Fenced code blocks — `<pre><code>`; with a language → wrapped in `<pre>`
- Links, images
- Lists (ordered and unordered), blockquotes
- Tables — column alignment is preserved as inline `style="text-align:…"`
- Horizontal rules (`---`)
- LaTeX math — emitted as `$$…$$` strings, suitable for KaTeX/MathJax to pick up downstream

## A small worked example

A "live counter" snippet using `h`, `auto`, and an OOB swap:

```julia
function counter_response(n::Int)
    main  = h.div(id="counter")(
        string(n),
        h.button(hx_post="/inc", hx_target="#counter")("+"),
    )
    mirror = h.span(string(n)) => "counter-mirror"   # OOB-swapped mirror elsewhere
    auto([main, mirror]; wrap=string)
end
```

A tiny page with a Hyperscript-driven menu toggle:

```julia
page = h.html(
    h.head(h.title("Demo"),
           h.script(src="https://unpkg.com/htmx.org")),
    h.body(
        h.button(_"on click toggle .open on #menu")("Menu"),
        h.nav(id="menu", class="closed")(
            h.a(href="/")("Home"),
            h.a(href="/about")("About"),
        ),
    ),
)
```

## See also

- [API Reference](api) — auto-generated from docstrings
- [HTMXObjects.jl](https://github.com/nsiccha/HTMXObjects.jl) — Oxygen + HTMX app scaffolding built on top of HTMX.jl
- [HTMX](https://htmx.org/) — the HTMX project
- [Hyperscript](https://hyperscript.org/) — the `_` attribute scripting language
