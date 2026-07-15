using TestItemRunner

# Shared imports and rendering helpers are spliced independently into every
# test item, so each `@testitem` stays isolated while avoiding repeated setup.
@testsnippet HTMXTestHelpers begin
    using HTMX
    # Render a `Node` to its HTML / Markdown string form.
    html(node) = repr("text/html", node)
    to_md(node) = repr("text/markdown", node)
end

# ================================================================
# Basic node creation
# ================================================================

"""
The `h.<tag>(...)` builder produces plain nodes whose HTML rendering wraps the
children in matching open/close tags, concatenating multiple children.
"""
@testitem "h - basic node creation" setup=[HTMXTestHelpers] tags=[:unit, :nodes] begin
    @test html(h.div()) == "<div></div>"
    @test html(h.p("hello")) == "<p>hello</p>"
    @test html(h.span("a", "b")) == "<span>ab</span>"
end

"""
Keyword arguments to the builder become HTML attributes, emitted in insertion
order.
"""
@testitem "h - attributes" setup=[HTMXTestHelpers] tags=[:unit, :nodes, :attributes] begin
    @test html(h.div(class="foo")) == "<div class=\"foo\"></div>"
    @test html(h.a(href="/page")) == "<a href=\"/page\"></a>"
    @test html(h.div(class="foo", id="bar")) == "<div class=\"foo\" id=\"bar\"></div>"
end

"""
Attributes supplied at construction and children supplied via the call syntax
render together on the same element.
"""
@testitem "h - attributes and children combined" setup=[HTMXTestHelpers] tags=[:unit, :nodes] begin
    node = h.div(class="container")("child text")
    @test html(node) == "<div class=\"container\">child text</div>"
end

"""
Nodes passed as children nest as child elements in the rendered HTML.
"""
@testitem "h - nested nodes" setup=[HTMXTestHelpers] tags=[:unit, :nodes] begin
    node = h.div(h.p("inner"))
    @test html(node) == "<div><p>inner</p></div>"
end

# ================================================================
# Call syntax
# ================================================================

"""
Calling a node appends children and returns a new node; the original is left
unchanged (immutable wrapping).
"""
@testitem "Node - call syntax appends children" setup=[HTMXTestHelpers] tags=[:unit, :nodes] begin
    node = h.ul()
    node2 = node(h.li("one"), h.li("two"))
    @test html(node2) == "<ul><li>one</li><li>two</li></ul>"
    # original is unchanged (immutable wrapping)
    @test html(node) == "<ul></ul>"
end

"""
Calling a node with keyword arguments merges them into the node's attributes.
"""
@testitem "Node - call syntax merges attributes" setup=[HTMXTestHelpers] tags=[:unit, :nodes, :attributes] begin
    node = h.div(class="a")
    node2 = node(id="b")
    @test occursin("class=\"a\"", html(node2))
    @test occursin("id=\"b\"", html(node2))
end

# ================================================================
# Attribute handling
# ================================================================

"""
Underscores in attribute names are rewritten to hyphens, so `hx_get` and
`data_foo` emit the HTMX/data attribute conventions `hx-get` and `data-foo`.
"""
@testitem "Underscore-to-hyphen in attribute names" setup=[HTMXTestHelpers] tags=[:unit, :attributes] begin
    node = h.div(hx_get="/endpoint")
    @test occursin("hx-get=\"/endpoint\"", html(node))

    node2 = h.div(data_foo="bar")
    @test occursin("data-foo=\"bar\"", html(node2))
end

"""
A string attribute value is preserved verbatim (`hx-swap-oob="true"` is the
correct HTMX form, not a bare attribute), while a genuine boolean attribute
given the string `"false"` is omitted entirely.
"""
@testitem "Boolean attributes" setup=[HTMXTestHelpers] tags=[:unit, :attributes] begin
    # A string value is kept verbatim — hx-swap-oob="true" is meaningful.
    node = h.div(hx_swap_oob="true")
    rendered = html(node)
    @test occursin("hx-swap-oob=\"true\"", rendered)

    # A boolean attribute given "false" is omitted entirely.
    node2 = h.div(hidden="false")
    rendered2 = html(node2)
    @test !occursin("hidden", rendered2)
end

"""
Attributes whose value is `nothing` are dropped from the output, both as a
keyword-only attribute and when mixed with real attributes.
"""
@testitem "nothing attributes are omitted" setup=[HTMXTestHelpers] tags=[:unit, :attributes] begin
    node = h.option("x"; selected=nothing)
    rendered = html(node)
    @test !occursin("selected", rendered)
    @test occursin(">x<", rendered)

    node2 = h.input(; type="text", disabled=nothing, class="foo")
    rendered2 = html(node2)
    @test occursin("type=\"text\"", rendered2)
    @test occursin("class=\"foo\"", rendered2)
    @test !occursin("disabled", rendered2)
end

"""
A `Bool` attribute value renders as `name="true"` when `true` (browsers treat
the quoted value as set) and is omitted entirely when `false`.
"""
@testitem "Bool attribute values" setup=[HTMXTestHelpers] tags=[:unit, :attributes] begin
    node = h.input(; checked=true)
    rendered = html(node)
    @test occursin("checked=\"true\"", rendered)

    node2 = h.input(; checked=false)
    rendered2 = html(node2)
    @test !occursin("checked", rendered2)
end

"""
`nothing` and `Bool` attribute semantics also hold when the attributes are
supplied through the call syntax: `nothing` is dropped and `true` renders as
`name="true"`.
"""
@testitem "nothing/Bool attributes via call syntax" setup=[HTMXTestHelpers] tags=[:unit, :attributes] begin
    node = h.div(class="a")(; selected=nothing, hidden=true)
    rendered = html(node)
    @test occursin("class=\"a\"", rendered)
    @test !occursin("selected", rendered)
    @test occursin("hidden=\"true\"", rendered)
end

# ================================================================
# Hyperscript
# ================================================================

"""
`HyperscriptString` is an `AbstractString` that round-trips through `String`
and concatenates back into a `HyperscriptString`.
"""
@testitem "HTMX.HyperscriptString" setup=[HTMXTestHelpers] tags=[:unit, :hyperscript] begin
    hs = HTMX.HyperscriptString("on click toggle .active")
    @test hs isa AbstractString
    @test String(hs) == "on click toggle .active"
    @test length(hs) == length("on click toggle .active")

    hs2 = HTMX.HyperscriptString("a") * HTMX.HyperscriptString("b")
    @test hs2 isa HTMX.HyperscriptString
    @test String(hs2) == "ab"
end

"""
A `HyperscriptString` child is emitted as the hyperscript `_` attribute rather
than as text content.
"""
@testitem "Hyperscript _ attribute via HyperscriptString children" setup=[HTMXTestHelpers] tags=[:unit, :hyperscript] begin
    hs = HTMX.HyperscriptString("on click log 'hi'")
    node = h.div(hs)
    rendered = html(node)
    @test occursin("_=", rendered)
    @test occursin("on click log 'hi'", rendered)
end

"""
The `HyperscriptString` payload lands inside the `_` attribute, never as the
element's text body.
"""
@testitem "HyperscriptString children move to _ attribute" setup=[HTMXTestHelpers] tags=[:unit, :hyperscript] begin
    hs = HTMX.HyperscriptString("on click toggle .active")
    node = h.button(hs)
    rendered = html(node)
    @test occursin("_=", rendered)
    @test occursin("on click toggle .active", rendered)
    @test !occursin(">on click toggle .active<", rendered)
end

"""
Multiple `HyperscriptString` children concatenate into a single `_` attribute.
"""
@testitem "Multiple HyperscriptString children concatenate" setup=[HTMXTestHelpers] tags=[:unit, :hyperscript] begin
    hs1 = HTMX.HyperscriptString("on click log 'a'")
    hs2 = HTMX.HyperscriptString("on load log 'b'")
    node = h.div(hs1, hs2)
    rendered = html(node)
    @test occursin("on click log 'a'", rendered)
    @test occursin("on load log 'b'", rendered)
end

"""
The `@__str` string macro constructs a `HyperscriptString` literal.
"""
@testitem "@__str macro" setup=[HTMXTestHelpers] tags=[:unit, :hyperscript] begin
    hs = @__str "hello world"
    @test hs isa HTMX.HyperscriptString
    @test String(hs) == "hello world"
end

# ================================================================
# auto function
# ================================================================

"""
`auto` renders strings verbatim and joins a vector of strings with newlines.
"""
@testitem "auto - basic conversions" setup=[HTMXTestHelpers] tags=[:unit, :auto] begin
    @test auto("hello"; wrap=identity) == "hello"
    @test auto(["a", "b"]; wrap=identity) == "a\nb"
end

"""
`auto` maps a `content => id` pair to an out-of-band swap `div` carrying the id
and `hx-swap-oob` marker.
"""
@testitem "auto - Pair creates OOB swap div" setup=[HTMXTestHelpers] tags=[:unit, :auto] begin
    result = auto("content" => "my-id"; wrap=identity)
    @test occursin("id=\"my-id\"", result)
    @test occursin("hx-swap-oob", result)
    @test occursin("content", result)
end

"""
Arbitrary objects (e.g. a `Node`) are rendered by `auto` through their
`text/html` representation.
"""
@testitem "auto - arbitrary objects use repr text/html" setup=[HTMXTestHelpers] tags=[:unit, :auto] begin
    node = h.p("test")
    result = auto(node; wrap=identity)
    @test result == "<p>test</p>"
end

"""
The `wrap` keyword is applied to `auto`'s output, allowing a caller-supplied
post-processing transform.
"""
@testitem "auto - wrap function is applied" setup=[HTMXTestHelpers] tags=[:unit, :auto] begin
    result = auto("hello"; wrap=uppercase)
    @test result == "HELLO"
end

# ================================================================
# Node primitive (owned by HTMX.jl — no Cobweb wrapper)
# ================================================================

"""
`Node` is HTMX.jl's own primitive: `tag`/`attrs`/`children` expose its parts,
and the call syntax returns a fresh node without mutating the original.
"""
@testitem "Node is the owned primitive" setup=[HTMXTestHelpers] tags=[:unit, :nodes] begin
    n = h.div(class="x")("test")
    @test n isa HTMX.Node
    @test HTMX.tag(n) === :div
    @test HTMX.attrs(n) isa AbstractDict
    @test HTMX.attrs(n)[:class] == "x"
    @test HTMX.children(n) == ["test"]
    # Call syntax returns a new node; the original is unchanged.
    @test HTMX.children(h.div()) == []
end

# ================================================================
# Markdown rendering (Node -> text/markdown via _md dispatch)
# ================================================================

"""
Inline formatting tags (`strong`/`b`, `em`/`i`, `code`, `a`) render to their
Markdown equivalents.
"""
@testitem "markdown - inline formatting" setup=[HTMXTestHelpers] tags=[:unit, :markdown] begin
    @test to_md(h.strong("bold")) == "**bold**"
    @test to_md(h.b("bold")) == "**bold**"
    @test to_md(h.em("it")) == "*it*"
    @test to_md(h.i("it")) == "*it*"
    @test to_md(h.code("x = 1")) == "`x = 1`"
    @test to_md(h.a(href="http://ex.com")("link")) == "[link](http://ex.com)"
end

"""
A paragraph preserves inline formatting of its children and terminates with a
blank line.
"""
@testitem "markdown - paragraph keeps inline formatting" setup=[HTMXTestHelpers] tags=[:unit, :markdown] begin
    p = h.p("hello ", h.strong("world"), " and ", h.code("y"))
    @test to_md(p) == "hello **world** and `y`\n\n"
end

"""
A `br` inside a paragraph renders as a hard newline in the Markdown output.
"""
@testitem "markdown - br renders a newline" setup=[HTMXTestHelpers] tags=[:unit, :markdown] begin
    @test to_md(h.p("a", h.br(), "b")) == "a\nb\n\n"
end

"""
Heading tags render with the matching number of `#` markers and keep inline
formatting of their children.
"""
@testitem "markdown - heading keeps inline formatting" setup=[HTMXTestHelpers] tags=[:unit, :markdown] begin
    @test to_md(h.h1("Top")) == "# Top\n"
    @test to_md(h.h2("Title ", h.em("x"))) == "## Title *x*\n"
end

"""
A list item renders as a `- ` bullet and keeps inline formatting of its
children.
"""
@testitem "markdown - list item keeps inline formatting" setup=[HTMXTestHelpers] tags=[:unit, :markdown] begin
    @test to_md(h.li("item ", h.strong("bold"))) == "- item **bold**\n"
end

"""
A `pre > code` block emits a fenced Markdown block using the `language-*` class
for the fence info string, without the inline-`code` backtick handler firing.
"""
@testitem "markdown - pre emits fenced block without stray backticks" setup=[HTMXTestHelpers] tags=[:unit, :markdown] begin
    out = to_md(h.pre(h.code(class="language-julia", "x = 1\ny = 2")))
    @test out == "```julia\nx = 1\ny = 2\n```\n"
    # The inline <code> handler must NOT fire inside <pre>.
    @test !occursin("`x = 1`", out)
end

"""
Table cells preserve inline Markdown formatting when a parsed table node is
rendered back to Markdown.
"""
@testitem "markdown - table cells keep inline formatting" setup=[HTMXTestHelpers] tags=[:unit, :markdown] begin
    out = to_md(md_to_node("| **A** | B |\n|---|---|\n| `c` | *d* |"))
    @test occursin("| **A** | B |", out)
    @test occursin("| `c` | *d* |", out)
end

"""
`md_to_node` parsing followed by Markdown rendering round-trips inline
formatting (bold, code, link).
"""
@testitem "markdown - md_to_node round-trips inline formatting" setup=[HTMXTestHelpers] tags=[:unit, :markdown] begin
    rt = "**bold** and `code` and [link](http://x)"
    @test strip(to_md(md_to_node(rt))) == rt
end

"""
`header` renders as a level-3 heading and `title` as a level-1 heading, both
keeping inline formatting.
"""
@testitem "markdown - header and title" setup=[HTMXTestHelpers] tags=[:unit, :markdown] begin
    @test to_md(h.header("Section")) == "### Section\n"
    @test to_md(h.title("Page ", h.code("Title"))) == "# Page `Title`\n"
end
