# title: Out-of-band swap + table-element template workaround
# description: `auto(content => "id"; wrap=...)` produces an HTMX `hx-swap-oob="true"` target. When `content` is a table element (`<tr>`, `<td>`, …), `auto` automatically wraps it in `<template>` — without it, the browser's `innerHTML` parser silently strips the row on swap.
# tags: oob, auto, advanced

# Render the auto-wrapped OOB target so the gallery card shows both shapes.
let plain   = HTMX.auto(h.span("42") => "live-counter"; wrap=string),
    row     = HTMX.auto(h.tr(h.td("row 5")) => "row-5";  wrap=string)
    h.div(
        h.h4("Plain OOB swap"),
        h.pre(h.code(plain)),
        h.h4("Table-row OOB swap (auto-templated)"),
        h.pre(h.code(row)),
    )
end
