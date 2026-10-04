//! SporeX-Setup.exe - instalator i aktualizator, ktory sam nic nie zawiera:
//! pyta GitHuba o najnowsze wydanie, pobiera `SporeX.exe` (i nowsza wersje
//! siebie) z paskiem postepu, sprawdza SHA-256 z `SHA256SUMS.txt` tego samego
//! wydania i instaluje gre dla biezacego uzytkownika. Ten sam plik pobrany
//! pol roku temu zainstaluje biezaca wersje. Wzor: SpectreNotes-Setup.
//!
//! Argumenty:
//!   --update        tryb aktualizacji (wolany z gry klawiszem F12)
//!   --wait <pid>    najpierw poczekaj, az gra (proces pid) sie zamknie
//!   --uninstall     odinstaluj (wpis w "Zainstalowane aplikacje")
//!   --no-launch     nie uruchamiaj gry po instalacji
//!   --repo o/r      inne repozytorium wydan niz wbudowane
//!   --download-only <dir>  tylko pobierz i sprawdz sumy do <dir> (test, CI)

#![windows_subsystem = "windows"]

mod hash;
mod http;
mod install;

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use windows::core::{Result, PCWSTR};
use windows::Win32::Foundation::{HWND, LPARAM, LRESULT, WPARAM};
use windows::Win32::Graphics::Gdi::{
    CreateFontW, GetStockObject, CLEARTYPE_QUALITY, DEFAULT_CHARSET, FF_DONTCARE, FW_NORMAL, HBRUSH,
    HFONT, OUT_DEFAULT_PRECIS, WHITE_BRUSH,
};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::Controls::{
    InitCommonControlsEx, ICC_PROGRESS_CLASS, INITCOMMONCONTROLSEX, PBM_SETPOS, PBM_SETRANGE32,
    PROGRESS_CLASSW,
};
use windows::Win32::UI::HiDpi::{
    GetDpiForSystem, SetProcessDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2,
};
use windows::Win32::UI::WindowsAndMessaging::*;

/// Repozytorium wydan (publiczne). Jedno zrodlo prawdy: to samo czyta
/// release.ps1, a gra ma je w scripts/core/updater.gd.
pub const RELEASES_REPO: &str = "AtmatiAdi/SporeX";
const SUMS: &str = "SHA256SUMS.txt";

const WM_PROGRESS: u32 = WM_APP + 1;
const WM_DONE: u32 = WM_APP + 2;
const ID_BUTTON: isize = 1;
const ID_LABEL: isize = 2;
const ID_BAR: isize = 3;

pub fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

struct Shared {
    text: String,
    pos: Option<u32>,
}

struct Setup {
    label: HWND,
    bar: HWND,
    button: HWND,
    shared: Arc<Mutex<Shared>>,
    cancel: Arc<AtomicBool>,
    done: bool,
}

struct Options {
    repo: String,
    wait_pid: Option<u32>,
    launch: bool,
    update: bool,
    download_only: Option<std::path::PathBuf>,
}

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.iter().any(|a| a == "--uninstall") {
        uninstall_flow();
        return Ok(());
    }
    unsafe {
        let _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        let icc = INITCOMMONCONTROLSEX {
            dwSize: std::mem::size_of::<INITCOMMONCONTROLSEX>() as u32,
            dwICC: ICC_PROGRESS_CLASS,
        };
        let _ = InitCommonControlsEx(&icc);
    }
    let opts = Options {
        repo: arg_value(&args, "--repo").unwrap_or_else(|| RELEASES_REPO.to_string()),
        wait_pid: arg_value(&args, "--wait").and_then(|s| s.parse().ok()),
        launch: !args.iter().any(|a| a == "--no-launch"),
        update: args.iter().any(|a| a == "--update"),
        download_only: arg_value(&args, "--download-only").map(std::path::PathBuf::from),
    };
    let hwnd = create_window(if opts.update { "SporeX – aktualizacja" } else { "SporeX – instalacja" })?;
    let shared = Arc::new(Mutex::new(Shared { text: "Sprawdzam najnowsze wydanie...".into(), pos: None }));
    let cancel = Arc::new(AtomicBool::new(false));
    let setup = Box::new(Setup {
        label: child(hwnd, ID_LABEL),
        bar: child(hwnd, ID_BAR),
        button: child(hwnd, ID_BUTTON),
        shared: shared.clone(),
        cancel: cancel.clone(),
        done: false,
    });
    unsafe {
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, Box::into_raw(setup) as isize);
        let _ = ShowWindow(hwnd, if opts.download_only.is_some() { SW_SHOWNOACTIVATE } else { SW_SHOW });
    }
    let hwnd_raw = hwnd.0 as isize;
    std::thread::spawn(move || {
        let r = run(&opts, &shared, &cancel, hwnd_raw);
        let (code, text) = match r {
            Ok(v) => (0, if opts.launch { format!("Zainstalowano SporeX {v}. Uruchamiam grę...") } else { format!("Zainstalowano SporeX {v}.") }),
            Err(e) => (1, format!("Nie udało się: {e}")),
        };
        shared.lock().unwrap().text = text;
        unsafe {
            let _ = PostMessageW(Some(HWND(hwnd_raw as *mut _)), WM_DONE, WPARAM(code), LPARAM(0));
        }
    });
    unsafe {
        let mut msg = MSG::default();
        while GetMessageW(&mut msg, None, 0, 0).as_bool() {
            let _ = TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }
    Ok(())
}

fn uninstall_flow() {
    let title = wide("SporeX");
    let ask = wide("Odinstalować SporeX?\n\nZapisy i ustawienia gry zostaną na dysku.");
    unsafe {
        let r = MessageBoxW(None, PCWSTR(ask.as_ptr()), PCWSTR(title.as_ptr()), MB_YESNO | MB_ICONQUESTION);
        if r != IDYES {
            return;
        }
    }
    let msg = match install::uninstall() {
        Ok(()) => "SporeX został odinstalowany.".to_string(),
        Err(e) => format!("Odinstalowanie nie powiodło się: {e}"),
    };
    let m = wide(&msg);
    unsafe {
        MessageBoxW(None, PCWSTR(m.as_ptr()), PCWSTR(title.as_ptr()), MB_OK | MB_ICONINFORMATION);
    }
}

fn arg_value(args: &[String], name: &str) -> Option<String> {
    args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).cloned()
}

fn child(hwnd: HWND, id: isize) -> HWND {
    unsafe { GetDlgItem(Some(hwnd), id as i32).unwrap_or_default() }
}

/// `"tag_name": "v0.1.0"` z JSON-a GitHuba (bez parsera - jedno pole).
fn json_str(body: &str, key: &str) -> Option<String> {
    let k = format!("\"{key}\"");
    let rest = &body[body.find(&k)? + k.len()..];
    let rest = &rest[rest.find(':')? + 1..];
    let rest = &rest[rest.find('"')? + 1..];
    Some(rest[..rest.find('"')?].to_string())
}

/// Suma z pliku w formacie `sha256sum` ("<hex>  <nazwa>").
fn sum_for(sums: &str, name: &str) -> Option<String> {
    sums.lines().find_map(|l| {
        let mut it = l.split_whitespace();
        let h = it.next()?;
        let n = it.next()?.trim_start_matches('*');
        (n == name).then(|| h.to_ascii_lowercase())
    })
}

fn human(b: u64) -> String {
    if b >= 1 << 20 {
        format!("{:.1} MB", b as f64 / 1048576.0)
    } else {
        format!("{} KB", b / 1024)
    }
}

/// Cala robota: wydanie -> pobranie z weryfikacja -> instalacja. Zwraca wersje.
fn run(opts: &Options, shared: &Arc<Mutex<Shared>>, cancel: &Arc<AtomicBool>, hwnd_raw: isize) -> std::result::Result<String, String> {
    let set = |text: String, pos: Option<u32>| {
        let mut s = shared.lock().unwrap();
        s.text = text;
        s.pos = pos;
        drop(s);
        unsafe {
            let _ = PostMessageW(Some(HWND(hwnd_raw as *mut _)), WM_PROGRESS, WPARAM(0), LPARAM(0));
        }
    };
    if let Some(pid) = opts.wait_pid {
        set("Czekam na zamknięcie gry...".into(), None);
        install::wait_pid(pid, 20_000);
    }
    install::cleanup_old();

    let ua = "User-Agent: SporeX-Setup";
    let api = format!("https://api.github.com/repos/{}/releases/latest", opts.repo);
    let r = http::request("GET", &api, &[ua, "Accept: application/vnd.github+json"], None)
        .map_err(|e| format!("brak połączenia z GitHubem ({})", e.message()))?;
    match r.status {
        200 => {}
        404 => return Err(format!("repozytorium {} nie ma jeszcze żadnego wydania", opts.repo)),
        403 | 429 => return Err("GitHub ograniczył liczbę zapytań – spróbuj za kilka minut".into()),
        s => return Err(format!("GitHub odpowiedział HTTP {s}")),
    }
    let tag = json_str(&r.body, "tag_name").ok_or("wydanie bez tagu")?;
    let version = tag.trim_start_matches('v').to_string();
    let base = format!("https://github.com/{}/releases/download/{tag}", opts.repo);

    let dir = opts.download_only.clone().unwrap_or_else(install::download_dir);
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let sums_path = dir.join(SUMS);
    http::download(&format!("{base}/{SUMS}"), &[ua], &sums_path, &mut |_, _| true)
        .map_err(|e| format!("{SUMS}: {}", e.message()))?;
    let sums = std::fs::read_to_string(&sums_path).map_err(|e| e.to_string())?;

    let fetch = |name: &str, show: bool| -> std::result::Result<std::path::PathBuf, String> {
        let want = sum_for(&sums, name).ok_or_else(|| format!("{SUMS} nie ma sumy dla {name}"))?;
        let dest = dir.join(name);
        let mut progress = |done: u64, total: Option<u64>| -> bool {
            if cancel.load(Ordering::Relaxed) {
                return false;
            }
            if show {
                let t = total.unwrap_or(0).max(1);
                set(
                    format!("Pobieram SporeX {version}: {} / {}", human(done), human(t)),
                    total.map(|t| ((done * 1000) / t.max(1)) as u32),
                );
            }
            true
        };
        http::download(&format!("{base}/{name}"), &[ua], &dest, &mut progress).map_err(|e| {
            if http::is_cancelled(&e) {
                "przerwano".to_string()
            } else {
                format!("{name}: {}", e.message())
            }
        })?;
        let got = hash::sha256_file(&dest).map_err(|e| e.to_string())?;
        if got != want {
            let _ = std::fs::remove_file(&dest);
            return Err(format!("suma kontrolna {name} się nie zgadza – plik uszkodzony, spróbuj ponownie"));
        }
        Ok(dest)
    };
    set(format!("Pobieram SporeX {version}..."), Some(0));
    let game = fetch(install::GAME_EXE, true)?;
    let setup = fetch(install::SETUP_EXE, false).ok();

    if opts.download_only.is_some() {
        return Ok(version);
    }
    set("Instaluję...".into(), Some(1000));
    let about = format!("https://github.com/{}", opts.repo);
    let exe = install::install(&game, setup.as_deref(), &version, &about).map_err(|e| e.to_string())?;
    let _ = std::fs::remove_dir_all(&dir);
    if opts.launch {
        install::spawn(&exe).map_err(|e| e.to_string())?;
    }
    Ok(version)
}

fn create_window(title: &str) -> Result<HWND> {
    unsafe {
        let class = wide("SporeXSetup");
        let hinst = GetModuleHandleW(None)?;
        let wc = WNDCLASSEXW {
            cbSize: std::mem::size_of::<WNDCLASSEXW>() as u32,
            lpfnWndProc: Some(wndproc),
            hInstance: hinst.into(),
            hCursor: LoadCursorW(None, IDC_ARROW)?,
            hbrBackground: HBRUSH(GetStockObject(WHITE_BRUSH).0),
            lpszClassName: PCWSTR(class.as_ptr()),
            hIcon: LoadIconW(None, IDI_APPLICATION)?,
            ..Default::default()
        };
        RegisterClassExW(&wc);
        let k = GetDpiForSystem() as f32 / 96.0;
        let px = |v: f32| (v * k).round() as i32;
        let (w, h) = (px(460.0), px(150.0));
        let sw = GetSystemMetrics(SM_CXSCREEN);
        let sh = GetSystemMetrics(SM_CYSCREEN);
        let title = wide(title);
        let hwnd = CreateWindowExW(
            WS_EX_DLGMODALFRAME,
            PCWSTR(class.as_ptr()),
            PCWSTR(title.as_ptr()),
            WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU,
            (sw - w) / 2,
            (sh - h) / 2,
            w,
            h,
            None,
            None,
            Some(hinst.into()),
            None,
        )?;
        let font = ui_font(k);
        let make = |cls: &str, text: &str, style: u32, x: f32, y: f32, cw: f32, ch: f32, id: isize| {
            let cls_w = wide(cls);
            let text_w = wide(text);
            let h = CreateWindowExW(
                WINDOW_EX_STYLE(0),
                PCWSTR(cls_w.as_ptr()),
                PCWSTR(text_w.as_ptr()),
                WINDOW_STYLE(style) | WS_CHILD | WS_VISIBLE,
                px(x),
                px(y),
                px(cw),
                px(ch),
                Some(hwnd),
                Some(HMENU(id as *mut _)),
                Some(hinst.into()),
                None,
            )
            .unwrap_or_default();
            SendMessageW(h, WM_SETFONT, Some(WPARAM(font.0 as usize)), Some(LPARAM(1)));
            h
        };
        make("STATIC", "...", 0x0080, 16.0, 14.0, 428.0, 40.0, ID_LABEL);
        let bar = make(&String::from_utf16_lossy(PROGRESS_CLASSW.as_wide()), "", 0, 16.0, 60.0, 428.0, 14.0, ID_BAR);
        SendMessageW(bar, PBM_SETRANGE32, Some(WPARAM(0)), Some(LPARAM(1000)));
        make("BUTTON", "Anuluj", BS_PUSHBUTTON as u32, 348.0, 86.0, 96.0, 28.0, ID_BUTTON);
        Ok(hwnd)
    }
}

fn ui_font(k: f32) -> HFONT {
    let face = wide("Segoe UI");
    unsafe {
        CreateFontW(
            -(12.0 * k).round() as i32,
            0,
            0,
            0,
            FW_NORMAL.0 as i32,
            0,
            0,
            0,
            DEFAULT_CHARSET,
            OUT_DEFAULT_PRECIS,
            windows::Win32::Graphics::Gdi::CLIP_DEFAULT_PRECIS,
            CLEARTYPE_QUALITY,
            FF_DONTCARE.0 as u32,
            PCWSTR(face.as_ptr()),
        )
    }
}

fn set_text(hwnd: HWND, text: &str) {
    let w = wide(text);
    unsafe {
        let _ = SetWindowTextW(hwnd, PCWSTR(w.as_ptr()));
    }
}

unsafe extern "system" fn wndproc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    let ptr = GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *mut Setup;
    if ptr.is_null() {
        return DefWindowProcW(hwnd, msg, wparam, lparam);
    }
    let s = &mut *ptr;
    match msg {
        WM_PROGRESS => {
            let (text, pos) = {
                let sh = s.shared.lock().unwrap();
                (sh.text.clone(), sh.pos)
            };
            set_text(s.label, &text);
            if let Some(p) = pos {
                SendMessageW(s.bar, PBM_SETPOS, Some(WPARAM(p as usize)), Some(LPARAM(0)));
            }
            LRESULT(0)
        }
        WM_DONE => {
            let text = s.shared.lock().unwrap().text.clone();
            set_text(s.label, &text);
            s.done = true;
            set_text(s.button, "Zamknij");
            if wparam.0 == 0 {
                SendMessageW(s.bar, PBM_SETPOS, Some(WPARAM(1000)), Some(LPARAM(0)));
                SetTimer(Some(hwnd), 1, 1500, None);
            }
            LRESULT(0)
        }
        WM_TIMER => {
            let _ = DestroyWindow(hwnd);
            LRESULT(0)
        }
        WM_COMMAND => {
            if (wparam.0 & 0xffff) as isize == ID_BUTTON {
                if s.done {
                    let _ = DestroyWindow(hwnd);
                } else {
                    s.cancel.store(true, Ordering::Relaxed);
                    set_text(s.label, "Przerywam...");
                }
            }
            LRESULT(0)
        }
        WM_CLOSE => {
            s.cancel.store(true, Ordering::Relaxed);
            let _ = DestroyWindow(hwnd);
            LRESULT(0)
        }
        WM_DESTROY => {
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
            drop(Box::from_raw(ptr));
            PostQuitMessage(0);
            LRESULT(0)
        }
        _ => DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tag_z_json() {
        let body = r#"{"url":"x","tag_name": "v0.3.1","name":"SporeX 0.3.1"}"#;
        assert_eq!(json_str(body, "tag_name").as_deref(), Some("v0.3.1"));
        assert_eq!(json_str(body, "nope"), None);
    }

    #[test]
    fn sumy() {
        let s = "abc123  SporeX.exe\ndef456  SporeX-Setup.exe\n";
        assert_eq!(sum_for(s, "SporeX.exe").as_deref(), Some("abc123"));
        assert_eq!(sum_for(s, "SporeX-Setup.exe").as_deref(), Some("def456"));
        assert_eq!(sum_for(s, "x.exe"), None);
    }
}
