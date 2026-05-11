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
# Node wrapping
# ================================================================

@testset "Node wraps Cobweb.Node" begin
    n = h.div("test")
    @test n isa HTMX.Node
    @test parent(n) isa HTMX.Cobweb.Node
end
