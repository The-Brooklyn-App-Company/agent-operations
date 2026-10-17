# Maintenance

## Source ownership

Every changing fact has exactly one owning record. Examples include a release inventory, a queue, a host list and a worker profile. Other documents link to that owner instead of copying it.

This kit owns the general practice. Your repositories own their own specifics.

Do not paste kit documents into repository instructions. Link to the pinned kit, and add only the local rules that differ from it.

## Pinned versions

Adopt a tagged release, such as `v0.1.1`, through a local checkout. Record the tag in your machine-local profile.

To upgrade:

1. Read [../CHANGELOG.md](../CHANGELOG.md) and the full diff between your current tag and the target tag.
2. Note any drift: local rules that the new version changes or contradicts.
3. Check out the new tag, then confirm that the skills still resolve the kit root.
4. Keep the previous tag available until the new one has been used successfully. To roll back, check out the previous tag again.

Do not point skills at a moving `main` branch or at whatever the latest version happens to be.

## Installing skills

The four skills live in `skills/<name>/SKILL.md`. Each skill locates the kit at runtime and then reads the canonical documents. On current Codex installations, use the documented user root `~/.agents/skills` or repository `.agents/skills`; preserve a compatible legacy user root only if the installed client already demonstrates discovery there. Reuse the root the client actually discovers; do not create duplicate installations. Current source: [official skill guidance](https://learn.chatgpt.com/docs/build-skills), checked 2026-10-17. Native plugin/import controls can differ by client.

The operator can preview selected directory links with `python3 scripts/link_skills.py --target <verified-skills-root> --skill operator-setup`. Add other `--skill` names only as needed. Under the approved setup, append `--apply` to create them from a clean tagged Git checkout. The helper refuses existing conflicting entries and does not overwrite instructions or create schedules. It links the directory, never just SKILL.md. On a fresh conversation verify the chosen skill is listed and explicitly invoke `$operator-setup`; source validation alone does not prove client discovery.

Create the optional profile at `~/.config/agent-operations/profile.local.json` (or an explicitly recorded alternate) from the example template, outside shared repositories. Its exact kit field is `kit.kitRoot`. Record the actual profile path in your local global guidance so the agent can find it. For copied/manual skills, provide that binding explicitly; if neither realpath nor an explicit profile binding works, report the gap rather than search unrelated directories.

- **macOS and Linux:** Symlink each skill directory into your client's skills location. The skill resolves its own real path and takes the directory two levels up as the kit root.
- **Windows:** Set `kit.kitRoot` in the machine-local profile, or use a local link that the client follows. A copied skill directory is not self-contained. It needs a configured route back to the kit checkout.

## Contributing

Use the normal git workflow for both documentation and skill changes: branch, pull request, review, merge, then tag. Keep skills thin and route their details to the documents. Contributions must contain only synthetic examples. Do not include real names, projects, hosts, accounts or internal URLs.

## Lifecycle of your own records

- **Propose:** Write the proposal in the owning queue, not in a new planning document.
- **Adopt:** Record the approval in the owning record.
- **Archive:** Move completed items into the owning record's archive.
- **Retire:** Remove routines, links and profiles together, then record the reason.

Temporary work batches stay temporary and do not become permanent planning documents. Parked work stays parked until a human reactivates it.
