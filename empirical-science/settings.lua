local shared = require("shared")

data:extend({
  -- Research data in mainline technologies: off by default.
  {type = "string-setting", name = "es-data-in-mainline", setting_type = "startup", order = "a",
   default_value = "off", allowed_values = shared.data.mainline_tiers},
  -- (0.72, after the advisory pass) Vanilla's endless technologies take empirical science packs: on by default
  --, off for a game without the mod's grind in its endgame.
  {type = "bool-setting", name = "es-data-in-endless", setting_type = "startup", order = "a2", default_value = true},
  -- Other mods' targets: science packs as targets, mixes derived.
  {type = "bool-setting", name = "es-derive-targets", setting_type = "startup", order = "b", default_value = false},
  -- World strength.
  {type = "string-setting", name = "es-world-strength", setting_type = "startup", order = "c",
   default_value = "standard", allowed_values = shared.world_strength_order},
  -- Science seed (0.70, user: hidden worlds players can share, whatever the terrain): 0 uses the map's seed.
  -- Read once, when the map is made (control.lua, storage.truth.science_seed).
  {type = "int-setting", name = "es-science-seed", setting_type = "runtime-global", order = "d",
   default_value = 0, minimum_value = 0, maximum_value = 4294967295},
})
