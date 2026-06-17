use std::process::{Child, Command};
use std::sync::Mutex;

use tauri::{Manager, RunEvent};

/// Holds the spawned Python backend so we can kill it on exit.
struct Backend(Mutex<Option<Child>>);

/// Absolute path to the repo's `backend/` dir, baked at compile time.
/// User chose "spawn local uv from repo" — this is a local personal tool, so
/// the build-machine path is the right anchor.
fn backend_dir() -> std::path::PathBuf {
    std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..")
        .join("backend")
}

fn spawn_backend() -> std::io::Result<Child> {
    // `uv run trinity serve --no-open` — uvicorn binds 127.0.0.1:7777.
    Command::new("uv")
        .args(["run", "trinity", "serve", "--no-open"])
        .current_dir(backend_dir())
        .spawn()
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .manage(Backend(Mutex::new(None)))
        .setup(|app| {
            match spawn_backend() {
                Ok(child) => {
                    *app.state::<Backend>().0.lock().unwrap() = Some(child);
                }
                Err(e) => {
                    eprintln!("failed to start Trinity backend via uv: {e}");
                }
            }
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("error building Trinity desktop app")
        .run(|app, event| {
            if let RunEvent::Exit = event {
                if let Some(mut child) =
                    app.state::<Backend>().0.lock().unwrap().take()
                {
                    let _ = child.kill();
                }
            }
        });
}
