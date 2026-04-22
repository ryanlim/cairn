# Claude Code bug: Agent worktree isolation refuses to use a git repo created mid-session

Paste-ready for the [anthropics/claude-code](https://github.com/anthropics/claude-code) issue tracker.

---

## Title

`Agent isolation: "worktree" reports "not in a git repository" when git was initialized after session start`

## Summary

When a Claude Code session is started in a directory that is not yet a git repository, the harness records that fact at startup. If `git init` is then run in that same session, the harness keeps using the cached "not a git repository" flag — so any later `Agent` invocation with `isolation: "worktree"` fails with a misleading error, even though git itself works perfectly in the directory.

## Environment

- Claude Code version: `2.1.117`
- macOS 26.x
- Shell: zsh
- Git version: stock Apple git (works correctly)

## Steps to reproduce

1. In a new terminal, `cd` into a directory that is **not** a git repository.
2. Start a Claude Code session there.
3. Inside the session, run `git init -b main` (and optionally make commits).
4. Verify the repo works: `git rev-parse --git-dir` → `.git`, `git status` → clean, `git worktree add /tmp/test-wt` → succeeds.
5. Ask Claude to dispatch an `Agent` with `isolation: "worktree"`.

## Expected behavior

The harness re-checks the live state of the directory (or invalidates the cached flag when `git init` is observed in tool output) and creates the worktree. Same behavior as if the session had been started in an already-initialized repo.

## Actual behavior

The Agent dispatch fails with:

```
Cannot create agent worktree: not in a git repository and no WorktreeCreate hooks are configured. Configure WorktreeCreate/WorktreeRemove hooks in settings.json to use worktree isolation with other VCS systems.
```

The error is doubly misleading: (a) the directory **is** a git repository, and (b) the suggested workaround (configure hooks) is wrong because the underlying VCS is supported — the harness just doesn't know.

## Confirmation that the cause is a stale cache

The session-start environment block (visible in the assistant's system prompt context) explicitly recorded `Is a git repository: false` at the moment the session started. After `git init`, the live filesystem state changed but that cached flag did not. Subsequent `git worktree` operations issued directly via the `Bash` tool work flawlessly:

```sh
$ git rev-parse --git-dir
.git
$ git worktree add /tmp/test-wt
Preparing worktree (new branch 'test-wt')
HEAD is now at <sha> ...
$ git worktree list
/path/to/repo                d78742d [main]
/tmp/test-wt                 d78742d [test-wt]
```

So git accepts the operation; the harness's pre-flight check is what's wrong.

## Suggested fix

Either:

1. **Re-probe at use-time** when an Agent invocation requests `isolation: "worktree"`, instead of trusting the session-start cache. This is cheapest and self-correcting.
2. **Invalidate the cache** when the harness observes `git init` (or `git clone`) in tool output during the session. More general but heavier to implement.

Option 1 is probably the right call — the worktree feature is invoked rarely enough that an extra `git rev-parse` per invocation is negligible, and it removes a class of "I changed the world after the session started" bugs.

## Workaround (for users hitting this today)

Restart the Claude Code session in the same directory. The new session probes the now-existing git repo at startup and the worktree feature becomes available.

For the duration of the affected session, dispatch agents without isolation; they share the working filesystem. This works fine if the agents' file scopes are kept disjoint, but it lacks the safety net worktrees provide.
