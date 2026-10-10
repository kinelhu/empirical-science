-- Writes this map's hidden world as JSON (scripts/ground_truth.sh). For the designers' eyes only.
script.on_init(function()
  helpers.write_file("es-groundtruth.json", helpers.table_to_json(remote.call("empirical-science", "ground_truth")))
  helpers.write_file("es-groundtruth-pairs.json", helpers.table_to_json(remote.call("empirical-science", "ground_truth_pairs")))
end)
