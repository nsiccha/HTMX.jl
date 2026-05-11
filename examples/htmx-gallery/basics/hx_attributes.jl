# title: HTMX attributes (underscore → hyphen)
# description: `h.button(hx_get="/x", hx_target="#out")` — Julia kwarg names with underscores render as HTMX hyphenated attributes. `nothing`/`false` are omitted; `true` renders as `name="true"`.
# tags: attributes, basics

h.div(
    h.button(
        "Click me";
        hx_get="/inc",
        hx_target="#count",
        hx_swap="innerHTML",
        disabled=false,
        autofocus=true,
    ),
    h.span("0"; id="count"),
)
