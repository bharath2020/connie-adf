# Agent instructions for connie-adf

## Release & tagging convention

Every TestFlight (or App Store) upload follows this sequence — no exceptions:

1. **Bump the build number** in `Demo/project.yml` (`CURRENT_PROJECT_VERSION`),
   run `xcodegen generate` in `Demo/`, and commit the bump
   (`chore: build <N> (<short feature summary>) for TestFlight`).
2. **Build and upload** (archive Release → export with the manual
   `ADFReader App Store` profile → `asc publish testflight --app 6789955057
   --ipa <path> --group <group-id> --wait`).
3. **Merge to `main`** with a `--no-ff` merge commit describing the feature
   (`Merge <branch>: <summary>`), if the build came from a branch.
4. **Tag `main` with the build number**: an annotated tag named `build-<N>`
   on the commit whose tree shipped (the merge commit, or the bump commit for
   direct-on-main builds). The tag message records the App Store Connect
   build ID and the distribution date/group. Push the tag with the branch:
   `git push origin main --follow-tags`.

Tags are the source of truth for "what code is in build N" — crash triage and
tester feedback reference build numbers, so every uploaded build must be
reconstructable by `git checkout build-<N>`.

Existing tags start at `build-15` (2026-07-16); builds 1–14 predate the
convention.

## Repo layout, invariants, and verification

- Architecture rules and hard-won performance invariants live in
  `docs/Architecture-Decisions.md` — read §8 (lazy rows), §16 (mass
  re-materialization livelock), and §20 (custom block plugins) before
  touching `Sources/ADFRendering`.
- Never bind `@State` to `onScrollVisibilityChange` in lazy rows (two
  captured livelocks; see the §20 spec's post-implementation review).
- Perf gates: `-fixture stress-5k -autoscroll` (< same-build baseline),
  plus a manual fling with instantaneous-CPU settle check (`top -l 2 -pid`),
  plus scene-snapshot thrash (Home/lock/switcher) and an idle soak for
  anything touching row lifecycles. The autoscroll gate alone provably
  misses livelocks.
- Demo app perf/automation launch args are documented in
  `Demo/ADFReader/ADFReaderApp.swift` (`-fixture`, `-autoscroll`,
  `-scrollToFraction`, `-searchQuery`, `-fontSizeStep`).
