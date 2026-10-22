# Full `bd init` with every default: agent files, hooks, git repo, config.
# The snapshot pins down every file init writes outside the Dolt store.
bd init --prefix test
bd info
bd where
