# Working in this repository

Rules for anyone changing this repository, human or agent. Build and test commands are in `README.md` and the `Makefile`; this file covers how the work is organised.

## One task, one worktree

Each task gets its own git worktree and its own branch. The main checkout stays on `main` and is not used for task work.

```sh
git fetch origin main
git worktree add -b <branch> ../lists-<branch> origin/main
```

- Name the branch after the change (`fix-repeat-end-date`, `android-drag-reorder`), and put the worktree next to the repository as `../lists-<branch>`.
- Build outputs (`core/target`, `apple/build`, `android/app/build`, generated bindings) are untracked and belong to the worktree, so a fresh worktree needs its own `make apple` or `make android` before the apps can be started.
- Do not switch branches inside a worktree to pick up another task, and do not edit files of one task from the worktree of another.
- Remove the worktree after its branch is merged: `git worktree remove ../lists-<branch>`.

## Interfaces run hidden during testing

A test run must not take the keyboard focus, put a window in front of the person at the machine, play sound, or disturb another process that uses the same emulator or app.

### macOS

Start the built app in the background and hidden, never with `make apple-run` or a plain `open`:

```sh
make apple
open -g -j apple/build/Build/Products/Debug/Lists.app
```

`-g` keeps the app from coming to the foreground, `-j` starts it hidden. Check the result through logs, the data folder (`cargo run --example lists` in `core/`) or the accessibility tree rather than by bringing the window forward. Quit the instance you started when the check is done, and leave an instance you did not start alone.

Checks that cannot be made without visible interaction (the global shortcut, the share sheet, drag and drop, a notification appearing) are not run silently: say so and leave them to the person.

### Android

Start the emulator without a window, sound or boot animation, and drive it through `adb`:

```sh
emulator -avd shareding_api36 -no-window -no-audio -no-boot-anim
adb -s <serial> install -r android/app/build/outputs/apk/debug/app-debug.apk
```

- Always address the emulator by serial (`adb devices`, then `adb -s <serial> …`). An emulator or device that was already attached belongs to someone else: do not install onto it, restart it or kill it.
- When the AVD is already in use, start a second instance with `-read-only` instead of reusing the running one.
- Take state from `adb shell`, `adb logcat`, `uiautomator dump` and `adb exec-out screencap`, not from a visible window.
- Shut down the emulator you started: `adb -s <serial> emu kill`.

## Specifications are updated with the code

The specifications in `docs/specs/` are the contract: `product.md`, `sync.md`, `caldav.md` and `import.md`. A change in behaviour is not finished until the specification describes the new behaviour.

- Update the specification in the same branch as the code, and before the code when the change is a new requirement rather than a fix.
- A new requirement or scenario gets its own identifier in the existing numbering; tests refer to it.
- When the change affects what a user sees or how the system is built, update `docs/usage.md`, `docs/architecture.md` and `README.md` as well.
- If the code and the specification disagree, find out which one is wrong before changing either. Do not edit the specification only to match what the code happens to do.

## Changes come from investigation, not from guesses

Every change starts with finding out how things work now and ends with evidence that the change does what it claims.

1. Reproduce the problem, or for a new feature read the code and the specification it touches.
2. State the hypothesis: what is wrong or what is needed, and what observation would show it.
3. Test the hypothesis with something that can fail: a test, a run of the app, a log line, a query against the data folder.
4. Change the code only after the hypothesis is confirmed. When it is refuted, drop it and form the next one; do not stack speculative fixes.
5. Verify the result the same way, then run `make test` and `make lint`.

A conclusion put together from reading files is still a hypothesis until it has been traced end to end or reproduced. Report it as unverified, and say which checks were run and which were not.
