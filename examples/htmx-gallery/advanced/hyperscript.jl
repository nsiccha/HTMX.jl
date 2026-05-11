# title: Hyperscript via `_"…"` literal
# description: Children of type `HyperscriptString` (built with the `_"…"` literal) are pulled out of the children list at render time and concatenated into the element's `_` attribute. Multiple snippets are newline-joined.
# tags: hyperscript, advanced

h.div(
    h.button("Menu";
        _"on click toggle .open on #menu",
        _"on mouseenter add .hover end",
    ),
    h.nav(id="menu", class="closed")(
        h.a(href="/")("Home"),
        h.a(href="/about")("About"),
    ),
)
