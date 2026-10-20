# homemesh agent notes

- Model a home in 3D, mark its ethernet jacks and the owner's placement
  rules, simulate Wi-Fi mesh arrangements and rank them. `docs/brief.md` is
  fixed; `docs/design.md` is the designer's (the first PR), kept in step
  with the code. Build nothing past the skeleton until the owner accepts the
  design.
- A web app on the tailnet: a browser 3D view and a Python backend, deployed
  later on the PC through the runner lane. An iOS RoomPlan capture app comes
  later.
- House data never enters git: no blueprints, photos, video, scans, RoomPlan
  exports or models of a real house in the repository, its issues, its CI
  logs or its fixtures. They live in a data directory outside git (`data/`
  is ignored). Test fixtures are synthetic houses.
- Deploying, tailnet nodes, node shares and runner registration are the
  owner session's work: put what you need in the PR and ask.
- Public, MIT. CI runs on GitHub: wait for it before merging.

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
