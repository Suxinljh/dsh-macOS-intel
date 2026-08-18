# DeepSeek Harness — macOS Desktop Shell (Tauri 2)

> I built a Tauri 2 macOS desktop shell for DeepSeek Harness, primarily targeting Intel Macs.
>
> The implementation does not modify the core Harness architecture. It bundles the existing `dsh web` runtime and a portable Node.js runtime, then launches it locally from a native Tauri application.
>
> Would the maintainers be interested in accepting this as an optional macOS desktop distribution?
>
> I can submit a PR if this direction is acceptable.

This repository contains an optional macOS desktop shell for [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness), built with **Tauri 2**. The primary target is **x86_64 / Intel macOS**.

The shell does **not** modify the core Harness architecture. It packages the existing `dsh web` runtime together with a portable Node.js runtime. On launch, a native Rust/Tauri process starts the local `dsh web` server, and the Tauri WebView loads the local UI over `http://127.0.0.1:<port>`.

> The `.app` distribution is intended to replace the legacy `package-macos-x64.sh` (`.pkg` installer) as the primary desktop distribution format.

## Interface Preview

### DeepSeek Harness Desktop Interface

![DeepSeek Harness desktop interface](docs/images/desktop-overview.jpg)

### About Window

![DeepSeek Harness about window](docs/images/about-window.png)

## Architecture

```text
┌──────────────────────────────────────────────────────────┐
│  DeepSeek Harness.app (Tauri 2, x86_64)                   │
│                                                          │
│  Contents/                                               │
│    MacOS/dsh                ← compiled Rust launcher      │
│    Resources/                                             │
│      runtime/              ← bundled Node.js (x64)       │
│      app/                  ← dsh runtime slice            │
│        apps/cli/lib/bin.js ← dsh CLI entry point          │
│        apps/web/dist/      ← built frontend assets        │
│        node_modules/       ← portable runtime dependencies│
│                                                          │
│  Startup flow (Rust setup):                               │
│   1. Resolve the application Resources directory          │
│   2. Spawn: node runtime/bin/node app/apps/cli/lib/bin.js│
│        web --host 127.0.0.1 --port <port>                 │
│   3. Read the "dsh web: http://127.0.0.1:<port>"          │
│      readiness line and resolve the actual port            │
│   4. Create a WebView window for the local URL             │
│   5. Send SIGTERM to the Node child on application exit    │
└──────────────────────────────────────────────────────────┘
```

`dsh web` runs a local `node:http` server. The default server address is `127.0.0.1:3080`, although the desktop shell uses port `0` by default so the operating system can select an available port. `frontend-static` serves `apps/web/dist`, while `apiproxy` provides the `/api` routes.

The command does not automatically open a browser, which makes it suitable for a native WebView shell. The server is bound to the loopback interface and the WebView uses the same local origin for the UI and API requests.

## Prerequisites

- Intel macOS (`x86_64`). Apple Silicon may run the x86_64 build through Rosetta, but this project is built for Intel Macs by default.
- Xcode Command Line Tools:

  ```bash
  xcode-select --install
  ```

- A stable Rust toolchain: <https://rustup.rs>
- Node.js 22 for the build and packaging scripts. The packaged application uses the bundled Node runtime at runtime.
- The official `deepseek-harness` repository. It is intentionally maintained outside this repository and is not included in the GitHub submission copy.
- `@tauri-apps/cli`, installed through the local package manifest.

## Building

Run the following commands from the repository root.

```bash
# Install the Tauri CLI dependencies.
npm install

# Build the release .app using existing core repository build artifacts.
bash scripts/build-tauri-macos.sh

# Reinstall dependencies and rebuild the core Harness before packaging.
bash scripts/build-tauri-macos.sh --rebuild

# Use the conservative runtime trimming mode.
bash scripts/build-tauri-macos.sh --trim

# Build a debug application.
bash scripts/build-tauri-macos.sh --debug

# Specify the location of the official DeepSeek Harness repository.
CORE_REPO=/path/to/deepseek-harness bash scripts/build-tauri-macos.sh
```

The release application is generated at:

```text
src-tauri/target/x86_64-apple-darwin/release/bundle/macos/DeepSeek Harness.app
```

The build script generates `src-tauri/resources/app.tar.gz` and `src-tauri/resources/runtime` as temporary packaging resources. These generated resources are ignored by Git and should not be committed.

## Creating a DMG

The default build produces the `.app` bundle. On macOS, a DMG can be created with the Tauri-generated `bundle_dmg.sh` script and the system `hdiutil` tool.

Use a clean source directory containing only the application bundle:

```bash
APP="src-tauri/target/x86_64-apple-darwin/release/bundle/macos/DeepSeek Harness.app"
SRC="$(mktemp -d /tmp/dsh-dmg-source.XXXXXX)"
cp -a "$APP" "$SRC/"

src-tauri/target/x86_64-apple-darwin/release/bundle/dmg/bundle_dmg.sh \
  --skip-jenkins \
  --no-internet-enable \
  --app-drop-link 540 140 \
  "src-tauri/target/x86_64-apple-darwin/release/bundle/macos/DeepSeek Harness_0.1.0_x64.dmg" \
  "$SRC"

rm -rf "$SRC"
```

The DMG is a local test distribution unless the application has been code-signed and notarized.

## Running

Open the generated `DeepSeek Harness.app` directly.

The Rust launcher:

1. Resolves the bundled Node.js runtime and application archive.
2. Extracts the runtime archive into the local desktop runtime directory when needed.
3. Starts `dsh web` on a dynamically assigned loopback port.
4. Waits for the server readiness message.
5. Creates the Tauri WebView window after the server is ready.
6. Terminates the local Node process when the desktop application exits.

Runtime logs are written to:

```text
~/.dsh/logs/dsh-server-stdout.log
~/.dsh/logs/dsh-server-stderr.log
~/.dsh/logs/dsh-server-desktop.log
```

The port can be overridden with the `DSH_PORT` environment variable. The default desktop configuration uses port `0` to avoid conflicts with another local service.

## Runtime Data Isolation

The packaging process does not copy the developer's local `~/.dsh` directory, conversation history, plugin cache messages, credentials, or local profiles into the `.app` bundle.

The current launcher inherits the user's `HOME` environment and the core Harness may use the current user's `~/.dsh` directory at runtime. A future production distribution should consider assigning a dedicated application data directory under:

```text
~/Library/Application Support/DeepSeek Harness/
```

This would prevent the desktop shell from reading or writing the user's existing command-line Harness data.

## Dependency Trimming and Optimization

- **Conservative trimming (`--trim`)**: preserves the relative pnpm workspace links required by the current runtime layout, while removing non-runtime directories such as documentation, website files, examples, Python sources, root-level assets, build caches, and landlock test materials. The frontend assets under `apps/web/dist/assets` are preserved.
- **Why not `pnpm deploy --prod` yet**: the current workspace contains runtime peer and override dependencies that are not always inferred by `pnpm deploy`. For example, packages such as `@deepseek-ai/cordis-plugin-group` and `@deepseek-ai/cosmokit` can be omitted from the deployed closure. The packaging script therefore prioritizes a verified, relocatable runtime tree over an aggressively trimmed but incomplete dependency graph.
- **Archive-based resource packaging**: the runtime app tree is stored as `app.tar.gz` so the Tauri bundler does not recursively walk pnpm symlink cycles.
- **Node.js runtime trimming**: npm, npx, headers, and documentation are removed from the bundled Node.js distribution. The Node executable and runtime libraries remain available.
- **Startup performance**: the server binds to an operating-system-assigned port, and the Rust launcher loads the WebView immediately after receiving the readiness line instead of polling a fixed port.
- **Rust binary size**: the release profile uses size optimization, LTO, a single code-generation unit, and symbol stripping.

## Signing and Notarization

Local builds are suitable for development and testing. For public distribution, configure an Apple Developer ID Application certificate, code-sign the application, notarize it with Apple, and staple the notarization ticket.

The relevant Tauri configuration is in:

```text
src-tauri/tauri.conf.json
```

Typical public distribution requirements include:

- Apple Developer account access;
- Developer ID Application signing identity;
- Hardened Runtime and appropriate entitlements;
- `codesign` for the `.app` bundle;
- `notarytool` for Apple notarization;
- `stapler` to attach the notarization ticket;
- optional DMG signing after the signed application has been packaged.

## Repository Scope

This repository is intentionally limited to the optional macOS desktop shell. The official DeepSeek Harness source tree is not vendored here. Set `CORE_REPO` to a local checkout of the official repository when building.

Generated dependencies, runtime archives, Tauri target directories, old installers, local verification output, and WorkBuddy metadata are excluded by `.gitignore`.

## Maintainer Feedback

This implementation is being proposed as an optional macOS distribution for DeepSeek Harness. Feedback from the maintainers would be welcome regarding:

- whether a Tauri-based desktop shell is an acceptable direction;
- whether the shell should live in the main repository or a separate repository;
- whether Intel-first support is useful, and whether an Apple Silicon or universal build should be added;
- the preferred runtime data isolation and release-signing model.

If this direction is acceptable, I would be happy to submit a PR for review.
