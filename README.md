# homemesh

Model a home in 3D and plan a Wi-Fi mesh: ethernet jacks, placement rules,
coverage simulation. A browser 3D view and a Python backend, run on the
tailnet; an iOS RoomPlan capture app later.

- Brief: [docs/brief.md](docs/brief.md). The design ([docs/design.md](docs/design.md)) is the
  project agent's first PR.
- A house's blueprints, photos, video, scans and model are private. They live
  in a data directory outside git (`data/` is ignored) and never enter the
  repository. Test fixtures are synthetic houses.

## Verify

```sh
./scripts/verify      # the Python tests (standard library unittest)
```

## License

MIT (`LICENSE`).
