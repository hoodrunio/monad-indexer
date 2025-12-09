# CI/CD Controls

## Workflows
- `.github/workflows/ci.yml` — gofmt/vet/test for `services/nft-icon-fetcher`, Helm dependency + lint for the chart, and Hadolint for all Dockerfiles (separation of duties, coding standards).
- `.github/workflows/security.yml` — gitleaks secrets scan, gosec SAST, Trivy vuln/config/secret/license scan, SBOM generation with Syft, weekly scheduled run, SARIF upload to code scanning (vulnerability management and shift-left security).
- `.github/workflows/release.yml` — tag-driven build/push of the nft-icon-fetcher image with Buildx provenance/SBOM and cosign keyless signing; gated by the `production` environment for approvals (change control and deployment authorization).

## Required GitHub setup
- Add repository secrets for releases: `REGISTRY_USERNAME` and `REGISTRY_PASSWORD` (GHCR or your registry PAT with `packages:write`). If missing, the release workflow skips publishing.
- Create a `production` environment with required reviewers and, optionally, wait timers. That enforces manual approval before releases (ISO 27001 A.12.1.2 / A.14.2.9).
- Enable branch protection on `main`: require pull requests with at least one approval, require status checks `CI - Build, Lint, and Test` and `Security - Build Quality Gates`, block force-pushes, and require signed commits if your policy demands it.
- Keep Actions artifact retention >= 30 days and restrict who can approve/modify workflow files (Settings → Actions and Branch protection).

## Control mapping (high level)
- Secure development lifecycle (A.14.2.x): gofmt/vet/test, Helm/Dockerfile linting, SAST (gosec), IaC lint (Trivy config scan), SBOMs.
- Technical vulnerability management (A.12.6.x): Trivy vuln scan, gitleaks secret detection, weekly scheduled security workflow, SARIF surfaced in GitHub code scanning.
- Change control and deployment approvals (A.12.1.2): branch protections + required checks, environment-gated release workflow with manual approval, signed container images.
- Asset/secret handling (A.8.x, A.9.x): registry credentials and signing keys stored in GitHub Secrets; no secrets kept in Git; External Secrets Operator remains for runtime secrets.
- Logging/evidence (A.12.4.x): GitHub Actions logs, SARIF reports, and SBOM artifacts retained for audits; container image provenance is attached via Buildx and cosign.

## How to use
- CI/Security run on every PR and push to `main` plus a weekly scheduled scan; failures block merges when required checks are enforced.
- For a production build: create a tag like `v1.2.3`. With registry creds configured and environment approval granted, the workflow pushes `ghcr.io/<org>/monad-indexer/nft-icon-fetcher:<tag>` and `:latest`, attaches provenance/SBOM, and signs with cosign (keyless via GitHub OIDC).
- Review SARIF results under GitHub Security → Code scanning alerts; download SBOM artifacts from the workflow run if needed for vendor due diligence or vulnerability triage.
