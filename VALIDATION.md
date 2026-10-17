# Release validation and limits

Version 0.1.2 was prepared on October 17, 2026. Initial Opus5.5 authoring and an independent GPT-6.1 Sol cold-start walkthrough were followed by a fresh individually scoped Opus5.5 public-kit audit and bounded fix verification. The reviewer accepted all concrete corrections with no remaining handoff blockers. This is content/source review, not another human account’s GitHub approval or installed-runtime acceptance. Review is evidence, not a guarantee.

Actual offline checks cover local documentation links, JSON/frontmatter, captured single-event routing decisions including acknowledged delivery/repeat suppression, failure episodes, unknown reads and uncertain-delivery reconciliation, no-overwrite skill linking in an isolated target, and committed-source archive/hash integrity. Package privacy review examines intended source and metadata; private runtime profiles and transcripts are excluded.

These checks do not prove installed-client skill discovery, a real native scheduled run, remote access, actual account grants, cross-account review, delivery acknowledgement or worker self-disposal on another machine. Setup acceptance records those separately using the actual supported tools. No paid model/API test or production effect is needed to read or try the synthetic example.

The Git tag identifies release source. Downloadable archive/manifest sidecars identify the exact commit and archive SHA256 without embedding a circular hash inside their own source. Archives contain tracked files only; linked skill installation uses a clean local Git checkout of the tag.
