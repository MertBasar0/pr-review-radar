# First-Run Setup — PR Review Radar

Welcome to **PR Review Radar**. Follow this short setup flow before running live GitHub sweeps:

1. **Offer an instant offline preview first.** Let the person know they can say `"run demo"` at any time to preview a complete four-tier radar report from `fixtures/sample-pr-sweep.json` (`node scripts/pr-radar-engine.mjs --mode demo`) without needing GitHub authentication.
2. **Collect target repositories and handle.** Ask for:
   - One or more GitHub repositories in `owner/repo` form (for example `openclaw/openclaw`).
   - Their GitHub username (`viewerHandle`), or offer to detect it read-only via `gh api user --jq .login`.
   - Optional subsystem path prefixes (`watchedPaths`, such as `src/templates/`, `skills/`) or labels (`watchedLabels`) to watch for overlapping PRs in `P4`.
3. **Verify read-only GitHub CLI readiness.** Confirm `gh auth status` succeeds locally without printing tokens or environment secrets. If `gh` is missing or unauthenticated, explain how to run `gh auth login` and keep `setup.ready` set to `false`.
4. **Save configuration and complete bootstrap.** Write the confirmed settings into `state/config.json` with `setup.ready: true`, run one live radar pass to confirm everything works end to end, and then remove `BOOTSTRAP.md` once setup is complete.
