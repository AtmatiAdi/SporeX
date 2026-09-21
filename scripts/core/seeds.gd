class_name Seeds
extends RefCounted
## Deterministic seed derivation. Every object in the universe (galaxy -> star ->
## planet -> terrain) derives its seed from its parent's seed and its index, so a
## single 64-bit galaxy seed reproduces the whole universe on every machine.
## That is what makes LAN multiplayer cheap: the host only has to share the seed.

const SYLLABLES := ["ka", "ra", "ve", "lo", "mi", "tu", "sa", "ne", "ori", "xa", "dra", "il", "un", "ze", "pho", "qua", "ly", "os", "ith", "ar"]


static func mix(parent: int, index: int) -> int:
	# String hash is stable across platforms and runs.
	return hash("%d:%d" % [parent, index])


static func mix3(a: int, b: int, c: int) -> int:
	return hash("%d:%d:%d" % [a, b, c])


static func rng(seed: int) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = seed
	return r


static func make_name(seed: int, min_syl: int = 2, max_syl: int = 3) -> String:
	var r := rng(seed)
	var n := r.randi_range(min_syl, max_syl)
	var s := ""
	for i in n:
		s += SYLLABLES[r.randi_range(0, SYLLABLES.size() - 1)]
	return s.capitalize()
