# Working on mpx

mpx is a native Swift/AppKit video player for Apple silicon and macOS 27 or later, backed by a pinned patched libmpv. Read [README.md](README.md) for app behaviour and [PACKAGING.md](PACKAGING.md) before building, testing, installing or releasing. Consult the local `DESIGN.md`, when present, for interface decisions.

Inspect the relevant source and scripts before changing them. Preserve existing conventions and unrelated working-tree changes. Keep fixes focused and verify behaviour with the relevant tests. Use clear Markdown for project documentation.

## Required update lifecycle

Every app update must follow **prepare → user test → accept → install → clean**. Documentation-only work does not require an app build or installation.

1. Prepare one self-contained test candidate at `build/development.noindex/mpx.app`, with playback libraries bundled. Run the relevant automated checks before handing it to the user. Record its version, build number and content identity so the accepted app can be identified unambiguously.
2. Launch that exact candidate for user testing and state its path. Confirm the launched process belongs to the candidate rather than another installed copy. Keep the current installed app until the user accepts the candidate. Quit a running candidate cleanly before replacing it; do not accumulate additional named copies or background cleanup waiters.
3. Wait for explicit user acceptance. Acceptance of the identified candidate authorises replacing `/Applications/mpx.app` and cleaning the workflow's temporary artifacts as one operation. Do not ask separately for routine installation or cleanup already covered by that acceptance. If the user requests more changes, prepare a new candidate for testing.
4. Install the accepted candidate unchanged. Do not rebuild, repackage or modify it after acceptance. Verify its recorded identity first, quit running copies cleanly, retain the previous installation temporarily, then verify the installed contents, signature and launch. Restore the previous installation if replacement fails; do not force-quit processes without authorisation.
5. After successful installation, unregister discarded temporary apps from Launch Services and remove the workflow's temporary apps, archives, test builds, staging and rollback material. Verify `build/development.noindex/` is empty or absent and any recorded external scratch paths are gone. Report the installed path/version and cleanup result. An update is not finalised while this cleanup remains incomplete.

The detailed lifecycle, cache policy and implementation gaps are in [PACKAGING.md](PACKAGING.md#local-update-workflow). These requirements are standing agent instructions; the existing scripts do **not** yet enforce the complete lifecycle. Before creating a user test build, account for their legacy outputs and cleanup gaps. Do not claim a helper exists or that cleanup occurred without checking it.

## Artifact ownership and recovery

- Keep transient build artifacts under `build/development.noindex/`. Maintain one current candidate. Internal staging or rollback copies may exist only while their operation needs them.
- Retain only the reusable caches and test inputs described in `PACKAGING.md`; prune obsolete dependency generations only when no retained app, active process or build references them. Do not retain spare app bundles or temporary app archives as caches.
- Validate project-local signing and launch. The `.noindex` suffix does not prevent Finder/File Provider metadata from invalidating signatures. If system-temporary scratch is necessary, record its exact owned path and clean it on normal completion, failure and catchable termination. Recover abandoned owned scratch on the next invocation.
- Do not delete caller-provided test scratch that this workflow does not own. Workflow-owned scratch shared between tests and packaged-library verification must survive until both finish, then be removed by the owning workflow.
- Scope deletion to verified workflow-owned paths. Guard against unexpected paths, symlinks and active processes. Never sweep unrelated system temporary files, installed apps, source files, preferences or playback history.
- Inventory legacy leftovers before a one-time cleanup and obtain explicit authorisation for the identified deletion set. This documentation change does not itself authorise deleting existing leftovers.
- If recovery or cleanup fails, report the exact remaining paths and required action. Never report successful finalisation while retaining unexplained temporary copies.

## Verification and publication

Development builds currently depend on the private libmpv prefix and Homebrew. Do not install that dependency-bound app as the final app. Use the existing self-contained packaging and verification logic; preserve the pinned recipe, bundled libraries, source provenance and licence notices.

Run checks appropriate to the change. A public release also requires the full local test suite and playback inspection on a supported physical Mac; hosted-runner display skips do not replace that coverage. Follow the version and changelog rules in `PACKAGING.md`.

User acceptance for local installation does not authorise GitHub publication. Verify repository ownership, effective Git author, signing identity and GitHub authentication as required by the user's Git instructions. Preserve existing remotes and identity configuration; do not change global Git configuration. Do not push, publish, create a pull request or push a release tag without explicit authorisation.
