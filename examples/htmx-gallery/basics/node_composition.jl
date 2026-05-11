# title: Node composition (call-form append + vector flattening)
# description: Calling a `Node` returns a *new* node with appended children / merged attributes. Vector-valued positional args are flattened — list comprehensions splice naturally without `...`.
# tags: nodes, composition, basics

let card = h.div(class="card"),
    items = ["apple", "banana", "cherry"]
    h.div(
        card(h.h3("Themed card"), h.p("body"))(class="card dark"),
        h.ul([h.li(it) for it in items]),
    )
end
