--!strict
--[[
	ShopService
	------------
	상점/차량 관련 서버 로직을 담당합니다.
	- 차량 구매 (게임머니 차감 / 로벅스 차는 현재 비활성)
	- 차량 선택
	- 커스터마이징 저장 (검증 포함)

	모든 요청은 클라이언트에서 RemoteEvent로 들어오며,
	서버에서 권한/잔액/소유를 검증합니다(클라이언트 신뢰 금지).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local GameConfig = require(ReplicatedStorage.GameConfig)
local Remotes = require(ReplicatedStorage.Remotes)
local DataManager = require(script.Parent.DataManager)

local ShopService = {}

local function notify(player: Player, message: string)
	Remotes.Event("Notify"):FireClient(player, message)
end

-- 차량 구매
function ShopService.handleBuy(player: Player, carId: string)
	if type(carId) ~= "string" then
		return
	end
	local carDef = GameConfig.CarsById[carId]
	if not carDef then
		notify(player, "존재하지 않는 차량입니다.")
		return
	end

	local data = DataManager.get(player)
	if not data then
		return
	end
	if data.ownedCars[carId] then
		notify(player, "이미 보유한 차량입니다.")
		return
	end

	-- 로벅스 전용 차량: 현재 결제 비활성 (구조만 준비)
	if carDef.currency == "Robux" then
		-- TODO: 출시 시 MarketplaceService로 robuxProductId 결제 처리
		notify(player, "이 차량은 로벅스 전용입니다. (현재 준비 중)")
		return
	end

	-- 게임머니 구매
	if data.money < carDef.price then
		notify(player, ("머니가 부족합니다. (필요 %d)"):format(carDef.price))
		return
	end

	if DataManager.addMoney(player, -carDef.price) then
		DataManager.grantCar(player, carId)
		notify(player, ("%s 구매 완료!"):format(carDef.displayName))
	end
end

-- 차량 선택
function ShopService.handleSelect(player: Player, carId: string)
	if type(carId) ~= "string" then
		return
	end
	local data = DataManager.get(player)
	if not data then
		return
	end
	if not data.ownedCars[carId] then
		notify(player, "보유하지 않은 차량입니다.")
		return
	end
	DataManager.setSelectedCar(player, carId)
end

-- 커스터마이징 검증 헬퍼
local function validColorIndexArray(arr: any): boolean
	return type(arr) == "table"
		and #arr == 3
		and type(arr[1]) == "number"
		and type(arr[2]) == "number"
		and type(arr[3]) == "number"
end

local function clampColorArray(arr: { number }): { number }
	return {
		math.clamp(math.floor(arr[1]), 0, 255),
		math.clamp(math.floor(arr[2]), 0, 255),
		math.clamp(math.floor(arr[3]), 0, 255),
	}
end

-- 커스터마이징 저장 (현재 선택 차량 대상)
function ShopService.handleSaveCustomization(player: Player, payload: any)
	if type(payload) ~= "table" then
		return
	end
	local data = DataManager.get(player)
	if not data then
		return
	end
	local carId = data.selectedCar
	local carDef = GameConfig.CarsById[carId]
	if not carDef then
		return
	end

	-- 입력 검증 후 안전한 값만 저장
	local custom = {
		bodyColor = validColorIndexArray(payload.bodyColor) and clampColorArray(payload.bodyColor)
			or { carDef.defaultColor.R * 255, carDef.defaultColor.G * 255, carDef.defaultColor.B * 255 },
		wheelColor = validColorIndexArray(payload.wheelColor) and clampColorArray(payload.wheelColor) or { 20, 20, 20 },
		neonColor = validColorIndexArray(payload.neonColor) and clampColorArray(payload.neonColor) or { 0, 0, 0 },
		sticker = "none",
		plate = "RACER",
		name = "박서우차",
	}

	-- 차 이름 (유니코드 허용 / 제어문자 제거 / 최대 12자, 기본값 "박서우차")
	if type(payload.name) == "string" then
		local cleaned = string.gsub(payload.name, "%c", "")
		cleaned = string.match(cleaned, "^%s*(.-)%s*$") or ""
		local okLen, count = pcall(utf8.len, cleaned)
		if okLen and type(count) == "number" then
			if count > 12 then
				local off = utf8.offset(cleaned, 13)
				if off then
					cleaned = string.sub(cleaned, 1, off - 1)
				end
			end
			if #cleaned > 0 then
				custom.name = cleaned
			end
		end
	end

	-- 스티커 id 검증
	if type(payload.sticker) == "string" then
		for _, s in ipairs(GameConfig.Customization.stickers) do
			if s.id == payload.sticker then
				custom.sticker = payload.sticker
				break
			end
		end
	end

	-- 번호판 텍스트 (최대 8자, 영숫자/공백만)
	if type(payload.plate) == "string" then
		local cleaned = string.gsub(payload.plate, "[^%w%s]", "")
		cleaned = string.sub(cleaned, 1, 8)
		if #cleaned > 0 then
			custom.plate = cleaned
		end
	end

	DataManager.setCustomization(player, carId, custom)
	notify(player, "커스터마이징 저장 완료!")
end

function ShopService.init()
	Remotes.Event("RequestBuyCar").OnServerEvent:Connect(ShopService.handleBuy)
	Remotes.Event("RequestSelectCar").OnServerEvent:Connect(ShopService.handleSelect)
	Remotes.Event("RequestSaveCustomization").OnServerEvent:Connect(ShopService.handleSaveCustomization)
end

return ShopService
