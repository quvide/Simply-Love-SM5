-- Song wheel tech analysis

local player = ...
local pn = ToEnumShortString(player)

-- array style to keep ordering in ipairs
local techtypes = {
	{
		tcc = "TechCountsCategory_Brackets",
		Condensed = {
			symbol_light  = "b",
			symbol_medium = "B",
			symbol_heavy  = "B+"
		},
		Verbose = {
			symbol_light  = "BR- ",
			symbol_medium = "BR ",
			symbol_heavy  = "BR+ "
		}
	},
	{
		tcc = "TechCountsCategory_Crossovers",
		Condensed = {
			symbol_light  = "x",
			symbol_medium = "X",
			symbol_heavy  = "X+"
		},
		Verbose = {
			symbol_light  = "XO- ",
			symbol_medium = "XO ",
			symbol_heavy  = "XO+ "
		}
	},
	{
		tcc = "TechCountsCategory_Footswitches",
		Condensed = {
			symbol_light  = "f",
			symbol_medium = "F",
			symbol_heavy  = "F+"
		},
		Verbose = {
			symbol_light  = "FS- ",
			symbol_medium = "FS ",
			symbol_heavy  = "FS+ "
		}
	},
	{
		tcc = "TechCountsCategory_Sideswitches",
		Condensed = {
			symbol_light  = "s",
			symbol_medium = "S",
			symbol_heavy  = "S+"
		},
		Verbose = {
			symbol_light  = "SS ",
			symbol_medium = "SS ",
			symbol_heavy  = "SS+ "
		}
	},
	{
		tcc = "TechCountsCategory_Jacks",
		Condensed = {
			symbol_light  = "j",
			symbol_medium = "J",
			symbol_heavy  = "J+"
		},
		Verbose = {
			symbol_light  = "JS- ",
			symbol_medium = "JS ",
			symbol_heavy  = "JS+ "
		}
	},
	{
		tcc = "TechCountsCategory_Doublesteps",
		Condensed = {
			symbol_light  = "d",
			symbol_medium = "D",
			symbol_heavy  = "D+"
		},
		Verbose = {
			symbol_light  = "DS- ",
			symbol_medium = "DS ",
			symbol_heavy  = "DS+ "
		}
	}
}

-- TODO: 2 actors, one for each player. Could this be one actor that draws both players?
local af = Def.BitmapText {
	Font = "Common Normal",
	Text = "",
	InitCommand = function(self)
		-- TODO: is this a good position? wide screen should have space to make the music wheel wider
		-- position on right side of the song title, left of ITL EX
		-- fits the maximum 6 techs
		self:visible(false)
		self:horizalign(right)
		self:zoom(0.6)
		if DarkUI() then self:diffuse(0, 0, 0, 1) end
	end,
	-- Set is called by MusicWheelItem::HandleMessage. There are a bunch of messages that can trigger it.
	SetCommand = function(self, params)
		-- default to invisible, if we fail to process something, we just return immediately and stay hidden
		self:visible(false)

		-- params is null sometimes for some reason?
		-- this seems to happen when changing songs and the previous diff doesn't exist for the new one
		-- we eventually do seem to get valid params
		if not params or not params.Song then
			-- SM("Null params")
			return
		end

		-- song of _this_ actor (every song on the music wheel)
		local song = params.Song
		if song == nil then
			-- SM("Song is nil")
			return
		end

		-- TODO: is there a better way of laying this out?
		local x_offset = 10
		if IsItlSong(song, player) then
			x_offset = 60
		end
		self:x(_screen.w / (WideScale(2.15, 2.14)) - x_offset)

		-- steps of _this_ actor
		local steps = SongUtil.GetPlayableSteps(song)

		-- visual vertical position depending on if 1 / 2 players are playing
		if GAMESTATE:GetNumSidesJoined() == 2 then
			if player == PLAYER_1 then
				self:y(-6)
			else
				self:y(6)
			end
		else
			self:y(0)
		end

		-- Minimum occurrence of tech to be counted.
		-- Static in sense that it doesn't depend on other chart properties, like its length / stepcount
		local static_threshold = 2

		local currentSteps = GAMESTATE:GetCurrentSteps(player)
		if currentSteps == nil then
			-- SM("currentSteps nil")
			return
		end

		local currentDifficulty = currentSteps:GetDifficulty()

		-- Like grades, show tech that matches the currently selected difficulty.
		local stepsToCheck = nil
		if #steps == 1 then
			-- If there's only a single difficulty, don't try to match the difficulty. Just show the only one.
			stepsToCheck = steps[1]
		else
			-- TODO: Match the engine (or theme?) behaviour on which difficulty will be autoselected from this chart
			for k, v in ipairs(steps) do
				if v:GetDifficulty() == currentDifficulty then
					stepsToCheck = v
				end
			end
		end

		if stepsToCheck == nil then
			-- SM("No steps to check")
			return
		end

		-- Modern tech parser output
		local tech = stepsToCheck:GetTechCounts(pn)

		-- Legacy radar values, we only currently need this for the step count. In the future could have jumps / rolls?
		local radar = stepsToCheck:GetRadarValues(pn)

		local found_techtypes = {}

		-- Total steps in the difficulty
		local stepcount = radar:GetValue("RadarCategory_Notes")

		local light_threshold = 0.005 * stepcount
		local normal_threshold = 0.02 * stepcount
		local heavy_threshold = 0.05 * stepcount

		-- The beef, convert the tech parser results into textual notation
		for key, t in ipairs(techtypes) do
			local tech_amount = tech:GetValue(t.tcc)
			local symbol = ""
			local t_symbols = t[ThemePrefs.Get("MusicWheelTechNotation")]

			if tech_amount > heavy_threshold then
				symbol = t_symbols.symbol_heavy
			elseif tech_amount > normal_threshold then
				symbol = t_symbols.symbol_medium
			elseif tech_amount > static_threshold and tech_amount > light_threshold then
				symbol = t_symbols.symbol_light
			end

			found_techtypes[#found_techtypes + 1] = symbol
		end

		local text = ""

		for key, value in ipairs(found_techtypes) do
			text = text .. value
		end

		self:settext(text)
		self:visible(true)
	end,
}

return af