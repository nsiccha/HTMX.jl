module HTMXTests
using Test, HTMX, Random, TestModules
include("HTMXTests.jl")
end

using TestModules
runtests!(HTMXTests)
