# Device metrics (M1–M6, E1–E3)

The frozen device metrics of the HarmonyOS port, carried from epic 016 (2026-10-24, frozen by the maintainer; source: the untracked `.issues-local/2026-10-24-dsh-hmos-native/00-epic-sot.md` §4–§5, §8 of this fork's working checkout). They apply unchanged to every upstream merge (skill `hmos-upstream-merge`). Hazards and gotchas are in [KNOWN-ISSUES.md](KNOWN-ISSUES.md); how to run the recipe is in [README.md](README.md).

Device roots on the PC (README "Second device root"):

| Root | Owner | Who writes it |
|---|---|---|
| `/data/storage/el2/base/dsh` (default) | the maintainer (his daily dsh) | the harmonybrew package `dsh`, released by homebrew-hmos `hmos-bundle` |
| a second root, e.g. `/data/storage/el2/base/dsh-dev` | whoever verifies the build (`DSH_OH_OWNER`, e.g. `nan`) | `deploy.sh` and `smoke.sh` with `DSH_OH_ROOT` set, during an upstream merge |

M1, M2, M3, M5 and M6 are measured on a second root, never on the default root. The release's own device smoke is homebrew-hmos's. E1–E3 are human.

## Machine metrics

All device readings go over `ssh hmos` under the self-signed node with the root's `TMPDIR`.

| ID | Measures | Command | Pass | Judge |
|---|---|---|---|---|
| M1 | Native addons load from the tree and are correctly signed | `smoke.sh` → `device-smoke.cjs` on the device; per signed ELF, `llvm-readelf -l` in `build-natives.sh` / `pack-tree.sh` | `M1 SMOKE-SUMMARY ok=5 fail=0` (require-builtin, flock, pty, koffi, rg); every `mapped=` / `path=` inside `<root>/tree`; every LOAD segment offset ≡ vaddr (mod 4K) after signing (`readings.txt`, `elf-sweep.txt`) | orchestrator |
| M2 | dsh starts on the device | `<root>/bin/dsh --profile headless --help` (in `smoke.sh`) | `M2 exit=0 no-usable-native-binding=no` | orchestrator |
| M3 | Keyless session persistence | `smoke.sh --m3`: replays `bash-tool-turn` and `fs-write` through `dsh-llm-replay` (no key, no network) | both `M3 <scenario> verdict=ok`, where ok = dsh exit 0 **and** every tool result `isError=false` **and** `session.lock` present beside the log. Exit 0 alone is not enough: headless exits 0 when the shell is missing | orchestrator |
| M4 | In-repo gates | the in-repo gates of skill `hmos-upstream-merge` (section 6) | green, or every red classified (also red on the pristine tag ⇒ `upstream`) | orchestrator |
| M5 | The recipe re-runs from empty | remove the root, deploy, `smoke.sh --m3` | M1, M2, M3 pass in one go | orchestrator |
| M6 | Web, search and terminal on the device | `smoke.sh --m6` | all of: `M6 rg verdict=ok`, `M6 fs-glob-sampling verdict=ok`, `M6 pty-tools-sandbox-backend verdict=ok`, `M6 terminal verdict=ok` (`TERM-SUMMARY ok=8 fail=0`), `M6 sharp ok`, `M6 web verdict=ok` | orchestrator |

M6 criteria as refined on 2026-10-24 (wording, not targets): "HTTP 200" means anonymous `GET /` 401 → startup-token login 303 → `GET /` with the cookie 200 (connection auth is by design); "rg returns a hit" means the placed `rg` hits a fixed match on the device **and** the glob tool replay `fs-glob-sampling` lists the fixture tree; "the terminal reads back" means the terminal-tool replay `pty-tools-sandbox-backend` reads `PTY_M6_OK` through the real PTY stack (`m6-replay.patch.yml`) **and** `m6-terminal.mjs` opens, echoes, resizes and closes `sh` and `zsh` terminals (8/8). The repository has no recorded session that calls the grep tool or a real PTY, hence the replay swaps.

### Per upstream merge

| Rule | Effect on the metrics |
|---|---|
| Every upstream merge | M1, M2, M3, M6 |
| Recipe changed since the last verified merge | M5 as well; a run whose deploy started from an empty root already covers it |
| The merge changes `deploy.sh`, `smoke.sh`, `push-env.sh`, `lib.sh` or `dsh-web.zsh` | review the change before running it on the device |
| Evidence | the `smoke.sh` output in the merge record; `M0 … commit=` must equal the merged head |

The device check of a merge passes when every line above is present and ok for the merged head.

## Human exits

| ID | What | How | Pass |
|---|---|---|---|
| E1 | Real API session | on the device, `dsh --profile headless "…"` with a shell tool call; `DEEPSEEK_API_KEY` typed by the maintainer in the device session (never pushed by an agent) | tool result non-empty, session ends normally. Note: headless has no sandbox backend on the device, so its bash tool is refused under workspace-write; run it with a full-access profile (`oh-accept`) or record the choice |
| E2 | oh-driven eval | the `oh-accept` profile runs one eval prompt; needs the maintainer's `oh serve` (UDS `--sock /data/storage/el2/base/oh/atd.sock`) | runs to the end |
| E3 | Web UI session | the device browser (`aa start -b com.huawei.hmos.browser`) opens the device's dsh web with the tokened URL; one session with shell, terminal and search | runs, no native or platform error |

On a second root these need the maintainer: a key in `<root>/env` via `push-env.sh --root … --allow-credentials` from a file holding only that key, and `DSH_OH_WITH_OH=1` for E2.

## Reference readings (epic 016, oh-vm + MOR-M1, 2026-10-24…26)

Regression anchors, not targets. Durations are wall clock on a shared machine.

| Step / metric | Reading |
|---|---|
| `pnpm install --frozen-lockfile` | 38.6 s (warm pnpm store) |
| `build-natives.sh` | < 1 min of compiling + rg 53 s (3 cores); once waited ~8 min for another session's cargo slot |
| `make-node.sh` | 5 s; node sha256 identical on VM and device (`e11de9ce…`), `.permission` unchanged by signing |
| `pack-tree.sh` | 7 min 54 s total; `build:artifacts --profile official` 248 s cold, 51–69 s warm (before upstream #7435 raised typecheck heaps to 8 GiB) |
| Tree | 952–968 MB, ~373 dependencies; ELF sweep keeps 5 signed, removes 4 unsigned |
| `deploy.sh` | 1 min 48 s – 4 min 23 s (`tar \| ssh` over the bridge); `sha256sum -c` 5/5 |
| M1 | 5/5 (+ rg 15.0.0, PCRE2 JIT available) |
| M2 | exit 0 in 6–8 s, 29 stdout lines, 0 stderr lines |
| M3 | 26–28 s for `smoke.sh --m3` |
| M6 | `smoke.sh --m3 --m6` 1 min 20 s; web start 13 s; `GET /` 39 131 B, title "DeepSeek Harness" |
| Chain, warm caches, no waits | ≈ 12–17 min |
