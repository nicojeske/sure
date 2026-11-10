# Devcontainer and parallel worktrees

How to run Rails, tests and checks when Ruby lives only in the devcontainer, and
how to keep several worktrees from colliding. The checks themselves are listed in
[development and verification](development.md#before-opening-a-pull-request).

## Running commands

The host has no Ruby. Run every Rails, Ruby and npm command in the app container,
`devcontainer-app-1`, which mounts the repository at `/workspace`. A path under the
repository maps one-to-one: a worktree at `.claude/worktrees/<name>` is
`/workspace/.claude/worktrees/<name>` in the container.

```sh
WT=/workspace/.claude/worktrees/<name>   # or /workspace for the main checkout
docker exec -w $WT devcontainer-app-1 bash -lc 'bin/rails test test/models/rule_test.rb'
```

Git commands in a worktree print `fatal: not a git repository` inside the
container, because the worktree's `.git` file points at a host path the container
doesn't mount. It's harmless; run git itself on the host.

## One test database per worktree

Concurrent test runs that share a database corrupt each other. Give each worktree
its own database through `POSTGRES_DB`, and pass the same name on every command:

```sh
DB=sure_test_<worktree-name>
docker exec -w $WT -e RAILS_ENV=test -e POSTGRES_DB=$DB devcontainer-app-1 bash -lc 'bin/rails db:prepare'
docker exec -w $WT -e POSTGRES_DB=$DB -e PARALLEL_WORKERS=4 devcontainer-app-1 bash -lc 'bin/rails test'
```

- Parallel test workers use `$DB_0`, `$DB_1`, …. `bin/rails db:drop` removes only
  `$DB`, so drop the worker databases too when the worktree is done:

  ```sh
  docker exec devcontainer-app-1 bash -lc 'for db in $(PGPASSWORD=$POSTGRES_PASSWORD psql -h db -U postgres -Atc "select datname from pg_database where datname ~ '"'"'^'"$DB"'(_[0-9]+)?$'"'"'"); do PGPASSWORD=$POSTGRES_PASSWORD psql -h db -U postgres -qc "drop database \"$db\""; done'
  ```

- Several worktrees testing at once share one 16-core machine: cap each run with
  `PARALLEL_WORKERS=4`, or `DISABLE_PARALLELIZATION=true` for focused runs and
  system tests.
- Apply a new migration to your worktree's test database only
  (`RAILS_ENV=test POSTGRES_DB=$DB bin/rails db:migrate`). The container's schema
  dump reformats every `check_constraint` line in `db/schema.rb`; commit only the
  lines your migration adds and the version bump.

## Assets

A fresh worktree has no compiled CSS, and every page then fails with
`tailwind.css not found`. Build it once per worktree, and again after merging view
or CSS changes and before running system tests:

```sh
docker exec -w $WT devcontainer-app-1 bash -lc 'bin/rails tailwindcss:build'
```

## Checks

Use the commands from the pre-PR checklist as written. For JavaScript that is
`npm run lint`; `npx biome check` also runs the formatter and reports formatting
differences already present on `main`.

## Removing a worktree

The container writes build output into the worktree as root, so `git worktree
remove` can fail with `Permission denied`. Remove the directory from inside the
container, then prune:

```sh
docker exec devcontainer-app-1 rm -rf /workspace/.claude/worktrees/<name>
git worktree prune
```
