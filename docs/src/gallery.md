---
htmxo-embed-fullwidth: true
---

# Gallery

A handful of bite-sized demos exercising the HTMX.jl building blocks:
hx-* attribute conventions, node composition, hyperscript `_` literals,
and out-of-band swap helpers. Each card's body is the rendered last
expression of the corresponding `.jl` file under
[`examples/htmx-gallery/`](https://github.com/nsiccha/HTMX.jl/tree/dev/examples/htmx-gallery).

In **dev** (`npm run docs:dev`), the embed below proxies through to the
running HTMX.jl web app on `localhost:8102`. In **production**, the same
path is served from the committed recordings under
`docs/src/public/live-htmx/` (produced by hitting `/record_gallery` on
the live app).

```@raw html
<div class="htmxo-embed-fullwidth">
<div class="htmxo-embed" data-hx-base="live-htmx/gallery" hx-swap="innerHTML">
  <em>Loading HTMX.jl gallery…</em>
</div>
</div>
```
