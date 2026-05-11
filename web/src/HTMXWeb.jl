module HTMXWeb

using HTMXObjects
using HTMX
using TestModules

include("test/runtests.jl")

pkg_dir(kind::Symbol) = joinpath(dirname(dirname(@__DIR__)), String(kind))
list_jl(kind::Symbol) = filter(f -> endswith(f, ".jl"), readdir(pkg_dir(kind)))

@htmx struct AppContext
    
    __page__(content) = HTMXObjects.pico_page(content)

    @get index() = h.div(
        h.h1("HTMX.jl"),
        h.nav(
            h.ul(
                h.li(h.a(href=__self__/"src")("Source files")),
                h.li(h.a(href=__self__/"tests")("Tests")),
                h.li(h.a(href=__self__/"structure")("DO type structure browser")),
            ),
        ),
        h.h2("Package overview"),
        h.p("HTML node builder wrapping Cobweb.jl with HTMX attribute conventions."),
        h.h3("Features"),
        h.ul(
            h.li("h.tag() builder syntax with attribute merging"),
            h.li("Underscore-to-hyphen conversion for hx-* attributes"),
            h.li("Boolean and nothing attribute handling"),
            h.li("HyperscriptString support for _ attribute"),
            h.li("auto() response helper with OOB swap support"),
        ),
    )

    @get src() = h.div(
        h.h1("Source files"),
        (h.div(
            h.h2("$kind/"),
            h.ul([h.li(h.a(href=__self__/"src_file/$kind/$f")(f)) for f in list_jl(kind)]...),
        ) for kind in (:src, :test))...,
    )

    @get src_file(kind::Symbol, name) = begin
        fpath = joinpath(pkg_dir(kind), name)
        isfile(fpath) || error("File not found: $fpath")
        h.div(
            h.h1(h.a(href=__self__/"src")("< "), "$kind/$name"),
            h.pre(h.code(read(fpath, String))),
        )
    end

    @include structure = HTMXObjects.StructureRoutes(; root=AppContext)

    @include tests = TestRoutes(; __req__, test_module=@__MODULE__)
end

function __init__()
    route!(AppContext())
end

end # module HTMXWeb
