# Release validation and limits

Version 0.1.1 was prepared on October 17, 2026. A bounded Opus5.5 authoring pass, an independent Sol cold-start walkthrough and a fresh Opus5.5 content review informed this release. Adoption issues around over-confirmation, local checkout/skill discovery, solo use and native worker bindings were corrected and the affected walkthrough was rechecked. Review is evidence, not a guarantee.

Actual offline checks cover local documentation links, JSON/frontmatter, synthetic unchanged/changed/read-failure/delivery-uncertain routing, no-overwrite skill linking in an isolated target, and committed-source archive/hash integrity. Package privacy review examines intended source and metadata; private runtime profiles and transcripts are excluded.

These checks do not prove installed-client skill discovery, a real native scheduled run, remote access, actual account grants, cross-account review, delivery acknowledgement or worker self-disposal on another machine. Setup acceptance records those separately using the actual supported tools. No paid model/API test or production effect is needed to read or try the synthetic example.

The Git tag identifies release source. Downloadable archive/manifest sidecars identify the exact commit and archive SHA256 without embedding a circular hash inside their own source. Archives contain tracked files only; linked skill installation uses a clean local Git checkout of the tag.
