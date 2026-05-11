module HTMXWeb

using HTMXObjects
using HTMX
using TestModules

include("test/runtests.jl")

pkg_root() = dirname(dirname(@__DIR__))
src_dir() = joinpath(pkg_root(), "src")
test_dir() = joinpath(pkg_root(), "test")

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
        h.h2("src/"),
        h.ul([h.li(h.a(href=__self__/"src_file"/"src"/f)(f))
              for f in filter(f -> endswith(f, ".jl"), readdir(src_dir()))]...),
        h.h2("test/"),
        h.ul([h.li(h.a(href=__self__/"src_file"/"test"/f)(f))
              for f in filter(f -> endswith(f, ".jl"), readdir(test_dir()))]...),
    )

    @get src_file(kind::Symbol, name) = begin
        dir = kind === :src ? src_dir() : test_dir()
        fpath = joinpath(dir, name)
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
