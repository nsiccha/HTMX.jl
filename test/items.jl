using TestItemRunner

# Shared imports and rendering helpers are spliced independently into every
# test item, so each `@testitem` stays isolated while avoiding repeated setup.
@testsnippet HTMXTestHelpers begin
    using HTMX
    # Render a `Node` to its HTML / Markdown string form.
    html(node) = repr("text/html", node)
    to_md(node) = repr("text/markdown", node)
    hxml(node) = repr("application/vnd.hyperview+xml", node)

    # Minimal dependency-free XML well-formedness check: start tags are
    # balanced and properly nested.
    function well_formed_xml(s)
        stack = String[]
        i = firstindex(s)
        while true
            lt = findnext('<', s, i)
            lt === nothing && break
            gt = findnext('>', s, lt)
            gt === nothing && return false
            body = strip(s[nextind(s, lt):prevind(s, gt)])
            if startswith(body, '/')
                isempty(stack) && return false
                pop!(stack) == strip(body[nextind(body, firstindex(body)):end]) ||
                    return false
            elseif !endswith(body, '/')
                push!(stack, String(first(split(body))))
            end
            i = nextind(s, gt)
        end
        isempty(stack)
    end
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

"""
Ordinary text children and attribute values escape HTML metacharacters exactly
once, while nested and otherwise self-rendering HTML children stay structural.
"""
@testitem "HTML escaping defaults" setup=[HTMXTestHelpers] tags=[:unit, :nodes, :attributes, :escaping] begin
    payload = "<&\"'>&"
    escaped = "&lt;&amp;&quot;&#39;&gt;&amp;"

    @test html(h.div(title=payload)(payload)) ==
        "<div title=\"$escaped\">$escaped</div>"
    @test html(h.div(h.span(payload))) ==
        "<div><span>$escaped</span></div>"
    @test html(h.div(Base.HTML("<em>trusted & structural</em>"))) ==
        "<div><em>trusted & structural</em></div>"
end

"""
`Raw` is the explicit child-only opt-out for complete trusted markup and
script/style bodies. Without it, even raw-text element children are escaped.
"""
@testitem "Raw HTML opt-out" setup=[HTMXTestHelpers] tags=[:unit, :nodes, :escaping, :raw] begin
    markup = "<em data-x=\"a&b\">trusted</em>"
    program = "if (a < b && c > d) console.log(\"ok\")"

    @test String(Raw(markup)) == markup
    @test html(h.div(Raw(markup))) == "<div>$markup</div>"
    @test html(h.script(Raw(program))) == "<script>$program</script>"
    @test html(h.script(program)) ==
        "<script>if (a &lt; b &amp;&amp; c &gt; d) console.log(&quot;ok&quot;)</script>"
    @test html(h.div(data_value=Raw("<b>&"))) ==
        "<div data-value=\"&lt;b&gt;&amp;\"></div>"
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
    @test occursin("on click log &#39;hi&#39;", rendered)
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
    @test occursin("on click log &#39;a&#39;", rendered)
    @test occursin("on load log &#39;b&#39;", rendered)
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
GFM task-list markers become disabled checkbox inputs. Checked markers accept
both lowercase and uppercase `x`, while unchecked items omit `checked`.
"""
@testitem "md_to_node - task lists" setup=[HTMXTestHelpers] tags=[:unit, :markdown, :parser] begin
    node = md_to_node("- [ ] pending\n- [x] done\n- [X] loud")
    list = only(HTMX.children(node))
    items = HTMX.children(list)
    inputs = [first(HTMX.children(item)) for item in items]

    @test HTMX.tag(list) === :ul
    @test length(items) == 3
    @test all(input -> HTMX.tag(input) === :input, inputs)
    @test all(input -> HTMX.attrs(input)[:disabled] == "true", inputs)
    @test !haskey(HTMX.attrs(inputs[1]), :checked)
    @test HTMX.attrs(inputs[2])[:checked] == "true"
    @test HTMX.attrs(inputs[3])[:checked] == "true"
    @test occursin("> pending</li>", html(node))
end

"""
MultiMarkdown empty cells extend the preceding cell. Spanning headers opt out
of click-to-sort behavior, while ordinary headers retain their source column
index for `sortTable`.
"""
@testitem "md_to_node - colspan and sortable tables" setup=[HTMXTestHelpers] tags=[:unit, :markdown, :parser, :tables] begin
    node = md_to_node(
        "| A | Group | | D |\n" *
        "|:---|:---:|---:|---|\n" *
        "| 1 | 2 | | 4 |",
    )
    table = only(HTMX.children(node))
    thead, tbody = HTMX.children(table)
    headers = HTMX.children(only(HTMX.children(thead)))
    cells = HTMX.children(only(HTMX.children(tbody)))

    @test HTMX.attrs(table)[:class] == "htmxo-sortable-table"
    @test length(headers) == 3
    @test HTMX.attrs(headers[2])[:colspan] == "2"
    @test !haskey(HTMX.attrs(headers[2]), :onclick)
    @test !haskey(HTMX.attrs(headers[2]), :class)
    @test occursin("sortTable(0,this)", HTMX.attrs(headers[1])[:onclick])
    @test occursin("sortTable(3,this)", HTMX.attrs(headers[3])[:onclick])
    @test length(cells) == 3
    @test HTMX.attrs(cells[2])[:colspan] == "2"
end

"""
A full-width body row is paired with its preceding primary row using matching
`row-` / `detail-` identifiers, and its sole cell spans the table.
"""
@testitem "md_to_node - master detail table rows" setup=[HTMXTestHelpers] tags=[:unit, :markdown, :parser, :tables] begin
    node = md_to_node(
        "| Name | Value | Status |\n" *
        "|---|---:|:---:|\n" *
        "| Alpha | 2 | Ready |\n" *
        "| detail text |||",
    )
    table = only(HTMX.children(node))
    tbody = HTMX.children(table)[2]
    primary, detail = HTMX.children(tbody)
    primary_id = HTMX.attrs(primary)[:id]
    detail_id = HTMX.attrs(detail)[:id]
    detail_cell = only(HTMX.children(detail))

    @test startswith(primary_id, "row-")
    @test detail_id == replace(primary_id, "row-" => "detail-"; count=1)
    @test HTMX.attrs(detail_cell)[:colspan] == "3"
    @test HTMX.children(detail_cell) == ["detail text"]
end

"""
Semantic HTML blocks preserve their agent-readable Markdown conventions:
figures use Quarto fences, details omit the summary toggle, and blockquotes
prefix every line.
"""
@testitem "markdown - figure details and blockquote" setup=[HTMXTestHelpers] tags=[:unit, :markdown, :semantic] begin
    figure = h.figure(id="fig-main")(
        h.img(src="/a.png", alt="A"),
        h.figcaption("Caption"),
    )
    @test to_md(figure) ==
        "\n\n::: {#fig-main}\n![A](/a.png)\n\nCaption\n:::\n\n"

    details = h.details(h.summary("Toggle"), h.p("Visible ", h.strong("content")))
    @test to_md(details) == "Visible **content**\n\n"
    @test !occursin("Toggle", to_md(details))

    blockquote = h.blockquote(h.p("A ", h.strong("B")), h.p("C"))
    @test to_md(blockquote) == "> A **B**\n> \n> C\n\n"
end

"""
Inline and fenced Markdown code is escaped exactly once before becoming HTML,
covering ampersands, quotes, apostrophes, and angle brackets.
"""
@testitem "md_to_node - code escaping" setup=[HTMXTestHelpers] tags=[:unit, :markdown, :parser, :escaping] begin
    payload = "<x attr=\"v\"> & 'quoted'"
    escaped = "&lt;x attr=&quot;v&quot;&gt; &amp; &#39;quoted&#39;"

    @test html(md_to_node("`$payload`")) ==
        "<div><p><code>$escaped</code></p></div>"
    @test html(md_to_node("```html\n$payload\n```")) ==
        "<div><pre><code>$escaped</code></pre></div>"
end

"""
`header` renders as a level-3 heading and `title` as a level-1 heading, both
keeping inline formatting.
"""
@testitem "markdown - header and title" setup=[HTMXTestHelpers] tags=[:unit, :markdown] begin
    @test to_md(h.header("Section")) == "### Section\n"
    @test to_md(h.title("Page ", h.code("Title"))) == "# Page `Title`\n"
end

# ================================================================
# HXML (Hyperview) rendering
# ================================================================

"""
`navigator` and `nav-route` preserve the native Hyperview container shape,
including the default stack type, self-closing routes, and escaped URLs.
"""
@testitem "hxml - navigator and nav-route containers" setup=[HTMXTestHelpers] tags=[:unit, :hxml, :navigation] begin
    @test hxml(h.navigator(
        h.var"nav-route"(href="/hxml", id="home");
        id="root",
        type="stack",
    )) ==
        "<navigator id=\"root\" type=\"stack\"><nav-route id=\"home\" href=\"/hxml\" /></navigator>"
    @test hxml(h.var"nav-route"()) == "<nav-route />"
    @test hxml(h.navigator(; id="x")) ==
        "<navigator id=\"x\" type=\"stack\"></navigator>"
    @test hxml(h.navigator(
        h.var"nav-route"(href="/a", id="a"),
        h.var"nav-route"(href="/b", id="b");
        id="t",
        type="tab",
    )) ==
        "<navigator id=\"t\" type=\"tab\"><nav-route id=\"a\" href=\"/a\" /><nav-route id=\"b\" href=\"/b\" /></navigator>"
    @test hxml(h.var"nav-route"(href="/x?a=1&b=2")) ==
        "<nav-route href=\"/x?a=1&amp;b=2\" />"
end

"""
Explicit Hyperview behavior nodes cover the full action surface, and implicit
anchor navigation uses the same behavior emitter.
"""
@testitem "hxml - explicit behavior actions" setup=[HTMXTestHelpers] tags=[:unit, :hxml, :navigation] begin
    @test hxml(h.behavior(action="push", trigger="press", href="/x")) ==
        "<behavior trigger=\"press\" action=\"push\" href=\"/x\" />"
    @test hxml(h.behavior(action="back")) ==
        "<behavior trigger=\"press\" action=\"back\" />"
    @test hxml(h.behavior(action="navigate", href="/y", target="main")) ==
        "<behavior trigger=\"press\" action=\"navigate\" href=\"/y\" target=\"main\" />"
    @test hxml(h.behavior(
        action="replace-inner",
        trigger="load",
        href="/z",
        delay="500",
    )) ==
        "<behavior trigger=\"load\" action=\"replace-inner\" href=\"/z\" delay=\"500\" />"
    @test hxml(h.behavior(action="new", href="/modal", verb="POST")) ==
        "<behavior trigger=\"press\" action=\"new\" href=\"/modal\" verb=\"POST\" />"
    @test hxml(h.a("Home", href="/home")) ==
        "<text style=\"a\"><behavior trigger=\"press\" action=\"push\" href=\"/home\" />Home</text>"
end

"""
Representative navigation, behavior, link, and table output is balanced XML;
the local checker also rejects a mismatched closing tag.
"""
@testitem "hxml - emission is well formed" setup=[HTMXTestHelpers] tags=[:unit, :hxml, :xml] begin
    @test well_formed_xml(hxml(h.navigator(
        h.var"nav-route"(href="/hxml", id="home");
        id="root",
        type="stack",
    )))
    @test well_formed_xml(hxml(h.behavior(action="back")))
    @test well_formed_xml(hxml(h.a("Home", href="/home")))
    @test well_formed_xml(hxml(h.table(h.tr(h.th("A"), h.td("1")))))
    @test !well_formed_xml("<navigator><nav-route /></wrong>")
end

"""
The vendor HXML MIME is registered as text, so `repr` returns the same
String-shaped result callers receive for HTML and Markdown.
"""
@testitem "hxml - repr returns a String" setup=[HTMXTestHelpers] tags=[:unit, :hxml, :mime] begin
    rendered = repr("application/vnd.hyperview+xml", h.div())
    @test rendered isa String
    @test rendered == "<view style=\"div\"></view>"
end

"""
HTMX emits a body fragment whose tag-first style ids and behaviors compose
into the consumer-owned `doc/screen/styles/body` envelope.
"""
@testitem "hxml - end-to-end consumer screen" setup=[HTMXTestHelpers] tags=[:integration, :hxml, :consumer] begin
    fragment = hxml(h.div(class="card")(
        h.h2("Invoice"),
        h.p(h.small("due "), h.code("2026-07-31")),
        h.ul(h.li(h.a("Open", href="/inv/1"))),
        h.button("Refresh"; hx_get="/inv/1/rows", hx_target="#content"),
    ))

    @test occursin("<view style=\"div card\">", fragment)
    @test occursin("<text style=\"h2\">Invoice</text>", fragment)
    @test occursin("<text style=\"small\">", fragment)
    @test occursin(
        "<behavior trigger=\"press\" action=\"push\" href=\"/inv/1\" />",
        fragment,
    )
    @test occursin(
        "action=\"replace-inner\" href=\"/inv/1/rows\" target=\"content\"",
        fragment,
    )

    dropped = hxml(h.div(style="color:red")("x"))
    @test !occursin("color:red", dropped)
    @test occursin("<view style=\"div\">", dropped)

    styles = "<styles>" *
        "<style id=\"div\" flexDirection=\"column\" />" *
        "<style id=\"card\" padding=\"16\" />" *
        "<style id=\"h2\" fontSize=\"20\" />" *
        "<style id=\"small\" color=\"gray\" />" *
        "<style id=\"code\" fontFamily=\"monospace\" />" *
        "<style id=\"ul\" /><style id=\"li\" />" *
        "<style id=\"a\" color=\"blue\" /><style id=\"button\" />" *
        "</styles>"
    doc = "<doc><screen>" * styles * "<body>" * fragment * "</body></screen></doc>"
    @test well_formed_xml(doc)
end
