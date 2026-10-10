-- Writes N hidden worlds from the mod's own generator to script-output, for docs/balance.py. The world
-- strength and N come from sample.lua, written by scripts/sample_worlds.sh (ES_STRENGTH; not committed).
local ok, cfg = pcall(require, "sample")
if not ok then cfg = {n = 2000, strength = "standard", out = "es-worlds.json"} end
script.on_init(function()
  local out = remote.call("empirical-science", "sample_worlds", cfg.n, cfg.strength)
  helpers.write_file(cfg.out, helpers.table_to_json(out))
end)
