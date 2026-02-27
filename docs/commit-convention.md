# Commit Convention

Use English Conventional Commits for all new commits.

## Subject format

`<type>(<scope>): <description>`

- `type`: `feat|fix|docs|refactor|perf|test|chore|style|build|ci`
- `scope`: optional, lowercase
- `description`: imperative, lowercase start, no trailing period
- Keep subject <= 72 chars

## Examples

- `fix(pairing): support legacy macos certificate import`
- `fix(network): avoid false paired state downgrade`
- `chore(release): prepare v1.0.3`

## Local automation

This repo includes:

- `.gitmessage`: commit message template
- `.githooks/commit-msg`: commit subject validator

Recommended setup (run once per local clone):

```bash
git config core.hooksPath .githooks
git config commit.template .gitmessage
```
