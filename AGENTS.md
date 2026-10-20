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
