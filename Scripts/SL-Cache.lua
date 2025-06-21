
local function CacheInitialize()
	local db = sqlite3.open("simplylove.db")
	db:exec("CREATE TABLE meta (schema_version INTEGER PRIMARY KEY);")
	db:exec("CREATE TABLE gs_ex_cache (playerid TEXT, charthash TEXT, exscore TEXT, UNIQUE(playerid, charthash) ON CONFLICT REPLACE);")
	db:exec("CREATE TABLE steps_hash_cache (filepath TEXT, difficulty TEXT, description TEXT, charthash TEXT, UNIQUE(filepath, difficulty, description) ON CONFLICT REPLACE);")
	-- lua.Info("Created tables")

	return db
end

local Db = CacheInitialize()

function CacheSetGSEX(charthash, playerid, exscore)
	local db = Db
	-- lua.Info(string.format("CacheGSEX(%s, %s, %s)", charthash, playerid, exscore))
	local stmt = db:prepare("INSERT INTO gs_ex_cache(playerid, charthash, exscore) VALUES (?, ?, ?)")
	stmt:bind_values(playerid, charthash, exscore)
	stmt:step()
	stmt:finalize()
end

function CacheGetGSEX(charthash, playerid)
	local db = Db
    -- lua.Info(string.format("GetCachedGSEX(%s, %s)", charthash, playerid))
	local stmt = db:prepare("SELECT exscore FROM gs_ex_cache WHERE charthash=? AND playerid=?")
	stmt:bind_values(charthash, playerid)
	local ret_step = stmt:step()
	if ret_step ~= sqlite3.ROW then
		return nil
	end
	local ret_value = stmt:get_value(0)
    -- lua.Info(string.format("CacheGetGSEX returning %s", ret_value))
	stmt:finalize()
	return ret_value
end

function CacheSetChartHash(filepath, difficulty, description, hash)
	-- lua.Info(string.format("CacheChartHash(%s, %s, %s, %s)", filepath, difficulty, description, hash))
	local db = Db
	local stmt = db:prepare("INSERT INTO steps_hash_cache(filepath, difficulty, description, charthash) VALUES (?, ?, ?, ?)")
	stmt:bind_values(filepath, difficulty, description, hash)
	stmt:step()
	stmt:finalize()
end

function CacheGetChartHash(filepath, difficulty, description)
	-- lua.Info(string.format("GetCacheChartHash(%s, %s, %s)", filepath, difficulty, description))
	local db = Db
	local stmt = db:prepare("SELECT charthash FROM steps_hash_cache WHERE filepath=? AND difficulty=? AND description=?")
	stmt:bind_values(filepath, difficulty, description)
	local ret_step = stmt:step()
	if ret_step ~= sqlite3.ROW then
		return nil
	end
	local retval = stmt:get_value(0)
	-- lua.Info(string.format("GetCacheChartHash returning %s", retval))
	stmt:finalize()
	return retval
end
