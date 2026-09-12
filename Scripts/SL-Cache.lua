local sqlite3 = sqlite3 -- Provided by lsqlite3

-- Guard every Cache_DBG call site with this flag so the string.format argument is not
-- evaluated when logging is off; it was measured at roughly the cost of the SQL step.
local CACHE_DEBUG = false
local function Cache_DBG(message)
	lua.Info(message)
end

local function CacheInitialize()
	if not sqlite3 then return end
	local db = sqlite3.open("simplylove.db")
	if not db then return end
	db:exec("CREATE TABLE meta (schema_version INTEGER PRIMARY KEY);")

	db:exec([[
		CREATE TABLE score_cache (
			player TEXT NOT NULL,
			hash TEXT NOT NULL,
			score TEXT NOT NULL,
			score_type TEXT NOT NULL,
			score_source TEXT NOT NULL,
			score_color TEXT,
			UNIQUE(
				player,
				hash,
				score_source,
				score_type
			) ON CONFLICT REPLACE
		);
	]])

	if CACHE_DEBUG then Cache_DBG("Created tables") end
	db:exec("PRAGMA journal_mode=WAL;")
  	db:exec("PRAGMA synchronous=NORMAL;")
	return db
end

local Db = CacheInitialize()
if not Db then
	lua.Warn("Initializing SL cache failed")
end

-- Statements are prepared once and reused. Parsing the SQL was measured at roughly the
-- same cost as executing it, so each call only binds, steps and resets.
-- reset() returns the statement to its initial state so it can be stepped again, and
-- releases any lock the previous step held. Bindings are overwritten by bind_values.
local SetStmt = Db and Db:prepare("INSERT INTO score_cache(player, hash, score, score_type, score_source, score_color) VALUES (?, ?, ?, ?, ?, ?)")
local LoadStmt = Db and Db:prepare("SELECT hash, score_type, score_source, score, score_color FROM score_cache WHERE player=?")
if Db and not (SetStmt and LoadStmt) then
	lua.Warn("Preparing SL cache statements failed")
	Db = nil
end

-- In-memory mirror of the score_cache table, one inner table per player.
-- Mem[player][key] is { score, score_color }. On the first read for a player, every row
-- that player has is loaded in one query and Loaded[player] is set; from then on a
-- missing key is authoritative and SQLite is never read again for that player.
-- Every write goes through CacheSet, which updates both, so the mirror cannot drift
-- from the database within a session.
local Mem = {}
local Loaded = {}

local function MemKey(hash, score_type, score_source)
	return hash .. "|" .. score_type .. "|" .. score_source
end

local function MemTable(player)
	local t = Mem[player]
	if t == nil then
		t = {}
		Mem[player] = t
	end
	return t
end

-- Load all of a player's rows into memory once. The unique index leads with player,
-- so this is an index range scan. Called lazily from CacheGet so no profile-load hook
-- is needed; the one-time cost lands on the first wheel item Set of the session.
local function MemLoad(player)
	if Loaded[player] or not Db then return end
	local t = SLProf.Begin()
	local mem = MemTable(player)
	local rows = 0
	LoadStmt:bind_values(player)
	while LoadStmt:step() == sqlite3.ROW do
		local hash = LoadStmt:get_value(0)
		local score_type = LoadStmt:get_value(1)
		local score_source = LoadStmt:get_value(2)
		mem[MemKey(hash, score_type, score_source)] = { LoadStmt:get_value(3), LoadStmt:get_value(4) }
		rows = rows + 1
	end
	LoadStmt:reset()
	Loaded[player] = true
	SLProf.Count("Cache.Load.rows", rows)
	SLProf.End("Cache.Load", t)
end

---@param player string
---@param hash string
---@param score string
---@param score_type string
---@param score_source string
---@param score_color string?
local function CacheSet(player, hash, score, score_type, score_source, score_color)
	MemTable(player)[MemKey(hash, score_type, score_source)] = { score, score_color }
	if not Db then return end

	if CACHE_DEBUG then Cache_DBG(string.format("CacheSet %s %s %s %s %s %s", player, hash, score, score_type, score_source, score_color or "nil")) end
	local t_all = SLProf.Begin()
	local t = SLProf.Begin()
	SetStmt:bind_values(player, hash, score, score_type, score_source, score_color)
	SetStmt:step()
	SLProf.End("Cache.Set.step", t)
	t = SLProf.Begin()
	SetStmt:reset()
	SLProf.End("Cache.Set.reset", t)
	SLProf.End("Cache.Set", t_all)
end

---@param player string
---@param hash string
---@param score_type string
---@param score_source string
---@return string?, string?
local function CacheGet(player, hash, score_type, score_source)
	MemLoad(player)
	local hit = MemTable(player)[MemKey(hash, score_type, score_source)]
	if hit == nil then
		SLProf.Count("Cache.Mem.miss")
		return nil, nil
	end
	SLProf.Count("Cache.Mem.hit")
	return hit[1], hit[2]
end

---@param player string
---@param hash string
---@param score string
function CacheSetGSEX(player, hash, score)
	CacheSet(player, hash, score, "ex", "groovestats", nil)
end

---@param player string
---@param hash string
---@return string?, string?
function CacheGetGSEX(player, hash)
	return CacheGet(player, hash, "ex", "groovestats")
end

---@param player string
---@param hash string
---@param score string
---@param color string
function CacheSetLocalEX(player, hash, score, color)
	CacheSet(player, hash, score, "ex", "local", color)
end

---@param player string
---@param hash string
---@return string?, string?
function CacheGetLocalEX(player, hash)
	return CacheGet(player, hash, "ex", "local")
end

---@param player string
---@param hash string
---@param score string
function CacheSetGSITG(player, hash, score)
	CacheSet(player, hash, score, "itg", "groovestats", nil)
end

---@param player string
---@param hash string
---@return string?, string?
function CacheGetGSITG(player, hash)
	return CacheGet(player, hash, "itg", "groovestats")
end

---@param player string
---@param hash string
---@param score string
---@param color string
function CacheSetLocalITG(player, hash, score, color)
	CacheSet(player, hash, score, "itg", "local", color)
end

---@param player string
---@param hash string
---@return string?, string?
function CacheGetLocalITG(player, hash)
	return CacheGet(player, hash, "itg", "local")
end

-- ArrowCloud rows carry a colour index only when the grade pins the lamp down
-- (see GradeToAwardMapIndex in ScreenSelectMusic overlay/ArrowCloudScores.lua);
-- otherwise the colour is nil and the wheel draws the score white.

---@param player string
---@param hash string
---@param score string
---@param color string?
function CacheSetACEX(player, hash, score, color)
	CacheSet(player, hash, score, "ex", "arrowcloud", color)
end

---@param player string
---@param hash string
---@return string?, string?
function CacheGetACEX(player, hash)
	return CacheGet(player, hash, "ex", "arrowcloud")
end

---@param player string
---@param hash string
---@param score string
---@param color string?
function CacheSetACITG(player, hash, score, color)
	CacheSet(player, hash, score, "itg", "arrowcloud", color)
end

---@param player string
---@param hash string
---@return string?, string?
function CacheGetACITG(player, hash)
	return CacheGet(player, hash, "itg", "arrowcloud")
end