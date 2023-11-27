using NARXEFEAgents
using Documenter

DocMeta.setdocmeta!(NARXEFEAgents, :DocTestSetup, :(using NARXEFEAgents); recursive=true)

makedocs(;
    modules=[NARXEFEAgents],
    authors="wmkouw <wmkouw@gmail.com> and contributors",
    repo="https://github.com/wmkouw/NARXEFEAgents.jl/blob/{commit}{path}#{line}",
    sitename="NARXEFEAgents.jl",
    format=Documenter.HTML(;
        prettyurls=get(ENV, "CI", "false") == "true",
        canonical="https://wmkouw.github.io/NARXEFEAgents.jl",
        edit_link="main",
        assets=String[],
    ),
    pages=[
        "Home" => "index.md",
    ],
)

deploydocs(;
    repo="github.com/wmkouw/NARXEFEAgents.jl",
    devbranch="main",
)
