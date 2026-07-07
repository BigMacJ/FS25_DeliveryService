BORDealerHaulageB57Departure = BORDealerHaulageB57Departure or {}
local M = BORDealerHaulageB57Departure
local unpackArgs = unpack or table.unpack

M.CLEAR_HOLD_MS = 1800
M.DEPARTURE_DISTANCE = 16

local function pack(...)
    return {n = select("#", ...), ...}
end

function M:log(text, ...)
    local ok, result = pcall(string.format, "[DealerHaulage][B57][Departure] " .. text, ...)
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

function M:isDealerVehicle(vehicle)
    if not self:isVehicle(vehicle) then
        return false
    end
    local service = self:getService()
    local active = service and service.activeDelivery
    if type(active) ~= "table" then
        return false
    end
    for _, key in ipairs({"truck", "tractorUnit", "vehicle", "deliveryVehicle", "lowLoader", "trailer"}) do
        if active[key] == vehicle then
            return true
        end
    end
    return false
end

function M:extractVehicle(args)
    for index = 1, args.n do
        if self:isVehicle(args[index]) then
            return args[index]
        end
    end
    return nil
end

function M:isCancelled()
    local service = self:getService()
    if type(service) ~= "table" then
        return false
    end
    for _, key in ipairs({"manualCancel", "manualCancelled", "playerCancelled", "cancelRequested", "deliveryCancelled"}) do
        if service[key] == true then
            return true
        end
    end
    return false
end

function M:nearestAhead(vehicle)
    local evidenceModule = rawget(_G, "BORDealerHaulageB57Evidence")
    if type(evidenceModule) == "table" and type(evidenceModule.nearestAhead) == "function" then
        return evidenceModule:nearestAhead(vehicle, self.DEPARTURE_DISTANCE)
    end
    return nil
end

function M:installHooks()
    local autoDrive = rawget(_G, "AutoDrive")
    if type(autoDrive) ~= "table" then
        return
    end
    self.hooks = self.hooks or {}

    for _, name in ipairs({"StartDriving", "startDriving"}) do
        local original = autoDrive[name]
        if type(original) == "function" and not self.hooks[name] then
            autoDrive[name] = function(...)
                local args = pack(...)
                local vehicle = M:extractVehicle(args)

                if M.releasing or vehicle == nil or not M:isDealerVehicle(vehicle) then
                    return original(...)
                end

                if M.pending == nil then
                    M.pending = {
                        original = original,
                        args = args,
                        vehicle = vehicle,
                        source = "AutoDrive." .. name,
                        clearSince = nil,
                        lastBlock = nil
                    }
                    M:log("Hold armed via %s; %.1fs continuously clear required",
                        M.pending.source, M.CLEAR_HOLD_MS / 1000)
                else
                    M.pending.args = args
                    M.pending.vehicle = vehicle
                end

                return false
            end
            self.hooks[name] = true
            self:log("Installed hook AutoDrive.%s", name)
        end
    end
end

function M:processPending()
    local pending = self.pending
    if pending == nil then
        return
    end

    if self:isCancelled() then
        self:log("Hold cancelled because manual cancellation owns the mission")
        self.pending = nil
        return
    end

    local now = rawget(_G, "g_time") or 0
    local evidence = self:nearestAhead(pending.vehicle)

    if evidence ~= nil then
        pending.clearSince = nil
        local signature = tostring(evidence.node) .. ":" .. string.format("%.1f", evidence.distance)
        if signature ~= pending.lastBlock then
            pending.lastBlock = signature
            self:log("Held: object=%s distance=%.1fm node=%s",
                tostring(evidence.label), evidence.distance, tostring(evidence.node))
        end
        return
    end

    if pending.clearSince == nil then
        pending.clearSince = now
        pending.lastBlock = nil
        self:log("Corridor clear; stabilising for %.1fs", self.CLEAR_HOLD_MS / 1000)
        return
    end

    if now - pending.clearSince < self.CLEAR_HOLD_MS then
        return
    end

    self.pending = nil
    self.releasing = true
    self:log("Corridor confirmed clear; releasing AutoDrive")
    local ok, errorMessage = pcall(pending.original, unpackArgs(pending.args, 1, pending.args.n))
    self.releasing = false

    if not ok then
        self:log("AutoDrive release failed: %s", tostring(errorMessage))
    end
end

function M:loadMap()
    self.lastInstall = 0
    self.pending = nil
    self:log("Safe departure hold loaded")
end

function M:update(dt)
    local now = rawget(_G, "g_time") or 0
    if now - (self.lastInstall or 0) >= 1500 then
        self.lastInstall = now
        self:installHooks()
    end
    self:processPending()
end

function M:deleteMap()
    self.pending = nil
end

addModEventListener(M)
