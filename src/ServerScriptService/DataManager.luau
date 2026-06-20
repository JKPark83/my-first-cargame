--!strict
--[[
	DataManager
	------------
	플레이어 데이터의 영구 저장을 담당합니다.
	- 머니, 보유 차량, 선택 차량, 차량별 커스터마이징을 DataStore에 저장
	- 접속 시 로드(재시도 포함), 퇴장/자동/서버종료 시 저장
	- 세션 캐시로 잦은 DataStore 호출을 줄임

	다른 서버 모듈은 이 모듈의 API만 사용해 데이터를 다룹니다.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.GameConfig)
local Remotes = require(ReplicatedStorage.Remotes)

local DataManager = {}

local STORE_NAME = "PlayerData_v1"
local AUTOSAVE_INTERVAL = 120 -- 초
local MAX_RETRIES = 4

-- Studio에서 API 접근이 막혀있을 수 있으므로 pcall로 감쌈
local store: DataStore? = nil
do
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME)
	end)
	if ok then
		store = result
	else
		warn("[DataManager] DataStore 사용 불가 (Studio API 설정 확인). 세션 임시 저장으로 동작합니다.")
	end
end

export type Customization = {
	bodyColor: { number }, -- {r,g,b} 0~255
	wheelColor: { number },
	neonColor: { number },
	sticker: string, -- 스티커 id
	plate: string, -- 번호판 텍스트
}

export type PlayerData = {
	money: number,
	ownedCars: { [string]: boolean }, -- carId -> 보유 여부
	selectedCar: string,
	customizations: { [string]: Customization }, -- carId -> 커스텀
	stats: {
		races: number,
		wins: number,
		bestTime: number, -- 개인 최고 완주 기록(초). 0 = 기록 없음
	},
}

-- 세션 캐시: userId -> PlayerData
local cache: { [number]: PlayerData } = {}
-- 로드 완료 여부
local loaded: { [number]: boolean } = {}

-- =====================================================================
-- 기본 데이터 / 검증
-- =====================================================================
local function defaultData(): PlayerData
	local owned = {}
	-- 기본 보유 차량(무료 초보차) 지급
	for _, car in ipairs(GameConfig.Cars) do
		if car.price == 0 and car.currency == "Money" then
			owned[car.id] = true
		end
	end
	return {
		money = GameConfig.Economy.startingMoney,
		ownedCars = owned,
		selectedCar = GameConfig.Economy.defaultCarId,
		customizations = {},
		stats = { races = 0, wins = 0, bestTime = 0 },
	}
end

-- 저장된 데이터가 손상/구버전이어도 안전하도록 기본값과 병합
local function reconcile(raw: any): PlayerData
	local data = defaultData()
	if type(raw) ~= "table" then
		return data
	end
	if type(raw.money) == "number" then
		data.money = raw.money
	end
	if type(raw.ownedCars) == "table" then
		for id, v in pairs(raw.ownedCars) do
			if GameConfig.CarsById[id] and v == true then
				data.ownedCars[id] = true
			end
		end
	end
	if type(raw.selectedCar) == "string" and data.ownedCars[raw.selectedCar] then
		data.selectedCar = raw.selectedCar
	end
	if type(raw.customizations) == "table" then
		for id, c in pairs(raw.customizations) do
			if GameConfig.CarsById[id] and type(c) == "table" then
				data.customizations[id] = c
			end
		end
	end
	if type(raw.stats) == "table" then
		data.stats.races = tonumber(raw.stats.races) or 0
		data.stats.wins = tonumber(raw.stats.wins) or 0
		data.stats.bestTime = tonumber(raw.stats.bestTime) or 0
	end
	return data
end

-- =====================================================================
-- 로드 / 저장
-- =====================================================================
local function loadData(player: Player)
	local userId = player.UserId
	local data: PlayerData

	if store then
		local key = "u_" .. userId
		local attempt = 0
		local raw = nil
		local success = false
		while attempt < MAX_RETRIES and not success do
			attempt += 1
			local ok, result = pcall(function()
				return store:GetAsync(key)
			end)
			if ok then
				success = true
				raw = result
			else
				warn(("[DataManager] 로드 실패(%d/%d) %s: %s"):format(attempt, MAX_RETRIES, player.Name, tostring(result)))
				task.wait(2 ^ attempt)
			end
		end
		data = reconcile(raw)
	else
		data = defaultData()
	end

	cache[userId] = data
	loaded[userId] = true
	DataManager.pushToClient(player)
end

function DataManager.save(player: Player): boolean
	local userId = player.UserId
	local data = cache[userId]
	if not data or not store then
		return false
	end
	local key = "u_" .. userId
	local attempt = 0
	while attempt < MAX_RETRIES do
		attempt += 1
		local ok, err = pcall(function()
			store:UpdateAsync(key, function()
				return data
			end)
		end)
		if ok then
			return true
		else
			warn(("[DataManager] 저장 실패(%d/%d) %s: %s"):format(attempt, MAX_RETRIES, player.Name, tostring(err)))
			task.wait(2 ^ attempt)
		end
	end
	return false
end

-- =====================================================================
-- 공개 API
-- =====================================================================
function DataManager.get(player: Player): PlayerData?
	return cache[player.UserId]
end

function DataManager.isLoaded(player: Player): boolean
	return loaded[player.UserId] == true
end

-- 클라이언트로 현재 데이터 전송
function DataManager.pushToClient(player: Player)
	local data = cache[player.UserId]
	if data then
		Remotes.Event("PlayerDataUpdated"):FireClient(player, data)
	end
end

-- 머니 증감 (음수 가능). 성공 여부 반환.
function DataManager.addMoney(player: Player, amount: number): boolean
	local data = cache[player.UserId]
	if not data then
		return false
	end
	if data.money + amount < 0 then
		return false
	end
	data.money += amount
	DataManager.pushToClient(player)
	return true
end

-- 차량 지급(구매 성공 시 등). 이미 보유면 false.
function DataManager.grantCar(player: Player, carId: string): boolean
	local data = cache[player.UserId]
	if not data or not GameConfig.CarsById[carId] then
		return false
	end
	if data.ownedCars[carId] then
		return false
	end
	data.ownedCars[carId] = true
	DataManager.pushToClient(player)
	return true
end

-- 선택 차량 변경 (보유한 차만 가능)
function DataManager.setSelectedCar(player: Player, carId: string): boolean
	local data = cache[player.UserId]
	if not data or not data.ownedCars[carId] then
		return false
	end
	data.selectedCar = carId
	DataManager.pushToClient(player)
	return true
end

-- 커스터마이징 저장 (현재 선택 차량 대상)
function DataManager.setCustomization(player: Player, carId: string, custom: Customization): boolean
	local data = cache[player.UserId]
	if not data or not data.ownedCars[carId] then
		return false
	end
	data.customizations[carId] = custom
	DataManager.pushToClient(player)
	return true
end

function DataManager.recordRace(player: Player, won: boolean)
	local data = cache[player.UserId]
	if not data then
		return
	end
	data.stats.races += 1
	if won then
		data.stats.wins += 1
	end
end

-- 개인 최고 기록 갱신. 신기록이면 true 반환.
function DataManager.updateBestTime(player: Player, time: number): boolean
	local data = cache[player.UserId]
	if not data or time <= 0 then
		return false
	end
	if data.stats.bestTime == 0 or time < data.stats.bestTime then
		data.stats.bestTime = time
		DataManager.pushToClient(player)
		return true
	end
	return false
end

-- =====================================================================
-- 라이프사이클
-- =====================================================================
function DataManager.init()
	Players.PlayerAdded:Connect(loadData)

	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(loadData, player)
	end

	Players.PlayerRemoving:Connect(function(player)
		DataManager.save(player)
		cache[player.UserId] = nil
		loaded[player.UserId] = nil
	end)

	-- 자동 저장 루프
	task.spawn(function()
		while true do
			task.wait(AUTOSAVE_INTERVAL)
			for _, player in ipairs(Players:GetPlayers()) do
				DataManager.save(player)
			end
		end
	end)

	-- 서버 종료 시 일괄 저장
	game:BindToClose(function()
		if RunService:IsStudio() then
			return
		end
		for _, player in ipairs(Players:GetPlayers()) do
			task.spawn(DataManager.save, player)
		end
		task.wait(3)
	end)
end

return DataManager
