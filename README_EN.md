# DeepSeek Harness — macOS Desktop Shell

> An unofficial Tauri 2 desktop shell for [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness), focused on macOS Intel (x86_64).

This repository provides a native macOS desktop application for DeepSeek Harness.

It does **not modify or fork the core Harness architecture**. Instead, it packages the existing `dsh web` runtime together with a portable Node.js runtime and launches it from a Tauri 2 desktop application.

The goal is to provide a lightweight `.app` distribution that runs DeepSeek Harness as a native macOS application rather than requiring users to start `dsh web` manually and open it in a browser.

> This is an independent, unofficial distribution. It is not an official DeepSeek product.

## Preview

### Desktop Application

![DeepSeek Harness desktop interface](docs/images/desktop-overview.jpg)

### **About Window**

![DeepSeek Harness about window](docs/images/about-window.png)

## Download

Latest release: **v0.1.2-alpha.2** (desktop shell shows 0.1.2)

Bundled DeepSeek Harness: `dsh-v0.1.2-alpha.2`

- [GitHub Release v0.1.2-alpha.2](https://github.com/Suxinljh/dsh-macOS-intel/releases/tag/v0.1.2-alpha.2)

The current release provides macOS builds for Intel / x86_64 in two forms:

- `DeepSeek.Harness.Intel-0.1.2_x64.dmg` — the desktop app. Open it and drag `.app` into `Applications`.
- `dsh-0.1.2-macos-x64.pkg` — a command-line installer. It installs Harness together with a bundled Node runtime under `/usr/local/dsh` and exposes the `dsh` command at `/usr/local/bin/dsh`.

## How It Works

The desktop application is essentially a native shell around the existing Harness web runtime:

```text
DeepSeek Harness.app
│
├── Tauri 2 / Rust launcher
│
├── Bundled Node.js runtime
│
└── Harness runtime
    ├── dsh web
    ├── apps/web/dist
    └── required runtime dependencies
```

When the application starts:

```text
Tauri Application
       │
       ▼
Start bundled Node.js
       │
       ▼
dsh web --host 127.0.0.1 --port 0 --no-open
       │
       ▼
Local HTTP server
       │
       ▼
Tauri WebView
       │
       ▼
http://127.0.0.1:<port>
```

The server listens only on the local loopback interface.

The desktop shell uses port `0` by default, allowing the operating system to assign an available port and avoiding conflicts with existing local services.

## Repository Structure

```text
dsh-macOS-intel/
│
├── docs/
│   └── images/
│       ├── desktop-overview.jpg
│       └── about-window.png
│
├── scripts/
│   ├── build-tauri-macos.sh
│   ├── gen-icon.py
│   └── build-dmg.sh
│
├── src-tauri/
│   ├── icons/
│   │   ├── icon.icns
│   │   └── icon.png
│   │
│   ├── src/
│   │   ├── lib.rs
│   │   └── main.rs
│   │
│   ├── capabilities/
│   │   └── default.json
│   │
│   ├── gen/
│   │   └── schemas/
│   │
│   ├── Cargo.toml
│   ├── Cargo.lock
│   ├── build.rs
│   └── tauri.conf.json
│
├── ui-stub/
│   └── index.html
│
├── package.json
├── package-lock.json
├── package-macos-x64.sh
├── .gitignore
└── README.md
```

The repository only contains the desktop shell and its build scripts.

The official DeepSeek Harness source code is intentionally kept outside this repository.

During development, the build script reads a local checkout of the official Harness repository and packages the required runtime files into the Tauri application.

## Relationship With DeepSeek Harness

This project is designed as a distribution layer rather than a replacement implementation.

```text
Official DeepSeek Harness
        │
        │  dsh web
        ▼
Local Harness Web Runtime
        │
        ▼
Tauri 2 Desktop Shell
        │
        ▼
DeepSeek Harness.app
```

The core Harness source remains maintained by the official project.

This repository only provides:

- macOS desktop packaging
- Tauri application lifecycle
- bundled Node.js runtime
- local `dsh web` process management
- WebView integration
- macOS application resources
- build and packaging scripts

No changes to the Harness application architecture are required.

## Requirements

The current build targets:

- macOS
- Intel / x86_64
- Node.js 22 for building
- Rust
- Xcode Command Line Tools
- A local checkout of the official DeepSeek Harness repository

Install Xcode Command Line Tools if necessary:

```bash
xcode-select --install
```

Install Rust from:

[https://rustup.rs](https://rustup.rs/)

The application itself includes its own Node.js runtime, so Node.js is not required by the end user after the application has been packaged.

## Build

Clone this repository and install the dependencies:

```bash
npm install
```

By default, the build script expects the official Harness repository to be available at a predefined local path.

You can explicitly specify the location:

```bash
CORE_REPO=/path/to/deepseek-harness \
bash scripts/build-tauri-macos.sh
```

### Standard build

```bash
bash scripts/build-tauri-macos.sh
```

### Rebuild Harness before packaging

```bash
bash scripts/build-tauri-macos.sh --rebuild
```

### Conservative runtime trimming

```bash
bash scripts/build-tauri-macos.sh --trim
```

### Debug build

```bash
bash scripts/build-tauri-macos.sh --debug
```

The generated application is located at:

```text
src-tauri/target/x86_64-apple-darwin/release/bundle/macos/
```

### Building the DMG (with background image and icon layout)

Install dmgbuild first:

```bash
pip3 install dmgbuild
```

Then run:

```bash
bash scripts/build-dmg.sh
```

The script produces `dist/DeepSeek.Harness.Intel-<version>_x64.dmg` from the built `.app`.
The background image and icon layout are written directly into `.DS_Store` by dmgbuild,
so no Finder automation is needed and the result is reproducible.

## Running

Open the generated:

```text
DeepSeek Harness.app
```

The application will:

1. Locate the bundled Node.js runtime.
2. Locate the packaged Harness runtime.
3. Start `dsh web`.
4. Let the operating system assign an available local port.
5. Wait until the web server is ready.
6. Open the local server inside the Tauri WebView.
7. Stop the Node.js process when the application exits.

No external browser is required.

## Runtime Data

The desktop shell does not package the developer's local Harness data into the application.

It does not intentionally include:

- local conversation history
- credentials
- plugin cache
- personal profiles
- local `~/.dsh` contents
- development machine configuration

The packaged application currently inherits the user's `HOME` environment when launching the Harness runtime.

This means the underlying Harness runtime may access the user's existing `~/.dsh` data, depending on the behavior of the current Harness version.

Runtime logs are stored under:

```text
~/.dsh/logs/
```

For example:

```text
dsh-server-stdout.log
dsh-server-stderr.log
dsh-server-desktop.log
```

Runtime data isolation can be further improved in a future version by assigning the desktop application its own application data directory.

## Packaging Approach

The application bundles three main components:

```text
DeepSeek Harness.app
│
├── Tauri application
│
├── Node.js runtime
│
└── Harness runtime
    ├── CLI runtime
    ├── Web frontend
    └── required dependencies
```

The Harness runtime is packaged separately from the source repository.

Temporary packaging resources such as:

```text
src-tauri/resources/app.tar.gz
src-tauri/resources/runtime/
```

are generated during the build process and are excluded from Git.

This keeps the repository lightweight while allowing the build process to generate a self-contained desktop application.

## Intel Support

The current release is primarily designed for Intel Macs:

```text
x86_64-apple-darwin
```

Apple Silicon Macs may be able to run the Intel application through Rosetta, but Apple Silicon is not the primary target of this repository.

A future version could provide:

- Intel x86_64
- Apple Silicon arm64
- Universal macOS builds

depending on the needs of the upstream project.

## Current Status

This project is currently an independent desktop distribution experiment.

The main questions for upstream integration are:

- Is a Tauri-based macOS shell an acceptable distribution approach?
- Should the desktop shell live in the official Harness repository or remain a separate repository?
- Is Intel macOS support useful enough to maintain?
- Should Apple Silicon / Universal builds be added?
- What runtime data directory should the desktop distribution use?

The implementation is intentionally kept separate from the core Harness code so that it can be evaluated independently.

## Upstream Proposal

This repository was created to explore whether the existing DeepSeek Harness web application could also be distributed as a native macOS application.

The implementation does not require architectural changes to Harness.

If this approach is considered useful by the maintainers, the desktop shell can be adapted to the preferred upstream repository structure and submitted as a PR.

## Changelog

### v0.1.2

- Aligned with the official DeepSeek Harness release `dsh-v0.1.2-alpha.2`; the desktop shell version moved from `0.1.1` to `0.1.2`.
- Adapted to the new browser-session authentication: `dsh web` now prints its ready address with a `?token=...` query, and the server only accepts requests that carry that token or the cookie it is exchanged for. The desktop shell now parses the full ready URL and loads the token-carrying address in the WebView — the previous bare origin is rejected on the first request.
- Raised the readiness timeout from 30 to 60 seconds: newer harness builds print the ready line only after the profile's Loader tree settles, and the first launch also has to initialize `~/.dsh/profiles`.
- Fixed the default `CORE_REPO` path in `scripts/build-tauri-macos.sh`. It pointed outside the repository, so the build failed outright unless the path was passed explicitly.
- Added the command-line installer artifact `dsh-<version>-macos-x64.pkg`.

> Known issue: if a `dsh` process is killed abruptly, a stale `~/.dsh/profiles/node_modules.lock` can remain and make the next launch time out waiting for the writer lock. Removing that `.lock` file restores normal startup.

### v0.1.1

- Aligned the desktop shell version with the official DeepSeek Harness release tag (`dsh-v0.1.1-rc.2`); the desktop shell version was adjusted from `0.2.0` to `0.1.1`.
- Fixed an issue where the desktop app opened the system default browser on launch: newer harness `dsh web` opens a browser by default. The desktop shell now passes `--no-open` when starting `dsh web`, so the UI is served exclusively by the Tauri WebView and no external browser is launched.

### v0.2.0

- Improved DMG icon layout and background image by writing `.DS_Store` programmatically with `dmgbuild` for reproducible results.

### v0.1.0

- First runnable release: Tauri 2 desktop shell + bundled Node.js runtime + DeepSeek Harness runtime, with the UI rendered in the Tauri WebView.

## Disclaimer

This project is **not an official DeepSeek product** and is not affiliated with or endorsed by DeepSeek.

It is an independent macOS desktop shell built around the existing open-source DeepSeek Harness project.

For the official Harness project, source code and documentation are available at:

https://github.com/deepseek-ai/deepseek-harness
