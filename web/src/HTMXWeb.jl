module HTMXWeb

using HTMXObjects
using HTMX

# Load Treebars before importing RecordingRoutes — Treebars activates
# HTMXObjects's HTMXObjectsTreebarsExt, which injects `RecordingRoutes`
# with the polling_fetchindex progress UI. Without it the recorder
# blocks on the request until done.
using Treebars
using HTMXObjects: RecordingRoutes

pkg_dir(kind::Symbol) = joinpath(dirname(dirname(@__DIR__)), String(kind))
list_jl(kind::Symbol) = filter(f -> endswith(f, ".jl"), readdir(pkg_dir(kind)))

@dynamicstruct struct HTMXAppData
    gallery_dir = joinpath(dirname(dirname(@__DIR__)), "examples", "htmx-gallery")
    gallery     = Gallery(gallery_dir)

    # Recording flow (HTMXObjectsTreebarsExt's `RecordingRoutes`).
    # Drives `record!` over `recording_paths` and writes the produced
    # static HTML/fragment/markdown under `recording_dir`.
    recording_dir   = joinpath(dirname(dirname(@__DIR__)), "docs", "src", "public", "live-htmx")
    recording_base  = get(ENV, "RECORD_BASE_PREFIX", "/HTMX.jl/dev/live-htmx")
    recording_paths = let ids = [it.id for it in gallery.items]
        ["/", "/gallery", ["/entries/$id" for id in ids]...]
    end
end

const APPDATA = HTMXAppData()

# Default gallery card: title heading + description + the rendered
# spec (the `.jl` file's last top-level expression — for HTMX.jl
# those are `h.*` Node values that render directly as HTML), plus a
# fenced source-code block.
htmx_card(item::GalleryItem; spec) = h.article(
    h.header(h.h3(h.a(item.title; href="entries/$(item.id)"))),
    isempty(item.description) ? h.span() : h.p(item.description),
    spec,
    h.details(
        h.summary("Source"),
        h.pre(h.code(item.code_string; class="language-julia")),
    ),
)

@htmx struct AppContext
    __appdata__ = APPDATA
    # NOTE: don't `(; gallery) = __appdata__` here — clashes with the
    # `@get gallery()` route on the same struct (last-definition-wins
    # warning per htmxo-use §7a Exception). Reach through
    # `__appdata__.gallery` inside route bodies instead.

    __page__(content) = HTMXObjects.pico_page(content)

    @get index() = h.div(
        h.h1("HTMX.jl"),
        h.nav(
            h.ul(
                h.li(h.a(href=__self__/"gallery")("Gallery")),
                h.li(h.a(href=__self__/"record_gallery")("Record gallery")),
                h.li(h.a(href=__self__/"src")("Source files")),
                h.li(h.a(href=__self__/"tests")("Tests")),
                h.li(h.a(href=__self__/"structure")("DO type structure browser")),
            ),
        ),
        h.h2("Package overview"),
        h.p("Self-contained HTML node builder with HTMX attribute conventions."),
        h.h3("Features"),
        h.ul(
            h.li("h.tag() builder syntax with attribute merging"),
            h.li("Underscore-to-hyphen conversion for hx-* attributes"),
            h.li("Boolean and nothing attribute handling"),
            h.li("HyperscriptString support for _ attribute"),
            h.li("auto() response helper with OOB swap support"),
        ),
    )

    # Per-id route: each gallery card links here for a single-item view.
    @include entries(id::String) = begin
        item = find_item(__parent__.__appdata__.gallery, id)
        spec = isnothing(item) ? h.span() : Base.include(@__MODULE__, item.path)

        @get index() = isnothing(item) ?
            h.article("No item with id $(id)") :
            h.article(
                h.header(h.h2(item.title)),
                isempty(item.description) ? h.span() : h.p(item.description),
                spec,
                h.details(
                    h.summary("Source"),
                    h.pre(h.code(item.code_string; class="language-julia")),
                ),
            )
    end

    @get gallery() = h.div(; data_layout="wide")(
        h.h1("HTMX.jl gallery"),
        h.p("Low-level HTMX-attribute building blocks: hx-* attribute conventions, node composition, hyperscript `_` literals, and out-of-band swaps. Each card's body is the rendered last expression of the source file."),
        gallery_grid(
            __appdata__.gallery.items;
            section_titles = __appdata__.gallery.section_titles,
            card_renderer  = item -> htmx_card(item;
                spec = Base.include(@__MODULE__, item.path)),
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

    @include record_gallery = RecordingRoutes(;
        app_type    = AppContext,
        paths       = __appdata__.recording_paths,
        record_dir  = __appdata__.recording_dir,
        record_base = __appdata__.recording_base,
        label       = "Recording HTMX.jl gallery",
    )

    @include structure = HTMXObjects.StructureRoutes(; root=AppContext)

    @include tests = TestRoutes(; project=pkgdir(HTMX))
end

function __init__()
    route!(AppContext())
end

end # module HTMXWeb
