# Contributing

Bug reports and pull requests are welcome.

## Report a bug

Open an issue with:

- The mod version and the Factorio version.
- The other mods you run.
- What you did, what you expected, and what happened.
- The log file, `factorio-current.log`, if the game crashed.

## Submit a change

1. Fork the repository and create a branch.
1. Make the change. Follow the conventions below.
1. Run the checks in [README.md](README.md#run-the-checks).
1. Open a pull request. Say what the change does and which checks you ran.

## Conventions

- Prefix every prototype name with `es-`.
- Look up each API in the version-matched reference, `doc-html/runtime-api.json` and `prototype-api.json` in
  the game folder. The 1.1 and 2.0 APIs differ.
- Take per-map randomness from seeded state in `storage`. Never call `math.random` in the data stage:
  prototypes must be the same on every map and in multiplayer.
- Add every new locale key to `empirical-science/locale/en/locale.cfg`. `scripts/check.sh` fails on a missing
  key.
- Write player-facing text in the register of vanilla Factorio's own strings.
- If you add a module, entity, circuit signal or `storage` key, update `docs/how-it-works.md`.
  `scripts/check.sh` fails when that file names something that no longer exists.
- If you change balance parameters, rerun `scripts/balance.sh`. Don't type its numbers anywhere else.
- If you rename or remove a prototype, add a file to `empirical-science/migrations/`.
