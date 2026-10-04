extends Node
## Autoload. In exported builds asks GitHub for the latest release; if it is
## newer than this build, the HUD offers F12. The update itself is done by
## SporeX-Setup.exe (installed next to the game, or downloaded on demand):
## it waits for the game to exit, downloads and verifies the new SporeX.exe,
## swaps it in and starts it again.

const REPO := "AtmatiAdi/SporeX"   # same as RELEASES_REPO in tools/setup/src/main.rs
const SETUP := "SporeX-Setup.exe"

signal update_available(version: String)

var version := str(ProjectSettings.get_setting("application/config/version", "0.0.0"))
var latest := ""
var available := false
var status := ""
var _http: HTTPRequest


func _ready() -> void:
	if not OS.has_feature("template") or OS.get_cmdline_user_args().has("--no-update-check"):
		return
	_http = HTTPRequest.new()
	_http.timeout = 10.0
	add_child(_http)
	_http.request_completed.connect(_on_latest, CONNECT_ONE_SHOT)
	_http.request("https://api.github.com/repos/%s/releases/latest" % REPO,
		["User-Agent: SporeX/" + version, "Accept: application/vnd.github+json"])


func _on_latest(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		return
	var data = JSON.parse_string(body.get_string_from_utf8())
	if not data is Dictionary:
		return
	latest = str(data.get("tag_name", "")).trim_prefix("v")
	available = is_newer(latest, version)
	if available:
		update_available.emit(latest)


static func is_newer(a: String, b: String) -> bool:
	var pa := a.split(".")
	var pb := b.split(".")
	for i in 3:
		var x := int(pa[i]) if i < pa.size() else 0
		var y := int(pb[i]) if i < pb.size() else 0
		if x != y:
			return x > y
	return false


func start_update() -> void:
	if not available or _http == null:
		return
	var local := OS.get_executable_path().get_base_dir().path_join(SETUP)
	if FileAccess.file_exists(local):
		_run_setup(local)
		return
	# Game not installed by the setup (e.g. a copied exe): fetch the setup first.
	status = "pobieram instalator..."
	var dest := OS.get_user_data_dir().path_join(SETUP)
	_http.download_file = dest
	_setup_dest = dest
	_http.request_completed.connect(_on_setup_downloaded, CONNECT_ONE_SHOT)
	_http.request("https://github.com/%s/releases/latest/download/%s" % [REPO, SETUP], ["User-Agent: SporeX/" + version])


func _run_setup(path: String) -> void:
	OS.create_process(path, ["--update", "--wait", str(OS.get_process_id())])
	get_tree().quit()


var _setup_dest := ""


func _on_setup_downloaded(result: int, code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	if result == HTTPRequest.RESULT_SUCCESS and code == 200:
		_run_setup(_setup_dest)
	else:
		status = "nie udało się pobrać instalatora (HTTP %d)" % code
