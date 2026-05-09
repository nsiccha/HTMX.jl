module HTMXWeb

using HTMXObjects
using HTMX
using TestModules

include("test/runtests.jl")

pkg_root() = dirname(dirname(@__DIR__))
src_dir() = joinpath(pkg_root(), "src")
test_dir() = joinpath(pkg_root(), "test")

@htmx struct AppContext
    
    page(content) = htmx(h.body(h.main(class="container")(content)); pico_version="2")

    @get index = page[h.div(
        h.h1("HTMX.jl"),
        h.nav(
            h.ul(
                h.li(h.a(href="/src")("Source files")),
                h.li(h.a(href="/tests")("Tests")),
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
    )]

    @get src = begin
        files = filter(f -> endswith(f, ".jl"), readdir(src_dir()))
        test_files = filter(f -> endswith(f, ".jl"), readdir(test_dir()))
        page[h.div(
            h.h1("Source files"),
            h.h2("src/"),
            h.ul([h.li(h.a(href="/src/src_$f")(f)) for f in files]...),
            h.h2("test/"),
            h.ul([h.li(h.a(href="/src/test_$f")(f)) for f in test_files]...),
        )]
    end

    @get src_file(name) = begin
        parts = split(name, "_"; limit=2)
        dir = parts[1] == "src" ? src_dir() : test_dir()
        fname = String(parts[2])
        fpath = joinpath(dir, fname)
        isfile(fpath) || error("File not found: $fpath")
        content = read(fpath, String)
        page[h.div(
            h.h1(h.a(href="/src")("< "), parts[1] * "/" * fname),
            h.pre(h.code(content)),
        )]
    end

    @include tests = TestRoutes(; __req__, test_module=@__MODULE__)
end

function __init__()
    route!(AppContext())
end

end # module HTMXWeb
