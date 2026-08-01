class_name Args
extends RefCounted
## Command-line access that does not care about autoload order.
##
## Terrain resolves before Net (it has to -- Net hashes the terrain at
## handshake), so neither can read arguments parsed by the other. Keeping the
## parse static and stateless means any autoload can ask at any time.
##
## Everything after `--` on the Godot command line lands here.

static func has(flag: String) -> bool:
	return OS.get_cmdline_user_args().has(flag)


static func value(flag: String, fallback: String = "") -> String:
	var a := OS.get_cmdline_user_args()
	var i := a.find(flag)
	if i == -1 or i + 1 >= a.size():
		return fallback
	# The first wins, and the rest are dropped. Saying so out loud costs one
	# line and saves the afternoon it cost once: a harness built its arguments
	# by concatenating two lists that each carried a --grant, half the kit never
	# arrived, and the run failed as though the game were broken.
	if a.rfind(flag) != i:
		push_warning("Args: '%s' given more than once; using the first ('%s')"
			% [flag, a[i + 1]])
	return a[i + 1]


static func number(flag: String, fallback: float = 0.0) -> float:
	var v := value(flag, "")
	return fallback if v.is_empty() else float(v)


static func integer(flag: String, fallback: int = 0) -> int:
	var v := value(flag, "")
	return fallback if v.is_empty() else int(v)
