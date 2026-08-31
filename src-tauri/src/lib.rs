// DeepSeek Harness (dsh) — Tauri 2 macOS desktop shell.
//
// Lifecycle:
//   1. Resolve the bundled resource directory (node runtime + dsh app slice).
//   2. Spawn the bundled Node runtime running `apps/cli/lib/bin.js web`.
//   3. Drain node stdout/stderr to ~/.dsh/logs and parse the loopback URL from
//      the "dsh web: http://127.0.0.1:<port>[/?token=...]" ready line.
//   4. Open the main WebView window pointed at the local server.
//   5. On app exit, SIGTERM the Node child for a clean shutdown.
//
// The core Harness architecture is untouched — we only drive the existing
// `dsh web` profile from a native shell.

use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::Mutex;
use std::time::{Duration, UNIX_EPOCH};

use tauri::Manager;

pub struct AppState {
    pub server: Mutex<Option<Child>>,
}

fn dsh_log_dir() -> std::path::PathBuf {
    let base = std::env::var("HOME").unwrap_or_else(|_| ".".to_string());
    let dir = std::path::Path::new(&base).join(".dsh").join("logs");
    let _ = std::fs::create_dir_all(&dir);
    dir
}

fn desktop_runtime_dir() -> PathBuf {
    let base = std::env::var("HOME").unwrap_or_else(|_| ".".to_string());
    Path::new(&base).join(".dsh").join("desktop-runtime")
}

fn unpack_runtime(resource_dir: &Path) -> std::io::Result<PathBuf> {
    let archive = resource_dir.join("app.tar.gz");
    let runtime_dir = desktop_runtime_dir();
    let marker = runtime_dir.join(".dsh-runtime-ready");
    let archive_stamp = std::fs::metadata(&archive).ok().map(|meta| {
        let modified = meta
            .modified()
            .ok()
            .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
            .map(|duration| duration.as_nanos())
            .unwrap_or(0);
        format!("{}:{}", meta.len(), modified)
    });
    if marker.exists() && archive_stamp.as_deref() == std::fs::read_to_string(&marker).ok().as_deref().map(str::trim) {
        return Ok(runtime_dir.join("app"));
    }
    if !archive.exists() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::NotFound,
            format!("bundled app archive missing: {:?}", archive),
        ));
    }
    let _ = std::fs::remove_dir_all(&runtime_dir);
    std::fs::create_dir_all(&runtime_dir)?;
    let status = Command::new("/usr/bin/tar")
        .args(["-xzf"])
        .arg(&archive)
        .arg("-C")
        .arg(&runtime_dir)
        .status()?;
    if !status.success() {
        return Err(std::io::Error::other("failed to unpack dsh runtime archive"));
    }
    if let Some(stamp) = archive_stamp {
        std::fs::write(&marker, format!("{}\n", stamp))?;
    }
    Ok(runtime_dir.join("app"))
}

fn open_log(name: &str) -> std::fs::File {
    let path = dsh_log_dir().join(format!("dsh-server-{}.log", name));
    std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
        .unwrap_or_else(|_| {
            std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open("/dev/null")
                .unwrap()
        })
}

/// Parse the loopback Web URL out of a `dsh web: <url>` ready line.
///
/// Since 0.1.2 the harness authenticates browser sessions: the printed URL
/// carries a `?token=...` query, and the server exchanges it for an auth
/// cookie on the first request. The WebView must therefore load that exact
/// URL — a bare origin is rejected.
fn parse_web_url(line: &str) -> Option<String> {
    const LOOPBACK: &str = "http://127.0.0.1:";
    // Trust only the readiness line; other logs may mention the address.
    let after = line.get(line.find("dsh web: ")? + "dsh web: ".len()..)?;
    let tail = after.get(after.find(LOOPBACK)? + LOOPBACK.len()..)?;
    // Any trailing `(LAN: ...)` summary addresses another host, so stop at the
    // first whitespace.
    let end = tail.find(char::is_whitespace).unwrap_or(tail.len());
    let port: String = tail.chars().take_while(|c| c.is_ascii_digit()).collect();
    if port.is_empty() {
        return None;
    }
    Some(format!("{}{}", LOOPBACK, &tail[..end]))
}

/// Kill the bundled Node server with SIGTERM for a graceful shutdown.
fn stop_server(child: &mut Child) {
    let pid = child.id();
    // std::process::Child::kill() sends SIGKILL; dsh prefers SIGTERM (exit 0),
    // so dispatch it explicitly via /bin/kill.
    let _ = Command::new("/bin/kill")
        .args(["-TERM", &pid.to_string()])
        .status();
}

pub fn run() {
    let app = tauri::Builder::default()
        .setup(|app| {
            let resource_dir = app
                .path()
                .resource_dir()
                .expect("failed to resolve resource dir");

            // Port: 0 lets the OS pick a free port; we read the actual port
            // from node's stdout ready line. Override via DSH_PORT.
            let port_arg: u16 = std::env::var("DSH_PORT")
                .ok()
                .and_then(|p| p.parse().ok())
                .unwrap_or(0);

            let node_bin = resource_dir.join("runtime").join("bin").join("node");
            let app_cwd = unpack_runtime(&resource_dir)?;
            let cli_bin = app_cwd
                .join("apps")
                .join("cli")
                .join("lib")
                .join("bin.js");

            if !node_bin.exists() || !cli_bin.exists() {
                return Err(Box::new(std::io::Error::new(
                    std::io::ErrorKind::NotFound,
                    format!(
                        "bundled dsh runtime missing (node={:?}, cli={:?}). \
                         Rebuild with `pnpm build:app`.",
                        node_bin, cli_bin
                    ),
                )));
            }

            let mut child = Command::new(&node_bin)
                .arg(&cli_bin)
                .arg("web")
                .arg("--host")
                .arg("127.0.0.1")
                .arg("--port")
                .arg(port_arg.to_string())
                // Newer harness `dsh web` auto-opens the system default browser.
                // The desktop shell provides its own Tauri WebView as the UI
                // surface, so suppress the harness's browser launch.
                .arg("--no-open")
                .current_dir(&app_cwd)
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .spawn()?;

            // Drain node stdio to logs and capture the ready URL.
            let (tx, rx) = std::sync::mpsc::channel::<String>();
            if let Some(stdout) = child.stdout.take() {
                let tx = tx.clone();
                let mut log = open_log("stdout");
                std::thread::spawn(move || {
                    for line in BufReader::new(stdout).lines().map_while(Result::ok) {
                        let _ = writeln!(log, "{}", line);
                        if let Some(url) = parse_web_url(&line) {
                            let _ = tx.send(url);
                        }
                    }
                });
            }
            if let Some(stderr) = child.stderr.take() {
                let mut log = open_log("stderr");
                std::thread::spawn(move || {
                    for line in BufReader::new(stderr).lines().map_while(Result::ok) {
                        let _ = writeln!(log, "{}", line);
                    }
                });
            }

            // Since 0.1.2 the ready line is printed only after the profile's
            // Loader tree settles, and first launch also initializes
            // ~/.dsh/profiles; 30s proved too tight for that.
            let url = match rx.recv_timeout(Duration::from_secs(60)) {
                Ok(url) => url,
                Err(error) => {
                    stop_server(&mut child);
                    return Err(Box::new(std::io::Error::new(
                        std::io::ErrorKind::TimedOut,
                        format!(
                            "dsh web did not report readiness within 60 seconds: {}. See ~/.dsh/logs.",
                            error
                        ),
                    )));
                }
            };
            let _ = writeln!(open_log("desktop"), "dsh desktop: loading {}", url);

            let window = tauri::WebviewWindowBuilder::new(
                app.handle(),
                "main",
                tauri::WebviewUrl::External(url.parse().unwrap()),
            )
            .title("DeepSeek Harness")
            .inner_size(1280.0, 800.0)
            .min_inner_size(800.0, 600.0)
            .build()?;
            let _ = window;

            app.manage(AppState {
                server: Mutex::new(Some(child)),
            });
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("error while building tauri application");

    app.run(|app_handle, event| {
        if let tauri::RunEvent::ExitRequested { .. } = event {
            if let Some(state) = app_handle.try_state::<AppState>() {
                if let Ok(mut guard) = state.server.lock() {
                    if let Some(child) = guard.as_mut() {
                        stop_server(child);
                    }
                }
            }
        }
    });
}
