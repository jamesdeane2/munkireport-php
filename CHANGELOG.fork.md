# Fork divergence from upstream

This file tracks every commit on this fork that is NOT in upstream
`munkireport/munkireport-php`. It is the audit trail for "what's
different about what we deploy."

## Why this fork exists

We fork rather than deploy upstream releases directly because:

1. **Dependabot scans our `composer.json` / `composer.lock`** and opens
   PRs for vulnerable dependencies. Dependabot only works on owned
   repositories.
2. **Reproducible builds via GitHub Actions**: every push to
   `main-iglu` and every tag produces a release tarball with
   `vendor/` already populated by `composer install --no-dev` against a
   pinned PHP 8.3. The tarball is the deployable unit, version-tagged
   to a git SHA.
3. **Date-stamped version tags** (`5.8.1-YYYY.MM.DD`) so the cve-tracker
   matrix can name exactly which build is on each host.
4. **Defense in depth**: if upstream slows down or goes dormant in
   future, the fork already has its own pipeline and ownership.

## Operating model

- `main-iglu` is our default branch and tracks `v5.8.1` plus any
  divergence below.
- Upstream `5.x` is the live upstream branch; we merge from there
  periodically (target: quarterly).
- `git remote add upstream https://github.com/munkireport/munkireport-php`
  if not present. `--push` is set to `DISABLE` to prevent accidental
  pushes back to upstream.

## Divergence log

### 2026-05-19 (later) — Deploy script (Stage C)

- Added `scripts/deploy.sh` — fetches a tagged tarball from this fork's
  GitHub Releases and ssh-deploys it to one of `tuimunki | munki |
  munkireport`. Credentials read from KeePass at runtime, never
  embedded. Preserves `.env`, `app/db/db.sqlite`, and `local/*`
  customisations across the swap. Migrations run via the host's
  `php@8.3`. Previous install dir is preserved as `*.prev-<timestamp>`
  for rollback.
- Deploy is invoked from the Mac Studio operator console — there is
  intentionally no CI-side deploy job. The CI workflow's only job is
  to build + publish the tarball as a Release. Deploy is a deliberate
  human-in-the-loop action.

### 2026-05-19 — Fork bootstrap + CI

- Forked at upstream `v5.8.1` (commit `cddf0a9`).
- Default branch on fork is `main-iglu`, pointing at v5.8.1.
- No code patches applied. Stock 5.8.1 runs cleanly on PHP 8.3 +
  `illuminate/* 10.16.*` (validated on tuimunki).
- Added `.github/workflows/build.yml` — builds tarball on push to
  `main-iglu` and on any tag; tag pushes also publish a GitHub
  release with the tarball attached.
- Added `.github/dependabot.yml` — daily composer scan, weekly
  github-actions scan. PRs target `main-iglu`.
- Upstream's two workflows (`build-release-tag.yml`,
  `github-registry.yml`) are left in place. They trigger on `v*` tags
  and pushes to `5.x` respectively, neither of which we use on our
  fork, so they're inert. Kept rather than deleted to minimise
  divergence from upstream and keep the diff narrow.
- First fork-side tag: `5.8.1-2026.05.19`.

## Historical context (kept for audit trail)

### Why no `please` patch?

A `please` script patch ("MunkiReportContainer") was developed on
2026-05-15 against upstream `v5.8.0` to work around
`Illuminate\Container\Container::runningUnitTests()` being undefined
when illuminate 10's `ConfiguresPrompts` trait calls it. Upstream
`v5.8.0`'s composer.json allowed `~7.0|~10.0` for illuminate, and
modern composer resolution picked up too-new versions, triggering the
fatal.

Upstream `v5.8.1` (May 2026) pinned `illuminate/*` to `10.16.*` and
added `prefer-stable: true`. This change happens to avoid the bug
entirely — the pinned versions don't trip the `ConfiguresPrompts`
codepath in the same way. **The patch is therefore not needed on
5.8.1**, and is intentionally not committed to this fork.

The original patched script is preserved in the operator's runbooks at
`~/.soma/workspace/runbooks/munkireport/please.5.8.0-patched` for
reference and in case a future divergence needs to revive it.

### Why fork `5.x`-style branch as `main-iglu`?

Upstream maintains two branches: `main` (currently 54 commits ahead /
20 behind `5.x` — an apparent integration branch state) and `5.x`
(where releases are cut from, including `v5.8.1`). We anchor on `5.x`
because that's where the tagged releases live. Calling our default
`main-iglu` distinguishes it from upstream's `main` and signals our
ownership.
