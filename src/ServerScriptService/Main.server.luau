--!strict
--[[
	Main (서버 진입점)
	-------------------
	모든 서버 시스템을 초기화하고 RemoteEvent 핸들러를 연결합니다.
	실행 순서:
	  1) 라운지 생성
	  2) 데이터 매니저 초기화 (DataStore)
	  3) 상점/경주 서비스 초기화
	  4) 원격 요청 핸들러 연결
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Remotes)

local LoungeBuilder = require(script.Parent.LoungeBuilder)
local DataManager = require(script.Parent.DataManager)
local ShopService = require(script.Parent.ShopService)
local RaceManager = require(script.Parent.RaceManager)
local LeaderboardService = require(script.Parent.LeaderboardService)

-- 1) 라운지 생성
LoungeBuilder.build()

-- 2) 데이터 매니저
DataManager.init()

-- 3) 서비스 초기화
ShopService.init()
RaceManager.init()
LeaderboardService.init()

-- 4) 경주 관련 원격 요청 연결
Remotes.Event("RequestJoinQueue").OnServerEvent:Connect(function(player)
	RaceManager.joinQueue(player)
end)

Remotes.Event("RequestLeaveQueue").OnServerEvent:Connect(function(player)
	RaceManager.leaveQueue(player)
end)

-- 클라이언트가 최초 데이터 일괄 요청 시 응답
Remotes.Function("GetPlayerData").OnServerInvoke = function(player)
	-- 로드 완료까지 잠시 대기
	local waited = 0
	while not DataManager.isLoaded(player) and waited < 10 do
		task.wait(0.2)
		waited += 0.2
	end
	return DataManager.get(player)
end

-- 글로벌 순위표 + 개인 최고기록 요청
Remotes.Function("GetLeaderboard").OnServerInvoke = function(player)
	local data = DataManager.get(player)
	return {
		top = LeaderboardService.getTop(),
		personalBest = data and data.stats.bestTime or 0,
	}
end

-- 캐릭터 스폰 시 라운지 위치로 이동
local function onCharacterAdded(character: Model)
	task.wait(0.1)
	local hrp = character:WaitForChild("HumanoidRootPart", 5)
	if hrp then
		character:PivotTo(LoungeBuilder.getSpawnCFrame() * CFrame.new(math.random(-15, 15), 0, math.random(-15, 15)))
	end
end

local function onPlayerAdded(player: Player)
	if player.Character then
		onCharacterAdded(player.Character)
	end
	player.CharacterAdded:Connect(onCharacterAdded)
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in ipairs(Players:GetPlayers()) do
	onPlayerAdded(player)
end

-- 경주 참가 패드: 밟으면 대기열 참가
local queuePad = LoungeBuilder.getQueuePad()
if queuePad then
	local debounce: { [number]: number } = {}
	queuePad.Touched:Connect(function(hit)
		local character = hit.Parent
		local player = character and Players:GetPlayerFromCharacter(character)
		if not player then
			return
		end
		local now = os.clock()
		if debounce[player.UserId] and now - debounce[player.UserId] < 2 then
			return
		end
		debounce[player.UserId] = now
		RaceManager.joinQueue(player)
	end)
end

-- 라운지 전광판 주기 갱신 + 전체 클라이언트 순위 브로드캐스트
task.spawn(function()
	while true do
		local top = LeaderboardService.getTop()
		LoungeBuilder.updateLeaderboard(top)
		Remotes.Event("LeaderboardUpdated"):FireAllClients(top)
		task.wait(30)
	end
end)

print("[Server] 자동차 경주 게임 서버 초기화 완료 🏁")
