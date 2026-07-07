BORDealerHaulageB57Evidence = BORDealerHaulageB57Evidence or {}
local M = BORDealerHaulageB57Evidence

M.SCAN_INTERVAL_MS = 250
M.EVIDENCE_DISTANCE = 32

local function lower(value)
    return string.lower(tostring(value or ""))
end

function M:log(text, ...)
    local ok, result = pcall(string.format, "[DealerHaulage][B57][Evidence] " .. text, ...)
    print(ok and result or text)
end

function M:getService()
    return rawget(_G, "DeliveryService") or rawget(_G, "g_deliveryService")
end

function M:getRoot(vehicle)
    if type(vehicle) ~= "table" then
        return nil
    end
    if vehicle.rootNode ~= nil then
        return vehicle.rootNode
    end
    if type(vehicle.components) == "table" and type(vehicle.components[1]) == "table" then
        return vehicle.components[1].node
    end
    return nil
end

function M:isVehicle(value)
    return type(value) == "table" and self:getRoot(value) ~= nil
end

function M:getActiveVehicle()
    local service = self:getService()
    local active = service and service.activeDelivery
    if type(active) ~= "table" then
        return nil
    end
    for _, key in ipairs({"truck", "tractorUnit", "vehicle", "deliveryVehicle"}) do
        if self:isVehicle(active[key]) then
            return active[key]
        end
    end
    return nil
end

function M:getName(object)
    if type(object) ~= "table" then
        return "unknown object"
    end
    if type(object.getName) == "function" then
        local ok, name = pcall(object.getName, object)
        if ok and name ~= nil and tostring(name) ~= "" then
            return tostring(name)
        end
    end
    return tostring(object.configFileName or object.typeName or object.className or "vehicle/object")
end

function M:nearestAhead(vehicle, maximumDistance)
    local mission = rawget(_G, "g_currentMission")
    local root = self:getRoot(vehicle)
    if mission == nil or root == nil or type(mission.vehicles) ~= "table"
        or rawget(_G, "getWorldTranslation") == nil
        or rawget(_G, "localDirectionToWorld") == nil then
        return nil
    end

    local x, _, z = getWorldTranslation(root)
    local fx, _, fz = localDirectionToWorld(root, 0, 0, 1)
    local best = nil

    for _, candidate in pairs(mission.vehicles) do
        if candidate ~= vehicle and self:isVehicle(candidate) then
            local candidateRoot = self:getRoot(candidate)
            local cx, _, cz = getWorldTranslation(candidateRoot)
            local dx = cx - x
            local dz = cz - z
            local forward = dx * fx + dz * fz
            local lateral = math.abs(-dx * fz + dz * fx)
            local distance = math.sqrt(dx * dx + dz * dz)

            if forward > 0 and forward <= maximumDistance and lateral <= 4.5 then
                if best == nil or distance < best.distance then
                    best = {
                        node = candidateRoot,
                        distance = distance,
                        label = self:getName(candidate)
                    }
                end
            end
        end
    end

    return best
end

function M:record(reason, source)
    local vehicle = self:getActiveVehicle()
    if vehicle == nil then
        return
    end
    local evidence = self:nearestAhead(vehicle, self.EVIDENCE_DISTANCE)
    if evidence ~= nil then
        self:log("source=%s reason=%s object=%s distance=%.1fm node=%s",
            tostring(source), tostring(reason), tostring(evidence.label), evidence.distance, tostring(evidence.node))
    else
        self:log("source=%s reason=%s object=none within %dm",
            tostring(source), tostring(reason), self.EVIDENCE_DISTANCE)
    end
end

function M:pollReasons()
    local service = self:getService()
    if type(service) ~= "table" then
        return
    end
    self.lastReasons = self.lastReasons or {}

    for key, value in pairs(service) do
        if type(value) == "string" then
            local keyText = lower(key)
            local valueText = lower(value)
            local keyRelevant = keyText:find("reason", 1, true) or keyText:find("collision", 1, true)
                or keyText:find("blocked", 1, true) or keyText:find("stop", 1, true)
            local valueRelevant = valueText:find("collision", 1, true) or valueText:find("contact", 1, true)
                or valueText:find("blocked", 1, true) or valueText:find("unexpected stop", 1, true)
                or valueText:find("vehicle ahead", 1, true)

            if keyRelevant and valueRelevant and value ~= "" and self.lastReasons[key] ~= value then
                self.lastReasons[key] = value
                self:record(value, key)
            end
        end
    end
end

function M:loadMap()
    self.lastPoll = 0
    self:log("Collision evidence logger loaded")
end

function M:update(dt)
    local now = rawget(_G, "g_time") or 0
    if now - (self.lastPoll or 0) >= self.SCAN_INTERVAL_MS then
        self.lastPoll = now
        self:pollReasons()
    end
end

function M:deleteMap()
    self.lastReasons = nil
end

addModEventListener(M)
