import ProjectDescription

let workspace = Workspace(
    name: "Conv",
    projects: [
        "Projects/App",
        "Projects/Core/*",
        "Projects/Engines/*",
        "Projects/Features/*",
    ]
)
