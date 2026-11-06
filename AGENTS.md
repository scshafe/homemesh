# homemesh agent notes

- Model a home, mark its ethernet jacks and the owner's placement rules, simulate Wi-Fi mesh arrangements and rank them. `docs/brief.md` is
  fixed; `docs/design.md` is the original design; `docs/design-standalone-app.md` is the accepted design of what the repository is now.
- **A standalone iPhone app.** `ios/` is the app (RoomPlan capture, an editor, the plan and 3D views), `core/` is `HomemeshCore`, the
  Foundation-only Swift engine it runs (it also builds and tests on Linux). Houses live on the phone. **Nothing is deployed and there is no
  server**: the web app, the FastAPI layer and `deploy/` were retired on 2026-11-05.
- The Python code in `homemesh/` is kept only as the **oracle**: `scripts/golden` writes the golden vectors the Swift core is tested against
  (`core/Tests/HomemeshCoreTests/Golden/`), and `tests/test_golden.py` fails when they are stale. A Swift change that disagrees with Python is a
  bug in one of the two. `Golden/api_session.json` is a frozen recording of the retired API, replayed by the Swift tests.
- House data never enters git: no blueprints, photos, video, scans, RoomPlan exports or models of a real house in the repository, its issues,
  its CI logs or its fixtures. Test fixtures are synthetic houses.
- Never write the tailnet name. The iOS app builds only in CI (macOS job); Swift toolchains for `core/` are under `~/swift`.
- Merging deploys nothing (`dev.toml` `[deploy]` lane `none`). Say in each PR what only a device can show (the scan, touch handling, the Files app).
- Public, MIT. CI runs on GitHub: wait for it before merging (Linux `verify` and `core`, macOS `ios`).

<!-- scshafe-dev:begin landing -->
## Verify and landing

Managed by scshafe-dev: `dev adopt` and `dev update` refresh this section from `dev.toml`; change `dev.toml`, not these lines.

Before finishing, both of these must pass:

```sh
./scripts/verify
dev check .
```

How a change lands:

1. Work on a branch and open a PR.
2. Run the two commands above. If the repository is private, GitHub Actions does not run for it: verify locally and say in the PR what you ran. If it is public, wait for CI to be green.
3. Merge your own PR with a merge commit, one change at a time: `gh pr merge <N> --merge --subject "Merge #<N>: <title>"`. Never squash or rebase (both are off on the repository), and pass `--subject`: `gh pr merge` does not make the `Merge #N: <title>` subject by itself.

The project's agent may merge its own PR and push `main`; there is no approval gate.
<!-- scshafe-dev:end landing -->
