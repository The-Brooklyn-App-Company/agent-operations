# Releases

## Declared in the pull request

Every PR declares whether operational work is needed. A change with rollout effects includes the versioned migrations/scripts/config and relevant tests alongside code and declares its activation needs in the pull request, using the activation section in [../templates/release-record.md](../templates/release-record.md). Activation needs include:

- Migrations
- Tests
- Configuration
- Feature flags
- Jobs
- Prompt activation

The section also states compatibility, ordering, idempotency, recovery steps and the permissions required.

## Promotion

Promotion assembles a plan with these parts:

- An owner
- The exact source SHA
- The exact artifact
- The target environment
- The ordered activations

The plan lives in one repository-owned release index or record. Reuse the existing one, and do not start a parallel tracker.

## Closeout

The maintainer executes the approved ordered plan, verifies the actual target/artifact and changed production behavior, completes activations and owns diagnosis/authorized recovery until settlement. The report records:

- Execution health
- Each activation
- Recovery, if needed
- The post-deploy report

Keep these states distinct and record each one separately:

- CI is green.
- The source is merged.
- Staging is verified.
- The runtime is verified.
- The customer has accepted.

An accepted fix does not wait on an unrelated held experiment or trial; integrate them separately unless a real dependency is shown. The kit sets no universal soak period, no mandatory manual cloud console login and no paid test run. Each repository decides what evidence settles a release.

## Authority

Release authority is scoped to the release that was approved. These remain separate human decisions:

- UI control or authentication that the human controls
- Outbound email
- Purchases
- Expanded spend

The release-closeout skill routes to this document. It never grants itself these permissions.

## Team defaults

Use [team collaboration](team-collaboration.md) for a two-person account policy. Solo adopters use independent agent review and the repository’s authorized integration route; no second human account is required. Neither path grants additional release authority.

Use one record per production promotion, including failed/partial attempts, times/evidence, recovery baseline, outcomes and remaining owner/action. A docs-only source change with no production promotion does not create a fake production release record. Closeout uses the normal docs path without redeploying the product just to publish a receipt.
