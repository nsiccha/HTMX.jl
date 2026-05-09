using Revise
using HTMXWeb

begin
    HTMXWeb.terminate()
    port = length(ARGS) >= 1 ? parse(Int, ARGS[1]) : 8102
    HTMXWeb.serve(; host="0.0.0.0", revise=:lazy, port, async=true)
end
