# Run in a fresh process with the package cache already built:
#   julia --startup-file=no --project=. benchmark/performance.jl
# The same script can target another checkout with --project=/path/to/checkout.
using Printf, SHA
load = @timed @eval using HTMX
@printf("ENV julia=%s threads=%d load_ms=%.3f load_bytes=%d\n",
    VERSION, Threads.nthreads(), 1000load.time, load.bytes)
using Markdown

function firstcall(f, label)
    result = @timed @time f()
    @printf("FIRST %-32s ms=%10.3f bytes=%d\n", label, 1000result.time, result.bytes)
    result.value
end
function warm(f, label; samples=11)
    f(); f()
    measurements = [@timed f() for _ in 1:samples]
    times = sort([m.time for m in measurements])
    bytes = sort([m.bytes for m in measurements])
    @printf("WARM %-32s median_ms=%10.4f min_ms=%10.4f bytes=%d\n",
        label, 1000times[cld(samples, 2)], 1000first(times), bytes[cld(samples, 2)])
end
function table(n=1000, k=8)
    h.table(h.thead(h.tr([h.th("column $j") for j in 1:k])),
        h.tbody([h.tr([h.td("row $i col $j & <value>"; class="cell", data_value=i)
                      for j in 1:k]; id="row-$i") for i in 1:n]); class="table")
end

small = firstcall(() -> h.p("hello & <world>"; class="intro"), "construct paragraph")
for mime in (MIME"text/html"(), MIME"text/markdown"(), MIME"application/vnd.hyperview+xml"())
    firstcall(() -> repr(mime, small), "paragraph $mime")
end
big = firstcall(table, "construct table 1000x8")
for (label, mime) in (("HTML", MIME"text/html"()), ("Markdown", MIME"text/markdown"()),
                      ("HXML", MIME"application/vnd.hyperview+xml"()))
    output = firstcall(() -> repr(mime, big), "table $label")
    println("OUTPUT $label bytes=$(sizeof(output)) sha256=$(bytes2hex(sha256(output)))")
    warm(() -> repr(mime, big), "table $label")
end
warm(table, "construct table 1000x8")
source = join(["Paragraph $i **bold** [link](https://example.org) and `code`.\n" for i in 1:500], "\n")
ast = Markdown.parse(source)
firstcall(() -> md_to_node(ast), "convert 500 paragraphs")
warm(() -> md_to_node(ast), "convert 500 paragraphs")

struct Counted
    calls::Base.RefValue{Int}
end
function Base.show(io::IO, m::MIME"text/markdown", x::Counted)
    x.calls[] += 1
    show(io, m, h.span("content"))
end
for depth in (0, 1, 4, 8, 12)
    calls = Ref(0)
    node = foldl((node, _) -> h.header(node), 1:depth; init=h.span(Counted(calls)))
    repr(MIME"text/markdown"(), node)
    calls[] = 0
    result = @timed repr(MIME"text/markdown"(), node)
    @printf("HEADERS depth=%d calls=%d ms=%.4f bytes=%d\n", depth, calls[], 1000result.time, result.bytes)
end
for n in (400, 800, 1600)
    node = h.div([HTMX.HyperscriptString("on click log 'x'") for _ in 1:n])
    warm(() -> repr(MIME"text/html"(), node), "hyperscript $n")
end
function distinct_keywords(n)
    for i in 1:n
        kwargs = NamedTuple{(Symbol("data_probe_$i"),)}(("v",))
        h.div("x"; kwargs...)
    end
end
firstcall(() -> distinct_keywords(30), "30 distinct keyword sets")
warm(() -> distinct_keywords(30), "30 distinct keyword sets")
println("BENCHMARK COMPLETE")
