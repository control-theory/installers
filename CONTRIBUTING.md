# Contributing

## Branching & release workflow

This repo publishes the **public install scripts** (served at `install.controltheory.com` via GitHub Pages). The `main` branch is what the public gets — do **not** commit to it directly.

```
feature branch ──► stage ──► (PR) ──► main
   (your work)    (test)            (public release)
```

| Branch | Role | Where it publishes (`deploy.yml`) |
|--------|------|-----------------------------------|
| `stage` | Integration & testing | served under `/stage/` on the Pages site |
| `main`  | Public release | served at the site **root** (what users `curl`) |

> Heads-up: `deploy.yml` builds the site from **both** branches. Pushing to `main` changes the public root immediately; changes you only put on `stage` show up under `/stage/`, **not** at the root. (This is the gotcha that bit us — test on `stage`, release via `main`.)

### How to land a change

1. Branch off `stage`, do your work, open a PR **into `stage`**.
2. Merge to `stage` and test against the `/stage/` scripts.
3. When it's good, open a PR **from `stage` into `main`** and merge it. That is the *only* way to release publicly.

### Enforcement (so we can't forget)

`main` is protected:

- **Direct pushes are blocked** — everything goes through a PR.
- **Only `stage` may be merged into `main`.** A required status check (`source-branch-guard`, see `.github/workflows/enforce-stage-only.yml`) fails any PR into `main` whose source branch isn't `stage`.
- Force-pushes and branch deletion are blocked, and the rules apply to admins too.

If you find yourself wanting to push to `main` directly: don't. Land it on `stage`, then merge `stage` → `main`.
