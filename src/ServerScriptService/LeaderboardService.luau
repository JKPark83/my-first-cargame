--!strict
--[[
	LeaderboardService
	-------------------
	글로벌 최고 기록(완주 시간) 순위표를 관리합니다.
	- OrderedDataStore에 시간(ms)을 저장 → 오름차순(빠른 순) 정렬
	- 이름은 별도 DataStore에 보관 (OrderedDataStore는 숫자만 저장 가능)
	- 상위 N개를 캐시해 잦은 조회를 방지
	- 라운지 전광판 / UI 패널이 이 캐시를 사용

	Studio에서 API 접근이 막혀있으면 자동으로 비활성(빈 순위) 처리됩니다.
]]

local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.GameConfig)

local LeaderboardService = {}

local TIME_STORE_NAME = "BestTimes_v1"
local NAME_STORE_NAME = "LbNames_v1"

local timeStore: OrderedDataStore? = nil
local nameStore: DataStore? = nil
do
	local ok = pcall(function()
		timeStore = DataStoreService:GetOrderedDataStore(TIME_STORE_NAME)
		nameStore = DataStoreService:GetDataStore(NAME_STORE_NAME)
	end)
	if not ok then
		warn("[LeaderboardService] DataStore 사용 불가 — 글로벌 순위표 비활성")
	end
end

export type Entry = { rank: number, name: string, time: number }

-- 캐시
local cachedTop: { Entry } = {}
local lastFetch = 0
local fetching = false

-- 신기록을 글로벌 순위에 제출
function LeaderboardService.submit(userId: number, name: string, timeSeconds: number)
	if not timeStore or not nameStore or timeSeconds <= 0 then
		return
	end
	local timeMs = math.floor(timeSeconds * 1000)
	task.spawn(function()
		-- 기존 기록보다 빠를 때만 갱신 (낮을수록 좋음)
		pcall(function()
			(timeStore :: OrderedDataStore):UpdateAsync("u_" .. userId, function(old)
				if old == nil or timeMs < old then
					return timeMs
				end
				return old
			end)
		end)
		pcall(function()
			(nameStore :: DataStore):SetAsync("u_" .. userId, name)
		end)
		-- 다음 조회 때 갱신되도록 캐시 무효화
		lastFetch = 0
	end)
end

-- 상위 N개를 가져와 캐시 (이름 조회 포함)
local function fetchTop()
	if not timeStore or not nameStore or fetching then
		return
	end
	fetching = true
	local ok, err = pcall(function()
		local pages = (timeStore :: OrderedDataStore):GetSortedAsync(true, GameConfig.Leaderboard.topCount)
		local page = pages:GetCurrentPage()
		local result: { Entry } = {}
		for rank, entry in ipairs(page) do
			local userId = tostring(entry.key):gsub("^u_", "")
			local nm = "플레이어"
			local nok, nresult = pcall(function()
				return (nameStore :: DataStore):GetAsync("u_" .. userId)
			end)
			if nok and type(nresult) == "string" then
				nm = nresult
			end
			result[rank] = {
				rank = rank,
				name = nm,
				time = (tonumber(entry.value) or 0) / 1000,
			}
		end
		cachedTop = result
		lastFetch = os.clock()
	end)
	fetching = false
	if not ok then
		warn("[LeaderboardService] 순위 조회 실패: " .. tostring(err))
	end
end

-- 캐시된 상위 목록 반환 (필요 시 갱신)
function LeaderboardService.getTop(): { Entry }
	if os.clock() - lastFetch > GameConfig.Leaderboard.cacheSeconds then
		fetchTop()
	end
	return cachedTop
end

function LeaderboardService.init()
	-- 주기적 백그라운드 갱신
	task.spawn(function()
		while true do
			fetchTop()
			task.wait(GameConfig.Leaderboard.cacheSeconds)
		end
	end)
end

return LeaderboardService
