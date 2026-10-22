# Hierarchical IDs: children under an epic get dotted suffixes.
bd init --prefix test --skip-agents --skip-hooks --quiet

# Upstream orders ties by created_at (1s resolution), then random hash ID;
# `sleep 1` between creates keeps listing order deterministic.
E=$(bd create 'Launch' -t epic --silent)
sleep 1
bd create 'Write docs' --parent "$E" --silent
sleep 1
bd create 'Record demo' --parent "$E" --silent
sleep 1
C3=$(bd create 'Press kit' --parent "$E" --silent)
sleep 1
bd create 'Logo' --parent "$C3" --silent
bd children "$E"
# The CHILDREN section of show has no defined order upstream.
BDIFF_UNORDERED='^  ↳ ' bd show "$E"
bd list
bd list --json
bd epic status
