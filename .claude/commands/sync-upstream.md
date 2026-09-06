---
description: Merge we-promise/sure (upstream) into main, resolve conflicts, verify, commit and push
---

This repo is a fork of `we-promise/sure`. A daily `upstream-sync` GitHub Action
(`.github/workflows/upstream-sync.yml`) tries to merge `upstream/main` into our
`main` automatically; when it can't auto-merge, it's supposed to open a "Upstream
sync conflict" issue (this step itself has a bug and sometimes fails silently —
check `gh run list --workflow=upstream-sync.yml` and `gh issue list --search
"Upstream sync conflict"` for context on why you're being asked to do this).

Do the merge yourself, end to end: resolve, verify, commit, and push. Don't stop
to ask before pushing — that's the point of this command.

## Steps

1. **Check the working tree is clean** (`git status`) before doing anything
   destructive. If there's uncommitted work, stop and ask.

2. **Fetch and merge:**
   ```
   git remote add upstream https://github.com/we-promise/sure.git 2>/dev/null || true
   git fetch upstream main
   git merge upstream/main --no-edit
   ```

3. **Resolve each conflicted file on its merits — don't default to "ours" or
   "theirs".** Read both sides of every hunk before choosing:
   - If the two sides touch unrelated things in the same hunk (e.g. two
     unrelated features each adding one line to the same method/array/YAML
     map), **keep both** rather than picking one side and silently dropping
     the other's feature.
   - If upstream refactored something we've also locally modified, prefer
     adopting upstream's new structure and re-applying our specific
     customization on top of it, rather than reverting to our old structure.
   - **Don't let a feature silently disappear.** If a conflict looks like
     upstream removed/replaced something we still rely on (e.g. a view
     upstream now gates behind a preview flag that most users don't have),
     don't just delete our working version — keep it and layer upstream's
     addition alongside it, then flag the tradeoff in your final summary
     instead of making that product call silently.
   - `.sure-version`: take whichever of the two version strings sorts higher
     (`sort -V`).
   - `db/schema.rb`: **do not hand-resolve this.** Take either side as a
     placeholder, then regenerate it properly (see step 4).
   - Check `db/migrate/` for two *different* migration files sharing the same
     timestamp prefix (a real collision, not a git conflict marker — `ls
     db/migrate | sed -E 's/^([0-9]+)_.*/\1/' | sort | uniq -d`). If found,
     figure out which file is already ours (already merged/released — check
     `git log --oneline --diff-filter=A -- <path>` and whether it's reachable
     from `main` history already) vs. the incoming upstream one. **Rename only
     the incoming upstream migration** to a fresh, later timestamp — renaming
     our own already-shipped migration would break `schema_migrations` on any
     self-hosted install that already ran it.

4. **Regenerate `db/schema.rb` from migrations instead of hand-merging it.**
   Bring up the dev containers if they aren't already running
   (`docker compose -f .devcontainer/docker-compose.yml up -d app`), then
   inside the `app` container:
   ```
   bundle install   # pick up any new gems from the merged Gemfile.lock
   bin/rails db:migrate
   ```
   This runs the full merged set of migrations against the existing dev
   database (non-destructive — never `db:drop`/`db:reset` the dev database)
   and dumps a correct, conflict-free `schema.rb`. Confirm no `<<<<<<<`
   markers remain anywhere: `git grep -n '^<<<<<<<\|^>>>>>>>'`.

5. **Stage every resolved file** (`git add`) — double check nothing was left
   as `UU` (`git status --short | grep -E '^UU|^AA|^DD'` should be empty)
   before moving on.

6. **Verify before committing**, inside the `app` container:
   - `bin/rails test` (full suite — a merge can surface a test whose
     assumptions upstream's changes quietly invalidated, like a "sanity
     check" pinning old buggy behavior that upstream just fixed; look for
     failures caused by the merge itself, not just conflicted files, and fix
     the test/root cause rather than skipping it)
   - `bin/rubocop`
   - `bundle exec erb_lint app/**/*.erb -a` for any touched `.erb` files
   - `bin/brakeman --no-pager`

   Only proceed once everything is clean.

7. **Commit and push:**
   ```
   git commit --no-edit   # if the merge commit isn't already made
   git push origin main
   ```

8. **Summarize** what was merged, call out any product/design judgment calls
   you made while resolving conflicts (not just "resolved X files"), and note
   anything you deliberately left for the user to weigh in on.
