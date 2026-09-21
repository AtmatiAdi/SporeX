extends Node
## Autoload. Quality presets so the same build runs on an integrated GPU (LOW)
## and looks good on a discrete one (HIGH). Applied at startup (auto-detect)
## and switchable at runtime with F1/F2/F3.

enum Quality { LOW, MEDIUM, HIGH }

signal changed(quality: int)

var quality: int = Quality.MEDIUM
var _env: Environment


func _ready() -> void:
	quality = _detect()


func _detect() -> int:
	var name := RenderingServer.get_video_adapter_name().to_lower()
	if name.contains("intel") or name.contains("iris") or name.contains("uhd") or name.contains("llvmpipe"):
		return Quality.LOW
	if name.contains("rtx") or name.contains("rx 7") or name.contains("rx 6") or name.contains("arc a7"):
		return Quality.HIGH
	return Quality.MEDIUM


func adapter_name() -> String:
	return RenderingServer.get_video_adapter_name()


func planet_segments() -> int:
	match quality:
		Quality.LOW: return 192
		Quality.MEDIUM: return 320
	return 512


func apply(q: int, env: Environment, viewport: Viewport) -> void:
	quality = q
	_env = env
	match q:
		Quality.LOW:
			viewport.msaa_3d = Viewport.MSAA_DISABLED
			viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
			viewport.scaling_3d_scale = 0.8
			env.glow_enabled = false
		Quality.MEDIUM:
			viewport.msaa_3d = Viewport.MSAA_2X
			viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
			viewport.scaling_3d_scale = 1.0
			env.glow_enabled = true
			env.glow_intensity = 0.5
			env.glow_bloom = 0.05
		_:
			viewport.msaa_3d = Viewport.MSAA_4X
			viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
			viewport.scaling_3d_scale = 1.0
			env.glow_enabled = true
			env.glow_intensity = 0.7
			env.glow_bloom = 0.08
	changed.emit(q)


func quality_name() -> String:
	return ["LOW", "MEDIUM", "HIGH"][quality]
