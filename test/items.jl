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

"""
A vector positional child is flattened one level into the child list, in both
the builder and the call form — so a long child list can be passed as one
vector instead of splatted, holding the same children and rendering
byte-identical HTML.
"""
@testitem "Vector children are flattened" setup=[HTMXTestHelpers] tags=[:unit, :nodes] begin
    kids = Any[h.div(class="x")("item $k") for k in 1:10]
    @test HTMX.children(h.div(class="c")(kids)) == kids
    @test HTMX.children(h.div(kids; class="c")) == kids
    @test html(h.div(class="c")(kids...)) == html(h.div(class="c")(kids))
    # mixed scalar + vector, empty vector, "" entries, escaped text
    m1 = h.div("a", ["b", "c"], "", "<&>", Any[])
    m2 = h.div("a", "b", "c", "", "<&>")
    @test HTMX.children(m1) == HTMX.children(m2)
    @test html(m1) == html(m2)
end

"""
Varargs child collection is linear in the child count: doubling the children
roughly doubles allocation instead of quadrupling it (folding `vcat` across
the arguments is quadratic).
"""
@testitem "varargs children scale linearly" setup=[HTMXTestHelpers] tags=[:unit, :nodes] begin
    small = Any[h.div("item $k") for k in 1:1000]
    large = Any[h.div("item $k") for k in 1:2000]
    h.div()(small...)  # warmup
    a_small = @allocated h.div()(small...)
    a_large = @allocated h.div()(large...)
    @test a_large < 3 * a_small
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
A `pre` block whose verbatim body itself contains a fenced code block must use
an outer fence longer than any backtick run inside (CommonMark rule), so the
body survives as one code block instead of closing early with a stray fence.
"""
@testitem "markdown - pre lengthens fence around inner fenced block" setup=[HTMXTestHelpers] tags=[:unit, :markdown] begin
    body = "intro line\n```julia\nx = 1\n```\ntrailing line"
    out = to_md(h.pre(h.code(body)))
    lines = split(out, '\n')
    @test lines[1] == "````"
    @test lines[end-1] == "````"
    @test count(==("````"), lines) == 2
    @test "```julia" in lines
    @test "```" in lines

    # The language info string rides the lengthened fence.
    out_lang = to_md(h.pre(h.code(class="language-julia", body)))
    @test split(out_lang, '\n')[1] == "````julia"

    # Longer inner runs push the fence further: N+1 backticks where N is longest.
    out2 = to_md(h.pre(h.code("a\n````\nb\n````\nc")))
    @test split(out2, '\n')[1] == "`````"
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
Rows that sit directly under `<table>` (no `thead`/`tbody`, as browsers
accept) render like sectioned rows, in document order; `caption` and
`colgroup` contribute nothing.
"""
@testitem "markdown - table rows without sections" setup=[HTMXTestHelpers] tags=[:unit, :markdown] begin
    @test to_md(h.table(h.tr(h.th("a")), h.tr(h.td("1")))) == "| a |\n| --- |\n| 1 |\n\n"
    @test to_md(h.div("Total", h.table(h.tr(h.td("a"))))) == "Total\n\n| a |\n| --- |\n\n"
    @test to_md(h.table(h.caption("c"), h.colgroup(h.col()), h.thead(h.tr(h.th("a"))),
        h.tr(h.td("1")), h.tbody(h.tr(h.td("2"))))) == "| a |\n| --- |\n| 1 |\n| 2 |\n\n"
end

"""
Every table row stays one Markdown line: a `br` in a cell renders as inline
`<br>`, any other line break in the cell's content (block children,
multi-line text) folds into `<br>`, and `|` is escaped as `\\|`, also inside
code spans. Outside a table, `br` is still a newline.
"""
@testitem "markdown - table cells stay on one row" setup=[HTMXTestHelpers] tags=[:unit, :markdown] begin
    @test to_md(h.table(h.tr(h.th("Source | files")),
        h.tr(h.td(h.strong("Alpha | registry"), h.br(), h.small("a.csv"))))) ==
        "| Source \\| files |\n| --- |\n| **Alpha \\| registry**<br>a.csv |\n\n"
    @test to_md(h.table(h.tr(h.td(h.code("p|q")), h.td("a", h.br(), h.br(), "b")))) ==
        "| `p\\|q` | a<br><br>b |\n| --- | --- |\n\n"
    @test to_md(h.table(h.tr(h.td(h.p("one"), h.p("two")), h.td("multi\nline"),
        h.td(h.ul(h.li("i"), h.li("j")))))) ==
        "| one<br>two | multi<br>line | - i<br>- j |\n| --- | --- | --- |\n\n"
    @test to_md(h.p("a", h.br(), "b")) == "a\nb\n\n"
end

"""
A table as a figure's first child still parses as a table: a blank line
follows the opening fence, since a pipe table cannot interrupt the paragraph
that a fence line becomes where it is not a div opener (GFM).
"""
@testitem "markdown - figure keeps a leading table a block" setup=[HTMXTestHelpers] tags=[:unit, :markdown, :semantic] begin
    @test to_md(h.figure(h.table(h.tr(h.th("a")), h.tr(h.td("1"))))) ==
        "\n\n::: {}\n\n| a |\n| --- |\n| 1 |\n\n:::\n\n"
    @test to_md(h.figure(id="fig-t")(h.table(h.tr(h.th("a"))), h.figcaption("Cap"))) ==
        "\n\n::: {#fig-t}\n\n| a |\n| --- |\n\n\nCap\n:::\n\n"
end

"""
An id-less figure still opens a Pandoc div: Pandoc opens one only on a fence
with attributes (a bare `:::` always closes), so the opener is `::: {}`. Its
caption therefore stays inside the div, and an id-less figure around
identified child figures nests instead of closing at the first child's fence.
"""
@testitem "markdown - id-less figure opens a div" setup=[HTMXTestHelpers] tags=[:unit, :markdown, :semantic] begin
    @test to_md(h.figure(h.table(h.tr(h.th("a")), h.tr(h.td("1"))), h.figcaption("Cap"))) ==
        "\n\n::: {}\n\n| a |\n| --- |\n| 1 |\n\n\nCap\n:::\n\n"
    composite = h.figure(
        h.figure(id="fig-a")(h.img(src="/a.png", alt="A"), h.figcaption("A")),
        h.figure(id="fig-b")(h.img(src="/b.png", alt="B"), h.figcaption("B")),
        h.figcaption("Both"))
    @test to_md(composite) ==
        "\n\n::: {}\n\n\n\n::: {#fig-a}\n\n![](/a.png){alt=\"A\"}\n\nA\n:::\n\n\n\n\n" *
        "::: {#fig-b}\n\n![](/b.png){alt=\"B\"}\n\nB\n:::\n\n\nBoth\n:::\n\n"
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
        "\n\n::: {#fig-main}\n\n![](/a.png){alt=\"A\"}\n\nCaption\n:::\n\n"

    details = h.details(h.summary("Toggle"), h.p("Visible ", h.strong("content")))
    @test to_md(details) == "Visible **content**\n\n"
    @test !occursin("Toggle", to_md(details))

    blockquote = h.blockquote(h.p("A ", h.strong("B")), h.p("C"))
    @test to_md(blockquote) == "> A **B**\n> \n> C\n\n"
end

"""
Markdown math keeps its inline or block context in paragraphs, formatting,
headings, links, tables, list items, and blockquotes. A standalone LaTeX AST
retains its display behavior.
"""
@testitem "md_to_node - inline and display math" setup=[HTMXTestHelpers] tags=[:unit, :markdown, :parser, :math] begin
    import Markdown

    source = "Inline \$x_i\$ stays inside prose.\n\n```math\nx_i=1\n```"
    expected = raw"<div><p>Inline \(x_i\) stays inside prose.</p>$$x_i=1$$</div>"
    @test html(md_to_node(source)) == expected
    @test html(md_to_node(Markdown.parse(source))) == expected
    @test html(md_to_node(raw"Inline ``x_i`` stays inside prose.")) ==
        raw"<div><p>Inline \(x_i\) stays inside prose.</p></div>"
    @test html(md_to_node(raw"*Inline $x_i$.*")) ==
        raw"<div><p><em>Inline \(x_i\).</em></p></div>"
    @test html(md_to_node(raw"**Inline $x_i$.**")) ==
        raw"<div><p><strong>Inline \(x_i\).</strong></p></div>"
    @test html(md_to_node(raw"**Outer *$x_i$* text**")) ==
        raw"<div><p><strong>Outer <em>\(x_i\)</em> text</strong></p></div>"
    @test html(md_to_node(raw"[$x_i$](https://example.com)")) ==
        "<div><p><a href=\"https://example.com\">\\(x_i\\)</a></p></div>"
    for level in 1:6
        @test html(md_to_node(repeat("#", level) * raw" Header $x_i$")) ==
            "<div><h$level>Header \\(x_i\\)</h$level></div>"
    end
    table = html(md_to_node("| \$a\$ | B |\n|---|---|\n| *\$x_i\$* | c |"))
    @test occursin(raw">\(a\)</th>", table)
    @test occursin(raw"><em>\(x_i\)</em></td>", table)
    @test !occursin(raw"$$", table)
    @test html(md_to_node(raw"- Inline $x_i$")) ==
        raw"<div><ul><li><p>Inline \(x_i\)</p></li></ul></div>"
    @test html(md_to_node(raw"- [ ] Inline $x_i$")) ==
        "<div><ul><li><input type=\"checkbox\" disabled=\"true\"> Inline \\(x_i\\)</li></ul></div>"
    @test html(md_to_node(raw"> Inline $x_i$")) ==
        raw"<div><blockquote><p>Inline \(x_i\)</p></blockquote></div>"
    @test html(md_to_node("> ```math\n> x_i=1\n> ```")) ==
        raw"<div><blockquote>$$x_i=1$$</blockquote></div>"
    @test html(md_to_node("- ```math\n  x_i=1\n  ```")) ==
        raw"<div><ul><li>$$x_i=1$$</li></ul></div>"
    @test md_to_node(Markdown.LaTeX("x_i=1")) == raw"$$x_i=1$$"
end

"""
Inline and display formulas use ordinary text children, preserving exactly-once
HTML escaping for ampersands, quotes, apostrophes, and angle brackets.
"""
@testitem "md_to_node - math escaping" setup=[HTMXTestHelpers] tags=[:unit, :markdown, :parser, :math, :escaping] begin
    payload = "<x attr=\"v\"> & 'quoted'"
    escaped = "&lt;x attr=&quot;v&quot;&gt; &amp; &#39;quoted&#39;"
    @test html(md_to_node("Inline \$$payload\$ prose.")) ==
        "<div><p>Inline \\($escaped\\) prose.</p></div>"
    @test html(md_to_node("```math\n$payload\n```")) ==
        "<div>\$\$$escaped\$\$</div>"
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
An inline-only `header` renders as a level-3 heading and `title` as a level-1
heading, both keeping inline formatting.
"""
@testitem "markdown - header and title" setup=[HTMXTestHelpers] tags=[:unit, :markdown] begin
    @test to_md(h.header("Section")) == "### Section\n"
    @test to_md(h.header(h.strong("Power"))) == "### **Power**\n"
    @test to_md(h.title("Page ", h.code("Title"))) == "# Page `Title`\n"
end

"""
A `header` holding its own blocks renders them unprefixed, each on its own
line: a page header with a nav link and an `h1` projects as a paragraph and a
real level-1 heading, not one `### ` line containing a literal `#`.
"""
@testitem "markdown - header with blocks renders them unprefixed" setup=[HTMXTestHelpers] tags=[:unit, :markdown] begin
    page = h.main(
        h.header(h.nav(class="sqkm-nav")(h.a(href="/")("Landesübersicht Schleswig-Holstein")),
                 h.h1("Einrichtung Kita-01")),
        h.section(h.h2("Beschwerden"), h.p("Text")),
    )
    @test to_md(page) ==
        "[Landesübersicht Schleswig-Holstein](/)\n\n# Einrichtung Kita-01\n" *
        "\n---\n\n## Beschwerden\nText\n\n\n"
    @test to_md(h.header(h.h2("Recording done"))) == "## Recording done\n"
    @test to_md(h.header(h.small("kind"), h.h2("label"), h.code("id"))) ==
        "kind\n\n## label\n`id`\n"
    @test to_md(h.header(h.p(h.strong("Configure")), h.button("x"))) ==
        "**Configure**\n\n"
end

"""
A block element inside a transparent container starts on its own line: inline
text before it is closed as a paragraph, so headings, rules, fences and quotes
are never glued onto the preceding text (and text before a rule never becomes a
setext heading). A block directly after a list marker or inline opener stays
where it was.
"""
@testitem "markdown - blocks start on their own line" setup=[HTMXTestHelpers] tags=[:unit, :markdown] begin
    @test to_md(h.div(h.div(h.a(href="/")("x")), h.h1("y"))) == "[x](/)\n\n# y\n"
    @test to_md(h.div("lead", h.h2("y"), "tail", h.ul(h.li("a")))) ==
        "lead\n\n## y\ntail\n\n- a\n"
    @test to_md(h.div("text", h.hr(), "after")) == "text\n\n---\nafter"
    @test to_md(h.div("intro", h.section(h.p("x")))) == "intro\n\n---\n\nx\n\n\n"
    @test to_md(h.div("see", h.pre(h.code("x=1")))) == "see\n\n```\nx=1\n```\n"
    @test to_md(h.blockquote("a", h.h1("b"))) == "> a\n> \n> # b\n\n"
    @test to_md(h.ul(h.li(h.p("a")), h.li(h.p("b")))) == "- a\n\n\n- b\n\n\n"
    @test to_md(h.div("see", h.figure(h.img(src="/a.png", alt="A")))) ==
        "see\n\n::: {}\n\n![](/a.png){alt=\"A\"}\n:::\n\n"
end

"""
Content after a list item starts after a blank line, so it is not read as lazy
continuation of the last item; consecutive items stay a tight list.
"""
@testitem "markdown - content after a list item starts a new block" setup=[HTMXTestHelpers] tags=[:unit, :markdown] begin
    @test to_md(h.div(h.ul(h.li("a"), h.li("b")), "tail")) == "- a\n- b\n\ntail"
    @test to_md(h.div(h.ul(h.li("a")), h.p("p"))) == "- a\n\np\n\n"
    @test to_md(h.div(h.ul(h.li("a")), h.h2("b"))) == "- a\n\n## b\n"
    # whitespace-only text between items keeps them one list
    @test to_md(h.ul(h.li("a"), " ", h.li("b"))) == "- a\n - b\n"
end

"""
A block container (`div`, `nav`, `dl`, `details`, ...) is a paragraph boundary,
as in HTML: inline text before it is closed as a paragraph and content after it
starts a new one, so sibling divs no longer run together. It adds no trailing
blank line of its own, so a lone or nested container renders as before.
"""
@testitem "markdown - block containers are paragraph boundaries" setup=[HTMXTestHelpers] tags=[:unit, :markdown] begin
    @test to_md(h.div(h.div("one"), h.div("two"))) == "one\n\ntwo"
    @test to_md(h.div("lead", h.div("x"), "tail")) == "lead\n\nx\n\ntail"
    @test to_md(h.div(h.div(h.div("x")), h.nav("y"))) == "x\n\ny"
    @test to_md(h.div("x")) == "x"
    @test to_md(h.div("a", h.div(), "b")) == "a\n\nb"
    @test to_md(h.dl(h.dt("Term"), h.dd("Def"))) == "Term\n\nDef"
    @test to_md(h.div("x", h.details(h.summary("s"), "content"), "y")) == "x\n\ncontent\n\ny"
    @test to_md([h.div("a"), h.div("b")]) == "a\n\nb"
    @test to_md(h.div(h.span("a"), h.span("b"))) == "ab"
    # a table cell folds the boundary into `<br>`
    @test to_md(h.table(h.tr(h.td(h.div("a"), h.div("b")), h.td("x", h.p("y"))))) ==
        "| a<br>b | x<br>y |\n| --- | --- |\n\n"
    # list items stay one tight list; an inline-only header keeps its label
    @test to_md(h.ul(h.li(h.div("a")), h.li(h.div("b")))) == "- a\n- b\n"
    @test to_md(h.header(h.div("Title"))) == "### Title\n"
    @test to_md(h.header(h.div("T"), h.div("sub"))) == "T\n\nsub\n"
end

"""
Content that must stay one paragraph keeps its block containers transparent:
the text of a link or other inline element, a heading line, and a figure
caption, which Quarto reads as the figure div's last paragraph.
"""
@testitem "markdown - containers stay inline in links, headings and captions" setup=[HTMXTestHelpers] tags=[:unit, :markdown, :semantic] begin
    @test to_md(h.div(h.a(href="/")(h.div("card"), h.div("sub")), "after")) == "[cardsub](/)after"
    @test to_md(h.strong(h.div("a"), h.div("b"))) == "**ab**"
    @test to_md(h.h2(h.div("a"), h.div("b"))) == "## ab\n"
    caption = h.figcaption(h.div(class="caption-header")(h.span(h.strong("Title"), " — short")), " — long")
    @test to_md(h.figure(id="fig-a")(h.img(src="/a.png", alt="A"), caption)) ==
        "\n\n::: {#fig-a}\n\n![](/a.png){alt=\"A\"}\n\n**Title** — short — long\n:::\n\n"
    # a caption rendered on its own (placed in a custom layout) stays one paragraph too
    @test to_md(caption) == "**Title** — short — long"
    @test to_md(h.div("before", caption, "after")) == "before\n\n**Title** — short — long\n\nafter"
end

"""
An `<a>` without `href`, such as an htmx-only `h.a("x"; hx_get=…)`, is no
hyperlink: HTML has it represent its contents. Its Markdown is that content,
written like a `span` (block children stay blocks, a linked id is still
anchored), never the empty link `[x]()` that Pandoc's Typst writer turns into
`#link("")`, which Typst refuses. An explicit `href=""` links to the current
document and stays a link.
"""
@testitem "markdown - an a without href renders its content" setup=[HTMXTestHelpers] tags=[:unit, :markdown] begin
    @test to_md(h.p("Länder: ", h.a("Bayern"; hx_get="/region/09", hx_target="#x"), " · ",
                    h.a("Berlin"; href="/region/11"))) == "Länder: Bayern · [Berlin](/region/11)\n\n"
    @test to_md(h.a("x"; href=nothing)) == "x"
    @test to_md(h.a("x"; href=false)) == "x"
    @test to_md(h.a(hx_get="/")) == ""
    @test to_md(h.a("z"; href="")) == "[z]()"
    @test to_md(h.a(h.strong("b"); hx_get="/")) == "**b**"
    @test to_md(h.div(h.a(h.div("card"), h.div("sub"); hx_get="/c"), "after")) == "card\n\nsub\n\nafter"
    @test to_md(h.h2(h.a("T"; hx_get="/"))) == "## T\n"
    @test to_md(h.header(h.a("Home"; hx_get="/"))) == "### Home\n"
    @test to_md(h.ul(h.li(h.a("one"; hx_get="/1")), h.li(h.a("two"; hx_get="/2")))) == "- one\n- two\n"
    @test to_md(h.table(h.tr(h.th("a")), h.tr(h.td(h.a("x"; hx_get="/"))))) == "| a |\n| --- |\n| x |\n\n"
    @test to_md(h.p(h.a(lang="en")("word"))) == "[word]{lang=\"en\"}\n\n"
    @test to_md(h.div(h.a("go"; href="#t"), h.p(h.a(id="t")("target")))) == "[go](#t)\n\n[]{#t}target\n\n"
end

"""
A non-`Node` child is spliced into the running line unless its type declares
`HTMX.markdown_block`, which delimits it like a `div` among a node's children
or a vector's elements; inside a link it stays inline.
"""
@testitem "markdown - markdown_block delimits non-Node children" setup=[HTMXTestHelpers] tags=[:unit, :markdown] begin
    struct InlineThing end
    struct BlockThing end
    Base.show(io::IO, ::MIME"text/markdown", ::InlineThing) = print(io, "[i]")
    Base.show(io::IO, ::MIME"text/markdown", ::BlockThing) = print(io, "**A:** 1")
    HTMX.markdown_block(::BlockThing) = true

    @test !HTMX.markdown_block(InlineThing())
    @test to_md(h.div(InlineThing(), InlineThing())) == "[i][i]"
    @test to_md(h.div(BlockThing(), BlockThing())) == "**A:** 1\n\n**A:** 1"
    @test to_md(h.div("lead", BlockThing(), "tail")) == "lead\n\n**A:** 1\n\ntail"
    @test to_md([BlockThing(), BlockThing()]) == "**A:** 1\n\n**A:** 1"
    @test to_md(h.a(href="/")(BlockThing(), "x")) == "[**A:** 1x](/)"
end

"""
An image is inline, as in HTML, and its alt text is a Pandoc attribute rather
than the image description: a described image alone in its paragraph is a
Pandoc implicit figure, whose caption Quarto takes from the description while
the image loses its alt text (a PDF/UA-1 build then fails). A figure still
gives its image its own paragraph, ahead of the caption.
"""
@testitem "markdown - img keeps its alt text as an attribute" setup=[HTMXTestHelpers] tags=[:unit, :markdown] begin
    img = h.img(src="/a.png", alt="A")
    @test to_md(h.div(img)) == "![](/a.png){alt=\"A\"}"
    @test to_md(h.p("See ", img, " here.")) == "See ![](/a.png){alt=\"A\"} here.\n\n"
    @test to_md(h.h2(h.img(src="/i.png", alt="Icon"), " Title")) == "## ![](/i.png){alt=\"Icon\"} Title\n"
    @test to_md(h.a(href="/")(img)) == "[![](/a.png){alt=\"A\"}](/)"
    @test to_md(h.table(h.tr(h.th("x")), h.tr(h.td(img)))) ==
        "| x |\n| --- |\n| ![](/a.png){alt=\"A\"} |\n\n"
    # no alt attribute, an empty (decorative) alt, and a value needing escapes
    @test to_md(h.img(src="/a.png")) == "![](/a.png)"
    @test to_md(h.img(src="/a.png", alt="")) == "![](/a.png){alt=\"\"}"
    @test to_md(h.img(src="/a.png", alt="say \"hi\" \\ ok\nnext")) ==
        "![](/a.png){alt=\"say \\\"hi\\\" \\\\ ok next\"}"
    @test to_md(h.img(alt="no source")) == ""
    # in a figure every child is its own paragraph and the caption comes last
    @test to_md(h.figure(id="fig-r")(h.figcaption("Radon"), img)) ==
        "\n\n::: {#fig-r}\n\n![](/a.png){alt=\"A\"}\n\nRadon\n:::\n\n"
    @test to_md(h.figure(img, h.img(src="/b.png", alt="B"))) ==
        "\n\n::: {}\n\n![](/a.png){alt=\"A\"}\n\n![](/b.png){alt=\"B\"}\n:::\n\n"
    @test to_md(h.figure("text", h.figcaption("Cap"))) == "\n\n::: {}\n\ntext\n\nCap\n:::\n\n"
    @test to_md(h.figure("text")) == "\n\n::: {}\n\ntext\n:::\n\n"
end

"""
An `<ol>` numbers its items from its `start`, as the HTML shows them. A list
directly after another list starts after a blank line, and one of the same kind
also after a `<!-- -->` line, so adjacent lists stay apart in CommonMark and
Pandoc readers (a change of bullet character does not split a Pandoc list).
"""
@testitem "markdown - ordered lists are numbered and adjacent lists stay apart" setup=[HTMXTestHelpers] tags=[:unit, :markdown] begin
    import Markdown
    @test to_md(h.ol(h.li("one"), h.li("two"))) == "1. one\n2. two\n"
    @test to_md(h.ol(start=3)(h.li("c"), h.li("d"))) == "3. c\n4. d\n"
    @test to_md(h.ol(start="7")(h.li("g"))) == "7. g\n"
    @test to_md(h.ol(h.li(h.p("a")), h.li(h.p("b")))) == "1. a\n\n\n2. b\n\n\n"
    # refused: CommonMark list numbers are 0-999999999, so these starts have no Markdown form
    @test_throws ArgumentError to_md(h.ol(start="x")(h.li("a")))
    @test_throws ArgumentError to_md(h.ol(start=-1)(h.li("a")))

    @test to_md(h.div(h.ul(h.li("a")), h.ol(h.li("b")))) == "- a\n\n1. b\n"
    @test to_md(h.div(h.ol(h.li("a")), h.ul(h.li("b")))) == "1. a\n\n- b\n"
    @test to_md(h.div(h.ul(h.li("a")), h.ul(h.li("b")))) == "- a\n\n<!-- -->\n\n- b\n"
    @test to_md(h.div(h.ol(h.li("a")), h.ol(h.li("b")))) == "1. a\n\n<!-- -->\n\n1. b\n"
    @test to_md(h.div(h.div(h.ul(h.li("a"))), h.div(h.ul(h.li("b"))))) == "- a\n\n<!-- -->\n\n- b\n"
    # lists separated by content, or by an empty list, need no separator
    @test to_md(h.div(h.ul(h.li("a")), h.p("x"), h.ul(h.li("b")))) == "- a\n\nx\n\n- b\n"
    @test to_md(h.div(h.p("x"), h.ul(), h.ul(h.li("b")))) == "x\n\n- b\n"
    # a nested list keeps the outer numbering going
    @test to_md(h.ol(h.li("a", h.ul(h.li("x"))), h.li("b"))) == "1. a\n\n- x\n\n2. b\n"
    @test to_md(h.table(h.tr(h.th("x")), h.tr(h.td(h.ol(h.li("a"), h.li("b")))))) ==
        "| x |\n| --- |\n| 1. a<br>2. b |\n\n"

    lists(s) = [(x.ordered, length(x.items)) for x in Markdown.parse(s).content if x isa Markdown.List]
    @test lists(to_md(h.ol(start=3)(h.li("c"), h.li("d")))) == [(3, 2)]
    @test lists(to_md(h.div(h.ul(h.li("a")), h.ol(h.li("b"))))) == [(-1, 1), (1, 1)]
    @test lists(to_md(h.div(h.ul(h.li("a")), h.ul(h.li("b"))))) == [(-1, 1), (-1, 1)]
end

"""
An element whose `lang` differs from the enclosing language is written in a
Pandoc language scope, which Quarto carries into its output: a block as a
`::: {lang="…"}` fenced div, inline content (and a block inside a list item,
table cell, heading or caption, where a fence would break the line) as a
`[…]{lang="…"}` span. `<html lang>` is the document language and writes
nothing; a `<pre>` body stays verbatim.
"""
@testitem "markdown - lang becomes a Pandoc language scope" setup=[HTMXTestHelpers] tags=[:unit, :markdown] begin
    @test to_md(h.div(h.p("Deutsch."), h.div(lang="en")(h.p("English.")))) ==
        "Deutsch.\n\n::: {lang=\"en\"}\n\nEnglish.\n\n:::\n\n"
    @test to_md(h.div(lang="en")("plain")) == "::: {lang=\"en\"}\n\nplain\n\n:::\n\n"
    @test to_md(h.p("Das ", h.span(lang="en")("word"), " hier.")) == "Das [word]{lang=\"en\"} hier.\n\n"
    @test to_md(h.h2(lang="en")("Title")) == "::: {lang=\"en\"}\n\n## Title\n:::\n\n"
    @test to_md(h.h2("Titel ", h.span(lang="en")("word"))) == "## Titel [word]{lang=\"en\"}\n"
    @test to_md(h.p(h.a(href="/x", lang="en")("link"))) == "[[link](/x)]{lang=\"en\"}\n\n"
    # only a change of language is written; html's lang is the document's
    @test to_md(h.html(lang="de")(h.body(h.p("Hallo"), h.div(lang="en")(h.p("Hi")), h.div(lang="DE")(h.p("Wieder"))))) ==
        "Hallo\n\n::: {lang=\"en\"}\n\nHi\n\n:::\n\nWieder\n\n"
    @test to_md(h.div(lang="en")(h.p("a"), h.p(lang="en")("b"))) == "::: {lang=\"en\"}\n\na\n\nb\n\n:::\n\n"
    # a list item, a cell, a row and a caption stay on their line
    @test to_md(h.ul(h.li("a"), h.li(lang="en")("b"), h.li(h.div(lang="en")("c")))) ==
        "- a\n- [b]{lang=\"en\"}\n- [c]{lang=\"en\"}\n"
    table = h.table(h.tr(h.th("Begriff"), h.th(lang="en")("Term")), h.tr(lang="en")(h.td("dog"), h.td(lang="de")("Hund")))
    @test to_md(h.html(lang="de")(table)) ==
        "| Begriff | [Term]{lang=\"en\"} |\n| --- | --- |\n| [dog]{lang=\"en\"} | Hund |\n\n"
    @test to_md(h.figure(id="fig-e")(h.img(src="/a.png", alt="A"), h.figcaption(lang="en")("Cap"))) ==
        "\n\n::: {#fig-e}\n\n![](/a.png){alt=\"A\"}\n\n[Cap]{lang=\"en\"}\n:::\n\n"
    # nothing to tag: an empty lang, an empty span, a <pre> body
    @test to_md(h.p(lang="")("x")) == "x\n\n"
    @test to_md(h.p("a", h.span(lang="en"), "b")) == "ab\n\n"
    @test to_md(h.pre(h.code(h.span(lang="en")("x = 1")))) == "```\nx = 1\n```\n"
end

"""
An element's `id` is written only when an in-page link of the same document
points at it, so Markdown without in-page links, and every id that only names
an hx-swap target, stays as it was. The link can come before or after its
target, from an `<a href>` anywhere in the rendered value, from a string, or
from the Markdown of a non-`Node` child. A `<pre>` body writes no ids.
"""
@testitem "markdown - only ids that in-page links point at are written" setup=[HTMXTestHelpers] tags=[:unit, :markdown] begin
    struct LinkThing end
    Base.show(io::IO, ::MIME"text/markdown", ::LinkThing) = print(io, "[go](#t)")
    target = h.div(id="t")(h.p("x"))
    written = "::: {#t}\n\nx\n\n:::\n\n"
    go = h.a("go"; href="#t")

    @test to_md(target) == "x\n\n"
    @test to_md(h.div(h.table(h.tr(h.th("k")), h.tr(id="row-1")(h.td("a"))), h.div(id="detail-slot-1")("b"))) ==
        "| k |\n| --- |\n| a |\n\nb"
    @test to_md(h.div(h.p(go), target)) == "[go](#t)\n\n" * written
    @test to_md(h.div(target, h.p(go))) == written * "[go](#t)\n\n"
    @test to_md([h.p(go), target]) == "[go](#t)\n\n" * written
    @test to_md(h.div("see [go](#t)", target)) == "see [go](#t)\n\n" * written
    @test to_md(h.div(LinkThing(), target)) == "[go](#t)\n\n" * written
    # only the ids that are linked; other pages' fragments and `#` are not in-page links
    @test to_md(h.div(go, h.p(id="u")("y"))) == "[go](#t)\n\ny\n\n"
    @test to_md(h.div(h.a("x"; href="/p#t"), h.a("y"; href="#"), target)) == "[x](/p#t)[y](#)\n\nx\n\n"
    @test to_md(h.div(go, h.pre(h.code(h.span(id="t")("x = 1"))))) == "[go](#t)\n\n```\nx = 1\n```\n"
end

"""
A linked id is written where Pandoc keeps it as a label for Quarto's Typst
output, which stops on a link to a missing label. A block element is a fenced
div `::: {#id}`, carrying its language in the same attribute block. A heading
writes `{#id}` on its line. Anything else (inline content, an image, a list
item, a caption, an element with no Markdown of its own, and a block where a
fence would break the line) gets an empty anchor span `[]{#id}` in front of it:
Pandoc's Typst writer drops an image's own id, and Typst keeps one label per
position, so two anchors in a row are kept apart by a zero-width space. An id
the `#` shorthand cannot spell is written `id="…"`.
"""
@testitem "markdown - a linked id is written as a Pandoc identifier" setup=[HTMXTestHelpers] tags=[:unit, :markdown] begin
    go = h.a("go"; href="#t")
    linked(x) = to_md(h.div(go, x))

    @test linked(h.p(id="t")("x")) == "[go](#t)\n\n::: {#t}\n\nx\n\n:::\n\n"
    @test linked(h.div(id="t", lang="en")(h.p("x"))) == "[go](#t)\n\n::: {#t lang=\"en\"}\n\nx\n\n:::\n\n"
    @test linked(h.pre(id="t")(h.code("x = 1"))) == "[go](#t)\n\n::: {#t}\n\n```\nx = 1\n```\n:::\n\n"
    @test linked(h.blockquote(h.p(id="t")("x"))) == "[go](#t)\n\n> ::: {#t}\n> \n> x\n> \n> :::\n\n"
    # a header holding a linked block still renders its blocks unprefixed
    @test linked(h.header(h.span("Label"), h.div(id="t")("x"))) == "[go](#t)\n\nLabel\n\n::: {#t}\n\nx\n\n:::\n\n"

    @test linked(h.h2(id="t")("Title")) == "[go](#t)\n\n## Title {#t}\n"
    @test linked(h.h2(id="t", lang="en")("Title")) == "[go](#t)\n\n::: {lang=\"en\"}\n\n## Title {#t}\n:::\n\n"
    @test linked(h.ul(h.li(h.h2(id="t")("Title")))) == "[go](#t)\n\n- ## Title {#t}\n\n"
    @test linked(h.ul(h.li(h.h2(id="t", lang="en")("Title")))) == "[go](#t)\n\n- []{#t}[## Title]{lang=\"en\"}\n"
    @test to_md(h.div(h.a("a"; href="#a/b"), h.h2(id="a/b")("Drei"))) == "[a](#a/b)\n\n## Drei {id=\"a/b\"}\n"
    @test to_md(h.div(h.a("a"; href="#ü-1.x:y"), h.h2(id="ü-1.x:y")("Ü"))) == "[a](#ü-1.x:y)\n\n## Ü {#ü-1.x:y}\n"

    @test to_md(h.p(go, " Text ", h.span(id="t")("Wort"), " mehr")) == "[go](#t) Text []{#t}Wort mehr\n\n"
    @test to_md(h.p(go, " ", h.span(id="t", lang="en")("word"))) == "[go](#t) []{#t}[word]{lang=\"en\"}\n\n"
    @test to_md(h.p(go, " ", h.img(id="t", src="/a.png", alt="A"))) == "[go](#t) []{#t}![](/a.png){alt=\"A\"}\n\n"
    @test to_md(h.p(go, h.span(id="t")())) == "[go](#t)[]{#t}\n\n"
    @test to_md(h.p(go, h.a("u"; href="#u"), h.span(id="t")(h.span(id="u")("x")))) ==
        "[go](#t)[u](#u)[]{#t}\u200b[]{#u}x\n\n"
    @test linked(h.hr(id="t")) == "[go](#t)[]{#t}\n\n---\n"
    @test linked(h.ul(h.li(id="t")("item"))) == "[go](#t)\n\n- []{#t}item\n"
    @test linked(h.ul(h.li(id="t", lang="en")("item"))) == "[go](#t)\n\n- []{#t}[item]{lang=\"en\"}\n"
    @test linked(h.ul(h.li(h.div(id="t")(h.p("a"))))) == "[go](#t)\n\n- []{#t}a\n\n\n"
    @test linked(h.figure(id="fig-r")(h.img(src="/a.png", alt="A"), h.figcaption(id="t")("Radon"))) ==
        "[go](#t)\n\n::: {#fig-r}\n\n![](/a.png){alt=\"A\"}\n\n[]{#t}Radon\n:::\n\n"
end

"""
A section's (or article's) id goes on the heading that opens it,
`## Eins {#id}`, which is Pandoc's own model of a section; Pandoc writes it back
as `<section id>`. A section that does not open with a heading, or whose heading
writes a linked id of its own, is a fenced div instead.
"""
@testitem "markdown - a linked section id goes on its opening heading" setup=[HTMXTestHelpers] tags=[:unit, :markdown] begin
    go = h.a("go"; href="#t")
    linked(x) = to_md(h.div(go, x))
    @test to_md(h.article(h.section(id="t")(h.h2("Eins"), h.p("Text")), h.p(h.a("zu Eins"; href="#t")))) ==
        "\n---\n\n\n---\n\n## Eins {#t}\nText\n\n\n[zu Eins](#t)\n\n\n"
    @test linked(h.article(id="t")(h.h1("Eins"))) == "[go](#t)\n\n---\n\n# Eins {#t}\n\n"
    # the heading's own id, when nothing links to it, gives way
    @test linked(h.section(id="t")(h.h2(id="h")("Eins"))) == "[go](#t)\n\n---\n\n## Eins {#t}\n\n"
    @test linked(h.section(id="t", lang="en")(h.h2("One"))) ==
        "[go](#t)\n\n::: {lang=\"en\"}\n\n\n---\n\n## One {#t}\n\n:::\n\n"
    @test linked(h.section(id="t")(h.p("Text"), h.h2("Später"))) ==
        "[go](#t)\n\n::: {#t}\n\n\n---\n\nText\n\n## Später\n\n:::\n\n"
    @test to_md(h.div(go, h.a("h"; href="#h"), h.section(id="t")(h.h2(id="h")("Eins")))) ==
        "[go](#t)[h](#h)\n\n::: {#t}\n\n\n---\n\n## Eins {#h}\n\n:::\n\n"
end

"""
In a pipe table a linked id is an anchor at the start of a cell: a cell's own,
and a row's or table section's at its first cell. An id that no cell follows is
an anchor after the table. A linked table is a fenced div, which Quarto numbers
as a table when its id starts with `tbl-`.
"""
@testitem "markdown - linked ids in tables" setup=[HTMXTestHelpers] tags=[:unit, :markdown, :tables] begin
    go = h.a("go"; href="#t")
    linked(x) = to_md(h.div(go, x))
    @test linked(h.table(h.tr(h.th("a")), h.tr(h.td(id="t")("x")))) == "[go](#t)\n\n| a |\n| --- |\n| []{#t}x |\n\n"
    @test linked(h.table(h.tr(h.th("a"), h.th("b")), h.tr(id="t")(h.td("x"), h.td("y")))) ==
        "[go](#t)\n\n| a | b |\n| --- | --- |\n| []{#t}x | y |\n\n"
    @test linked(h.table(h.thead(h.tr(h.th("a"))), h.tbody(id="t")(h.tr(h.td("x"))))) ==
        "[go](#t)\n\n| a |\n| --- |\n| []{#t}x |\n\n"
    @test to_md(h.div(go, h.a("u"; href="#u"), h.table(h.tr(h.th("a")), h.tr(id="t")(h.td(id="u")("x"))))) ==
        "[go](#t)[u](#u)\n\n| a |\n| --- |\n| []{#t}\u200b[]{#u}x |\n\n"
    @test linked(h.table(h.tr(h.th("a")), h.tr(h.td(id="t", lang="en")("x")))) ==
        "[go](#t)\n\n| a |\n| --- |\n| []{#t}[x]{lang=\"en\"} |\n\n"
    @test to_md(h.div(h.a("p"; href="#a|b"), h.table(h.tr(h.th("a")), h.tr(h.td(id="a|b")("x"))))) ==
        "[p](#a|b)\n\n| a |\n| --- |\n| []{id=\"a\\|b\"}x |\n\n"
    @test linked(h.table(h.tr(h.th("a")), h.tfoot(id="t"))) == "[go](#t)\n\n| a |\n| --- |\n\n[]{#t}"
    @test to_md(h.div(h.a("t"; href="#tbl-x"), h.table(id="tbl-x")(h.tr(h.th("a")), h.tr(h.td("x"))))) ==
        "[t](#tbl-x)\n\n::: {#tbl-x}\n\n| a |\n| --- |\n| x |\n\n:::\n\n"
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

"""
HTML form inputs map to native Hyperview fields, including the required ISO
date label format, min/max bounds, keyboard hints, and secure passwords.
"""
@testitem "hxml - native form fields" setup=[HTMXTestHelpers] tags=[:unit, :hxml, :forms] begin
    @test hxml(h.input(type="date", name="due", value="2026-07-31")) ==
        "<date-field style=\"date-field\" name=\"due\" value=\"2026-07-31\" label-format=\"YYYY-MM-DD\" />"
    @test hxml(h.input(
        type="date",
        name="d",
        min="2026-01-01",
        max="2026-12-31",
    )) ==
        "<date-field style=\"date-field\" name=\"d\" label-format=\"YYYY-MM-DD\" min=\"2026-01-01\" max=\"2026-12-31\" />"
    @test hxml(h.input(type="email", name="e")) ==
        "<text-field style=\"text-field\" name=\"e\" keyboard-type=\"email-address\" />"
    @test hxml(h.input(type="number", name="n")) ==
        "<text-field style=\"text-field\" name=\"n\" keyboard-type=\"decimal-pad\" />"
    @test hxml(h.input(type="tel", name="p")) ==
        "<text-field style=\"text-field\" name=\"p\" keyboard-type=\"phone-pad\" />"
    @test hxml(h.input(type="url", name="u")) ==
        "<text-field style=\"text-field\" name=\"u\" keyboard-type=\"url\" />"
    @test hxml(h.input(type="password", name="pw")) ==
        "<text-field style=\"text-field\" name=\"pw\" secure-text=\"true\" />"
    @test hxml(h.input(type="text", name="q")) ==
        "<text-field style=\"text-field\" name=\"q\" />"
    @test hxml(h.input(type="checkbox", name="ok")) ==
        "<switch style=\"switch\" name=\"ok\" />"
    @test well_formed_xml(hxml(h.input(type="date", name="due", value="2026-07-31")))
end

"""
A view groups only bare inline text. Children that emit their own Hyperview
`text` elements remain direct siblings so flex layouts can distribute them.
"""
@testitem "hxml - views preserve self-text inline siblings" setup=[HTMXTestHelpers] tags=[:unit, :hxml, :layout] begin
    @test hxml(h.div(class="kv")(
        h.span(class="kv-label")("k"),
        h.span(class="kv-value")("v"),
    )) ==
        "<view style=\"div kv\"><text style=\"span kv-label\">k</text><text style=\"span kv-value\">v</text></view>"
    @test hxml(h.div(h.span("T"))) ==
        "<view style=\"div\"><text style=\"span\">T</text></view>"
    @test hxml(h.div("hello")) ==
        "<view style=\"div\"><text>hello</text></view>"
    @test hxml(h.div(h.time("2pm"), h.time("3pm"))) ==
        "<view style=\"div\"><text>2pm3pm</text></view>"
    @test hxml(h.p("Hello ", h.strong("world"), "!")) ==
        "<text style=\"p\">Hello <text style=\"strong\">world</text>!</text>"
    @test well_formed_xml(hxml(h.div(class="kv")(
        h.span(class="kv-label")("k"),
        h.span(class="kv-value")("v"),
    )))
end

"""
A non-`Node` child of a view is placed by its own HXML output: a wrapper that
writes a node's HXML sits exactly where that node would, instead of inside an
anonymous `<text>` run; text-valued children (numbers, `Raw`, text-only
wrappers) still join the run, and a value that writes nothing leaves no trace.
"""
@testitem "hxml - foreign view children are placed by their output" setup=[HTMXTestHelpers] tags=[:unit, :hxml, :layout] begin
    struct Forward
        node::Node
    end
    Base.show(io::IO, m::MIME"application/vnd.hyperview+xml", w::Forward) = show(io, m, w.node)
    struct Silent end
    Base.show(::IO, ::MIME"application/vnd.hyperview+xml", ::Silent) = nothing
    struct Gap end
    Base.show(io::IO, ::MIME"application/vnd.hyperview+xml", ::Gap) = print(io, " ")
    row(id) = h.tr(h.td(id); id)

    @test hxml(h.tbody(row("a"), Forward(row("b")))) == hxml(h.tbody(row("a"), row("b"))) ==
        "<view style=\"tbody\"><view id=\"a\" style=\"tr\"><view style=\"td\"><text>a</text></view></view>" *
        "<view id=\"b\" style=\"tr\"><view style=\"td\"><text>b</text></view></view></view>"
    @test hxml(h.div(Forward(h.span("k")), h.span("v"))) == hxml(h.div(h.span("k"), h.span("v")))
    @test hxml(h.div("lead ", Forward(h.div("card")), " tail")) ==
        "<view style=\"div\"><text>lead </text><view style=\"div\"><text>card</text></view><text> tail</text></view>"
    # text-valued children keep joining the run
    @test hxml(h.div("n=", 3, " items")) == "<view style=\"div\"><text>n=3 items</text></view>"
    @test hxml(h.div("x", Raw("<b>y</b>"))) == "<view style=\"div\"><text>x&lt;b&gt;y&lt;/b&gt;</text></view>"
    @test hxml(h.div("a ", Forward(h.time("t")), " b")) == "<view style=\"div\"><text>a t b</text></view>"
    @test hxml(h.div("a", Gap(), "b")) == "<view style=\"div\"><text>a b</text></view>"
    # empty output writes nothing, not even an empty run
    @test hxml(h.div("a", Silent(), "b")) == "<view style=\"div\"><text>ab</text></view>"
    @test hxml(h.tr(h.td("x"), Silent())) == "<view style=\"tr\"><view style=\"td\"><text>x</text></view></view>"
    @test well_formed_xml(hxml(h.tbody(row("a"), Forward(row("b")))))
    @test well_formed_xml(hxml(h.div("lead ", Forward(h.div("card")), " tail")))
end
