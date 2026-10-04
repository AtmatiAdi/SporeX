class_name HeightMapService
extends RefCounted
## One worker thread, a priority queue of planet seeds and a cache of results.
## The selected planet is always processed first; the other playable planets are
## prefetched in the background so that switching targets never shows a
## placeholder. Results are delivered on the main thread via call_deferred.

signal map_ready(res: PlanetGenerator.HeightMapResult)

var cache := {}          # seed -> HeightMapResult (finest level available)
var _queue: Array[int] = []
var _thread: Thread
var _mutex := Mutex.new()
var _sem := Semaphore.new()
var _exit := false
var _current := 0


func _init() -> void:
	_thread = Thread.new()
	_thread.start(_run)


func request(seed: int, front: bool = false) -> void:
	if cache.has(seed) and cache[seed].size == PlanetGenerator.FINE:
		return
	_mutex.lock()
	_queue.erase(seed)
	if front:
		_queue.push_front(seed)
	else:
		_queue.push_back(seed)
	_mutex.unlock()
	_sem.post()


## Forget everything (new universe): pending jobs and cached maps.
func reset() -> void:
	_mutex.lock()
	_queue.clear()
	_mutex.unlock()
	cache.clear()


func best(seed: int) -> PlanetGenerator.HeightMapResult:
	return cache.get(seed)


func _run() -> void:
	while true:
		_sem.wait()
		if _exit:
			return
		_mutex.lock()
		if _queue.is_empty():
			_mutex.unlock()
			continue
		var seed: int = _queue.pop_front()
		_current = seed
		_mutex.unlock()
		for sz in [PlanetGenerator.COARSE, PlanetGenerator.FINE]:
			if _exit:
				return
			if sz == PlanetGenerator.COARSE and cache.has(seed):
				continue
			var t0 := Time.get_ticks_msec()
			var res := PlanetGenerator.build_height_map(seed, sz)
			print("heightmap seed=%d %dx%d: %d ms" % [seed, sz.x, sz.y, Time.get_ticks_msec() - t0])
			_deliver.call_deferred(res)


func _deliver(res: PlanetGenerator.HeightMapResult) -> void:
	cache[res.seed] = res
	map_ready.emit(res)


func shutdown() -> void:
	_exit = true
	_sem.post()
	if _thread.is_started():
		_thread.wait_to_finish()
