# Design: pinned binary, unpinned data

**Status**: policy (2026-06-15) | **Decided in**: D23

Several static scanners need live data (vulnerability advisories, misconfig rules) that changes faster
than binary releases. This doc records how each is handled and why the approach is safe given the
binary sha256 pin.

## The principle

> The binary sha256 pin transitively pins everything embedded at build time.
> Data fetched from the network at runtime is unpinned and must be explicitly suppressed.

## Per-tool decisions

### osv-scanner
OSV-scanner fetches the OSV advisory database at runtime by default.
This is an existing precedent in this pipeline: advisories must be current or CVE coverage degrades.
Decision: accept the network call (same as today). The scanner binary is still pinned.

### trivy (config/misconfig mode)
Trivy fetches its checks bundle from `mirror.gcr.io/aquasec/trivy-checks:2` at runtime by default.
This would mean the check rules are not pinned — a registry tag can be silently overwritten.
Decision: pass `--skip-check-update`. The checks bundle is embedded in the trivy binary at build time
and used as a fallback (documented in aquasecurity/trivy docs/guide/advanced/air-gap.md).
The binary sha256 therefore pins the checks transitively.

### zizmor
Zizmor can make GitHub API calls for "online audits" (checking referenced action versions against the
registry). This is a network call consuming a GitHub token and introducing nondeterminism.
Decision: pass `--no-online-audits`. The offline ruleset is sufficient for the threat model (template
injection, unpinned actions, cache poisoning, secrets exposure) without the nondeterminism.

### golangci-lint
golangci-lint downloads the repo's full Go module graph for type-aware linters (errcheck, staticcheck).
This is unavoidable: the module graph is not embeddable.
Decision: accept the network call; pass `GOTOOLCHAIN=local` to prevent the tool from downloading a
different Go toolchain (the runner's preinstalled Go is used). `CGO_ENABLED=0` prevents any C build.
If the runner's Go is older than the repo's `go` directive, golangci-lint exits and the step's `|| true`
guard skips it silently — no finding loss, no job failure.

## Summary table

| Tool | Data source | Runtime network | Decision |
|---|---|---|---|
| opengrep | rules pinned at `OPENGREP_RULES_REF` commit | no | existing pin |
| gitleaks | built-in ruleset | no | fully pinned |
| osv-scanner | OSV advisory DB | yes (accepted) | existing precedent |
| ruff | built-in rules | no | fully pinned |
| golangci-lint | Go module graph | yes (accepted) | `GOTOOLCHAIN=local` |
| oxlint | built-in rules | no | fully pinned |
| shellcheck | built-in rules | no | fully pinned |
| hadolint | built-in rules + embedded shellcheck | no | fully pinned |
| actionlint | built-in rules + PATH shellcheck | no | fully pinned |
| zizmor | built-in rules | no (`--no-online-audits`) | hermetic |
| trivy | embedded checks bundle | no (`--skip-check-update`) | hermetic via binary pin |
| typos | built-in dictionary | no | fully pinned |
