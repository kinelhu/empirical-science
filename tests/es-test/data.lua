-- Test benches need no power.
data.raw["assembling-machine"]["es-test-bench"].energy_source = {type = "void"}

-- Other mods' targets: this mod registers one, as another mod would.
data.raw["mod-data"]["es-targets"].data["es-test-pipe"] = {result = "pipe", batch = 30, process = {metalwork = 1}}
