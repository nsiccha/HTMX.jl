using TestModules
using HTMX

# Helper
html(node) = repr("text/html", node)

# ================================================================
# Basic node creation
# ================================================================

@testset "h - basic node creation" begin
    @test html(h.div()) == "<div></div>"
    @test html(h.p("hello")) == "<p>hello</p>"
    @test html(h.span("a", "b")) == "<span>ab</span>"
end

@testset "h - attributes" begin
    @test html(h.div(class="foo")) == "<div class=\"foo\"></div>"
    @test html(h.a(href="/page")) == "<a href=\"/page\"></a>"
    @test html(h.div(class="foo", id="bar")) == "<div class=\"foo\" id=\"bar\"></div>"
end

@testset "h - attributes and children combined" begin
    node = h.div(class="container")("child text")
    @test html(node) == "<div class=\"container\">child text</div>"
end

@testset "h - nested nodes" begin
    node = h.div(h.p("inner"))
    @test html(node) == "<div><p>inner</p></div>"
end

# ================================================================
# Call syntax
# ================================================================

@testset "Node - call syntax appends children" begin
    node = h.ul()
    node2 = node(h.li("one"), h.li("two"))
    @test html(node2) == "<ul><li>one</li><li>two</li></ul>"
    # original is unchanged (immutable wrapping)
    @test html(node) == "<ul></ul>"
end

@testset "Node - call syntax merges attributes" begin
    node = h.div(class="a")
    node2 = node(id="b")
    @test occursin("class=\"a\"", html(node2))
    @test occursin("id=\"b\"", html(node2))
end

# ================================================================
# Attribute handling
# ================================================================

@testset "Underscore-to-hyphen in attribute names" begin
    node = h.div(hx_get="/endpoint")
    @test occursin("hx-get=\"/endpoint\"", html(node))

    node2 = h.div(data_foo="bar")
    @test occursin("data-foo=\"bar\"", html(node2))
end

@testset "Boolean attributes" begin
    # true renders as bare attribute
    node = h.div(hx_swap_oob="true")
    rendered = html(node)
    @test occursin("hx-swap-oob", rendered)
    @test !occursin("hx-swap-oob=\"true\"", rendered)

    # false attribute is omitted entirely
    node2 = h.div(hidden="false")
    rendered2 = html(node2)
    @test !occursin("hidden", rendered2)
end

@testset "nothing attributes are omitted" begin
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

@testset "Bool attribute values" begin
    node = h.input(; checked=true)
    rendered = html(node)
    @test occursin("checked", rendered)
    @test !occursin("checked=\"true\"", rendered)

    node2 = h.input(; checked=false)
    rendered2 = html(node2)
    @test !occursin("checked", rendered2)
end

@testset "nothing/Bool attributes via call syntax" begin
    node = h.div(class="a")(; selected=nothing, hidden=true)
    rendered = html(node)
    @test occursin("class=\"a\"", rendered)
    @test !occursin("selected", rendered)
    @test occursin("hidden", rendered)
    @test !occursin("hidden=\"true\"", rendered)
end

# ================================================================
# Hyperscript
# ================================================================

@testset "HTMX.HyperscriptString" begin
    hs = HTMX.HyperscriptString("on click toggle .active")
    @test hs isa AbstractString
    @test String(hs) == "on click toggle .active"
    @test length(hs) == length("on click toggle .active")

    hs2 = HTMX.HyperscriptString("a") * HTMX.HyperscriptString("b")
    @test hs2 isa HTMX.HyperscriptString
    @test String(hs2) == "ab"
end

@testset "Hyperscript _ attribute via HyperscriptString children" begin
    hs = HTMX.HyperscriptString("on click log 'hi'")
    node = h.div(hs)
    rendered = html(node)
    @test occursin("_=", rendered)
    @test occursin("on click log 'hi'", rendered)
end

@testset "HyperscriptString children move to _ attribute" begin
    hs = HTMX.HyperscriptString("on click toggle .active")
    node = h.button(hs)
    rendered = html(node)
    @test occursin("_=", rendered)
    @test occursin("on click toggle .active", rendered)
    @test !occursin(">on click toggle .active<", rendered)
end

@testset "Multiple HyperscriptString children concatenate" begin
    hs1 = HTMX.HyperscriptString("on click log 'a'")
    hs2 = HTMX.HyperscriptString("on load log 'b'")
    node = h.div(hs1, hs2)
    rendered = html(node)
    @test occursin("on click log 'a'", rendered)
    @test occursin("on load log 'b'", rendered)
end

@testset "@__str macro" begin
    hs = @__str "hello world"
    @test hs isa HTMX.HyperscriptString
    @test String(hs) == "hello world"
end

# ================================================================
# auto function
# ================================================================

@testset "auto - basic conversions" begin
    @test auto("hello"; wrap=identity) == "hello"
    @test auto(["a", "b"]; wrap=identity) == "a\nb"
end

@testset "auto - Pair creates OOB swap div" begin
    result = auto("content" => "my-id"; wrap=identity)
    @test occursin("id=\"my-id\"", result)
    @test occursin("hx-swap-oob", result)
    @test occursin("content", result)
end

@testset "auto - arbitrary objects use repr text/html" begin
    node = h.p("test")
    result = auto(node; wrap=identity)
    @test result == "<p>test</p>"
end

@testset "auto - wrap function is applied" begin
    result = auto("hello"; wrap=uppercase)
    @test result == "HELLO"
end

# ================================================================
# Node primitive (owned by HTMX.jl — no Cobweb wrapper)
# ================================================================

@testset "Node is the owned primitive" begin
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

to_md(node) = repr("text/markdown", node)

@testset "markdown - inline formatting" begin
    @test to_md(h.strong("bold")) == "**bold**"
    @test to_md(h.b("bold")) == "**bold**"
    @test to_md(h.em("it")) == "*it*"
    @test to_md(h.i("it")) == "*it*"
    @test to_md(h.code("x = 1")) == "`x = 1`"
    @test to_md(h.a(href="http://ex.com")("link")) == "[link](http://ex.com)"
end

@testset "markdown - paragraph keeps inline formatting" begin
    p = h.p("hello ", h.strong("world"), " and ", h.code("y"))
    @test to_md(p) == "hello **world** and `y`\n\n"
end

@testset "markdown - br renders a newline" begin
    @test to_md(h.p("a", h.br(), "b")) == "a\nb\n\n"
end

@testset "markdown - heading keeps inline formatting" begin
    @test to_md(h.h1("Top")) == "# Top\n"
    @test to_md(h.h2("Title ", h.em("x"))) == "## Title *x*\n"
end

@testset "markdown - list item keeps inline formatting" begin
    @test to_md(h.li("item ", h.strong("bold"))) == "- item **bold**\n"
end

@testset "markdown - pre emits fenced block without stray backticks" begin
    out = to_md(h.pre(h.code(class="language-julia", "x = 1\ny = 2")))
    @test out == "```julia\nx = 1\ny = 2\n```\n"
    # The inline <code> handler must NOT fire inside <pre>.
    @test !occursin("`x = 1`", out)
end

@testset "markdown - table cells keep inline formatting" begin
    out = to_md(md_to_node("| **A** | B |\n|---|---|\n| `c` | *d* |"))
    @test occursin("| **A** | B |", out)
    @test occursin("| `c` | *d* |", out)
end

@testset "markdown - md_to_node round-trips inline formatting" begin
    rt = "**bold** and `code` and [link](http://x)"
    @test strip(to_md(md_to_node(rt))) == rt
end

@testset "markdown - header and title" begin
    @test to_md(h.header("Section")) == "### Section\n"
    @test to_md(h.title("Page ", h.code("Title"))) == "# Page `Title`\n"
end
