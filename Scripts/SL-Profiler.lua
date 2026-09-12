-- Lightweight wall-clock profiler for the music wheel score path.
--
-- Usage:
--   local t = SLProf.Begin()
--   ... work ...
--   SLProf.End("Section.name", t)
--   SLProf.Count("Some.counter", n)
--
-- Results are written to Logs/Log.txt via Trace(), prefixed with [SLProf],
-- every DumpInterval seconds of activity (MaybeDump is called from Score.lua's
-- SetCommand). Each dump resets the accumulators, so every dump is a fresh window.
-- Set SLProf.Enabled = false to turn every call into a no-op.

SLProf = {
	Enabled = false,
	DumpInterval = 10, -- seconds of activity between dumps
}

local stats = {}     -- name -> { n, total, max, min } in seconds
local counters = {}  -- name -> n
local last_dump = nil
local now = GetTimeSinceStart

function SLProf.Begin()
	if not SLProf.Enabled then return nil end
	return now()
end

function SLProf.End(name, t0)
	if t0 == nil then return end
	local dt = now() - t0
	local s = stats[name]
	if s == nil then
		s = { n = 0, total = 0, max = 0, min = math.huge }
		stats[name] = s
	end
	s.n = s.n + 1
	s.total = s.total + dt
	if dt > s.max then s.max = dt end
	if dt < s.min then s.min = dt end
	return dt
end

function SLProf.Count(name, n)
	if not SLProf.Enabled then return end
	counters[name] = (counters[name] or 0) + (n or 1)
end

function SLProf.MaybeDump()
	if not SLProf.Enabled then return end
	local t = now()
	if last_dump == nil then
		last_dump = t
		return
	end
	if t - last_dump >= SLProf.DumpInterval then
		SLProf.Dump("periodic")
	end
end

function SLProf.Dump(reason)
	if not SLProf.Enabled then return end
	local rows = {}
	for name, s in pairs(stats) do rows[#rows + 1] = { name = name, s = s } end
	table.sort(rows, function(a, b) return a.s.total > b.s.total end)

	Trace(("[SLProf] ---- %s ----"):format(reason or "dump"))
	Trace(("[SLProf] %-28s %7s %10s %9s %9s %9s"):format("section", "calls", "total ms", "avg us", "max us", "min us"))
	for _, r in ipairs(rows) do
		local s = r.s
		Trace(("[SLProf] %-28s %7d %10.2f %9.1f %9.1f %9.1f"):format(
			r.name, s.n, s.total * 1000, s.total / s.n * 1e6, s.max * 1e6, s.min * 1e6))
	end

	local cnames = {}
	for name in pairs(counters) do cnames[#cnames + 1] = name end
	table.sort(cnames)
	for _, name in ipairs(cnames) do
		Trace(("[SLProf] count %-22s %7d"):format(name, counters[name]))
	end

	stats = {}
	counters = {}
	last_dump = now()
end
