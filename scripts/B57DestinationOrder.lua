BORDealerHaulageB57Destination = BORDealerHaulageB57Destination or {}
local M = BORDealerHaulageB57Destination
local unpackArgs = unpack or table.unpack

local function pack(...)
    return {n = select("#", ...), ...}
end

local function lower(value)
    return string.lower(tostring(value or ""))
end

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$") or tostring(value or "")
end

local function normalise(value)
    return lower(trim(value)):gsub("[%s%p_]+", "")
end

function M:log(text, ...)
    local ok, result = pcall(string.format, "[DealerHaulage][B57][Destinations] " .. text, ...)
    print(ok and result or text)
end

function M:getService()
    return rawget(_G, "DeliveryService") or rawget(_G, "g_deliveryService")
end

function M:getLabel(entry)
    if type(entry) == "string" or type(entry) == "number" then
        return trim(entry)
    end
    if type(entry) ~= "table" then
        return ""
    end
    for _, key in ipairs({"displayName", "destinationName", "markerName", "locationName", "title", "text", "label", "name"}) do
        local value = entry[key]
        if type(value) == "string" and trim(value) ~= "" then
            return trim(value)
        end
    end
    return ""
end

function M:getId(entry)
    if type(entry) == "number" then
        return entry
    end
    if type(entry) ~= "table" then
        return nil
    end
    for _, key in ipairs({"destinationId", "markerId", "mapMarkerId", "wayPointId", "waypointId", "id", "index"}) do
        local value = entry[key]
        if type(value) == "number" or type(value) == "string" then
            return value
        end
    end
    return nil
end

function M:getLastUsed(service)
    if self.lastSelected ~= nil then
        return self.lastSelected
    end
    if type(service) ~= "table" then
        return nil
    end
    for _, key in ipairs({"lastAutoDriveDestination", "lastAutoDriveDestinationId", "lastUsedAutoDriveDestination", "lastUsedDestination", "lastDestination", "lastDestinationId", "previousDestination", "recentDestination", "selectedAutoDriveDestination"}) do
        if service[key] ~= nil then
            return service[key]
        end
    end
    local active = service.activeDelivery
    if type(active) == "table" then
        for _, key in ipairs({"lastDestination", "destination", "destinationId", "autoDriveDestination", "markerId"}) do
            if active[key] ~= nil then
                return active[key]
            end
        end
    end
    return nil
end

function M:matches(entry, reference)
    if reference == nil then
        return false
    end
    local entryId = self:getId(entry)
    local referenceId = self:getId(reference)
    if referenceId == nil and (type(reference) == "number" or type(reference) == "string") then
        referenceId = reference
    end
    if entryId ~= nil and referenceId ~= nil and tostring(entryId) == tostring(referenceId) then
        return true
    end
    local a = normalise(self:getLabel(entry))
    local b = normalise(self:getLabel(reference))
    if b == "" and type(reference) == "string" then
        b = normalise(reference)
    end
    return a ~= "" and b ~= "" and a == b
end

function M:reorder(list, service)
    if type(list) ~= "table" or list[1] == nil or list[2] == nil then
        return false
    end
    local recognised = 0
    for index = 1, math.min(#list, 8) do
        if self:getLabel(list[index]) ~= "" or self:getId(list[index]) ~= nil then
            recognised = recognised + 1
        end
    end
    if recognised < 2 then
        return false
    end

    local reference = self:getLastUsed(service)
    local pinned = nil
    local remainder = {}
    local seen = {}

    for _, entry in ipairs(list) do
        local id = self:getId(entry)
        local label = self:getLabel(entry)
        local key = id ~= nil and ("id:" .. tostring(id)) or ("label:" .. normalise(label))
        if key == "label:" then
            key = "entry:" .. tostring(entry)
        end
        if not seen[key] then
            seen[key] = true
            if pinned == nil and self:matches(entry, reference) then
                pinned = entry
            else
                table.insert(remainder, entry)
            end
        end
    end

    table.sort(remainder, function(a, b)
        local aLabel = lower(M:getLabel(a))
        local bLabel = lower(M:getLabel(b))
        if aLabel == bLabel then
            return tostring(M:getId(a) or "") < tostring(M:getId(b) or "")
        end
        return aLabel < bLabel
    end)

    for index = #list, 1, -1 do
        list[index] = nil
    end
    local position = 1
    if pinned ~= nil then
        list[position] = pinned
        position = position + 1
    end
    for _, entry in ipairs(remainder) do
        list[position] = entry
        position = position + 1
    end
    return true
end

function M:inspect(value, service, depth)
    depth = depth or 0
    if type(value) ~= "table" or depth > 2 then
        return
    end
    if self:reorder(value, service) then
        return
    end
    for _, child in pairs(value) do
        if type(child) == "table" then
            self:inspect(child, service, depth + 1)
        end
    end
end

function M:install()
    local service = self:getService()
    if type(service) ~= "table" then
        return
    end
    self.hooks = self.hooks or {}
    local installed = 0

    for name, original in pairs(service) do
        if type(original) == "function" and not self.hooks[name] then
            local key = lower(name)
            local destination = key:find("destination", 1, true) or key:find("marker", 1, true)
            local getter = key:find("get", 1, true) or key:find("list", 1, true) or key:find("build", 1, true) or key:find("collect", 1, true) or key:find("available", 1, true)
            local selector = key:find("select", 1, true) or key:find("choose", 1, true) or key:find("set", 1, true)

            if destination and getter then
                service[name] = function(...)
                    local results = pack(original(...))
                    for index = 1, results.n do
                        M:inspect(results[index], service, 0)
                    end
                    return unpackArgs(results, 1, results.n)
                end
                self.hooks[name] = true
                installed = installed + 1
            elseif destination and selector then
                service[name] = function(...)
                    local args = pack(...)
                    for index = 1, args.n do
                        local candidate = args[index]
                        if type(candidate) == "string" or type(candidate) == "number" or type(candidate) == "table" then
                            if M:getLabel(candidate) ~= "" or M:getId(candidate) ~= nil then
                                M.lastSelected = candidate
                                break
                            end
                        end
                    end
                    return original(...)
                end
                self.hooks[name] = true
                installed = installed + 1
            end
        end
    end

    if installed > 0 then
        self:log("Installed %d ordering hook(s)", installed)
    end
end

function M:loadMap()
    self.lastAttempt = 0
    self:log("Last-used-first and alphabetical ordering loaded")
end

function M:update(dt)
    local now = rawget(_G, "g_time") or 0
    if now - (self.lastAttempt or 0) >= 1500 then
        self.lastAttempt = now
        self:install()
    end
end

function M:deleteMap()
    self.lastSelected = nil
end

addModEventListener(M)
