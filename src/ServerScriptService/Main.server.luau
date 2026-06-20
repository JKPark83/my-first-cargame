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

-- 보유 아이템 사용 (바나나/로켓/물풍선)
Remotes.Event("RequestUseItem").OnServerEvent:Connect(function(player)
	RaceManager.useItem(player)
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

-- 라운지 패드 터치 공통 처리: 사람(Humanoid)만 통과 + 2초 디바운스
local padDebounce: { [number]: number } = {} -- 경주 참가 패드
local csDebounce: { [number]: number } = {} -- 차량 선택 패드

local function acceptPadTouch(hit: BasePart, store: { [number]: number }): Player?
	local character = hit.Parent
	local player = character and Players:GetPlayerFromCharacter(character)
	if not player then
		return nil
	end
	-- 차량 파트 등 비캐릭터 접촉 무시: Humanoid가 있어야 통과
	if not (character and character:FindFirstChildOfClass("Humanoid")) then
		return nil
	end
	local now = os.clock()
	if store[player.UserId] and now - store[player.UserId] < 2 then
		return nil
	end
	store[player.UserId] = now
	return player
end

-- 패드에 ProximityPrompt 부착: 밟기(Touched)는 환경에 따라 누락될 수 있어
-- [E] 상호작용으로 확실하게 트리거되도록 보강한다.
local function addPadPrompt(pad: BasePart, actionText: string, objectText: string): ProximityPrompt
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = actionText
	prompt.ObjectText = objectText
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.HoldDuration = 0
	prompt.RequiresLineOfSight = false
	prompt.MaxActivationDistance = 14
	prompt.UIOffset = Vector2.new(0, 0)
	prompt.Parent = pad
	return prompt
end

-- 경주 참가 패드: 밟거나 [E]로 대기열 참가
local queuePad = LoungeBuilder.getQueuePad()
if queuePad then
	queuePad.Touched:Connect(function(hit)
		local player = acceptPadTouch(hit, padDebounce)
		if player then
			RaceManager.joinQueue(player)
		end
	end)
	local queuePrompt = addPadPrompt(queuePad, "경주 참가", "🏁 레이스")
	queuePrompt.Triggered:Connect(function(player)
		RaceManager.joinQueue(player)
	end)
end

-- 차량 선택 패드: 밟거나 [E]로 차고 UI 열기 (경주 중에는 차단)
local carSelectPad = LoungeBuilder.getCarSelectPad()
if carSelectPad then
	carSelectPad.Touched:Connect(function(hit)
		if RaceManager.isRacing() then
			return
		end
		local player = acceptPadTouch(hit, csDebounce)
		if player then
			Remotes.Event("OpenGarageUI"):FireClient(player)
		end
	end)
	local csPrompt = addPadPrompt(carSelectPad, "차고 열기", "🚗 차량 선택")
	csPrompt.Triggered:Connect(function(player)
		if RaceManager.isRacing() then
			return
		end
		Remotes.Event("OpenGarageUI"):FireClient(player)
	end)
end

-- 퇴장 시 디바운스 테이블 정리 (메모리 누수 방지)
Players.PlayerRemoving:Connect(function(p)
	padDebounce[p.UserId] = nil
	csDebounce[p.UserId] = nil
end)

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
