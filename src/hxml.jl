# --- Hyperview HXML rendering ---
#
# A THIRD Node serializer beside HTML and Markdown, for Hyperview
# (https://hyperview.org) — "HTMX for native mobile": the server emits HXML (a
# strict XML dialect) that a React-Native client renders as native views. Like
# the HTML/Markdown serializers, this emits a BODY FRAGMENT (the
# <view>/<text>/<form>/<behavior> tree); the enclosing
# <doc><screen><styles><body> chrome and content-negotiation are added by the
# web framework on top (HTMXObjects), exactly as its `_page_wrapper` wraps the
# HTML fragment.
#
# The impedance mismatch this handles: HXML strictly separates a TEXT context
# (inside <text>, where only text runs nest) from a VIEW context (inside <view>,
# where bare text is INVALID and must be wrapped in <text>). Block tags render
# to <view> and group their inline children into <text> runs (see
# `_hxml_view_children`); inline/text tags render to a <text> whose children
# recurse transparently as nested runs.
#
# Styling: Hyperview has no CSS — elements reference styles by id
# (style="foo"), defined in the chrome's <styles> block. EVERY element carries a
# style id derived from its semantic tag (h.small → style="small") FOLLOWED by
# any `class` tokens, space-joined (h.div(class="row") → style="div row"); the
# chrome (HTMXObjects) supplies a matching tag-name stylesheet — so <view
# style="div"> picks up a sane default and the app extends/overrides per class.
# The client IGNORES undefined style ids, so styling purely by class is safe: the
# tag-name prefix is harmlessly undefined. An inline CSS `style="color:red"` has
# no Hyperview equivalent (style= is an id reference list, not a declaration) and
# is DROPPED. The tag-derived vocabulary: div/section/… view ids, the text ids
# (p small span strong em code pre h1..h6 li a label header … th td), plus
# whatever `class` tokens the app uses.

const _hxml_mime = MIME"application/vnd.hyperview+xml"()

# HXML is a text format (an XML dialect), exactly like text/html and
# text/markdown — both of which Base already registers as text mimes (which is
# why `repr("text/html", node)` returns a String). Base doesn't know this vendor
# MIME, so register it: without this, `repr(mime, node)` returns a Vector{UInt8},
# surprising callers who serialize HXML the same way they serialize the HTML
# rendering, and breaking String-level tests/assertions on the output.
Base.istextmime(::MIME{Symbol("application/vnd.hyperview+xml")}) = true

# XML escaping for element text and double-quoted attribute values. Note the
# apostrophe → &apos; (XML), distinct from the HTML serializer's &#39;.
const _XML_ESCAPE_PAIRS = ('&' => "&amp;", '<' => "&lt;", '>' => "&gt;", '"' => "&quot;", '\'' => "&apos;")
_xml_escape(x::AbstractString) = replace(x, _XML_ESCAPE_PAIRS...)
_xml_escape(io::IO, x::AbstractString) = _escape(io, x, _XML_ESCAPE_PAIRS)

# Entry points (mirror the text/markdown block above).
# Fallback: any non-Node value renders as its XML-escaped string form.
Base.show(io::IO, ::MIME"application/vnd.hyperview+xml", val) = _xml_escape(io, string(val))
Base.show(io::IO, ::MIME"application/vnd.hyperview+xml", val::AbstractString) = _xml_escape(io, val)
# Hyperscript is browser-side JS — meaningless to a native client, so drop it.
Base.show(io::IO, ::MIME"application/vnd.hyperview+xml", ::HyperscriptString) = nothing
# Arrays: render each element.
Base.show(io::IO, m::MIME"application/vnd.hyperview+xml", val::AbstractArray) = foreach(v -> show(io, m, v), val)
# Node: dispatch by tag via _hxml(io, m, node, ::Val{tag}).
Base.show(io::IO, m::MIME"application/vnd.hyperview+xml", n::Node) = _hxml(io, m, n, Val(tag(n)))

# Default: recurse transparently (unknown tags fall here, like _md's default).
_hxml(io, m, node::Node, ::Val) = _hxml_recurse(io, m, node)

# Recurse into children as if the node were transparent (text-context: children
# nest directly). HyperscriptString children are skipped (browser-only JS).
_hxml_recurse(io, m, node) = for c in children(node)
    c isa HyperscriptString || show(io, m, c)
end

# --- element emit helpers ---

# Does this view child need to be grouped into an anonymous <text> run? A <view>
# may not hold bare text directly (Hyperview does not render it), so any child
# that serializes to BARE TEXT — a raw String, or a transparent tag like
# <time>/<abbr> that recurses to bare text — must be wrapped. A child that EMITS
# ITS OWN element (a <view>/<text>/<image>/…) is already valid inside the <view>
# and emits as-is, becoming its own flex child. `true` ⟹ wrap/group. Any other
# value is placed by its own output instead (see `_hxml_view_child`).
_hxml_inline(::AbstractString) = true
_hxml_inline(n::Node) = _hxml_tag_inline(Val(tag(n)))
# Unknown tags default to `true` (wrap): an unrecognised inline text tag (time,
# cite, q, …) recurses to bare text, so grouping keeps that text out of the
# <view>. Every tag whose _hxml method emits its OWN element is marked `false`
# (emit direct): the block/view tags AND the inline text tags
# (span/small/strong/b/em/i/code/a) that render to their own <text>. Wrapping
# THOSE would collapse several <text> elements into a single flex child — two
# <span>s must stay two <text> children of the <view> for a row layout to
# space-between them (the reported kv bug).
_hxml_tag_inline(::Val) = true
for t in (:div, :main, :body, :section, :article, :nav, :footer, :header, :aside,
          :details, :figure, :blockquote, :html, :head,
          :ul, :ol, :li, :dl, :dt, :dd,
          :table, :thead, :tbody, :tfoot, :tr, :th, :td,
          :form, :fieldset, :select, :textarea, :input, :button, :option,
          :img, :hr, :p, :pre, :label, :figcaption, :summary, :title,
          :h1, :h2, :h3, :h4, :h5, :h6,
          :span, :small, :strong, :b, :em, :i, :code, :a,
          :script, :style, :meta, :link, :datalist)
    @eval _hxml_tag_inline(::Val{$(QuoteNode(t))}) = false
end
# Navigation containers (Hyperview-native) are standalone — never grouped into a
# <text> run; they sit at the <doc> level, not inside a <view>. A <behavior> is
# a direct child of the element it acts on (emitted first), never a text run.
_hxml_tag_inline(::Val{:navigator}) = false
_hxml_tag_inline(::Val{Symbol("nav-route")}) = false
_hxml_tag_inline(::Val{:behavior}) = false

# Emit children into a VIEW context: consecutive inline children are grouped
# into a single <text> run; standalone (block) children emit directly. This is
# what keeps bare text out of <view> (which Hyperview does not render).
function _hxml_view_children(io, m, node)
    run = false
    for c in children(node)
        run = _hxml_view_child(io, m, c, run)
    end
    run && print(io, "</text>")
end

# Write one view child. `run` says whether a <text> run is open before it; the
# result says whether one is open after it.
_hxml_view_child(io, m, ::HyperscriptString, run) = run
_hxml_view_child(io, m, c::Union{AbstractString,Node}, run) =
    (run = _hxml_run(io, run, _hxml_inline(c)); show(io, m, c); run)
# Any other value (an app's wrapper type, a number, `Raw`) is placed by its own
# output, so a wrapper that writes a Node's HXML sits exactly where that Node
# would. Text output is XML-escaped and never holds a literal `<`, so output
# that starts with `<` and ends with `>` is markup and emits directly; anything
# else is text and joins the run. Empty output writes nothing and leaves the run
# as it was.
function _hxml_view_child(io, m, c, run)
    s = sprint(show, m, c; context=io)
    isempty(s) && return run
    run = _hxml_run(io, run, !_hxml_markup(strip(s)))
    print(io, s)
    run
end
_hxml_markup(s) = startswith(s, '<') && endswith(s, '>')
# Open or close the <text> run so that it is open exactly when the next child
# is inline; returns the new state.
_hxml_run(io, run, inline) =
    (run == inline || print(io, inline ? "<text>" : "</text>"); inline)

# Print the style="…" attribute: the tag-derived style id (or nothing) followed
# by any `class` tokens, space-joined. Emits nothing when both are absent.
function _hxml_print_style(io, node, styleid)
    cls = get(attrs(node), :class, nothing)
    (styleid === nothing && cls === nothing) && return
    print(io, " style=\"")
    need_sep = false
    if styleid !== nothing
        print(io, styleid); need_sep = true
    end
    if cls !== nothing
        _hxml_class_tokens(io, string(cls), need_sep)
    end
    print(io, '"')
end

# Attribute values are heterogeneous. Specialize token iteration after string
# conversion so eachsplit's state stays concrete without allocating a vector.
function _hxml_class_tokens(io, cls::AbstractString, need_sep)
    for tok in eachsplit(cls)
        need_sep && print(io, ' ')
        _xml_escape(io, tok)
        need_sep = true
    end
end

# Print id="…" if the node carries one (needed as a <behavior> target).
function _xml_attribute(io, key, value)
    value === nothing && return
    print(io, ' ', key, "=\"")
    _xml_escape(io, string(value))
    print(io, '"')
end
_hxml_print_id(io, node) = _xml_attribute(io, :id, get(attrs(node), :id, nothing))

# Open tag: <hxtag id=… style=… extra…>. `extra` = pairs of (name, value); each
# value is XML-escaped, and a `nothing` value skips the attribute. `selfclose`
# emits `… />` instead of `…>` (self-closing leaf elements: fields, <image>).
function _hxml_open(io, node, hxtag; styleid=nothing, extra=(), selfclose=false)
    print(io, '<', hxtag)
    _hxml_print_id(io, node)
    _hxml_print_style(io, node, styleid)
    for (k, v) in extra
        _xml_attribute(io, k, v)
    end
    print(io, selfclose ? " />" : ">")
end

# <view styleid> + behavior + grouped children + </view>. Block containers.
function _hxml_view(io, m, node, styleid; default_action="replace-inner", fallback_href=nothing)
    _hxml_open(io, node, "view"; styleid)
    _hxml_behavior(io, node; default_action, fallback_href)
    _hxml_view_children(io, m, node)
    print(io, "</view>")
end

# <text styleid> + behavior + text-run children + </text>. Text/inline tags.
function _hxml_text(io, m, node, styleid; default_action="replace-inner", fallback_href=nothing, fallback_form=nothing)
    _hxml_open(io, node, "text"; styleid)
    _hxml_behavior(io, node; default_action, fallback_href, fallback_form)
    _hxml_recurse(io, m, node)
    print(io, "</text>")
end

# --- hx-* → <behavior> : the HTMX → Hyperview action bridge (decision 1laq0z0, part 4) ---

# hx-swap → Hyperview action. HTMX's default swap is innerHTML → replace-inner.
const _HX_SWAP_ACTION = Dict(
    "innerHTML" => "replace-inner", "outerHTML" => "replace",
    "beforeend" => "append", "afterbegin" => "prepend",
)
# hx-<verb> attr → HTTP verb, in precedence order (keys are hyphenated, as
# stored by `_attr_symbol`).
const _HX_VERB_ATTRS = (
    Symbol("hx-get") => "GET", Symbol("hx-post") => "POST", Symbol("hx-put") => "PUT",
    Symbol("hx-delete") => "DELETE", Symbol("hx-patch") => "PATCH",
)

_strip_hash(s) = startswith(s, '#') ? s[nextind(s, 1):end] : s

# HTMX trigger → Hyperview trigger. Polling ("every 2s") → interval; the delay
# is parsed separately by `_hxml_delay`.
function _hxml_trigger(t)
    t === nothing && return "press"
    s = strip(string(t))
    startswith(s, "every") && return "interval"
    s == "click" ? "press" : s   # load / refresh / visible pass through
end
# Parse a "<n>s" / "<n>ms" delay out of an interval trigger → milliseconds.
function _hxml_delay(t)
    t === nothing && return nothing
    mt = match(r"every\s+([\d.]+)\s*(ms|s)?", strip(string(t)))
    mt === nothing && return nothing
    n = parse(Float64, mt.captures[1])
    ms = mt.captures[2] == "ms" ? n : n * 1000
    string(round(Int, ms))
end

# Resolve (href, verb, action, target) from a node's hx-* attrs, honouring a
# fallback href (a plain <a>) and a default action; target is #-stripped.
# Returns all-nothing when the node carries no hx-verb and no fallback.
function _hx_request(a; default_action="replace-inner", fallback_href=nothing)
    href = nothing; verb = nothing
    for (k, v) in _HX_VERB_ATTRS
        hv = get(a, k, nothing)
        hv === nothing || (href = string(hv); verb = v; break)
    end
    if href === nothing
        fallback_href === nothing && return (nothing, nothing, nothing, nothing)
        href = string(fallback_href); verb = "GET"
    end
    swap = get(a, Symbol("hx-swap"), nothing)
    push = get(a, Symbol("hx-push-url"), nothing)
    action = swap !== nothing ? get(_HX_SWAP_ACTION, string(swap), "replace-inner") :
             push !== nothing ? "push" : default_action
    tgt = get(a, Symbol("hx-target"), nothing)
    target = tgt === nothing ? nothing : _strip_hash(string(tgt))
    (href, verb, action, target)
end

# Emit a <behavior/> child from the node's hx-* attrs, a fallback href (plain
# <a>), or an inherited form-submit request (a submit control inside a <form>).
# None present → nothing (the element is non-interactive). The `trigger` is
# always taken from the node itself (a submit presses; a poll intervals), even
# when the rest of the request is inherited from the form.
# Emit <behavior/> markup from resolved fields — the single behavior emitter,
# shared by the implicit hx-* derivation and the explicit h.behavior(...) tag so
# both serialize identically. Self-closing leaf; href omits when absent (back /
# close / new carry none), verb omits when GET or absent.
function _hxml_behavior_tag(io; trigger, action, href=nothing, verb=nothing, target=nothing, delay=nothing)
    print(io, "<behavior trigger=\"", trigger, '"')
    _xml_attribute(io, :action, action)
    _xml_attribute(io, :href, href)
    (verb === nothing || verb == "GET") || print(io, " verb=\"", verb, '"')
    _xml_attribute(io, :target, target)
    delay === nothing || print(io, " delay=\"", delay, '"')
    print(io, " />")
end

function _hxml_behavior(io, node; default_action="replace-inner", fallback_href=nothing, fallback_form=nothing)
    a = attrs(node)
    href, verb, action, target = _hx_request(a; default_action, fallback_href)
    if href === nothing
        fallback_form === nothing && return
        href, verb, action, target = fallback_form
    end
    trig = get(a, Symbol("hx-trigger"), nothing)
    _hxml_behavior_tag(io; trigger=_hxml_trigger(trig), action, href, verb, target, delay=_hxml_delay(trig))
end

# <behavior> as an explicit tag: h.behavior(action=…, trigger=…, href=…, verb=…,
# target=…, delay=…). Lets HTMXObjects' NavIntent declare the FULL Hyperview
# action set uniformly by building Nodes — push/replace/swap AND back/navigate/
# new/close — rather than hand-writing HXML. Shares _hxml_behavior_tag, so
# explicit and html-derived behaviors serialize identically. trigger defaults to
# press, action to push.
_hxml(io, m, node::Node, ::Val{:behavior}) = let a = attrs(node)
    _hxml_behavior_tag(io;
        trigger = something(get(a, :trigger, nothing), "press"),
        action  = something(get(a, :action, nothing), "push"),
        href    = get(a, :href, nothing),
        verb    = get(a, :verb, nothing),
        target  = get(a, :target, nothing),
        delay   = get(a, :delay, nothing))
end

# === Section A: direct element maps ===

# Block containers → <view style="<tag>">.
for t in (:div, :main, :body, :section, :article, :nav, :footer, :header, :aside,
          :details, :figure, :blockquote)
    @eval _hxml(io, m, node::Node, ::Val{$(QuoteNode(t))}) = _hxml_view(io, m, node, $(string(t)))
end
# <html>/<head> are page chrome the fragment must not emit — recurse into body.
for t in (:html, :head)
    @eval _hxml(io, m, node::Node, ::Val{$(QuoteNode(t))}) = _hxml_recurse(io, m, node)
end

# Text / heading / label tags → <text style="<tag>">. Inline children nest as
# text runs (h.p(h.small(…), h.code(…)) → nested <text> runs, not flattened).
for t in (:p, :small, :span, :strong, :b, :em, :i, :code, :pre, :label,
          :figcaption, :summary, :title,
          :h1, :h2, :h3, :h4, :h5, :h6)
    @eval _hxml(io, m, node::Node, ::Val{$(QuoteNode(t))}) = _hxml_text(io, m, node, $(string(t)))
end

# <a> → inline <text> + a push behavior (navigation). A plain href with no hx-*
# still navigates; an hx-swap/hx-target on the <a> overrides the action.
_hxml(io, m, node::Node, ::Val{:a}) =
    _hxml_text(io, m, node, "a"; default_action="push", fallback_href=get(attrs(node), :href, nothing))

# Lists: <ul>/<ol> → <view>; each <li> → a <view> row (so nested inline text is
# wrapped and nested lists/blocks stay valid).
for t in (:ul, :ol, :li)
    @eval _hxml(io, m, node::Node, ::Val{$(QuoteNode(t))}) = _hxml_view(io, m, node, $(string(t)))
end

# <br> → newline within the current text run; <hr> → a styled divider view.
_hxml(io, m, node::Node, ::Val{:br}) = print(io, "\n")
_hxml(io, m, node::Node, ::Val{:hr}) = (_hxml_open(io, node, "view"; styleid="hr"); print(io, "</view>"))

# === Section B: components ===

# <button> → tappable <text> + behavior. Its own hx-* wins; otherwise it submits
# the enclosing <form> (if any) via the inherited form-submit target.
_hxml(io, m, node::Node, ::Val{:button}) =
    _hxml_text(io, m, node, "button"; fallback_form=_hxml_form_submit())

# Tables → nested flexbox <view>s (Hyperview has no <table>): the chrome styles
# "tr" as a row and "th"/"td" as flexed cells. Header click-to-sort is JS
# (onclick) with no Hyperview equivalent, so cells render statically.
for t in (:table, :thead, :tbody, :tfoot, :tr, :th, :td)
    @eval _hxml(io, m, node::Node, ::Val{$(QuoteNode(t))}) = _hxml_view(io, m, node, $(string(t)))
end

# <img> → self-closing <image source=…> (Hyperview uses `source`, not `src`).
_hxml(io, m, node::Node, ::Val{:img}) =
    _hxml_open(io, node, "image"; styleid="img", selfclose=true,
        extra=(("source", get(attrs(node), :src, nothing)),))

# --- forms ---

# <form> → <form>. The form's hx-post/hx-get becomes the submit target that
# descendant <button>/<input type=submit> controls inherit; when such a control
# fires, Hyperview collects every <form> field's name/value into the request.
_hxml(io, m, node::Node, ::Val{:form}) = _hxml_form(io, m, node)
function _hxml_form(io, m, node)
    _hxml_open(io, node, "form"; styleid="form")
    req = _hx_request(attrs(node))
    if req[1] === nothing
        _hxml_view_children(io, m, node)
    else
        task_local_storage(() -> _hxml_view_children(io, m, node), :hxml_form_submit, req)
    end
    print(io, "</form>")
end
# The enclosing form's submit target, or nothing outside a form.
_hxml_form_submit() = get(task_local_storage(), :hxml_form_submit, nothing)

# === Section: navigation (Hyperview-native containers, no HTML equivalent) ===
#
# <navigator>/<nav-route> ARE the client navigation stack: Hyperview mounts a
# stack only when the doc root is a <navigator> (a bare <screen> has none, so
# push/back can't initialise — the invoices-mobile entrypoint gap). They carry
# no style/behaviour — they're the stack machine, not rendered content. The
# framework (HTMXObjects) builds them from route metadata and composes them into
# the <doc> chrome; the serializer just emits the tag surface, so one navigation
# description dual-serialises (→ <a hx-push-url> for HTML, → <navigator> here).
function _hxml(io, m, node::Node, ::Val{:navigator})
    print(io, "<navigator")
    _hxml_print_id(io, node)
    _xml_attribute(io, :type, get(attrs(node), :type, "stack"))
    print(io, '>')
    _hxml_recurse(io, m, node)
    print(io, "</navigator>")
end
# <nav-route href> references a screen by route: a self-closing leaf, unless it
# carries inline content (an eager <doc>/modal), in which case it wraps it.
function _hxml(io, m, node::Node, ::Val{Symbol("nav-route")})
    print(io, "<nav-route")
    _hxml_print_id(io, node)
    href = get(attrs(node), :href, nothing)
    _xml_attribute(io, :href, href)
    if isempty(children(node))
        print(io, " />")
    else
        print(io, '>')
        _hxml_recurse(io, m, node)
        print(io, "</nav-route>")
    end
end

# <input> → a form field, dispatched on its `type`.
_hxml(io, m, node::Node, ::Val{:input}) =
    _hxml_input(io, node, Val(Symbol(lowercase(string(get(attrs(node), :type, "text"))))))
# Self-closing field with name/value/placeholder passthrough.
function _hxml_field(io, node, hxtag; extra=())
    a = attrs(node)
    _hxml_open(io, node, hxtag; styleid=hxtag, selfclose=true,
        extra=(("name", get(a, :name, nothing)),
               ("value", get(a, :value, nothing)),
               ("placeholder", get(a, :placeholder, nothing)),
               extra...))
end
_hxml_input(io, node, ::Val)             = _hxml_field(io, node, "text-field")   # text/search/unknown
# Native keyboard-type / secure-text hints (Hyperview <text-field> attrs) so the
# right native keyboard / secure entry shows per input type. (Decision 1w08p5y.)
_hxml_input(io, node, ::Val{:email})     = _hxml_field(io, node, "text-field"; extra=(("keyboard-type", "email-address"),))
_hxml_input(io, node, ::Val{:number})    = _hxml_field(io, node, "text-field"; extra=(("keyboard-type", "decimal-pad"),))
_hxml_input(io, node, ::Val{:tel})       = _hxml_field(io, node, "text-field"; extra=(("keyboard-type", "phone-pad"),))
_hxml_input(io, node, ::Val{:url})       = _hxml_field(io, node, "text-field"; extra=(("keyboard-type", "url"),))
_hxml_input(io, node, ::Val{:password})  = _hxml_field(io, node, "text-field"; extra=(("secure-text", "true"),))
# <input type="date"> → Hyperview's native <date-field> (a real native date
# picker). `label-format` is REQUIRED by Hyperview; HTML has no display-format
# attr, so default to ISO "YYYY-MM-DD" (override via a `label-format` attr).
# min/max (ISO dates) pass through. Native-fidelity investment (decision 1w08p5y).
function _hxml_input(io, node, ::Val{:date})
    a = attrs(node)
    _hxml_field(io, node, "date-field"; extra=(
        ("label-format", get(a, Symbol("label-format"), "YYYY-MM-DD")),
        ("min", get(a, :min, nothing)),
        ("max", get(a, :max, nothing)),
    ))
end
_hxml_input(io, node, ::Val{:checkbox})  = _hxml_field(io, node, "switch")
_hxml_input(io, node, ::Val{:radio})     = _hxml_field(io, node, "switch")
_hxml_input(io, node, ::Val{:hidden})    = _hxml_field(io, node, "text-field"; extra=(("hide", "true"),))
function _hxml_input(io, node, ::Val{:submit})
    _hxml_open(io, node, "text"; styleid="submit")
    _hxml_behavior(io, node; fallback_form=_hxml_form_submit())
    _xml_escape(io, string(get(attrs(node), :value, "Submit")))
    print(io, "</text>")
end

# <textarea> → <text-area name>value</text-area> (value = its text children).
function _hxml(io, m, node::Node, ::Val{:textarea})
    _hxml_open(io, node, "text-area"; styleid="text-area",
        extra=(("name", get(attrs(node), :name, nothing)),))
    _hxml_recurse(io, m, node)
    print(io, "</text-area>")
end

# <select> → <select-single>/<select-multiple>; each <option> wraps its label
# text in a <text> (Hyperview's option content model).
function _hxml(io, m, node::Node, ::Val{:select})
    hxtag = haskey(attrs(node), :multiple) ? "select-multiple" : "select-single"
    _hxml_open(io, node, hxtag; styleid="select",
        extra=(("name", get(attrs(node), :name, nothing)),))
    _hxml_view_children(io, m, node)
    print(io, "</", hxtag, '>')
end
function _hxml(io, m, node::Node, ::Val{:option})
    _hxml_open(io, node, "option"; styleid="option",
        extra=(("value", get(attrs(node), :value, nothing)),))
    _hxml_view_children(io, m, node)
    print(io, "</option>")
end

# === Section C: graceful degradation ===

# Non-content / browser-only tags → dropped (no HXML equivalent; matches the
# markdown serializer). <datalist> has no Hyperview counterpart — the paired
# <input> still renders as a plain field.
for t in (:script, :style, :meta, :link, :datalist)
    @eval _hxml(io, m, node::Node, ::Val{$(QuoteNode(t))}) = nothing
end

# Description lists: <dl>/<dd> → <view>, <dt> → a <text> term.
for t in (:dl, :dd)
    @eval _hxml(io, m, node::Node, ::Val{$(QuoteNode(t))}) = _hxml_view(io, m, node, $(string(t)))
end
_hxml(io, m, node::Node, ::Val{:dt}) = _hxml_text(io, m, node, "dt")

# Embedded external content (iframe/embed/object — e.g. a PDF preview) →
# <web-view url=…>, Hyperview's in-app browser. src/data → url.
for t in (:iframe, :embed, :object)
    @eval _hxml(io, m, node::Node, ::Val{$(QuoteNode(t))}) =
        _hxml_open(io, node, "web-view"; styleid="web-view", selfclose=true,
            extra=(("url", get(attrs(node), :src, get(attrs(node), :data, nothing))),))
end
