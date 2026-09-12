-- -----------------------------------------------------------------------
-- ArrowCloud helpers shared between the ArrowCloud module and the theme.
--
-- The module (Modules/ArrowCloud.lua) owns the ArrowCloud.ini file in the
-- player's profile: it creates it, writes the key after a QR login and reads it
-- back for score submission. This file only mirrors the key into SL[pn] so that
-- screens which do not go through the module (the music wheel score cache) can
-- authenticate. The module calls ParseArrowCloudIni itself after a login so the
-- in-memory copy is refreshed without a profile reload.

local profile_slot = {
	[PLAYER_1] = "ProfileSlot_Player1",
	[PLAYER_2] = "ProfileSlot_Player2"
}

-- Reads <profile>/ArrowCloud.ini and stores the API key in SL[pn].ArrowCloudApiKey.
-- Read-only on purpose: the ini is created and rewritten by the module.
ParseArrowCloudIni = function(player)
	if not player or not profile_slot[player] then return end

	local pn = ToEnumShortString(player)
	SL[pn].ArrowCloudApiKey = ""

	local dir = PROFILEMAN:GetProfileDir(profile_slot[player])
	-- We require an explicit profile to be loaded.
	if not dir or #dir == 0 then return end

	local path = dir .. "ArrowCloud.ini"
	if not FILEMAN:DoesFileExist(path) then return end

	local contents = IniFile.ReadFile(path)
	local section = contents and contents["ArrowCloud"]
	if type(section) ~= "table" then return end

	local key = section["ApiKey"]
	if type(key) == "string" and #key > 0 then
		SL[pn].ArrowCloudApiKey = key
	end
end
