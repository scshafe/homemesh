# homemesh

Model a home in 3D and plan a Wi-Fi mesh: ethernet jacks, placement rules,
coverage simulation. A standalone iPhone app (`ios/`) scans the rooms with
RoomPlan, edits the plan by touch and plans the mesh on the phone, with the engine
in `core/` (Swift). Houses live on the phone; there is no server. The Python
engine in `homemesh/` stays as the test oracle for the Swift core.

- Brief: [docs/brief.md](docs/brief.md). The original design is [docs/design.md](docs/design.md);
  the accepted design of the standalone app is [docs/design-standalone-app.md](docs/design-standalone-app.md).
- A house's blueprints, photos, video, scans and model are private. They live
  on the phone (or in a data directory outside git) and never enter the
  repository. Test fixtures are synthetic houses.

## Verify

```sh
./scripts/verify      # installs requirements.lock into .venv, runs the Python oracle's unittest suite (including the golden-vector check)
swift test --package-path core   # the Swift engine (Linux or macOS)
```

## License

MIT (`LICENSE`).
