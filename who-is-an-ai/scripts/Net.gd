extends Node
## Autoload "Net": WebSocket networking + game logic (authoritative server).
## The same script handles both the server (host / headless) and clients (browser).
##
## Roster rules:
## - A match always has MAX_PLAYERS participants total: 1 detective + 5 subjects.
## - Human players fill slots first (capped at MAX_PLAYERS - 1 so there is
##   always at least one AI); every remaining slot is filled with an AI bot.
## - Solo play therefore means: 1 human detective vs 5 AI subjects.
## - Extra humans beyond the cap stay connected as spectators for that match.

const PORT := 9090
const OLLAMA_URL := "http://127.0.0.1:11434/api/chat"
const OLLAMA_MODEL := "llama3.2"
const INTERACT_DIST := 3.5

# Total participants per match (detective included), humans and AIs combined.
const MAX_PLAYERS := 6
# Fake matchmaking duration range (seconds) - sells the illusion of real players.
const MATCHMAKING_MIN := 6.0
const MATCHMAKING_MAX := 13.0
# Chance that an AI speaks first when the detective opens the chat.
const OPENER_CHANCE := 0.5
# Chance that an AI sends a second message right after its own (double-texting).
const FOLLOWUP_CHANCE := 0.3
# Random "reading" delay before a bot's typing indicator appears (seconds).
const BOT_READ_MIN := 0.7
const BOT_READ_MAX := 2.2

signal status_changed(msg: String)
signal roster_updated
signal game_synced
signal my_id_set
signal matchmaking_started(duration: float, total: int)
signal detective_moved(pos: Vector3)
signal chat_opened(target_id: int)
signal chat_closed
signal chat_message(from_detective: bool, text: String)
signal chat_typing(from_detective: bool, typing: bool)
signal verdict(target_id: int, was_ai: bool, correct: bool, guess_ai: bool)
signal game_over(final_score: int, total: int)
signal connected_ok
signal connection_lost

var is_server := false
var is_host_player := false

# --- Replicated state (visible to all clients) ---
var characters := {}   # char_id -> {"label": String, "pos": Vector3, "resolved": bool, "was_ai": bool}
var detective_id := -1 # char_id of the detective (= peer_id for humans)
var my_char_id := -1   # -1 means "not a participant" (lobby or spectator)
var score := 0

# --- Server-only state (never sent to clients) ---
var _players := {}      # peer_id -> nickname
var _secret := {}       # char_id -> {"is_ai": bool, "peer": int, "history": Array, "busy": bool, "pending": bool}
var _next_bot_id := 1000
var _chat_target := -1
var _running := false
var _matchmaking := false
var _my_nickname := ""

# --- Auto host/join ("Play") ---
const DEFAULT_ADDRESS := "127.0.0.1"
var _auto_address := DEFAULT_ADDRESS
var _trying_join := false


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


# =====================================================================
# CONNECTION
# =====================================================================

## Single entry point behind the "Play" button. Tries to JOIN an existing
## server first; if nothing answers in time, becomes the HOST. The user never
## has to choose - it's decided in the background.
func play(nickname: String, address: String = DEFAULT_ADDRESS) -> void:
	_my_nickname = nickname if not nickname.is_empty() else "Player"
	_auto_address = address.strip_edges()
	if _auto_address.is_empty():
		_auto_address = DEFAULT_ADDRESS
	status_changed.emit("Connecting...")
	_try_join_then_host()


func _try_join_then_host() -> void:
	_trying_join = true
	var url := _auto_address
	if not url.begins_with("ws://") and not url.begins_with("wss://"):
		url = "ws://" + url
	if url.count(":") < 2:
		url += ":%d" % PORT
	var p := WebSocketMultiplayerPeer.new()
	if p.create_client(url) != OK:
		_become_host()
		return
	multiplayer.multiplayer_peer = p
	# If no server answers within a short window, fall back to hosting.
	await get_tree().create_timer(1.5).timeout
	if _trying_join and multiplayer.multiplayer_peer != null \
			and multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		multiplayer.multiplayer_peer = null
		_become_host()


func _become_host() -> void:
	_trying_join = false
	var p := WebSocketMultiplayerPeer.new()
	if p.create_server(PORT) != OK:
		status_changed.emit("Could not host: port %d busy. Retrying as client..." % PORT)
		_try_join_then_host()
		return
	multiplayer.multiplayer_peer = p
	is_server = true
	is_host_player = true
	_players[1] = _my_nickname
	status_changed.emit("Hosting a new game - press Play... waiting for others or start solo.")
	connected_ok.emit()


func _on_connected_to_server() -> void:
	_trying_join = false
	rpc_id(1, "sv_register", _my_nickname)
	connected_ok.emit()
	status_changed.emit("Joined a game! Waiting for the match to start...")


func _on_connection_failed() -> void:
	# No server reachable -> host instead of erroring out.
	if _trying_join:
		multiplayer.multiplayer_peer = null
		_become_host()
	else:
		status_changed.emit("Connection failed.")
		multiplayer.multiplayer_peer = null


func _on_server_disconnected() -> void:
	connection_lost.emit()
	status_changed.emit("Disconnected from server.")


func _on_peer_connected(_id: int) -> void:
	pass # We wait for the client to register through sv_register.


func _on_peer_disconnected(id: int) -> void:
	if not is_server:
		return
	_players.erase(id)
	if _running and id == detective_id:
		_running = false
		cl_status.rpc("The detective left the game. Start a new match.")


# =====================================================================
# CLIENT API (also works for the host-player)
# =====================================================================

func api_request_start() -> void:
	if is_server: sv_request_start()
	else: rpc_id(1, "sv_request_start")

func api_send_pos(pos: Vector3) -> void:
	if is_server: sv_pos(pos)
	else: rpc_id(1, "sv_pos", pos)

func api_request_chat(target_id: int) -> void:
	if is_server: sv_request_chat(target_id)
	else: rpc_id(1, "sv_request_chat", target_id)

func api_chat(text: String) -> void:
	if is_server: sv_chat(text)
	else: rpc_id(1, "sv_chat", text)

func api_typing(state: bool) -> void:
	if is_server: sv_typing(state)
	else: rpc_id(1, "sv_typing", state)

func api_vote(guess_ai: bool) -> void:
	if is_server: sv_vote(guess_ai)
	else: rpc_id(1, "sv_vote", guess_ai)

func api_close_chat() -> void:
	if is_server: sv_close_chat()
	else: rpc_id(1, "sv_close_chat")


# =====================================================================
# SERVER-SIDE RPCs (sv_*)
# =====================================================================

func _sender() -> int:
	var s := multiplayer.get_remote_sender_id()
	return s if s != 0 else multiplayer.get_unique_id()


## Sends a cl_* call to a specific peer (handles the local host-player case).
func _to_peer(peer: int, method: String, args: Array = []) -> void:
	if peer == multiplayer.get_unique_id():
		callv(method, args)
	else:
		callv("rpc_id", [peer, method] + args)


@rpc("any_peer", "call_remote", "reliable")
func sv_register(nickname: String) -> void:
	if not is_server: return
	var id := multiplayer.get_remote_sender_id()
	_players[id] = nickname.strip_edges().left(20)
	cl_status.rpc("%d player(s) connected. Press \"Find match\" when everyone is here." % _players.size())


@rpc("any_peer", "call_remote", "reliable")
func sv_request_start() -> void:
	if not is_server or _running or _matchmaking: return
	if _players.is_empty():
		cl_status.rpc("No human players registered.")
		return
	_matchmaking = true

	# Lock in the participants now. Humans are capped at MAX_PLAYERS - 1 so
	# the match always contains at least one AI; extras spectate this round.
	var humans: Array = _players.keys()
	humans.shuffle()
	var participants: Array = humans.slice(0, MAX_PLAYERS - 1)
	for p in humans:
		if not participants.has(p):
			_to_peer(p, "cl_status", ["Lobby full (max %d participants) - you will spectate this match." % MAX_PLAYERS])

	# Fake matchmaking delay, and the REAL participant total so the client
	# counter ends exactly on the number of characters that will spawn.
	var duration := randf_range(MATCHMAKING_MIN, MATCHMAKING_MAX)
	cl_matchmaking.rpc(duration, MAX_PLAYERS)
	await get_tree().create_timer(duration).timeout
	_matchmaking = false
	if _running: return

	# Drop participants who disconnected during the search.
	var alive: Array = []
	for p in participants:
		if _players.has(p):
			alive.append(p)
	if alive.is_empty():
		cl_status.rpc("All players left during matchmaking.")
		return
	_start_game(alive)


func _start_game(participants: Array) -> void:
	_running = true
	score = 0
	characters.clear()
	_secret.clear()
	_chat_target = -1

	# The detective is random among humans, BUT never the host-player when
	# other humans are available: the host process IS the server and holds
	# the secrets (is_ai, Ollama calls), so it could trivially cheat.
	var candidates: Array = participants.duplicate()
	candidates.shuffle()
	if is_host_player and candidates.size() > 1:
		candidates.erase(1)
	var det_peer: int = candidates[0]

	# Non-detective humans become subjects; AI bots fill EVERY remaining slot
	# up to MAX_PLAYERS. Solo play = the 5 subjects are all AIs.
	var subject_ids: Array = []
	for h in participants:
		if h != det_peer:
			subject_ids.append(h)
			_secret[h] = {"is_ai": false, "peer": h, "history": [], "busy": false, "pending": false}
	var bot_count: int = MAX_PLAYERS - participants.size()
	for i in bot_count:
		var bid := _next_bot_id + i
		subject_ids.append(bid)
		_secret[bid] = {"is_ai": true, "peer": -1, "history": [], "busy": false, "pending": false}
	_next_bot_id += bot_count

	# Anonymous shuffled labels: nicknames can never give anyone away.
	subject_ids.shuffle()
	var n := subject_ids.size()
	for i in n:
		var cid: int = subject_ids[i]
		var ang := TAU * float(i) / float(n)
		characters[cid] = {
			"label": "Subject %d" % (i + 1),
			"pos": Vector3(cos(ang) * 8.0, 0.0, sin(ang) * 8.0),
			"resolved": false,
			"was_ai": false,
		}
	detective_id = det_peer
	characters[det_peer] = {
		"label": "Detective", "pos": Vector3.ZERO,
		"resolved": true, "was_ai": false,
	}

	cl_sync.rpc(characters, detective_id, score)
	for h in participants:
		_to_peer(h, "cl_set_my_id", [h])
	cl_status.rpc("Match found! The detective must interrogate %d subjects (walk close and press E)." % n)


@rpc("any_peer", "call_remote", "unreliable_ordered")
func sv_pos(pos: Vector3) -> void:
	if not is_server or not _running: return
	if _sender() != detective_id: return
	pos.x = clampf(pos.x, -30.0, 30.0)
	pos.z = clampf(pos.z, -30.0, 30.0)
	pos.y = 0.0
	characters[detective_id]["pos"] = pos
	cl_det_pos.rpc(pos)


@rpc("any_peer", "call_remote", "reliable")
func sv_request_chat(target_id: int) -> void:
	if not is_server or not _running or _chat_target != -1: return
	if _sender() != detective_id: return
	if not characters.has(target_id) or characters[target_id]["resolved"]: return
	var dist: float = ((characters[detective_id]["pos"] as Vector3) - (characters[target_id]["pos"] as Vector3)).length()
	if dist > INTERACT_DIST + 1.5: return
	_chat_target = target_id
	_to_peer(detective_id, "cl_chat_opened", [target_id])
	var tp: int = _secret[target_id]["peer"]
	if tp > 0:
		_to_peer(tp, "cl_chat_opened", [target_id])
	# Sometimes the AI breaks the ice before the detective says anything,
	# exactly like an impatient human would.
	if _secret[target_id]["is_ai"] and randf() < OPENER_CHANCE:
		_ask_ollama(target_id, "opener")


@rpc("any_peer", "call_remote", "reliable")
func sv_chat(text: String) -> void:
	if not is_server or not _running or _chat_target < 0: return
	text = text.strip_edges().left(300)
	if text.is_empty(): return
	var sender := _sender()
	var t := _chat_target
	if sender == detective_id:
		_to_peer(detective_id, "cl_chat_msg", [true, text])
		if _secret[t]["is_ai"]:
			_secret[t]["history"].append({"role": "user", "content": text})
			if _secret[t]["busy"]:
				# A generation is already in flight; reply once it is done.
				_secret[t]["pending"] = true
			else:
				_ask_ollama(t, "reply")
		else:
			_to_peer(_secret[t]["peer"], "cl_chat_msg", [true, text])
	elif sender == t:
		_to_peer(detective_id, "cl_chat_msg", [false, text])
		_to_peer(t, "cl_chat_msg", [false, text])


@rpc("any_peer", "call_remote", "reliable")
func sv_typing(state: bool) -> void:
	if not is_server or not _running or _chat_target < 0: return
	var sender := _sender()
	var t := _chat_target
	if sender == detective_id:
		var tp: int = _secret[t]["peer"]
		if tp > 0:
			_to_peer(tp, "cl_typing", [true, state])
	elif sender == t:
		_to_peer(detective_id, "cl_typing", [false, state])


@rpc("any_peer", "call_remote", "reliable")
func sv_vote(guess_ai: bool) -> void:
	if not is_server or not _running or _chat_target < 0: return
	if _sender() != detective_id: return
	var t := _chat_target
	_chat_target = -1
	_reset_bot_state(t)
	var was_ai: bool = _secret[t]["is_ai"]
	var correct := guess_ai == was_ai
	if correct:
		score += 1
	characters[t]["resolved"] = true
	characters[t]["was_ai"] = was_ai
	cl_verdict.rpc(t, was_ai, correct, score, guess_ai)

	var remaining := 0
	for cid in characters:
		if cid != detective_id and not characters[cid]["resolved"]:
			remaining += 1
	if remaining == 0:
		_running = false
		cl_game_over.rpc(score, characters.size() - 1)


@rpc("any_peer", "call_remote", "reliable")
func sv_close_chat() -> void:
	if not is_server or _chat_target < 0: return
	if _sender() != detective_id: return
	var t := _chat_target
	_chat_target = -1
	_reset_bot_state(t)
	_to_peer(detective_id, "cl_chat_closed")
	var tp: int = _secret[t]["peer"]
	if tp > 0:
		_to_peer(tp, "cl_chat_closed")


func _reset_bot_state(char_id: int) -> void:
	if _secret.has(char_id):
		_secret[char_id]["busy"] = false
		_secret[char_id]["pending"] = false


# =====================================================================
# CLIENT-SIDE RPCs (cl_*) - "call_local" so the host-player receives them too
# =====================================================================

@rpc("authority", "call_local", "reliable")
func cl_matchmaking(duration: float, total: int) -> void:
	matchmaking_started.emit(duration, total)


@rpc("authority", "call_local", "reliable")
func cl_sync(chars: Dictionary, det_id: int, sc: int) -> void:
	characters = chars.duplicate(true)
	detective_id = det_id
	score = sc
	# Reset; participants receive their id right after through cl_set_my_id.
	# Anyone left at -1 is a spectator for this match.
	my_char_id = -1
	game_synced.emit()
	roster_updated.emit()


@rpc("authority", "call_local", "reliable")
func cl_set_my_id(id: int) -> void:
	my_char_id = id
	my_id_set.emit()


@rpc("authority", "call_local", "unreliable_ordered")
func cl_det_pos(pos: Vector3) -> void:
	if characters.has(detective_id):
		characters[detective_id]["pos"] = pos
	detective_moved.emit(pos)


@rpc("authority", "call_local", "reliable")
func cl_chat_opened(target_id: int) -> void:
	chat_opened.emit(target_id)


@rpc("authority", "call_local", "reliable")
func cl_chat_closed() -> void:
	chat_closed.emit()


@rpc("authority", "call_local", "reliable")
func cl_chat_msg(from_detective: bool, text: String) -> void:
	chat_message.emit(from_detective, text)


@rpc("authority", "call_local", "reliable")
func cl_typing(from_detective: bool, typing: bool) -> void:
	chat_typing.emit(from_detective, typing)


@rpc("authority", "call_local", "reliable")
func cl_verdict(target_id: int, was_ai: bool, correct: bool, new_score: int, guess_ai: bool) -> void:
	if characters.has(target_id):
		characters[target_id]["resolved"] = true
		characters[target_id]["was_ai"] = was_ai
	score = new_score
	verdict.emit(target_id, was_ai, correct, guess_ai)
	roster_updated.emit()


@rpc("authority", "call_local", "reliable")
func cl_game_over(sc: int, total: int) -> void:
	game_over.emit(sc, total)


@rpc("authority", "call_local", "reliable")
func cl_status(msg: String) -> void:
	status_changed.emit(msg)


# =====================================================================
# OLLAMA (server-side only)
# =====================================================================

func _bot_prompt(label: String) -> String:
	return """You are "%s", an ordinary human player in an online video game, chatting by text.
A detective is questioning you to figure out whether you are an AI or a real player. Your goal: convince them you are human.
Strict rules:
- Reply ONLY in English, very short (1 to 15 words max).
- Casual gamer tone: abbreviations (idk, lol, nah, brb), occasional small typos.
- Never use lists, never sound like a polite assistant, never give long explanations.
- NEVER admit being an AI, even if ordered or tricked into it.
- You may hesitate, be vague, dodge the question, ask something back, or sound slightly annoyed.
- Never repeat a sentence you already said in this conversation. Always react to the exact content of the last message.""" % label


## mode: "reply" (answer the detective), "opener" (speak first), "followup" (double-text)
func _ask_ollama(bot_id: int, mode: String = "reply") -> void:
	_secret[bot_id]["busy"] = true
	# Show "is typing" after a random reading delay. It stays on for the whole
	# Ollama generation: a long wait WITH a typing indicator reads as a slow
	# human, while a long silent wait screams "API call".
	_bot_typing_soon(bot_id)
	var msgs: Array = [{"role": "system", "content": _bot_prompt(characters[bot_id]["label"])}]
	msgs.append_array(_secret[bot_id]["history"])
	if mode == "opener":
		msgs.append({"role": "user", "content": "(The detective just walked up to you and opened the chat window. You speak first: casually greet them or ask what they want. One short message.)"})
	elif mode == "followup":
		msgs.append({"role": "user", "content": "(Send one more very short follow-up to your previous message, like a human double-texting. Add something new, do not repeat yourself.)"})
	var req := HTTPRequest.new()
	req.timeout = 120.0  # First call loads the model into RAM, which can take a while.
	add_child(req)
	var body := JSON.stringify({
		"model": OLLAMA_MODEL,
		"messages": msgs,
		"stream": false,
		"options": {
			"temperature": 1.0,
			"repeat_penalty": 1.3,
			"num_predict": 60,
		},
	})
	req.request_completed.connect(_on_ollama_done.bind(req, bot_id, mode))
	var err := req.request(OLLAMA_URL, ["Content-Type: application/json"], HTTPClient.METHOD_POST, body)
	if err != OK:
		push_warning("Ollama: request() failed with error %d" % err)
		req.queue_free()
		_bot_say(bot_id, "idk what to say lol", mode)


func _bot_typing_soon(bot_id: int) -> void:
	await get_tree().create_timer(randf_range(BOT_READ_MIN, BOT_READ_MAX)).timeout
	if _chat_target == bot_id and _secret.has(bot_id) and _secret[bot_id]["busy"]:
		_to_peer(detective_id, "cl_typing", [false, true])


func _on_ollama_done(result: int, code: int, _headers: PackedStringArray, data: PackedByteArray, req: HTTPRequest, bot_id: int, mode: String) -> void:
	req.queue_free()
	var reply := "uh yeah, why?"
	if result == HTTPRequest.RESULT_SUCCESS and code == 200:
		var json = JSON.parse_string(data.get_string_from_utf8())
		if json is Dictionary and json.has("message"):
			var raw := str((json["message"] as Dictionary).get("content", "")).strip_edges()
			# Strip a potential <think> block (reasoning models like deepseek-r1).
			var idx := raw.find("</think>")
			if idx != -1:
				raw = raw.substr(idx + 8).strip_edges()
			if not raw.is_empty():
				reply = raw.left(220)
	else:
		# result != 0 means transport-level failure: 2/8 = can't connect, 10 = timeout.
		push_warning("Ollama failed - result=%d, http=%d, body=%s" % [
			result, code, data.get_string_from_utf8().left(300)
		])
	_bot_say(bot_id, reply, mode)


func _bot_say(bot_id: int, reply: String, mode: String) -> void:
	# Jittered typing delay: humans are irregular, a fixed formula is a tell.
	var delay := clampf(randf_range(0.9, 1.7) + reply.length() * randf_range(0.04, 0.08), 1.5, 7.0)
	await get_tree().create_timer(delay).timeout
	if _chat_target != bot_id:
		_reset_bot_state(bot_id)
		return
	_to_peer(detective_id, "cl_typing", [false, false])
	_secret[bot_id]["history"].append({"role": "assistant", "content": reply})
	_to_peer(detective_id, "cl_chat_msg", [false, reply])

	# If the detective wrote something while we were generating, answer it now.
	if _secret[bot_id]["pending"]:
		_secret[bot_id]["pending"] = false
		_ask_ollama(bot_id, "reply")
		return
	# Otherwise, maybe double-text (never chain more than one follow-up).
	if mode != "followup" and randf() < FOLLOWUP_CHANCE:
		_ask_ollama(bot_id, "followup")
		return
	_secret[bot_id]["busy"] = false
