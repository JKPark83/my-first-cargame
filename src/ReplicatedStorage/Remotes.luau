--!strict
--[[
	Remotes
	--------
	클라이언트 ↔ 서버 통신에 쓰는 RemoteEvent / RemoteFunction을
	한곳에서 정의하고 가져옵니다.

	서버에서 먼저 require 되면 인스턴스를 생성하고,
	클라이언트에서 require 되면 생성될 때까지 기다렸다가 가져옵니다.

	사용 예)
		local Remotes = require(ReplicatedStorage.Remotes)
		Remotes.Event("RequestBuyCar"):FireServer(carId)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local FOLDER_NAME = "GameRemotes"

-- 정의할 원격 통신 목록
local EVENT_NAMES = {
	-- 클라 → 서버
	"RequestBuyCar", -- 차량 구매 요청 (carId)
	"RequestSelectCar", -- 차량 선택 요청 (carId)
	"RequestSaveCustomization", -- 커스터마이징 저장 (table)
	"RequestJoinQueue", -- 대기열 참가
	"RequestLeaveQueue", -- 대기열 떠나기
	"CarControlInput", -- 주행 입력 (throttle, steer, ...)
	"RequestUseItem", -- 보유 아이템 사용 요청
	"RequestDriveFix", -- 출발 후 차가 안 움직일 때(소유권 누락) 서버에 재탑승/소유권 복구 요청

	-- 서버 → 클라
	"ItemUpdated", -- 보유 아이템 변경 (itemId 또는 "none")
	"ItemEffect", -- 아이템 발동 연출 (kind, ...)
	"PlayerDataUpdated", -- 플레이어 데이터(머니/보유차/커스텀) 갱신
	"QueueStateChanged", -- 대기열 상태/카운트다운 변경
	"RaceStateChanged", -- 경주 상태(시작/진행/종료) 변경
	"RaceLoading", -- 경주 진입 전환(트랙 생성/순간이동) 동안 로딩 화면 표시 (bool)
	"RaceSetup", -- 경주 시작 시 트랙 외곽선/바운드(미니맵용) 전달
	"RaceProgress", -- 실시간 순위/차량 위치(미니맵 HUD)
	"RaceCountdown", -- 경주 시작 카운트다운
	"RaceFinished", -- 경주 결과(순위/보상)
	"PodiumStart", -- 시상대 연출 시작 (results, top3) 서버→클라
	"LeaderboardUpdated", -- 글로벌 최고기록 순위 갱신
	"Notify", -- 일반 알림 메시지
	"OpenGarageUI", -- 차량 선택 패드 진입 → 클라이언트 차고 UI 열기
}

local FUNCTION_NAMES = {
	"GetPlayerData", -- 최초 접속 시 데이터 일괄 요청
	"GetLeaderboard", -- 글로벌 순위표 + 개인 최고기록 요청
}

local Remotes = {}

local function getFolder(): Folder
	if RunService:IsServer() then
		local folder = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
		if not folder then
			folder = Instance.new("Folder")
			folder.Name = FOLDER_NAME
			folder.Parent = ReplicatedStorage
		end
		return folder :: Folder
	else
		return ReplicatedStorage:WaitForChild(FOLDER_NAME) :: Folder
	end
end

local function getOrCreate(folder: Folder, name: string, className: string): Instance
	if RunService:IsServer() then
		local inst = folder:FindFirstChild(name)
		if not inst then
			inst = Instance.new(className)
			inst.Name = name
			inst.Parent = folder
		end
		return inst
	else
		return folder:WaitForChild(name)
	end
end

-- 서버에서 require 시 모든 원격 객체를 미리 생성
local function ensureAll()
	local folder = getFolder()
	if RunService:IsServer() then
		for _, name in ipairs(EVENT_NAMES) do
			getOrCreate(folder, name, "RemoteEvent")
		end
		for _, name in ipairs(FUNCTION_NAMES) do
			getOrCreate(folder, name, "RemoteFunction")
		end
	end
end

ensureAll()

-- 이름으로 RemoteEvent 가져오기
function Remotes.Event(name: string): RemoteEvent
	local folder = getFolder()
	return getOrCreate(folder, name, "RemoteEvent") :: RemoteEvent
end

-- 이름으로 RemoteFunction 가져오기
function Remotes.Function(name: string): RemoteFunction
	local folder = getFolder()
	return getOrCreate(folder, name, "RemoteFunction") :: RemoteFunction
end

return Remotes
