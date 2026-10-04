//! Instalacja per uzytkownik (bez administratora) i podmiana plikow przy
//! aktualizacji. Wzorowane na SpectreNotes (spectre-shell-win/install.rs).
//!
//! | co | gdzie |
//! |---|---|
//! | gra | `%LOCALAPPDATA%\SporeX\SporeX.exe` |
//! | instalator / aktualizator | `%LOCALAPPDATA%\SporeX\SporeX-Setup.exe` |
//! | skroty | menu Start i pulpit biezacego uzytkownika |
//! | wpis "Zainstalowane aplikacje" | `HKCU\...\Uninstall\SporeX` |
//! | zapisy i ustawienia gry | `%APPDATA%\Godot\app_userdata\SporeX` - instalacja ich nie dotyka |
//!
//! Podmiana dzialajacego pliku: Windows nie pozwala go nadpisac ani skasowac,
//! ale pozwala **przemianowac** (obraz w pamieci trzyma sie pliku, nie nazwy):
//! `X.exe` -> `X.old.exe`, nowy plik na miejsce starego, sprzatanie przy
//! nastepnym uruchomieniu instalatora.

use std::path::{Path, PathBuf};

use windows::core::{Interface, PCWSTR};
use windows::Win32::Foundation::{CloseHandle, ERROR_SUCCESS};
use windows::Win32::System::Com::{
    CoCreateInstance, CoInitializeEx, CoTaskMemFree, IPersistFile, CLSCTX_INPROC_SERVER,
    COINIT_APARTMENTTHREADED,
};
use windows::Win32::System::Registry::{
    RegCloseKey, RegCreateKeyExW, RegDeleteTreeW, RegSetValueExW, HKEY, HKEY_CURRENT_USER,
    KEY_WRITE, REG_DWORD, REG_OPTION_NON_VOLATILE, REG_SZ,
};
use windows::Win32::System::Threading::{OpenProcess, WaitForSingleObject, PROCESS_SYNCHRONIZE};
use windows::Win32::UI::Shell::{
    FOLDERID_Desktop, IShellLinkW, SHGetKnownFolderPath, ShellLink, KF_FLAG_DEFAULT,
};

use crate::wide;

pub const GAME_EXE: &str = "SporeX.exe";
pub const SETUP_EXE: &str = "SporeX-Setup.exe";
const UNINSTALL_KEY: &str = r"Software\Microsoft\Windows\CurrentVersion\Uninstall\SporeX";
const FIREWALL_RULE: &str = "SporeX (LAN)";

/// `%LOCALAPPDATA%\SporeX`.
pub fn app_dir() -> PathBuf {
    let base = std::env::var_os("LOCALAPPDATA")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."));
    base.join("SporeX")
}

/// Pobrane, jeszcze niezainstalowane pliki.
pub fn download_dir() -> PathBuf {
    app_dir().join("download")
}

fn start_menu_lnk() -> PathBuf {
    let base = std::env::var_os("APPDATA")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."));
    base.join(r"Microsoft\Windows\Start Menu\Programs\SporeX.lnk")
}

fn desktop_lnk() -> Option<PathBuf> {
    unsafe {
        let p = SHGetKnownFolderPath(&FOLDERID_Desktop, KF_FLAG_DEFAULT, None).ok()?;
        let s = p.to_string().ok();
        CoTaskMemFree(Some(p.0 as *const _));
        s.map(|s| PathBuf::from(s).join("SporeX.lnk"))
    }
}

pub fn current_exe() -> Option<PathBuf> {
    std::env::current_exe().ok()
}

fn same_path(a: &Path, b: &Path) -> bool {
    a.to_string_lossy().eq_ignore_ascii_case(&b.to_string_lossy())
}

/// Kladzie `src` w `dest`; jesli `dest` jest w uzyciu (dziala), najpierw
/// przemianowuje go na `.old.exe`.
fn put_file(src: &Path, dest: &Path) -> std::io::Result<()> {
    if same_path(src, dest) {
        return Ok(());
    }
    if dest.exists() && std::fs::remove_file(dest).is_err() {
        let old = dest.with_extension("old.exe");
        let _ = std::fs::remove_file(&old);
        std::fs::rename(dest, &old)?;
    }
    std::fs::copy(src, dest).map(|_| ())
}

/// Instalacja pobranej gry (i pobranego instalatora, jesli jest) - zwraca
/// sciezke zainstalowanej gry.
pub fn install(game: &Path, setup: Option<&Path>, version: &str, about_url: &str) -> std::io::Result<PathBuf> {
    let dir = app_dir();
    std::fs::create_dir_all(&dir)?;
    let dest = dir.join(GAME_EXE);
    put_file(game, &dest)?;
    // Aktualizator mieszka obok gry: z niego korzysta F12 w grze i odinstalowanie.
    let setup_dest = dir.join(SETUP_EXE);
    match setup {
        Some(s) => put_file(s, &setup_dest)?,
        None => {
            if let Some(me) = current_exe() {
                put_file(&me, &setup_dest)?;
            }
        }
    }
    std::fs::write(dir.join("version.txt"), version)?;
    create_shortcut(&start_menu_lnk(), &dest, "SporeX")?;
    if let Some(d) = desktop_lnk() {
        let _ = create_shortcut(&d, &dest, "SporeX");
    }
    let size_kb = std::fs::metadata(&dest).map(|m| m.len() / 1024).unwrap_or(0) as u32;
    register_uninstall(version, about_url, &dest, &setup_dest, size_kb)?;
    add_firewall_rule(&dest);
    Ok(dest)
}

/// Odinstalowanie: skroty, wpis, regula zapory, katalog gry (odlozonym
/// poleceniem - wlasnego pliku proces nie skasuje). Zapisy gry zostaja.
pub fn uninstall() -> std::io::Result<()> {
    let _ = std::fs::remove_file(start_menu_lnk());
    if let Some(d) = desktop_lnk() {
        let _ = std::fs::remove_file(d);
    }
    unregister_uninstall();
    remove_firewall_rule();
    use std::os::windows::process::CommandExt;
    std::process::Command::new("cmd")
        .raw_arg(format!(
            "/c ping 127.0.0.1 -n 3 >nul & rmdir /s /q \"{}\"",
            app_dir().display()
        ))
        .spawn()?;
    Ok(())
}

/// Sprzata `*.old.exe` po poprzedniej podmianie.
pub fn cleanup_old() {
    for name in [GAME_EXE, SETUP_EXE] {
        let old = app_dir().join(name).with_extension("old.exe");
        if old.exists() {
            let _ = std::fs::remove_file(old);
        }
    }
}

/// Czeka (do `timeout_ms`), az proces `pid` sie zakonczy - gra wola
/// aktualizator i sama wychodzi.
pub fn wait_pid(pid: u32, timeout_ms: u32) {
    unsafe {
        if let Ok(h) = OpenProcess(PROCESS_SYNCHRONIZE, false, pid) {
            let _ = WaitForSingleObject(h, timeout_ms);
            let _ = CloseHandle(h);
        }
    }
}

pub fn spawn(exe: &Path) -> std::io::Result<()> {
    std::process::Command::new(exe)
        .current_dir(exe.parent().unwrap_or(Path::new(".")))
        .spawn()
        .map(|_| ())
}

fn create_shortcut(lnk: &Path, target: &Path, desc: &str) -> std::io::Result<()> {
    let com = |e: windows::core::Error| std::io::Error::other(format!("shortcut: {e}"));
    unsafe {
        let _ = CoInitializeEx(None, COINIT_APARTMENTTHREADED);
        let link: IShellLinkW = CoCreateInstance(&ShellLink, None, CLSCTX_INPROC_SERVER).map_err(com)?;
        let target_w = wide(&target.to_string_lossy());
        let dir_w = wide(&target.parent().map(|p| p.to_string_lossy().into_owned()).unwrap_or_default());
        let desc_w = wide(desc);
        link.SetPath(PCWSTR(target_w.as_ptr())).map_err(com)?;
        link.SetWorkingDirectory(PCWSTR(dir_w.as_ptr())).map_err(com)?;
        link.SetDescription(PCWSTR(desc_w.as_ptr())).map_err(com)?;
        let file: IPersistFile = link.cast().map_err(com)?;
        if let Some(parent) = lnk.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let lnk_w = wide(&lnk.to_string_lossy());
        file.Save(PCWSTR(lnk_w.as_ptr()), true).map_err(com)?;
    }
    Ok(())
}

fn set_sz(h: HKEY, name: &str, value: &str) -> std::io::Result<()> {
    let name_w = wide(name);
    let data = wide(value);
    let bytes: Vec<u8> = data.iter().flat_map(|c| c.to_le_bytes()).collect();
    let rc = unsafe { RegSetValueExW(h, PCWSTR(name_w.as_ptr()), None, REG_SZ, Some(&bytes)) };
    if rc == ERROR_SUCCESS {
        Ok(())
    } else {
        Err(std::io::Error::other(format!("registry {name}: code {}", rc.0)))
    }
}

fn set_dword(h: HKEY, name: &str, value: u32) -> std::io::Result<()> {
    let name_w = wide(name);
    let rc = unsafe { RegSetValueExW(h, PCWSTR(name_w.as_ptr()), None, REG_DWORD, Some(&value.to_le_bytes())) };
    if rc == ERROR_SUCCESS {
        Ok(())
    } else {
        Err(std::io::Error::other(format!("registry {name}: code {}", rc.0)))
    }
}

fn register_uninstall(version: &str, about_url: &str, exe: &Path, setup: &Path, size_kb: u32) -> std::io::Result<()> {
    let key = wide(UNINSTALL_KEY);
    let mut h = HKEY::default();
    let rc = unsafe {
        RegCreateKeyExW(
            HKEY_CURRENT_USER,
            PCWSTR(key.as_ptr()),
            None,
            PCWSTR::null(),
            REG_OPTION_NON_VOLATILE,
            KEY_WRITE,
            None,
            &mut h,
            None,
        )
    };
    if rc != ERROR_SUCCESS {
        return Err(std::io::Error::other(format!("uninstall key: code {}", rc.0)));
    }
    let exe_s = exe.to_string_lossy();
    let dir_s = exe.parent().map(|p| p.to_string_lossy().into_owned()).unwrap_or_default();
    let r = (|| {
        set_sz(h, "DisplayName", "SporeX")?;
        set_sz(h, "DisplayVersion", version)?;
        set_sz(h, "Publisher", "SporeX")?;
        set_sz(h, "InstallLocation", &dir_s)?;
        set_sz(h, "DisplayIcon", &exe_s)?;
        set_sz(h, "UninstallString", &format!("\"{}\" --uninstall", setup.display()))?;
        set_sz(h, "URLInfoAbout", about_url)?;
        set_dword(h, "NoModify", 1)?;
        set_dword(h, "NoRepair", 1)?;
        set_dword(h, "EstimatedSize", size_kb)
    })();
    unsafe {
        let _ = RegCloseKey(h);
    }
    r
}

fn unregister_uninstall() {
    let key = wide(UNINSTALL_KEY);
    unsafe {
        let _ = RegDeleteTreeW(HKEY_CURRENT_USER, PCWSTR(key.as_ptr()));
    }
}

/// Regula zapory dla gry (przychodzace, sieci prywatne i publiczne) - gra
/// w LAN slucha na UDP 27015 (ENet) i 27016 (wykrywanie hostow). Dodanie
/// reguly wymaga administratora, wiec `netsh` idzie przez `runas` (jedno
/// pytanie UAC przy pierwszej instalacji); odmowa nic nie psuje - zostaje
/// zwykle pytanie zapory przy pierwszym hostowaniu.
fn add_firewall_rule(exe: &Path) {
    if has_firewall_rule(exe) {
        return;
    }
    let args = format!(
        "advfirewall firewall add rule name=\"{FIREWALL_RULE}\" dir=in action=allow \
         program=\"{}\" enable=yes profile=private,public",
        exe.display()
    );
    shell_execute("runas", "netsh", &args);
}

fn remove_firewall_rule() {
    shell_execute("runas", "netsh", &format!("advfirewall firewall delete rule name=\"{FIREWALL_RULE}\""));
}

fn has_firewall_rule(exe: &Path) -> bool {
    let out = std::process::Command::new("netsh")
        .args(["advfirewall", "firewall", "show", "rule", "name=all", "dir=in", "verbose"])
        .output();
    let Ok(out) = out else {
        return false;
    };
    let text = String::from_utf8_lossy(&out.stdout).to_ascii_lowercase();
    let want = exe.to_string_lossy().to_ascii_lowercase();
    text.split("\n\n")
        .chain(text.split("\r\n\r\n"))
        .any(|block| block.contains(&want) && block.contains("allow"))
}

fn shell_execute(verb: &str, file: &str, args: &str) {
    use windows::Win32::UI::Shell::ShellExecuteW;
    use windows::Win32::UI::WindowsAndMessaging::SW_HIDE;
    let verb = wide(verb);
    let file = wide(file);
    let args = wide(args);
    unsafe {
        let _ = ShellExecuteW(
            None,
            PCWSTR(verb.as_ptr()),
            PCWSTR(file.as_ptr()),
            PCWSTR(args.as_ptr()),
            PCWSTR::null(),
            SW_HIDE,
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sciezki() {
        assert!(app_dir().ends_with("SporeX"));
        assert!(start_menu_lnk().ends_with("SporeX.lnk"));
    }

    #[test]
    fn podmiana_zajetego_pliku_przez_rename() {
        let dir = std::env::temp_dir().join(format!("sporex-inst-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let src = dir.join("new.exe");
        let dest = dir.join("SporeX.exe");
        std::fs::write(&src, b"new").unwrap();
        std::fs::write(&dest, b"old").unwrap();
        put_file(&src, &dest).unwrap();
        assert_eq!(std::fs::read(&dest).unwrap(), b"new");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
