# macOS Development Launcher

**Date:** 2026-07-20

**Status:** Approved for implementation

## Goal

Provide one repository script that regenerates, builds, and launches the
macOS app while keeping the app process attached to the invoking terminal.
Developers should see the app's stdout and stderr directly and receive its
exit status.

## Interface

The entry point is:

```bash
./scripts/run-macos.sh [app arguments...]
```

It must work regardless of the caller's current directory. Any arguments are
forwarded unchanged to the app executable.

## Execution Flow

The script uses strict Bash error handling and performs these steps in order:

1. Resolve the repository root from the script location.
2. Run the existing `scripts/bootstrap.sh` entry point to require XcodeGen and
   regenerate `App/PatternSpike.xcodeproj` from `App/project.yml`.
3. Build the `PatternSpikeMac` scheme for macOS Debug with `xcodebuild`, using
   `.build/DerivedData` and disabled code signing, matching the verification
   scripts.
4. Require the expected executable at
   `.build/DerivedData/Build/Products/Debug/PatternSpike.app/Contents/MacOS/PatternSpike`.
5. Print the executable being launched and replace the launcher process with
   the app using `exec`.

Direct execution is intentional. `open` and Launch Services are not used
because they do not reliably attach the app's output streams to the terminal.

## Failure Behavior

- Missing XcodeGen uses the existing explicit bootstrap error.
- Project-generation or build failure stops immediately with the originating
  nonzero status.
- A successful build without the expected executable fails with a concise
  launcher-specific error.
- Once launched, the app's signals, stdout, stderr, arguments, and exit status
  pass directly through the launcher process.

The script does not install dependencies, run tests, clean DerivedData, launch
the iPad app, or background the process.

## Verification

A shell-level test uses temporary command fixtures to prove:

- regeneration precedes the build;
- the exact scheme, destination, DerivedData path, configuration, and signing
  behavior reach `xcodebuild`;
- app arguments are forwarded unchanged;
- generation and build failures stop before launch;
- a missing executable fails explicitly.

Final verification also includes shell syntax checking and a real macOS Debug
build. Generated project and build output must remain ignored.
