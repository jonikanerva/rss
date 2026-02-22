# Research Dossier: Agent Autonomy and Git Commit Governance

Date: 2026-02-22
Owner: RPI Orchestrator
Status: Draft for approval

## Problem and users

- Current operating model does not define a precise git progression policy for agent-led delivery.
- Current workflow asks for command-by-command confirmation too often, slowing normal development loops.
- Primary users: repository owner and coding agents operating in this repo.
- Secondary users: reviewers who need predictable commit history and low-risk automation boundaries.

## Constraints and assumptions

- Safety must remain intact: no destructive commands, no secret leakage, no uncontrolled production-impacting actions.
- `main` should remain stable and protected via PR workflow.
- Agent autonomy should increase only for low-risk, reversible operations.
- Evidence and traceability are required for any higher-risk write actions.

## Alternatives and tradeoffs

1. Fully manual confirmation for nearly all commands.
   - Pros: maximum human control.
   - Cons: slow iteration, high interruption overhead.

2. Full autonomous agent with broad write/admin privileges.
   - Pros: fastest execution.
   - Cons: unacceptable risk for repository, integrations, and auditability.

3. Risk-tiered autonomy policy (recommended).
   - Agent auto-runs read and low-risk local write operations.
   - Explicit approval remains for destructive, production, security, and billing-impacting actions.
   - Balanced speed, safety, and traceability.

## Evidence and source links

- Trunk-based and commit hygiene practices: https://trunkbaseddevelopment.com/
- Conventional commits reference: https://www.conventionalcommits.org/en/v1.0.0/
- GitHub protected branch best practices: https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches
- Principle of least privilege (security): https://owasp.org/www-community/controls/Least_Privilege_Principle

## Recommendation

- Adopt a risk-tiered execution policy:
  - Auto-allow safe local commands (status, diff, tests, lint, formatting, feature-branch commits).
  - Require explicit approval for high-risk commands (destructive git, force push, production deploy, IAM/billing, secret handling).
- Standardize commit progression around logical milestones (single-purpose commits with verification before commit).
- Document decision rights and handoff protocol under `docs/operating-model/`.
