# AUTONOMOUS-RUN.md

Operating manual for running the hardening work **unattended**.

Supersedes the `HUMAN CHECKPOINT` structure in `HARDENING-PLAN.md`. Task IDs
(T-1xx, T-2xx …) still refer to that document; this file replaces *how* they are
gated.

> **Scope note.** This assumes the MCP server and Godot plugin are **not being
> run** — this is pure repository work. Nothing here authorises pointing the tool
> at a real Godot project unattended.

---

## 1. The core idea

Autonomy is not the removal of verification. It is the replacement of a *human*
oracle with a *machine* one. The original plan needed checkpoints for two reasons:

1. there was no automated way to tell whether a GDScript change was even valid
2. three tasks were undecided judgment calls

Both are now fixed — the harness below is the oracle, and `DECISIONS.md` answers
the judgment calls up front. The checkpoints can go.

**Autonomous means uninterrupted, not unreviewed.** You still read the diff at the
end. Thirty clean single-task commits reviewed in one sitting is a completely
different experience from being interrupted five times mid-run.

---

## 2. The harness

Four oracles, all runnable by the agent, all wired into CI.

| Oracle | Command | Covers |
|---|---|---|
| Type check | `npx tsc --noEmit` | compile-level TS correctness |
| Unit tests | `npx vitest run` | T-103, T-201, T-202, T-203, T-204, T-205 |
| Parity | `node server/scripts/check-parity.mjs` | manifest ↔ handler drift, T-301, T-501 |
| Invariants | `node server/scripts/check-invariants.mjs` | T-101, T-102, T-104, T-105, T-106, T-209 |
| GDScript syntax | `gdparse` over `addons/` | any GDScript edit |
| GDScript lint | `gdlint addons/` | style (non-blocking initially) |

### Verified baseline

Measured against upstream `328e15f`:

```
check-parity.mjs      →  PASS   173 manifest / 173 handlers / 24 modules
check-invariants.mjs  →  FAIL   0 passed, 14 failed
vitest                →  FAIL   6 passed, 6 failed
gdparse addons/       →  PASS   exit 0
```

**Parity starts green and must stay green.** Any failure there is a regression the
agent introduced, not one it inherited.

**Invariants and vitest start red on purpose.** Those 14 + 6 failures *are* the
work. The run is complete when all four are green.

Each oracle was validated in both directions — deliberately broken code was
confirmed to produce a non-zero exit, and the vitest suite was confirmed to pass
in full against a hardened reference implementation (`reference/godot-bridge.hardened.ts`).
The tests are satisfiable, not aspirational.

### Setup

```bash
cd server && npm ci
pip3 install --break-system-packages "gdtoolkit==4.*"
```

### One-shot gate

```bash
#!/usr/bin/env bash
# scripts/verify.sh — must exit 0 before any commit
set -e
cd "$(dirname "$0")/.."
find addons -name '*.gd' -print0 | xargs -0 gdparse
node server/scripts/check-parity.mjs
node server/scripts/check-invariants.mjs
cd server
npx tsc --noEmit
npx vitest run
```

---

## 3. The loop

For each task in `HARDENING-PLAN.md`, in order:

1. Read the task and its listed file(s).
2. If the premise doesn't match what's on disk → **stop and report**. Do not improvise.
3. Make the change. Nothing else. No opportunistic refactoring.
4. Run `scripts/verify.sh`.
5. If it fails, fix your own change. **Never edit a test, invariant, or CI file to
   make a failure go away.** If you believe a check is genuinely wrong, stop and
   report — do not modify it.
6. Commit: `[T-ID] short description`. One task, one commit.
7. Next task.

Recommended order — front-load the tasks with the strongest oracles:

```
Phase A (fully machine-verified, TypeScript)
  T-202 → T-201 → T-205 → T-203 → T-204 → T-103
Phase B (invariant-verified, GDScript)
  T-101 → T-102 → T-104 → T-105
Phase C (decisions, mechanical)
  D-1/T-106 → D-2/T-209 → D-3/T-301
Phase D (hygiene)
  T-207 → T-208 → T-206 → T-502 → T-504 → T-505 → T-506
```

Phase A is where the agent is most reliable — real tests, immediate feedback.
Phase B changes GDScript, where `gdparse` proves validity but not behaviour;
the invariants carry the semantic weight there.

---

## 4. Containment

### The rule that matters most

**The agent must not be able to weaken its own checks.**

An agent given "make the tests pass" as an objective will eventually edit the
tests. Not maliciously — it's simply the shortest path to the stated goal. Prevent
it structurally rather than by instruction:

- **The token must not carry the `workflows` permission.** A fine-grained PAT
  scoped to this one repository, `contents: write` only. This makes
  `.github/workflows/ci.yml` physically unwritable.
- **Protect the check files.** Branch protection with required status checks, plus
  `CODEOWNERS` on:
  ```
  /.github/workflows/       @you
  /server/scripts/          @you
  /server/test/             @you
  /DECISIONS.md             @you
  /AUTONOMOUS-RUN.md        @you
  ```
- **Run the final verification yourself**, from a clean checkout, rather than
  trusting the agent's summary. A green report and a green build are different
  claims.

### Environment

- **Container, not your host.** Repo mounted; nothing else.
- **Egress allowlist:** `registry.npmjs.org`, `pypi.org`, `github.com`. Enough to
  install and build, not a comfortable exfiltration path.
- **No credentials in the environment** beyond the scoped PAT. No SSH agent
  forwarding, no cloud tokens, no `.env`.
- **Agent works on a branch** (`harden/phase-a`, …), never on `master`.

### Blast radius, honestly assessed

With the MCP not running, the worst realistic outcome is a bad commit on a branch
in a fork you control. That's recoverable with `git reset`. The residual risk is
narrower than it looks: **an agent silently introducing a vulnerability while
making the checks pass.** The invariants and the final human diff review are what
address that, and neither is optional.

---

## 5. What is still not autonomous

Two things. Be honest about them rather than pretending the harness covers them.

- **T-401 — runtime IPC redesign.** Out of scope per `DECISIONS.md`. It is a design
  change, and handing an under-specified design task to an unattended agent
  produces confident, plausible, wrong architecture.
- **End-to-end "does the plugin actually work in Godot."** No harness here
  substitutes for enabling the plugin once and watching it connect. `gdparse`
  proves the GDScript is valid, not that `EditorInterface` behaves as assumed.
  Budget one session at the end, against a throwaway project.

---

## 6. Definition of done

- [ ] `scripts/verify.sh` exits 0 from a clean checkout
- [ ] `check-invariants.mjs` — 14/14 passed
- [ ] `vitest` — 12/12 passed
- [ ] `check-parity.mjs` — green, tool count matches `DECISIONS.md` D-3 (expect 156)
- [ ] CI green on the branch
- [ ] One commit per task ID, no squashing
- [ ] Human has read the full diff
- [ ] Plugin enabled once in a throwaway Godot project and confirmed to connect
