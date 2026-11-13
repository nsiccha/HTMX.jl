using PrecompileTools: @setup_workload, @compile_workload

# Keep fixtures small and local. Exercise the runtime tag dispatch in each
# serializer as well as common constructor shapes; no user data or IO escapes
# the workload. Unseen keyword sets and consumer-defined renderers still compile
# when they are first used.
@setup_workload begin
    source = """
    # Title

    Paragraph **bold**, *italic*, [link](#details), and `code`.

    - first
    - second

    > quote

    | name | value |
    | :--- | ---: |
    | x | 1 |
    """
    @compile_workload begin
        paragraph = h.p("hello & <world>"; class="intro")
        table = h.table(h.thead(h.tr([h.th("name"), h.th("value")])),
            h.tbody([h.tr([h.td("x"; class="cell", data_value=1), h.td(1)]; id="row-1")]);
            class="table")
        document = h.html(lang="en")(h.body(
            h.header(h.h1("Title")), h.nav(h.a("details"; href="#details")),
            h.section(id="details")(paragraph, h.p("plain"), h.p("inline ", h.strong("bold"),
                h.em("italic"), h.code("x"), h.br(), h.span(lang="de")("Wort")),
                h.ul(h.li("one"), h.li("two")), h.ol(h.li("first")),
                h.blockquote(h.p("quote")), h.pre(h.code("x = 1")), table,
                h.figure(h.img(src="/plot.png", alt="plot"), h.figcaption("caption")),
                h.form(action="/save")(h.input(type="text", name="q", value=""),
                    h.button("Save"; type="submit"))),
            h.div(HyperscriptString("on click log 'ok'"))))
        parsed = md_to_node(source)
        for node in (paragraph, table, document, parsed)
            repr(MIME"text/html"(), node)
            repr(MIME"text/markdown"(), node)
            repr(MIME"application/vnd.hyperview+xml"(), node)
        end
        auto(paragraph; wrap=identity)
        auto([paragraph, table]; wrap=identity)
        auto(table => "table-slot"; wrap=identity)
    end
end
