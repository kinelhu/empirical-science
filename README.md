# Empirical Science

A Factorio 2.0 mod. You feed an additive, such as coal or sulfur, into a machine beside its recipe, and the
machine can make more products, run slower or pollute less. Which additive helps which recipe is hidden and
differs on every map. You find out with trials, sample analysis and statistics, then dose your factory with what
works.

To play the mod, install it from the Factorio mod portal. This repository holds the source and the development
tools.

## Requirements

- Factorio 2.0.77. Space Age and Quality are optional.
- [Factorio Charts](https://github.com/nickelbob/factorio-charts) 1.1.0. The scripts clone it into `vendor/`.
- macOS with the Steam install of Factorio. The scripts read the game's paths from `scripts/env.sh`. On another
  system, edit the paths in that file.
- [uv](https://docs.astral.sh/uv/) for the Python tools in `docs/` and `scripts/`.

## Repository layout

| Path | Contents |
| --- | --- |
| `empirical-science/` | The mod. This folder is what the mod portal ships. |
| `scripts/` | Shell and Python tools: profile setup, checks, tests, the balance model run, image builds. |
| `tests/` | Helper mods that the test scripts load: the integration test, the GUI test, upgrade tests, scene tools. |
| `docs/how-it-works.md` | A map of the mod: the loop, the hidden world, the modules, the tick loop, the circuit interface. Start here. |
| `docs/balance.py`, `docs/balance.md` | The balance model and its last report. |
| `docs/modpage/` | The mod portal page and the scripts that build its images. |

## Set up a development profile

The scripts never write to your normal Factorio profile. Each one uses its own profile under
`~/Library/Application Support/`.

1. Create the development profile. It links the mod folder into the profile, so edits take effect on the next
   game start:

   ```sh
   scripts/setup-dev-profile.sh
   ```

1. Start the game on the development profile:

   ```sh
   scripts/play.sh
   ```

Prototype changes need a game restart. `control.lua` changes need a save reload.

## Run the checks

Run these before you submit a change:

1. Load the data stage and create a map:

   ```sh
   scripts/check.sh
   ```

   This also lints the locale keys, the GUI element names and `docs/how-it-works.md`.

1. Run the headless integration test on several seeds. Each seed has a different hidden world:

   ```sh
   for seed in 12345 777 4242 1 34; do scripts/test.sh "$seed"; done
   ```

1. If you changed stations, dosing or quality, run the tips check. It is the only run without Space Age and
   Quality:

   ```sh
   scripts/tips_check.sh
   ```

1. If you changed the storage layout or the hidden world, run the upgrade tests against the earlier versions:

   ```sh
   scripts/upgrade_test.sh <commit>...
   ```

`scripts/guitest.sh` opens a game window and drives the station GUI. It needs a person at the keyboard to
dismiss one tutorial prompt.

## Balance

Balance comes from a model, not from playtests. `scripts/balance.sh` samples worlds from the mod's own
generator, regenerates `docs/balance.md` and writes the generated thresholds in
`empirical-science/scripts/`. Run it after you change a balance parameter or the hidden-world generator. Don't
edit the mod while it runs: the run checks that the mod did not change.

## Build a release

```sh
scripts/build_release.sh
```

This writes `dist/empirical-science_<version>.zip` from the last commit. It fails if `changelog.txt` has no
entry for the version in `info.json`, or if the zip does not load in a clean profile, with and without Space Age
and Quality.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT. See [LICENSE](LICENSE).
