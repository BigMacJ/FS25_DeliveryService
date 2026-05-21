DeliveryService = {}

DeliveryService.DAY_MS = 24 * 60 * 60 * 1000
DeliveryService.deliveryFee = 500
DeliveryService.returnToDealerDistance = 45
DeliveryService.groupWindowMs = 5 * 60 * 1000
DeliveryService.maxItemsPerHaulageManifest = 3
DeliveryService.maxTractorsPerHaulageManifest = 2
DeliveryService.maxTrailersPerHaulageManifest = 2
DeliveryService.extraMachinerySurchargeRate = 0.25
DeliveryService.recallDistance = 35
DeliveryService.lowLoaderSafetyCheckInterval = 250
DeliveryService.lowLoaderSafetyMoveThreshold = 0.01
DeliveryService.lowLoaderSafetyStableMs = 1000
DeliveryService.lowLoaderSafetyNotifyCooldown = 7000
DeliveryService.orphanTabRestoreInterval = 5000
DeliveryService.lowLoaderRoadSafeThreshold = 0.05
DeliveryService.unauthorisedHaulageRate = 0.05
DeliveryService.unauthorisedHaulageMinimumFee = 2500
DeliveryService.unauthorisedCargoCheckInterval = 500
DeliveryService.serviceCabReminderInterval = 30000
DeliveryService.serviceCabReminderStationaryDelay = 30000
DeliveryService.serviceCabReminderStationarySpeedKph = 1
DeliveryService.serviceCabInputReminderCooldown = 1500

DeliveryService.lowLoaderSafetyAnimations = {
    {
        key = "width",
        label = "width",
        animationName = "extensionAnim"
    },
    {
        key = "length",
        label = "length",
        animationName = "extensionAnim2"
    }
}

DeliveryService.truckXml = "data/vehicles/volvo/fh16/fh16.xml"
DeliveryService.lowLoaderXml = "$moddir$FS25_semiLowloader3A/semiLowloader3A.xml"
DeliveryService.courtesyTractorXml = "data/vehicles/fendt/vario700/vario700.xml"

DeliveryService.deliveryOptions = {
    {
        key = "standard",
        name = "Standard Haulage",
        delayText = "12 in-game hours",
        shortDelayText = "12h",
        delayMs = 12 * 60 * 60 * 1000,
        rate = 0.005,
        minimumFee = 250
    },
    {
        key = "express",
        name = "Express Haulage",
        delayText = "6 in-game hours",
        shortDelayText = "6h",
        delayMs = 6 * 60 * 60 * 1000,
        rate = 0.01,
        minimumFee = 500
    },
    {
        key = "priority",
        name = "Priority Haulage",
        delayText = "15 in-game minutes",
        shortDelayText = "15m",
        delayMs = 15 * 60 * 1000,
        rate = 0.025,
        minimumFee = 1000
    }
}

DeliveryService.declineOptionIndex = 4

DeliveryService.actionEventIds = {}
DeliveryService.activeDelivery = nil
DeliveryService.deliveryQueue = {}
DeliveryService.pendingChoiceQueue = {}
DeliveryService.prePurchaseChoiceQueue = {}
DeliveryService.currentShopChoice = nil
DeliveryService.nextPromptTimer = nil
DeliveryService.nextManifestId = 1
DeliveryService.shopHookInstalled = false
DeliveryService.shopHookMode = nil
DeliveryService.shopHookCheckTimer = 0
DeliveryService.shopHookBuyFunction = nil
DeliveryService.shopHookOnBoughtFunction = nil
DeliveryService.shopConfigSetStoreItemFunction = nil
DeliveryService.hirePurchaseHookFunction = nil
DeliveryService.hirePurchaseDialogTarget = nil

function DeliveryService:loadMap(name)
    print("Dealer Haulage loaded")
    self:registerActionEvents()
    self:installShopHooks()
    self:installHirePurchaseHooks()
end

function DeliveryService:deleteMap()
    self:clearActionEvents()

    if self.activeDelivery ~= nil then
        self:deleteServiceVehicle(self.activeDelivery.courtesyTractor)
        self:deleteServiceVehicle(self.activeDelivery.lowLoader)
        self:deleteServiceVehicle(self.activeDelivery.truck)
        self.activeDelivery = nil
    end

    self.deliveryQueue = {}
    self.pendingChoiceQueue = {}
    self.prePurchaseChoiceQueue = {}
    self.currentShopChoice = nil
    self.nextPromptTimer = nil
    self.nextManifestId = 1
    self.shopHookCheckTimer = 0
    self.hirePurchaseDialogTarget = nil
    self.shopConfigSetStoreItemFunction = nil
end

function DeliveryService:update(dt)
    self:updateShopHooks(dt)
    self:updatePendingChoicePrompt(dt)
    self:updatePendingChoiceLocks(dt)
    self:updateLockedDeliveryVehicles(dt)
    self:cleanupInvalidHaulageContracts()
    self:updateDeliveryQueue()
    self:updateServiceVehicleTabbable()
    self:updateLowLoaderExtensionSafety(dt)
    self:updateUnauthorisedCargoLock(dt)
    self:updateServiceCabReminder(dt)
    self:updateServiceCabInputReminder(dt)
    self:restoreOrphanedTabbableVehicles(dt)
    self:resetManifestSequenceIfIdle()
end

function DeliveryService:updateShopHooks(dt)
    self.shopHookCheckTimer = (self.shopHookCheckTimer or 0) - (dt or 0)

    if self.shopHookCheckTimer > 0 then
        return
    end

    self.shopHookCheckTimer = 3000
    self:installShopHooks()
    self:installHirePurchaseHooks()
end

function DeliveryService:updatePendingChoicePrompt(dt)
    if self.currentShopChoice ~= nil then
        return
    end

    if #self.pendingChoiceQueue == 0 then
        self.nextPromptTimer = nil
        return
    end

    self.nextPromptTimer = (self.nextPromptTimer or 1500) - dt

    if self.nextPromptTimer <= 0 then
        self.currentShopChoice = table.remove(self.pendingChoiceQueue, 1)
        self.nextPromptTimer = nil
        self:showShopDeliveryPrompt()
    end
end

function DeliveryService:installShopHooks()
    if BuyVehicleData == nil or Utils == nil or Utils.overwrittenFunction == nil then
        print("DeliveryService shop hook not available yet")
        return
    end

    local installedHook = false
    local hookModes = {}

    if BuyVehicleData.onBought ~= nil and BuyVehicleData.onBought ~= self.shopHookOnBoughtFunction then
        BuyVehicleData.onBought = Utils.overwrittenFunction(BuyVehicleData.onBought, DeliveryService.buyVehicleDataOnBought)
        self.shopHookOnBoughtFunction = BuyVehicleData.onBought
        installedHook = true
        hookModes[#hookModes + 1] = "onBought"
    end

    if BuyVehicleData.buy ~= nil and BuyVehicleData.buy ~= self.shopHookBuyFunction then
        BuyVehicleData.buy = Utils.overwrittenFunction(BuyVehicleData.buy, DeliveryService.buyVehicleDataBuy)
        self.shopHookBuyFunction = BuyVehicleData.buy
        installedHook = true
        hookModes[#hookModes + 1] = "buyCallback"
    end

    if installedHook then
        self.shopHookMode = table.concat(hookModes, "+")
        self.shopHookInstalled = true
        print("DeliveryService shop hook installed: " .. self.shopHookMode)
    end

    self:installShopConfigScreenHook()
end

function DeliveryService:installShopConfigScreenHook()
    if ShopConfigScreen == nil or ShopConfigScreen.setStoreItem == nil or Utils == nil or Utils.overwrittenFunction == nil then
        return
    end

    if ShopConfigScreen.setStoreItem == self.shopConfigSetStoreItemFunction then
        return
    end

    ShopConfigScreen.setStoreItem = Utils.overwrittenFunction(ShopConfigScreen.setStoreItem, DeliveryService.shopConfigScreenSetStoreItem)
    self.shopConfigSetStoreItemFunction = ShopConfigScreen.setStoreItem

    print("DeliveryService standard shop button hook installed")
end

function DeliveryService.shopConfigScreenSetStoreItem(shopConfigScreen, superFunc, storeItem, ...)
    local result = superFunc(shopConfigScreen, storeItem, ...)

    DeliveryService:installStandardShopButtonHooks(shopConfigScreen, storeItem)

    return result
end

function DeliveryService:installStandardShopButtonHooks(shopConfigScreen, storeItem)
    if shopConfigScreen == nil then
        return
    end

    shopConfigScreen.deliveryServiceCurrentStoreItem = storeItem

    self:installStandardShopButtonHook(shopConfigScreen, shopConfigScreen.buyButton, "buy")
    self:installStandardShopButtonHook(shopConfigScreen, shopConfigScreen.leaseButton, "lease")
end

function DeliveryService:installStandardShopButtonHook(shopConfigScreen, button, buttonRole)
    if button == nil or button.onClickCallback == nil then
        return
    end

    if button.onClickCallback ~= button.deliveryServiceHookedOnClickCallback then
        button.deliveryServiceOriginalOnClickCallback = button.onClickCallback
    end

    local hookedCallback = function(target, ...)
        DeliveryService:onStandardShopButtonPressed(target or shopConfigScreen, buttonRole, button.deliveryServiceOriginalOnClickCallback, ...)
    end

    button.deliveryServiceHookedOnClickCallback = hookedCallback
    button.onClickCallback = hookedCallback
end

function DeliveryService:installHirePurchaseHooks()
    self:installHirePurchaseDialogHook()
end

function DeliveryService:installHirePurchaseDialogHook()
    if g_gui == nil or g_gui.guis == nil then
        return
    end

    local gui = g_gui.guis["newFinanceFrame"]

    if gui == nil or gui.target == nil then
        return
    end

    local target = gui.target

    if target.deliveryServiceHirePurchaseHookInstalled then
        return
    end

    local originalOnClickPurchase = target.onClickPurchase

    if originalOnClickPurchase == nil and NewFinanceFrame ~= nil then
        originalOnClickPurchase = NewFinanceFrame.onClickPurchase
    end

    if originalOnClickPurchase == nil then
        return
    end

    local hookedOnClickPurchase = function(financeFrame, sender)
        local original = financeFrame.deliveryServiceOriginalOnClickPurchase or originalOnClickPurchase
        DeliveryService:showHirePurchaseHaulagePrompt(financeFrame, original, sender)
    end

    target.deliveryServiceOriginalOnClickPurchase = originalOnClickPurchase
    target.onClickPurchase = hookedOnClickPurchase
    target.deliveryServiceHirePurchaseHookInstalled = true
    self.hirePurchaseDialogTarget = target

    local replacedCallbacks = self:replaceGuiClickCallback(gui, originalOnClickPurchase, hookedOnClickPurchase)

    print("DeliveryService Hire Purchasing dialog hook installed, callbacks replaced: " .. tostring(replacedCallbacks))
end

function DeliveryService:replaceGuiClickCallback(element, oldCallback, newCallback)
    if element == nil then
        return 0
    end

    local replaced = 0

    if element.onClickCallback == oldCallback then
        element.onClickCallback = newCallback
        replaced = replaced + 1
    end

    if element.elements ~= nil then
        for _, child in ipairs(element.elements) do
            replaced = replaced + self:replaceGuiClickCallback(child, oldCallback, newCallback)
        end
    end

    return replaced
end

function DeliveryService:showHirePurchaseHaulagePrompt(financeFrame, superFunc, sender)
    if financeFrame == nil or superFunc == nil then
        return
    end

    if financeFrame.deliveryServicePromptOpen then
        return
    end

    if OptionDialog == nil or OptionDialog.show == nil then
        self:notify("Haulage option menu unavailable. Hire purchase not completed.", true)
        return
    end

    financeFrame.deliveryServicePromptOpen = true

    local itemPrice = math.max(0, math.floor(tonumber(financeFrame.totalPrice) or 0))
    local pending = {
        itemPrice = itemPrice,
        fees = self:calculateDeliveryFees(itemPrice),
        storeItem = financeFrame.storeItem,
        itemClass = self:getHaulageItemClass(nil, financeFrame.storeItem)
    }

    local text = "Item price: " .. self:formatMoney(itemPrice)
    local optionTexts = self:getDeliveryOptionTexts(pending)

    OptionDialog.show(
        function(index)
            financeFrame.deliveryServicePromptOpen = false
            DeliveryService:onHirePurchaseHaulageSelected(financeFrame, superFunc, sender, index)
        end,
        "Dealer Haulage",
        text,
        optionTexts
    )
end

function DeliveryService:onHirePurchaseHaulageSelected(financeFrame, superFunc, sender, index)
    if index == nil then
        self:notify("Hire purchase not completed. Choose haulage or self-collection to continue.")
        return
    end

    local storeItemXml = nil

    if financeFrame.storeItem ~= nil then
        storeItemXml = financeFrame.storeItem.xmlFilename
    end

    if index == self.declineOptionIndex then
        self:queuePrePurchaseChoice({
            declined = true,
            storeItemXml = storeItemXml
        })

        superFunc(financeFrame, sender)
        return
    end

    local option = self.deliveryOptions[index]

    if option == nil then
        self:notify("Haulage option was not recognised. Hire purchase not completed.", true)
        return
    end

    self:queuePrePurchaseChoice({
        optionKey = option.key,
        storeItemXml = storeItemXml
    })

    superFunc(financeFrame, sender)
end

function DeliveryService:queuePrePurchaseChoice(choice)
    if choice == nil then
        return
    end

    table.insert(self.prePurchaseChoiceQueue, choice)
end

function DeliveryService:getShopPlacementFromCallbackArguments(callbackArguments)
    if callbackArguments == nil then
        return nil
    end

    if callbackArguments.storePlaces ~= nil then
        return self:getShopPlacementFromWrapperArguments(callbackArguments)
    end

    return self:getShopPlacementFromWrapperArguments(callbackArguments.callbackArguments)
end

function DeliveryService:getShopPlacementFromWrapperArguments(wrapperArguments)
    if wrapperArguments == nil or wrapperArguments.storePlaces == nil then
        return nil
    end

    return {
        storePlaces = wrapperArguments.storePlaces,
        usedStorePlaces = wrapperArguments.usedStorePlaces or {}
    }
end

function DeliveryService.buyVehicleDataOnBought(buyVehicleData, superFunc, loadedVehicles, loadingState, callbackArguments)
    local result = superFunc(buyVehicleData, loadedVehicles, loadingState, callbackArguments)

    DeliveryService:onShopBoughtVehicles(
        loadedVehicles,
        loadingState,
        buyVehicleData,
        DeliveryService:getShopPlacementFromCallbackArguments(callbackArguments)
    )

    return result
end

function DeliveryService.buyVehicleDataBuy(buyVehicleData, superFunc, storePlaces, usedStorePlaces, callback, callbackTarget, callbackArguments)
    return DeliveryService:executeBuyVehicleDataBuy(buyVehicleData, superFunc, storePlaces, usedStorePlaces, callback, callbackTarget, callbackArguments)
end

function DeliveryService:executeBuyVehicleDataBuy(buyVehicleData, superFunc, storePlaces, usedStorePlaces, callback, callbackTarget, callbackArguments)
    local wrapperArguments = {
        callback = callback,
        callbackTarget = callbackTarget,
        callbackArguments = callbackArguments,
        buyVehicleData = buyVehicleData,
        storePlaces = storePlaces,
        usedStorePlaces = usedStorePlaces
    }

    return superFunc(
        buyVehicleData,
        storePlaces,
        usedStorePlaces,
        DeliveryService.onShopBuyCallback,
        DeliveryService,
        wrapperArguments
    )
end

function DeliveryService:getShouldPromptBeforeStandardPurchase(buyVehicleData)
    if buyVehicleData == nil or buyVehicleData.deliveryServicePromptOpen then
        return false
    end

    if self:hasPrePurchaseChoiceForBuyVehicleData(buyVehicleData) then
        return false
    end

    return self:getIsDeliverableStoreItem(buyVehicleData.storeItem)
end

function DeliveryService:showStandardPurchaseHaulagePrompt(buyVehicleData, superFunc, storePlaces, usedStorePlaces, callback, callbackTarget, callbackArguments)
    if OptionDialog == nil or OptionDialog.show == nil then
        self:executeBuyVehicleDataBuy(buyVehicleData, superFunc, storePlaces, usedStorePlaces, callback, callbackTarget, callbackArguments)
        return
    end

    buyVehicleData.deliveryServicePromptOpen = true

    local itemPrice = self:getOriginalItemPrice(buyVehicleData)
    local pending = {
        itemPrice = itemPrice,
        fees = self:calculateDeliveryFees(itemPrice),
        storeItem = buyVehicleData.storeItem,
        itemClass = self:getHaulageItemClass(nil, buyVehicleData.storeItem)
    }

    local text = "Item price: " .. self:formatMoney(itemPrice)
    local optionTexts = self:getDeliveryOptionTexts(pending)

    OptionDialog.show(
        function(index)
            buyVehicleData.deliveryServicePromptOpen = false
            DeliveryService:onStandardPurchaseHaulageSelected(
                buyVehicleData,
                superFunc,
                storePlaces,
                usedStorePlaces,
                callback,
                callbackTarget,
                callbackArguments,
                index
            )
        end,
        "Dealer Haulage",
        text,
        optionTexts
    )
end

function DeliveryService:onStandardPurchaseHaulageSelected(buyVehicleData, superFunc, storePlaces, usedStorePlaces, callback, callbackTarget, callbackArguments, index)
    if index == nil then
        self:notify("Purchase not completed. Choose haulage or self-collection to continue.")
        return
    end

    local storeItemXml = nil

    if buyVehicleData ~= nil and buyVehicleData.storeItem ~= nil then
        storeItemXml = buyVehicleData.storeItem.xmlFilename
    end

    if index == self.declineOptionIndex then
        self:queuePrePurchaseChoice({
            declined = true,
            storeItemXml = storeItemXml
        })

        self:executeBuyVehicleDataBuy(buyVehicleData, superFunc, storePlaces, usedStorePlaces, callback, callbackTarget, callbackArguments)
        return
    end

    local option = self.deliveryOptions[index]

    if option == nil then
        self:notify("Haulage option was not recognised. Purchase not completed.", true)
        return
    end

    self:queuePrePurchaseChoice({
        optionKey = option.key,
        storeItemXml = storeItemXml
    })

    self:executeBuyVehicleDataBuy(buyVehicleData, superFunc, storePlaces, usedStorePlaces, callback, callbackTarget, callbackArguments)
end

function DeliveryService:onStandardShopButtonPressed(shopConfigScreen, buttonRole, originalCallback, ...)
    if originalCallback == nil then
        return
    end

    if not self:getShouldPromptBeforeStandardShopButton(shopConfigScreen) then
        originalCallback(shopConfigScreen, ...)
        return
    end

    local args = {...}
    self:showStandardShopHaulagePrompt(shopConfigScreen, buttonRole, originalCallback, args)
end

function DeliveryService:getShouldPromptBeforeStandardShopButton(shopConfigScreen)
    if shopConfigScreen == nil or shopConfigScreen.deliveryServicePromptOpen then
        return false
    end

    local storeItem = self:getStoreItemFromShopConfigScreen(shopConfigScreen)

    if not self:getIsDeliverableStoreItem(storeItem) then
        return false
    end

    return true
end

function DeliveryService:getStoreItemFromShopConfigScreen(shopConfigScreen)
    if shopConfigScreen == nil then
        return nil
    end

    return shopConfigScreen.storeItem
        or shopConfigScreen.currentStoreItem
        or shopConfigScreen.selectedStoreItem
        or shopConfigScreen.deliveryServiceCurrentStoreItem
end

function DeliveryService:showStandardShopHaulagePrompt(shopConfigScreen, buttonRole, originalCallback, args)
    if OptionDialog == nil or OptionDialog.show == nil then
        originalCallback(shopConfigScreen, unpack(args or {}))
        return
    end

    local storeItem = self:getStoreItemFromShopConfigScreen(shopConfigScreen)
    local itemPrice = math.max(0, math.floor(tonumber(shopConfigScreen.totalPrice) or 0))

    if itemPrice <= 0 and storeItem ~= nil and storeItem.price ~= nil then
        itemPrice = math.max(0, math.floor(tonumber(storeItem.price) or 0))
    end

    local pending = {
        itemPrice = itemPrice,
        fees = self:calculateDeliveryFees(itemPrice),
        storeItem = storeItem,
        itemClass = self:getHaulageItemClass(nil, storeItem)
    }

    shopConfigScreen.deliveryServicePromptOpen = true

    OptionDialog.show(
        function(index)
            DeliveryService:onStandardShopHaulageSelected(shopConfigScreen, buttonRole, originalCallback, args, storeItem, index)
        end,
        "Dealer Haulage",
        "Item price: " .. self:formatMoney(itemPrice),
        self:getDeliveryOptionTexts(pending)
    )
end

function DeliveryService:onStandardShopHaulageSelected(shopConfigScreen, buttonRole, originalCallback, args, storeItem, index)
    if shopConfigScreen ~= nil then
        shopConfigScreen.deliveryServicePromptOpen = false
    end

    if index == self.declineOptionIndex then
        self:queuePrePurchaseChoice({
            declined = true,
            storeItemXml = storeItem ~= nil and storeItem.xmlFilename or nil
        })

        originalCallback(shopConfigScreen, unpack(args or {}))
        return
    end

    local option = self.deliveryOptions[index]

    if option == nil then
        self:notify("Purchase not completed. Choose haulage or self-collection to continue.")
        return
    end

    self:queuePrePurchaseChoice({
        optionKey = option.key,
        storeItemXml = storeItem ~= nil and storeItem.xmlFilename or nil
    })

    originalCallback(shopConfigScreen, unpack(args or {}))
end

function DeliveryService:onShopBuyCallback(loadedVehicles, loadingState, wrapperArguments)
    if wrapperArguments ~= nil and wrapperArguments.callback ~= nil then
        wrapperArguments.callback(
            wrapperArguments.callbackTarget,
            loadedVehicles,
            loadingState,
            wrapperArguments.callbackArguments
        )
    end

    local buyVehicleData = nil

    if wrapperArguments ~= nil then
        buyVehicleData = wrapperArguments.buyVehicleData
    end

    self:onShopBoughtVehicles(
        loadedVehicles,
        loadingState,
        buyVehicleData,
        self:getShopPlacementFromWrapperArguments(wrapperArguments)
    )
end

function DeliveryService:onShopBoughtVehicles(loadedVehicles, loadingState, buyVehicleData, shopPlacement)
    if VehicleLoadingState ~= nil and loadingState ~= VehicleLoadingState.OK then
        print("DeliveryService shop purchase ignored: loading state " .. tostring(loadingState))
        return
    end

    local cargoVehicle = self:getFirstDeliverableVehicle(loadedVehicles)

    if cargoVehicle == nil then
        print("DeliveryService shop purchase ignored: no suitable machinery found")
        return
    end

    if cargoVehicle.deliveryServiceShopHandled then
        print("DeliveryService shop purchase ignored: already handled")
        return
    end

    cargoVehicle.deliveryServiceShopHandled = true

    local purchaseText = "bought"

    if buyVehicleData ~= nil and buyVehicleData.leaseVehicle then
        purchaseText = "leased"
    end

    local itemPrice = self:getOriginalItemPrice(buyVehicleData)
    local fees = self:calculateDeliveryFees(itemPrice)
    local x, y, z, rx, ry, rz = self:getVehicleTransform(cargoVehicle)

    local pending = {
        cargoVehicle = cargoVehicle,
        storeItem = buyVehicleData ~= nil and buyVehicleData.storeItem or nil,
        itemClass = self:getHaulageItemClass(cargoVehicle, buyVehicleData ~= nil and buyVehicleData.storeItem or nil),
        itemPrice = itemPrice,
        fees = fees,
        purchaseText = purchaseText,
        promptOpen = false,
        lockX = x,
        lockY = y,
        lockZ = z,
        lockRotX = rx,
        lockRotY = ry,
        lockRotZ = rz,
        storePlaces = shopPlacement ~= nil and shopPlacement.storePlaces or nil,
        usedStorePlaces = shopPlacement ~= nil and shopPlacement.usedStorePlaces or nil,
        lockWarningTimer = 0
    }

    local prePurchaseChoice = self:popPrePurchaseChoiceForBuyVehicleData(buyVehicleData)

    if prePurchaseChoice ~= nil then
        if prePurchaseChoice.declined then
            cargoVehicle.deliveryServiceDeclined = true
            self:updateActionEventText()
            self:notify("Dealer haulage declined. This bought/leased item is set for self-collection.")
            print("DeliveryService pre-purchase haulage declined")
            return
        end

        local option = self:getDeliveryOptionByKey(prePurchaseChoice.optionKey)

        if option ~= nil then
            self:bookQueuedDelivery(pending, option)
            print("DeliveryService pre-purchase haulage choice applied")
            return
        end
    end

    table.insert(self.pendingChoiceQueue, pending)
    self:lockAwaitingVehicle(cargoVehicle, pending)

    if self.currentShopChoice == nil then
        self.nextPromptTimer = 1500
    end

    self:updateActionEventText()
    self:notify("Dealer haulage option queued for the bought/leased item.")
    print("DeliveryService shop purchase queued for delivery choice")
end

function DeliveryService:getFirstDeliverableVehicle(loadedVehicles)
    if loadedVehicles == nil then
        return nil
    end

    for _, vehicle in ipairs(loadedVehicles) do
        if self:getIsDeliverableVehicle(vehicle) then
            return vehicle
        end
    end

    return nil
end

function DeliveryService:getIsDeliverableVehicle(vehicle)
    if vehicle == nil or vehicle.deliveryServiceVehicle or vehicle.isDeleted then
        return false
    end

    if self:getIsObjectStyleVehicle(vehicle) then
        return false
    end

    if vehicle.spec_drivable ~= nil then
        return true
    end

    if vehicle.spec_attachable ~= nil then
        return true
    end

    if vehicle.spec_trailer ~= nil then
        return true
    end

    return false
end

function DeliveryService:getIsDeliverableStoreItem(storeItem)
    if storeItem == nil or storeItem.xmlFilename == nil then
        return false
    end

    local categoryName = string.lower(tostring(storeItem.categoryName or ""))

    if string.find(categoryName, "pallet") ~= nil
        or string.find(categoryName, "bigbag") ~= nil
        or categoryName == "bale"
        or categoryName == "bales"
        or string.find(categoryName, "object") ~= nil then
        return false
    end

    if XMLFile ~= nil and XMLFile.load ~= nil then
        local xmlFile = XMLFile.load("DeliveryServiceStoreItemXML", storeItem.xmlFilename, nil)

        if xmlFile ~= nil then
            local isMultipleItemPurchase = xmlFile:hasProperty("vehicle.multipleItemPurchase")
            xmlFile:delete()

            if isMultipleItemPurchase then
                return false
            end
        end
    end

    return true
end

function DeliveryService:getIsObjectStyleVehicle(vehicle)
    if vehicle == nil then
        return true
    end

    if vehicle.spec_pallet ~= nil then
        return true
    end

    if vehicle.spec_bigBag ~= nil then
        return true
    end

    if vehicle.spec_treeSaplingPallet ~= nil then
        return true
    end

    return false
end

function DeliveryService:getHaulageItemClass(vehicle, storeItem)
    local categoryName = ""

    if storeItem ~= nil and storeItem.categoryName ~= nil then
        categoryName = string.lower(tostring(storeItem.categoryName))
    elseif vehicle ~= nil then
        local vehicleStoreItem = self:getStoreItemFromVehicle(vehicle)

        if vehicleStoreItem ~= nil and vehicleStoreItem.categoryName ~= nil then
            categoryName = string.lower(tostring(vehicleStoreItem.categoryName))
        end
    end

    if self:getIsLargeHaulageItem(vehicle, categoryName) then
        return "large"
    end

    if vehicle ~= nil and vehicle.spec_trailer ~= nil then
        return "trailer"
    end

    if string.find(categoryName, "trailer") ~= nil or string.find(categoryName, "auger") ~= nil then
        return "trailer"
    end

    if vehicle ~= nil and vehicle.spec_drivable ~= nil then
        return "tractor"
    end

    return "implement"
end

function DeliveryService:getIsLargeHaulageItem(vehicle, categoryName)
    categoryName = string.lower(tostring(categoryName or ""))

    if vehicle ~= nil then
        if vehicle.spec_combine ~= nil or (vehicle.spec_pipe ~= nil and vehicle.spec_drivable ~= nil) then
            return true
        end
    end

    local largeCategoryWords = {
        "harvester",
        "harvesters",
        "combine",
        "forage",
        "cotton",
        "beet",
        "potato",
        "sugarcane"
    }

    for _, word in ipairs(largeCategoryWords) do
        if string.find(categoryName, word) ~= nil then
            return true
        end
    end

    return false
end

function DeliveryService:getStoreItemFromVehicle(vehicle)
    if vehicle == nil or g_storeManager == nil or vehicle.configFileName == nil then
        return nil
    end

    return g_storeManager:getItemByXMLFilename(vehicle.configFileName)
end

function DeliveryService:showShopDeliveryPrompt()
    local pending = self.currentShopChoice

    if pending == nil or pending.promptOpen then
        return
    end

    if OptionDialog == nil or OptionDialog.show == nil then
        self:notify("Haulage option menu unavailable. Press Dealer Haulage again later.", true)
        return
    end

    pending.promptOpen = true

    local text = "Item price: " .. self:formatMoney(pending.itemPrice)
    local optionTexts = self:getDeliveryOptionTexts(pending)

    OptionDialog.show(
        function(index)
            DeliveryService:onShopDeliveryOptionSelected(index)
        end,
        "Dealer Haulage",
        text,
        optionTexts
    )
end

function DeliveryService:getDeliveryOptionTexts(pending)
    local optionTexts = {}

    for _, option in ipairs(self.deliveryOptions) do
        local fee, isSurcharge = self:getBookingChargeForOption(pending, option)
        local feeText = self:formatMoney(fee)

        if isSurcharge then
            feeText = "add-on " .. feeText
        end

        optionTexts[#optionTexts + 1] = option.name .. " | " .. option.shortDelayText .. " | " .. feeText
    end

    optionTexts[#optionTexts + 1] = "Self-collection | no haulage"

    return optionTexts
end

function DeliveryService:getDeliveryOptionByKey(optionKey)
    for _, option in ipairs(self.deliveryOptions) do
        if option.key == optionKey then
            return option
        end
    end

    return nil
end

function DeliveryService:popPrePurchaseChoiceForBuyVehicleData(buyVehicleData)
    if #self.prePurchaseChoiceQueue == 0 then
        return nil
    end

    local storeItemXml = nil

    if buyVehicleData ~= nil and buyVehicleData.storeItem ~= nil then
        storeItemXml = buyVehicleData.storeItem.xmlFilename
    end

    for index, choice in ipairs(self.prePurchaseChoiceQueue) do
        if self:getPrePurchaseChoiceMatchesStoreItem(choice, storeItemXml) then
            return table.remove(self.prePurchaseChoiceQueue, index)
        end
    end

    return nil
end

function DeliveryService:hasPrePurchaseChoiceForBuyVehicleData(buyVehicleData)
    if #self.prePurchaseChoiceQueue == 0 then
        return false
    end

    local storeItemXml = nil

    if buyVehicleData ~= nil and buyVehicleData.storeItem ~= nil then
        storeItemXml = buyVehicleData.storeItem.xmlFilename
    end

    for _, choice in ipairs(self.prePurchaseChoiceQueue) do
        if self:getPrePurchaseChoiceMatchesStoreItem(choice, storeItemXml) then
            return true
        end
    end

    return false
end

function DeliveryService:getPrePurchaseChoiceMatchesStoreItem(choice, storeItemXml)
    if choice == nil then
        return false
    end

    if choice.storeItemXml == nil or storeItemXml == nil then
        return true
    end

    return string.lower(tostring(choice.storeItemXml)) == string.lower(tostring(storeItemXml))
end

function DeliveryService:onShopDeliveryOptionSelected(index)
    local pending = self.currentShopChoice

    if pending == nil then
        return
    end

    pending.promptOpen = false

    if index == nil then
        self:notify("Haulage choice still waiting. Press Dealer Haulage to choose.")
        return
    end

    if index == self.declineOptionIndex then
        self:declineShopDelivery(pending)
        return
    end

    local option = self.deliveryOptions[index]

    if option == nil then
        self:notify("Haulage option was not recognised.", true)
        return
    end

    self.currentShopChoice = nil
    self.nextPromptTimer = 700

    self:bookQueuedDelivery(pending, option)
end

function DeliveryService:declineShopDelivery(pending)
    self.currentShopChoice = nil
    self.nextPromptTimer = 700

    if pending.cargoVehicle ~= nil then
        pending.cargoVehicle.deliveryServiceDeclined = true
        self:unlockAwaitingVehicle(pending.cargoVehicle)
    end

    self:updateActionEventText()
    self:notify("Dealer haulage declined. This bought/leased item is set for self-collection.")
    print("DeliveryService shop delivery declined")
end

function DeliveryService:bookQueuedDelivery(pending, option)
    local cargoVehicle = pending.cargoVehicle

    if cargoVehicle == nil or cargoVehicle.isDeleted then
        self:updateActionEventText()
        self:notify("Haulage contract could not be booked because the bought/leased item was not found.", true)
        return
    end

    local normalFee = pending.fees[option.key] or option.minimumFee
    local fee, isManifestSurcharge, manifest = self:getBookingChargeForOption(pending, option)
    local currentTime = self:getCurrentGameTimeMs()

    if currentTime == nil then
        self:notify("Could not read in-game time. Starting haulage immediately.", true)
        self:unlockAwaitingVehicle(cargoVehicle)
        self:startDeliveryServiceForVehicle(cargoVehicle, fee, option.name, false)
        return
    end

    self:chargeMoney(fee)

    local x, y, z, rx, ry, rz = self:getVehicleTransform(cargoVehicle)
    local dueTime = currentTime + option.delayMs
    local manifestId = nil
    local manifestItemNumber = 1

    if manifest ~= nil then
        manifestId = manifest.manifestId
        manifestItemNumber = manifest.itemCount + 1
        dueTime = math.max(dueTime, manifest.dueTime or dueTime)
        self:setManifestDueTime(manifestId, dueTime)
    else
        manifestId = self:getNextManifestId()
    end

    local queuedDelivery = {
        cargoVehicle = cargoVehicle,
        manifestId = manifestId,
        manifestLabel = self:getManifestLabel(manifestId),
        manifestItemNumber = manifestItemNumber,
        optionKey = option.key,
        optionName = option.name,
        itemName = self:getVehicleDisplayName(cargoVehicle),
        itemClass = pending.itemClass or self:getHaulageItemClass(cargoVehicle, pending.storeItem),
        purchaseText = pending.purchaseText,
        delayText = option.delayText,
        fee = fee,
        normalFee = normalFee,
        isManifestSurcharge = isManifestSurcharge,
        storePlaces = pending.storePlaces,
        usedStorePlaces = pending.usedStorePlaces,
        dueTime = dueTime,
        readyNotified = false,
        lockX = x,
        lockY = y,
        lockZ = z,
        lockRotX = rx,
        lockRotY = ry,
        lockRotZ = rz,
        lockWarningTimer = 0
    }

    table.insert(self.deliveryQueue, queuedDelivery)
    self:lockAwaitingVehicle(cargoVehicle, queuedDelivery)

    self:updateActionEventText()

    if isManifestSurcharge then
        self:notify(queuedDelivery.manifestLabel .. ": " .. option.name .. " add-on delivery charge: " .. self:formatMoney(fee) .. ".")
        self:notify(queuedDelivery.manifestLabel .. " now has " .. tostring(manifestItemNumber) .. " bought/leased items. Haulage due in " .. self:formatGameDuration(dueTime - currentTime) .. ".")
    else
        self:notify(queuedDelivery.manifestLabel .. ": " .. option.name .. " booked. Fee: " .. self:formatMoney(fee) .. ".")
        self:notify("Bought/leased item held at the dealer yard. Haulage due in " .. option.delayText .. ".")
    end

    print("DeliveryService queued " .. option.name .. " for " .. tostring(option.delayMs) .. " ms")
end

function DeliveryService:updateDeliveryQueue()
    if #self.deliveryQueue == 0 then
        return
    end

    local currentTime = self:getCurrentGameTimeMs()

    if currentTime == nil then
        return
    end

    local notifiedManifests = {}

    for _, queuedDelivery in ipairs(self.deliveryQueue) do
        if currentTime >= queuedDelivery.dueTime and not queuedDelivery.readyNotified then
            queuedDelivery.readyNotified = true
            local manifestKey = queuedDelivery.manifestId or queuedDelivery
            local alreadyNotified = notifiedManifests[manifestKey]
            notifiedManifests[manifestKey] = true

            if not alreadyNotified then
                local itemCount = self:getQueuedManifestItemCount(queuedDelivery.manifestId)
                local readyText = (queuedDelivery.manifestLabel or self:getManifestLabel(queuedDelivery.manifestId)) .. " - " .. queuedDelivery.optionName

                if itemCount > 1 then
                    readyText = readyText .. " (" .. tostring(itemCount) .. " items)"
                end

                if self.activeDelivery ~= nil then
                    self:notify(readyText .. " is ready. Waiting for the current haulage kit to return.")
                else
                    self:notify(readyText .. " is ready at the dealer yard.")
                end
            end

            print("DeliveryService queued delivery ready")
        end
    end

    if self.activeDelivery ~= nil then
        local readyIndex = self:getReadyQueuedDeliveryIndex(currentTime)

        if readyIndex ~= nil and self.activeDelivery.stage == "returning" then
            self:prepareReturnForNextDelivery()
        end

        return
    end

    local readyIndex = self:getReadyQueuedDeliveryIndex(currentTime)

    if readyIndex == nil then
        return
    end

    local group = self:collectReadyQueuedDeliveries(currentTime, true)
    self:updateActionEventText()
    self:dispatchQueuedDeliveryGroup(group)
end

function DeliveryService:cleanupInvalidHaulageContracts()
    local removedManifests = {}
    local removedAny = false
    local index = 1

    while index <= #self.deliveryQueue do
        local queuedDelivery = self.deliveryQueue[index]
        local vehicle = queuedDelivery.cargoVehicle

        if not self:getIsQueuedVehicleStillAvailable(vehicle) then
            self:unlockAwaitingVehicle(vehicle)

            local manifestKey = queuedDelivery.manifestId or ("item" .. tostring(index))
            local removedManifest = removedManifests[manifestKey]

            if removedManifest == nil then
                removedManifest = {
                    label = queuedDelivery.manifestLabel or self:getManifestLabel(queuedDelivery.manifestId),
                    removedCount = 0
                }
                removedManifests[manifestKey] = removedManifest
            end

            removedManifest.removedCount = removedManifest.removedCount + 1

            table.remove(self.deliveryQueue, index)
            removedAny = true
        else
            index = index + 1
        end
    end

    if self.currentShopChoice ~= nil and not self:getIsQueuedVehicleStillAvailable(self.currentShopChoice.cargoVehicle) then
        self.currentShopChoice = nil
        removedAny = true
    end

    index = 1
    while index <= #self.pendingChoiceQueue do
        local pending = self.pendingChoiceQueue[index]

        if not self:getIsQueuedVehicleStillAvailable(pending.cargoVehicle) then
            table.remove(self.pendingChoiceQueue, index)
            removedAny = true
        else
            index = index + 1
        end
    end

    if removedAny then
        for manifestKey, removedManifest in pairs(removedManifests) do
            local remainingCount = self:getQueuedManifestItemCountByKey(manifestKey)

            if remainingCount > 0 then
                self:notify("Bought/leased item removed from " .. tostring(removedManifest.label) .. " because it is no longer available.", true)
                self:notify(tostring(removedManifest.label) .. " remains active with " .. tostring(remainingCount) .. " item(s).")
            else
                self:notify(tostring(removedManifest.label) .. " cancelled because the bought/leased item is no longer available.", true)
            end
        end

        if self.activeDelivery ~= nil and self.activeDelivery.stage == "returning" and #self.deliveryQueue == 0 then
            self.activeDelivery.stage = "delivered"
            self:notify("Remaining manifest cancelled. Haulage kit can now be recalled.")
        end

        self:updateActionEventText()
    end
end

function DeliveryService:getIsQueuedVehicleStillAvailable(vehicle)
    if vehicle == nil or vehicle.isDeleted then
        return false
    end

    if not self:getIsDeliverableVehicle(vehicle) then
        return false
    end

    local rootVehicle = vehicle.rootVehicle or vehicle

    for _, missionVehicle in ipairs(self:getVehicleList()) do
        if missionVehicle == vehicle or missionVehicle == rootVehicle then
            return true
        end
    end

    return false
end

function DeliveryService:getReadyQueuedDeliveryIndex(currentTime)
    currentTime = currentTime or self:getCurrentGameTimeMs()

    if currentTime == nil then
        return nil
    end

    local bestIndex = nil
    local bestDueTime = nil

    for index, queuedDelivery in ipairs(self.deliveryQueue) do
        if currentTime >= queuedDelivery.dueTime then
            if bestDueTime == nil or queuedDelivery.dueTime < bestDueTime then
                bestDueTime = queuedDelivery.dueTime
                bestIndex = index
            end
        end
    end

    return bestIndex
end

function DeliveryService:collectReadyQueuedDeliveries(currentTime, includeNearReady)
    currentTime = currentTime or self:getCurrentGameTimeMs()

    if currentTime == nil then
        return {}
    end

    local cutoffTime = currentTime

    if includeNearReady then
        cutoffTime = cutoffTime + self.groupWindowMs
    end

    local firstReadyDelivery = nil

    for _, queuedDelivery in ipairs(self.deliveryQueue) do
        if queuedDelivery.dueTime <= currentTime then
            if firstReadyDelivery == nil or queuedDelivery.dueTime < firstReadyDelivery.dueTime then
                firstReadyDelivery = queuedDelivery
            end
        end
    end

    if firstReadyDelivery == nil then
        return {}
    end

    local group = {}
    local index = 1

    while index <= #self.deliveryQueue do
        local queuedDelivery = self.deliveryQueue[index]
        local sameManifest = false

        if firstReadyDelivery.manifestId ~= nil then
            sameManifest = queuedDelivery.manifestId == firstReadyDelivery.manifestId
        else
            sameManifest = queuedDelivery.optionKey == firstReadyDelivery.optionKey
        end

        if sameManifest and queuedDelivery.dueTime <= cutoffTime and #group < self.maxItemsPerHaulageManifest then
            table.insert(group, table.remove(self.deliveryQueue, index))
        else
            index = index + 1
        end
    end

    return group
end

function DeliveryService:prepareReturnForNextDelivery()
    if self.activeDelivery == nil then
        return
    end

    if self.activeDelivery.stage ~= "returning" then
        self.activeDelivery.stage = "returning"
        self:updateActionEventText()
        self:updateServiceVehicleTabbable()
        self:notify("Next haulage contract is ready. Return the tractor unit and low loader near the next bought/leased item at the dealer yard.")
        print("DeliveryService reusable rig requested for next queued delivery")
    end
end

function DeliveryService:dispatchQueuedDeliveryGroup(group)
    local validGroup = self:getValidDeliveryGroup(group)

    if #validGroup == 0 then
        self:notify("Queued haulage contract failed because no valid bought/leased item was found.", true)
        return
    end

    for _, queuedDelivery in ipairs(validGroup) do
        self:unlockAwaitingVehicle(queuedDelivery.cargoVehicle)
    end

    self:startDeliveryServiceForGroup(validGroup, true)
end

function DeliveryService:tryStartNextQueuedDeliveryWithCurrentRig()
    if self.activeDelivery == nil then
        return
    end

    local currentTime = self:getCurrentGameTimeMs()
    local readyIndex = self:getReadyQueuedDeliveryIndex(currentTime)

    if readyIndex == nil then
        if #self.deliveryQueue == 0 then
            self.activeDelivery.stage = "delivered"
            self:updateActionEventText()
            self:updateServiceVehicleTabbable()
            self:notify("No remaining haulage manifests queued. You can recall the haulage kit.")
            return
        end

        self:showDeliveryQueueStatus()
        return
    end

    local firstReady = self.deliveryQueue[readyIndex]
    local cargoVehicle = firstReady.cargoVehicle

    if cargoVehicle == nil or cargoVehicle.isDeleted then
        table.remove(self.deliveryQueue, readyIndex)
        self:notify("Queued haulage contract skipped because the bought/leased item was not found.", true)
        return
    end

    local distance = self:getDeliveryRigDistanceToVehicle(self.activeDelivery, cargoVehicle)

    if distance == nil or distance > self.returnToDealerDistance then
        local distanceText = "near the dealer"

        if distance ~= nil then
            distanceText = tostring(math.floor(distance)) .. " metres away"
        end

        self:notify("Return the tractor unit and low loader to the dealer yard for the next haulage contract.", true)
        self:notify("Next bought/leased item is " .. distanceText .. ".")
        return
    end

    local group = self:collectReadyQueuedDeliveries(currentTime, true)
    local validGroup = self:getValidDeliveryGroup(group)

    if #validGroup == 0 then
        self:notify("No valid queued haulage contract is ready.", true)
        return
    end

    for _, queuedDelivery in ipairs(validGroup) do
        self:unlockAwaitingVehicle(queuedDelivery.cargoVehicle)
    end

    self:assignQueuedGroupToExistingRig(validGroup)
end

function DeliveryService:getValidDeliveryGroup(group)
    local validGroup = {}

    if group == nil then
        return validGroup
    end

    for _, queuedDelivery in ipairs(group) do
        local vehicle = queuedDelivery.cargoVehicle

        if vehicle ~= nil and not vehicle.isDeleted and self:getIsDeliverableVehicle(vehicle) then
            table.insert(validGroup, queuedDelivery)
        end
    end

    return validGroup
end

function DeliveryService:startDeliveryServiceForVehicle(cargoVehicle, fee, deliveryName, feeAlreadyCharged)
    local queuedDelivery = {
        cargoVehicle = cargoVehicle,
        optionName = deliveryName or "Dealer Haulage",
        fee = fee or self.deliveryFee
    }

    self:startDeliveryServiceForGroup({queuedDelivery}, feeAlreadyCharged == true)
end

function DeliveryService:startDeliveryServiceForGroup(group, feesAlreadyCharged)
    if self.activeDelivery ~= nil then
        self:notify("A haulage contract is already active.", true)
        return
    end

    local cargoVehicles = self:getCargoVehiclesFromGroup(group)
    local primaryCargoVehicle = cargoVehicles[1]

    if primaryCargoVehicle == nil then
        self:notify("No bought/leased item found for haulage.", true)
        return
    end

    local cargoX, cargoY, cargoZ, cargoRotY = self:getVehiclePosition(primaryCargoVehicle)

    if cargoX == nil then
        self:notify("Could not read the bought/leased item position.", true)
        print("DeliveryService start failed: no cargo position")
        return
    end

    local totalFee = self:getDeliveryGroupFee(group)
    local deliveryName = self:getDeliveryGroupName(group)
    local shopPlacement = self:getShopPlacementFromGroup(group)

    if not feesAlreadyCharged then
        self:chargeMoney(totalFee)
        self:notify(deliveryName .. " accepted. Fee: " .. self:formatMoney(totalFee) .. ".")
    end

    local truckX, truckZ = self:getOffsetPosition(cargoX, cargoZ, cargoRotY, 8, 3)
    local trailerX, trailerZ = self:getOffsetPosition(cargoX, cargoZ, cargoRotY, 8, -3)

    self.activeDelivery = {
        stage = "loading",
        cargoVehicle = primaryCargoVehicle,
        cargoVehicles = cargoVehicles,
        queuedDeliveries = group,
        truck = nil,
        lowLoader = nil,
        courtesyTractor = nil,
        needsCourtesyTractor = self:getGroupNeedsCourtesyTractor(cargoVehicles),
        readyNotified = false,
        deliveryName = deliveryName,
        fee = totalFee,
        startTruckX = truckX,
        startTruckZ = truckZ,
        startTrailerX = trailerX,
        startTrailerZ = trailerZ,
        startRotY = cargoRotY or 0,
        shopPlacement = shopPlacement
    }

    self:updateActionEventText()

    self:notify("Preparing tractor unit and low loader.")
    print("DeliveryService spawning truck and low loader")

    self:spawnServiceVehicle("truck", self.truckXml, truckX, truckZ, cargoRotY or 0, shopPlacement)
    self:spawnServiceVehicle("lowLoader", self.lowLoaderXml, trailerX, trailerZ, cargoRotY or 0, shopPlacement)
    self:spawnCourtesyTractorIfNeeded(self.activeDelivery)
end

function DeliveryService:assignQueuedGroupToExistingRig(group)
    local delivery = self.activeDelivery

    if delivery == nil then
        return
    end

    self:clearCourtesyTractor(delivery)

    local cargoVehicles = self:getCargoVehiclesFromGroup(group)
    local primaryCargoVehicle = cargoVehicles[1]

    if primaryCargoVehicle == nil then
        self:notify("No valid queued haulage contract is ready.", true)
        return
    end

    delivery.cargoVehicle = primaryCargoVehicle
    delivery.cargoVehicles = cargoVehicles
    delivery.queuedDeliveries = group
    delivery.deliveryName = self:getDeliveryGroupName(group)
    delivery.fee = self:getDeliveryGroupFee(group)
    delivery.shopPlacement = self:getShopPlacementFromGroup(group)
    delivery.needsCourtesyTractor = self:getGroupNeedsCourtesyTractor(cargoVehicles)
    delivery.readyNotified = false

    local x, y, z, rotY = self:getVehiclePosition(primaryCargoVehicle)
    delivery.startRotY = rotY or 0

    if delivery.needsCourtesyTractor then
        delivery.stage = "loading"
        self:updateActionEventText()
        self:updateServiceVehicleTabbable()
        self:spawnCourtesyTractorIfNeeded(delivery)
    else
        delivery.stage = "transport"
        self:updateActionEventText()
        self:updateServiceVehicleTabbable()
        self:notify(delivery.deliveryName .. " released from the dealer yard.")
        self:notify("Use the same tractor unit and low loader. Load the next bought/leased item and haul it.")
        delivery.readyNotified = true
    end

    print("DeliveryService next queued delivery assigned to existing rig")
end

function DeliveryService:getCargoVehiclesFromGroup(group)
    local cargoVehicles = {}

    for _, queuedDelivery in ipairs(group or {}) do
        if queuedDelivery.cargoVehicle ~= nil and not queuedDelivery.cargoVehicle.isDeleted then
            table.insert(cargoVehicles, queuedDelivery.cargoVehicle)
        end
    end

    return cargoVehicles
end

function DeliveryService:getShopPlacementFromGroup(group)
    for _, queuedDelivery in ipairs(group or {}) do
        if queuedDelivery.storePlaces ~= nil then
            return {
                storePlaces = queuedDelivery.storePlaces,
                usedStorePlaces = queuedDelivery.usedStorePlaces or {}
            }
        end
    end

    return nil
end

function DeliveryService:getDeliveryGroupFee(group)
    local totalFee = 0

    for _, queuedDelivery in ipairs(group or {}) do
        totalFee = totalFee + (queuedDelivery.fee or self.deliveryFee)
    end

    return totalFee
end

function DeliveryService:getDeliveryGroupName(group)
    if group == nil or #group == 0 then
        return "Dealer Haulage"
    end

    local label = group[1].manifestLabel or self:getManifestLabel(group[1].manifestId)
    local optionName = group[1].optionName or "Dealer Haulage"

    return label .. " - " .. optionName
end

function DeliveryService:getGroupNeedsCourtesyTractor(cargoVehicles)
    local hasTowableItem = false
    local hasTowCapableVehicle = false

    for _, vehicle in ipairs(cargoVehicles or {}) do
        if self:getIsTowCapableVehicle(vehicle) then
            hasTowCapableVehicle = true
        end

        if vehicle.spec_drivable == nil then
            hasTowableItem = true
        end
    end

    return hasTowableItem and not hasTowCapableVehicle
end

function DeliveryService:getIsTowCapableVehicle(vehicle)
    if vehicle == nil then
        return false
    end

    return vehicle.spec_drivable ~= nil and vehicle.spec_attacherJoints ~= nil
end

function DeliveryService:spawnCourtesyTractorIfNeeded(delivery)
    if delivery == nil or not delivery.needsCourtesyTractor then
        return
    end

    if delivery.courtesyTractor ~= nil and not delivery.courtesyTractor.isDeleted then
        return
    end

    local cargoVehicle = delivery.cargoVehicle
    local cargoX, cargoY, cargoZ, cargoRotY = self:getVehiclePosition(cargoVehicle)

    if cargoX == nil then
        self:notify("Dealer courtesy tractor could not be positioned.", true)
        return
    end

    local tractorX, tractorZ = self:getOffsetPosition(cargoX, cargoZ, cargoRotY, -6, 6)

    self:spawnServiceVehicle("courtesyTractor", self.courtesyTractorXml, tractorX, tractorZ, cargoRotY or 0, delivery.shopPlacement)
end

function DeliveryService:clearCourtesyTractor(delivery)
    if delivery == nil then
        return
    end

    local hadCourtesyTractor = delivery.courtesyTractor ~= nil and not delivery.courtesyTractor.isDeleted

    self:deleteServiceVehicle(delivery.courtesyTractor)

    if hadCourtesyTractor then
        self:notify("Dealer courtesy tractor recalled.")
    end

    delivery.courtesyTractor = nil
    delivery.needsCourtesyTractor = false
end

function DeliveryService:getDeliveryRigDistanceToVehicle(delivery, cargoVehicle)
    if delivery == nil or cargoVehicle == nil then
        return nil
    end

    local bestDistance = nil

    if delivery.truck ~= nil then
        bestDistance = self:getVehicleDistance(delivery.truck, cargoVehicle)
    end

    if delivery.lowLoader ~= nil then
        local trailerDistance = self:getVehicleDistance(delivery.lowLoader, cargoVehicle)

        if trailerDistance ~= nil and (bestDistance == nil or trailerDistance < bestDistance) then
            bestDistance = trailerDistance
        end
    end

    return bestDistance
end

function DeliveryService:getVehicleDistance(vehicleA, vehicleB)
    if vehicleA == nil or vehicleA.rootNode == nil or vehicleB == nil or vehicleB.rootNode == nil then
        return nil
    end

    local ax, ay, az = getWorldTranslation(vehicleA.rootNode)
    local bx, by, bz = getWorldTranslation(vehicleB.rootNode)

    return self:getDistance(ax, az, bx, bz)
end

function DeliveryService:lockAwaitingVehicle(vehicle, queuedDelivery)
    if vehicle == nil then
        return
    end

    local wasAlreadyLocked = vehicle.deliveryServiceLocked == true

    vehicle.deliveryServiceBooked = true
    vehicle.deliveryServiceLocked = true

    if not wasAlreadyLocked and vehicle.getIsTabbable ~= nil then
        vehicle.deliveryServicePreviousTabbable = vehicle:getIsTabbable()
    end

    self:registerAwaitingVehicleControlLock(vehicle)
    self:holdVehicleAtDealer(vehicle, queuedDelivery, false)
end

function DeliveryService:unlockAwaitingVehicle(vehicle)
    if vehicle == nil then
        return
    end

    vehicle.deliveryServiceBooked = false
    vehicle.deliveryServiceLocked = false

    if vehicle.setIsTabbable ~= nil and vehicle.deliveryServicePreviousTabbable ~= nil then
        vehicle:setIsTabbable(vehicle.deliveryServicePreviousTabbable)
    end

    vehicle.deliveryServicePreviousTabbable = nil
    vehicle.deliveryServiceAwaitingMotorNoticeShown = nil
end

function DeliveryService:registerAwaitingVehicleControlLock(vehicle)
    if vehicle == nil then
        return
    end

    local rootVehicle = vehicle.rootVehicle or vehicle

    if rootVehicle ~= nil and rootVehicle.registerPlayerVehicleControlAllowedFunction ~= nil then
        rootVehicle:registerPlayerVehicleControlAllowedFunction(vehicle, DeliveryService.awaitingVehicleControlAllowed)
    end
end

function DeliveryService.awaitingVehicleControlAllowed(vehicle)
    if vehicle ~= nil and vehicle.deliveryServiceLocked then
        return false, "Awaiting dealer haulage. You can enter and detach equipment, but driving is blocked."
    end

    return true, nil
end

function DeliveryService:updateLockedDeliveryVehicles(dt)
    if #self.deliveryQueue == 0 then
        return
    end

    for _, queuedDelivery in ipairs(self.deliveryQueue) do
        local vehicle = queuedDelivery.cargoVehicle

        if vehicle ~= nil and not vehicle.isDeleted and vehicle.deliveryServiceLocked then
            queuedDelivery.lockWarningTimer = math.max(0, (queuedDelivery.lockWarningTimer or 0) - dt)
            self:registerAwaitingVehicleControlLock(vehicle)
            self:holdVehicleAtDealer(vehicle, queuedDelivery, true)
        end
    end
end

function DeliveryService:holdVehicleAtDealer(vehicle, queuedDelivery, warnIfMoved)
    if vehicle == nil or vehicle.rootNode == nil or queuedDelivery.lockX == nil then
        return
    end

    local x, y, z = getWorldTranslation(vehicle.rootNode)
    local distance = self:getDistance(x, z, queuedDelivery.lockX, queuedDelivery.lockZ)
    local currentVehicle = self:getCurrentVehicle()
    local playerIsInVehicle = self:getIsSameVehicleOrRoot(currentVehicle, vehicle)

    if playerIsInVehicle then
        self:keepAwaitingVehicleParked(vehicle, queuedDelivery, warnIfMoved)
    else
        queuedDelivery.lockEntryWarningActive = false
        vehicle.deliveryServiceAwaitingMotorNoticeShown = nil
    end

    if distance <= 4 then
        if not playerIsInVehicle then
            queuedDelivery.lockWarningShown = false
        end

        return
    end

    if not playerIsInVehicle then
        self:updateAwaitingVehicleLockPosition(vehicle, queuedDelivery)
        self:settleVehiclePhysics(vehicle)

        if warnIfMoved and not queuedDelivery.lockWarningShown then
            queuedDelivery.lockWarningShown = true
            self:notify("Awaiting bought/leased item moved in the dealer yard. Pickup position updated.", true)
        end

        print("DeliveryService updated awaiting vehicle pickup position")
        return
    end

    if vehicle.setAbsolutePosition ~= nil then
        vehicle:setAbsolutePosition(
            queuedDelivery.lockX,
            queuedDelivery.lockY,
            queuedDelivery.lockZ,
            queuedDelivery.lockRotX or 0,
            queuedDelivery.lockRotY or 0,
            queuedDelivery.lockRotZ or 0
        )
    end

    self:settleVehiclePhysics(vehicle)

    if warnIfMoved and not queuedDelivery.lockWarningShown then
        queuedDelivery.lockWarningShown = true
        self:notify("This bought/leased item is awaiting dealer haulage and must stay at the dealer yard.", true)
    end

    print("DeliveryService returned awaiting vehicle to dealer")
end

function DeliveryService:updateAwaitingVehicleLockPosition(vehicle, queuedDelivery)
    if vehicle == nil or vehicle.rootNode == nil or queuedDelivery == nil then
        return
    end

    local x, y, z = getWorldTranslation(vehicle.rootNode)
    local rx, ry, rz = 0, 0, 0

    if getWorldRotation ~= nil then
        rx, ry, rz = getWorldRotation(vehicle.rootNode)
    end

    queuedDelivery.lockX = x
    queuedDelivery.lockY = y
    queuedDelivery.lockZ = z
    queuedDelivery.lockRotX = rx or 0
    queuedDelivery.lockRotY = ry or 0
    queuedDelivery.lockRotZ = rz or 0
end

function DeliveryService:keepAwaitingVehicleParked(vehicle, queuedDelivery, warnIfMoved)
    if vehicle == nil then
        return
    end

    local motorWasRunning = self:getIsVehicleMotorRunning(vehicle)
    self:forceStopVehicleMotor(vehicle)

    if motorWasRunning then
        if queuedDelivery ~= nil and not vehicle.deliveryServiceAwaitingMotorNoticeShown then
            vehicle.deliveryServiceAwaitingMotorNoticeShown = true
            self:notify("Awaiting dealer haulage. Engine held off to protect fuel, battery and wear.", true)
        end
    end

    if vehicle.setCruiseControlState ~= nil and Drivable ~= nil and Drivable.CRUISECONTROL_STATE_OFF ~= nil then
        vehicle:setCruiseControlState(Drivable.CRUISECONTROL_STATE_OFF, true)
    end

    if vehicle.setAccelerationPedalInput ~= nil then
        vehicle:setAccelerationPedalInput(0)
    end

    if vehicle.setBrakePedalInput ~= nil then
        vehicle:setBrakePedalInput(1)
    end

    if vehicle.brakeToStop ~= nil then
        vehicle:brakeToStop()
    end

    if warnIfMoved and queuedDelivery ~= nil and not queuedDelivery.lockEntryWarningActive then
        queuedDelivery.lockEntryWarningActive = true
        self:notify("Awaiting dealer haulage. You can enter and detach equipment, but the item cannot be driven yet.", true)
    end
end

function DeliveryService:getIsVehicleMotorRunning(vehicle)
    if vehicle == nil then
        return false
    end

    if vehicle.getIsMotorStarted ~= nil then
        local ok, isStarted = pcall(vehicle.getIsMotorStarted, vehicle)

        if ok and isStarted then
            return true
        end
    end

    local spec = vehicle.spec_motorized

    if spec ~= nil then
        if spec.isMotorStarted == true or spec.isMotorStarting == true then
            return true
        end
    end

    return false
end

function DeliveryService:forceStopVehicleMotor(vehicle)
    if vehicle == nil then
        return
    end

    if vehicle.stopMotor ~= nil then
        pcall(vehicle.stopMotor, vehicle, true)
        pcall(vehicle.stopMotor, vehicle)
    end

    if vehicle.setIsMotorStarted ~= nil then
        pcall(vehicle.setIsMotorStarted, vehicle, false, true)
        pcall(vehicle.setIsMotorStarted, vehicle, false)
    end

    if vehicle.setMotorStarted ~= nil then
        pcall(vehicle.setMotorStarted, vehicle, false, true)
        pcall(vehicle.setMotorStarted, vehicle, false)
    end

    if vehicle.setMotorState ~= nil then
        pcall(vehicle.setMotorState, vehicle, false, true)
        pcall(vehicle.setMotorState, vehicle, false)

        if MotorState ~= nil and MotorState.OFF ~= nil then
            pcall(vehicle.setMotorState, vehicle, MotorState.OFF, true)
            pcall(vehicle.setMotorState, vehicle, MotorState.OFF)
        end
    end

    local spec = vehicle.spec_motorized

    if spec ~= nil then
        spec.isMotorStarted = false
        spec.isMotorStarting = false
        spec.isMotorStopping = true
    end
end

function DeliveryService:getIsSameVehicleOrRoot(vehicleA, vehicleB)
    if vehicleA == nil or vehicleB == nil then
        return false
    end

    if vehicleA == vehicleB then
        return true
    end

    local rootA = vehicleA.rootVehicle or vehicleA
    local rootB = vehicleB.rootVehicle or vehicleB

    return rootA == rootB
end

function DeliveryService:settleVehiclePhysics(vehicle)
    if vehicle == nil then
        return
    end

    if vehicle.components ~= nil then
        for _, component in pairs(vehicle.components) do
            if component.node ~= nil then
                if setLinearVelocity ~= nil then
                    setLinearVelocity(component.node, 0, 0, 0)
                end

                if setAngularVelocity ~= nil then
                    setAngularVelocity(component.node, 0, 0, 0)
                end
            end
        end
    end

    if vehicle.raiseActive ~= nil then
        vehicle:raiseActive()
    end
end

function DeliveryService:showDeliveryQueueStatus()
    if #self.deliveryQueue == 0 then
        return
    end

    local currentTime = self:getCurrentGameTimeMs()
    local manifests = self:getQueuedManifestSummaries(currentTime)

    if #manifests == 0 then
        self:notify("No valid dealer haulage manifests queued.", true)
        return
    end

    self:notify("Dealer haulage queue: " .. tostring(#manifests) .. " manifest(s), " .. tostring(#self.deliveryQueue) .. " item(s).")

    for _, manifest in ipairs(manifests) do
        local timeText = "time unavailable"

        if manifest.remainingMs ~= nil then
            if manifest.remainingMs <= 0 then
                timeText = "ready now"
            else
                timeText = self:formatGameDuration(manifest.remainingMs)
            end
        end

        self:notify(manifest.label .. " - " .. manifest.optionName .. ": " .. tostring(manifest.itemCount) .. " item(s), " .. timeText .. ".")
        self:notify("Items: " .. manifest.itemText .. ".")
    end
end

function DeliveryService:showNearestQueuedCargoStatus()
    local queuedDelivery = self:getNearestQueuedDeliveryForPlayer(30)

    if queuedDelivery == nil then
        return false
    end

    local currentTime = self:getCurrentGameTimeMs()
    local timeText = "time unavailable"

    if currentTime ~= nil and queuedDelivery.dueTime ~= nil then
        local remainingMs = math.max(0, queuedDelivery.dueTime - currentTime)

        if remainingMs <= 0 then
            timeText = "ready now"
        else
            timeText = self:formatGameDuration(remainingMs)
        end
    end

    local label = queuedDelivery.manifestLabel or self:getManifestLabel(queuedDelivery.manifestId)
    local itemName = queuedDelivery.itemName or self:getVehicleDisplayName(queuedDelivery.cargoVehicle)

    self:notify(tostring(label) .. " - " .. tostring(queuedDelivery.optionName or "Dealer Haulage") .. ".")
    self:notify("Item: " .. tostring(itemName) .. ". ETA: " .. tostring(timeText) .. ".")

    return true
end

function DeliveryService:getNearestQueuedDeliveryForPlayer(maxDistance)
    local px, py, pz = self:getPlayerPosition()

    if px == nil then
        return nil
    end

    local nearestDelivery = nil
    local nearestDistance = maxDistance or 30

    for _, queuedDelivery in ipairs(self.deliveryQueue or {}) do
        local vehicle = queuedDelivery.cargoVehicle

        if vehicle ~= nil and not vehicle.isDeleted and vehicle.rootNode ~= nil then
            local x, y, z = getWorldTranslation(vehicle.rootNode)
            local distance = self:getDistance(px, pz, x, z)

            if distance <= nearestDistance then
                nearestDistance = distance
                nearestDelivery = queuedDelivery
            end
        end
    end

    return nearestDelivery
end

function DeliveryService:getNextQueuedManifestDialogText()
    local currentTime = self:getCurrentGameTimeMs()
    local manifests = self:getQueuedManifestSummaries(currentTime)
    local manifest = manifests[1]

    if manifest == nil then
        return nil
    end

    local timeText = "time unavailable"

    if manifest.remainingMs ~= nil then
        if manifest.remainingMs <= 0 then
            timeText = "ready now"
        else
            timeText = self:formatGameDuration(manifest.remainingMs)
        end
    end

    local itemText = self:truncateText(manifest.itemText or "item", 42)

    return "Next " .. tostring(manifest.label) .. ": " .. tostring(manifest.optionName) .. ", " .. timeText .. ". Items: " .. itemText .. "."
end

function DeliveryService:truncateText(text, maxLength)
    text = tostring(text or "")
    maxLength = maxLength or 60

    if string.len(text) <= maxLength then
        return text
    end

    return string.sub(text, 1, math.max(1, maxLength - 3)) .. "..."
end

function DeliveryService:getQueuedManifestSummaries(currentTime)
    local manifestMap = {}
    local manifests = {}

    for index, queuedDelivery in ipairs(self.deliveryQueue) do
        local manifestKey = queuedDelivery.manifestId or ("item" .. tostring(index))
        local manifest = manifestMap[manifestKey]

        if manifest == nil then
            manifest = {
                manifestId = queuedDelivery.manifestId,
                label = queuedDelivery.manifestLabel or self:getManifestLabel(queuedDelivery.manifestId),
                optionName = queuedDelivery.optionName or "Dealer Haulage",
                itemCount = 0,
                dueTime = queuedDelivery.dueTime,
                itemNames = {}
            }

            manifestMap[manifestKey] = manifest
            table.insert(manifests, manifest)
        end

        manifest.itemCount = manifest.itemCount + 1
        manifest.optionName = queuedDelivery.optionName or manifest.optionName

        if queuedDelivery.dueTime ~= nil then
            if manifest.dueTime == nil or queuedDelivery.dueTime > manifest.dueTime then
                manifest.dueTime = queuedDelivery.dueTime
            end
        end

        table.insert(manifest.itemNames, queuedDelivery.itemName or self:getVehicleDisplayName(queuedDelivery.cargoVehicle))
    end

    for _, manifest in ipairs(manifests) do
        if currentTime ~= nil and manifest.dueTime ~= nil then
            manifest.remainingMs = math.max(0, manifest.dueTime - currentTime)
        end

        manifest.itemText = table.concat(manifest.itemNames, ", ")
    end

    table.sort(manifests, function(a, b)
        if a.dueTime == nil then
            return false
        end

        if b.dueTime == nil then
            return true
        end

        if a.dueTime == b.dueTime then
            return tostring(a.label) < tostring(b.label)
        end

        return a.dueTime < b.dueTime
    end)

    return manifests
end

function DeliveryService:updatePendingChoiceLocks(dt)
    self:updatePendingChoiceLock(self.currentShopChoice, dt)

    for _, pending in ipairs(self.pendingChoiceQueue) do
        self:updatePendingChoiceLock(pending, dt)
    end
end

function DeliveryService:updatePendingChoiceLock(pending, dt)
    if pending == nil then
        return
    end

    local vehicle = pending.cargoVehicle

    if vehicle == nil or vehicle.isDeleted or not vehicle.deliveryServiceLocked then
        return
    end

    pending.lockWarningTimer = math.max(0, (pending.lockWarningTimer or 0) - (dt or 0))
    self:holdVehicleAtDealer(vehicle, pending, true)
end

function DeliveryService:restoreOrphanedTabbableVehicles(dt)
    if self.activeDelivery ~= nil or #self.deliveryQueue > 0 or #self.pendingChoiceQueue > 0 or self.currentShopChoice ~= nil then
        self.orphanTabRestoreTimer = self.orphanTabRestoreInterval
        return
    end

    self.orphanTabRestoreTimer = (self.orphanTabRestoreTimer or self.orphanTabRestoreInterval) - (dt or 0)

    if self.orphanTabRestoreTimer > 0 then
        return
    end

    self.orphanTabRestoreTimer = self.orphanTabRestoreInterval

    for _, vehicle in ipairs(self:getVehicleList()) do
        if vehicle ~= nil
            and not vehicle.isDeleted
            and not vehicle.deliveryServiceVehicle
            and not vehicle.deliveryServiceLocked
            and self:getIsDeliverableVehicle(vehicle)
            and self:getIsPlayerOwnedOrLeasedVehicle(vehicle)
            and vehicle.getIsTabbable ~= nil
            and vehicle.setIsTabbable ~= nil
            and not vehicle:getIsTabbable() then
            vehicle:setIsTabbable(true)

            if not self.orphanTabRestoreNotified then
                self.orphanTabRestoreNotified = true
                self:notify("Recovered tab access for machinery left locked by an interrupted haulage save.", true)
            end
        end
    end
end

function DeliveryService:getIsPlayerOwnedOrLeasedVehicle(vehicle)
    if vehicle == nil then
        return false
    end

    if VehiclePropertyState ~= nil then
        if vehicle.propertyState ~= VehiclePropertyState.OWNED and vehicle.propertyState ~= VehiclePropertyState.LEASED then
            return false
        end
    end

    local farmId = self:getCurrentFarmId()

    if farmId == nil then
        return true
    end

    if vehicle.getOwnerFarmId ~= nil then
        local ok, ownerFarmId = pcall(vehicle.getOwnerFarmId, vehicle)

        if ok and ownerFarmId ~= nil then
            return ownerFarmId == farmId
        end
    end

    if vehicle.ownerFarmId ~= nil then
        return vehicle.ownerFarmId == farmId
    end

    return true
end

function DeliveryService:getBookingChargeForOption(pending, option)
    local normalFee = pending.fees[option.key] or option.minimumFee
    local manifest = self:getOpenQueuedManifest(option.key, pending)

    if manifest == nil then
        return normalFee, false, nil
    end

    local surcharge = self:calculateExtraMachineryCharge(normalFee, option, manifest)

    return surcharge, true, manifest
end

function DeliveryService:getOpenQueuedManifest(optionKey, pending)
    local manifests = {}

    for _, queuedDelivery in ipairs(self.deliveryQueue) do
        if queuedDelivery.optionKey == optionKey and queuedDelivery.manifestId ~= nil and not queuedDelivery.readyNotified then
            local manifest = manifests[queuedDelivery.manifestId]

            if manifest == nil then
                manifest = {
                    manifestId = queuedDelivery.manifestId,
                    itemCount = 0,
                    mainFee = 0,
                    dueTime = queuedDelivery.dueTime,
                    tractorCount = 0,
                    trailerCount = 0,
                    largeCount = 0
                }
                manifests[queuedDelivery.manifestId] = manifest
            end

            manifest.itemCount = manifest.itemCount + 1
            manifest.mainFee = math.max(manifest.mainFee, queuedDelivery.normalFee or queuedDelivery.fee or 0)

            local itemClass = queuedDelivery.itemClass or self:getHaulageItemClass(queuedDelivery.cargoVehicle, queuedDelivery.storeItem)
            if itemClass == "tractor" then
                manifest.tractorCount = manifest.tractorCount + 1
            elseif itemClass == "trailer" then
                manifest.trailerCount = manifest.trailerCount + 1
            elseif itemClass == "large" then
                manifest.largeCount = manifest.largeCount + 1
            end

            if queuedDelivery.dueTime ~= nil then
                manifest.dueTime = math.max(manifest.dueTime or queuedDelivery.dueTime, queuedDelivery.dueTime)
            end
        end
    end

    local selectedManifest = nil

    for _, manifest in pairs(manifests) do
        if self:getCanAddPendingToManifest(manifest, pending) then
            if selectedManifest == nil or (manifest.dueTime or 0) < (selectedManifest.dueTime or 0) then
                selectedManifest = manifest
            end
        end
    end

    return selectedManifest
end

function DeliveryService:getCanAddPendingToManifest(manifest, pending)
    if manifest == nil or pending == nil then
        return false
    end

    local itemClass = pending.itemClass or self:getHaulageItemClass(pending.cargoVehicle, pending.storeItem)

    if itemClass == "large" or (manifest.largeCount or 0) > 0 then
        return false
    end

    local itemCount = manifest.itemCount or 0
    local tractorCount = manifest.tractorCount or 0
    local trailerCount = manifest.trailerCount or 0

    if itemClass == "trailer" or trailerCount > 0 then
        return itemCount < self.maxTrailersPerHaulageManifest
    end

    if itemCount >= self.maxItemsPerHaulageManifest then
        return false
    end

    if itemClass == "tractor" and tractorCount >= self.maxTractorsPerHaulageManifest then
        return false
    end

    return true
end

function DeliveryService:calculateExtraMachineryCharge(normalFee, option, manifest)
    return self:getExtraMachinerySurcharge(normalFee, option)
end

function DeliveryService:getExtraMachinerySurcharge(baseFee, option)
    local surcharge = math.floor(((baseFee or 0) * self.extraMachinerySurchargeRate) + 0.5)

    return math.max(0, surcharge)
end

function DeliveryService:setManifestDueTime(manifestId, dueTime)
    if manifestId == nil or dueTime == nil then
        return
    end

    for _, queuedDelivery in ipairs(self.deliveryQueue) do
        if queuedDelivery.manifestId == manifestId then
            queuedDelivery.dueTime = dueTime
        end
    end
end

function DeliveryService:getQueuedManifestItemCount(manifestId)
    if manifestId == nil then
        return 1
    end

    local count = 0

    for _, queuedDelivery in ipairs(self.deliveryQueue) do
        if queuedDelivery.manifestId == manifestId then
            count = count + 1
        end
    end

    return math.max(1, count)
end

function DeliveryService:getQueuedManifestItemCountByKey(manifestKey)
    local count = 0

    for index, queuedDelivery in ipairs(self.deliveryQueue) do
        local queuedManifestKey = queuedDelivery.manifestId or ("item" .. tostring(index))

        if queuedManifestKey == manifestKey then
            count = count + 1
        end
    end

    return count
end

function DeliveryService:getNextManifestId()
    local manifestId = self.nextManifestId or 1
    self.nextManifestId = manifestId + 1

    return manifestId
end

function DeliveryService:resetManifestSequenceIfIdle()
    if self.activeDelivery ~= nil then
        return
    end

    if #self.deliveryQueue > 0 or #self.pendingChoiceQueue > 0 or self.currentShopChoice ~= nil then
        return
    end

    self.nextManifestId = 1
end

function DeliveryService:getManifestLabel(manifestId)
    local number = math.max(1, math.floor(tonumber(manifestId) or 1))
    local label = ""

    while number > 0 do
        local remainder = (number - 1) % 26
        label = string.char(65 + remainder) .. label
        number = math.floor((number - 1) / 26)
    end

    return "Manifest " .. label
end

function DeliveryService:calculateDeliveryFees(itemPrice)
    local fees = {}
    local basePrice = tonumber(itemPrice) or 0

    for _, option in ipairs(self.deliveryOptions) do
        local fee = math.floor((basePrice * option.rate) + 0.5)

        if fee < option.minimumFee then
            fee = option.minimumFee
        end

        fees[option.key] = fee
    end

    return fees
end

function DeliveryService:getOriginalItemPrice(buyVehicleData)
    local price = nil

    if buyVehicleData ~= nil then
        if g_currentMission ~= nil and g_currentMission.economyManager ~= nil and buyVehicleData.storeItem ~= nil then
            price = g_currentMission.economyManager:getBuyPrice(
                buyVehicleData.storeItem,
                buyVehicleData.configurations,
                buyVehicleData.saleItem
            )
        end

        if price == nil or price <= 0 then
            price = buyVehicleData.price
        end

        if (price == nil or price <= 0) and buyVehicleData.storeItem ~= nil then
            price = buyVehicleData.storeItem.price
        end
    end

    return math.max(0, math.floor(tonumber(price) or 0))
end

function DeliveryService:getVehicleDisplayName(vehicle)
    if vehicle == nil then
        return "unknown item"
    end

    if vehicle.getName ~= nil then
        local name = vehicle:getName()

        if name ~= nil and name ~= "" then
            return name
        end
    end

    if vehicle.configFileName ~= nil then
        local filename = tostring(vehicle.configFileName)
        local name = filename:match("([^/\\]+)%.xml$")

        if name ~= nil and name ~= "" then
            return name
        end
    end

    return "bought/leased item"
end

function DeliveryService:getCurrentGameTimeMs()
    if g_currentMission == nil or g_currentMission.environment == nil then
        return nil
    end

    local environment = g_currentMission.environment
    local day = environment.currentMonotonicDay or environment.currentDay or 0
    local dayTime = environment.dayTime or 0

    return (day * self.DAY_MS) + dayTime
end

function DeliveryService:formatGameDuration(ms)
    local totalMinutes = math.ceil((ms or 0) / (60 * 1000))

    if totalMinutes <= 1 then
        return "1 in-game minute"
    end

    if totalMinutes < 60 then
        return tostring(totalMinutes) .. " in-game minutes"
    end

    local hours = math.floor(totalMinutes / 60)
    local minutes = totalMinutes - (hours * 60)

    if minutes == 0 then
        if hours == 1 then
            return "1 in-game hour"
        end

        return tostring(hours) .. " in-game hours"
    end

    return tostring(hours) .. "h " .. tostring(minutes) .. "m"
end

function DeliveryService:formatMoney(amount)
    local value = math.floor(tonumber(amount) or 0)

    if g_i18n ~= nil and g_i18n.formatMoney ~= nil then
        return g_i18n:formatMoney(value, 0, true)
    end

    return tostring(value)
end

function DeliveryService:registerActionEvents()
    self:clearActionEvents()

    if PlayerInputComponent ~= nil then
        self:registerActionEventForContext(PlayerInputComponent.INPUT_CONTEXT_NAME)
    end

    if Vehicle ~= nil then
        self:registerActionEventForContext(Vehicle.INPUT_CONTEXT_NAME)
    end

    self:updateActionEventText()
end

function DeliveryService:registerActionEventForContext(contextName)
    if contextName == nil then
        return
    end

    g_inputBinding:beginActionEventsModification(contextName)

    local eventAdded, eventId = g_inputBinding:registerActionEvent(
        InputAction.DS_TEST,
        self,
        DeliveryService.onDeliveryAction,
        false,
        true,
        false,
        true,
        nil,
        true
    )

    if eventId ~= nil then
        self.actionEventIds[#self.actionEventIds + 1] = eventId
        g_inputBinding:setActionEventTextVisibility(eventId, true)
        g_inputBinding:setActionEventActive(eventId, true)

        if GS_PRIO_VERY_HIGH ~= nil then
            g_inputBinding:setActionEventTextPriority(eventId, GS_PRIO_VERY_HIGH)
        end

        print("DeliveryService input registered for " .. tostring(contextName))
    else
        print("DeliveryService input failed for " .. tostring(contextName))
    end

    g_inputBinding:endActionEventsModification()
end

function DeliveryService:updateActionEventText()
    local text = "Dealer Haulage Status"

    if self.currentShopChoice ~= nil or #self.pendingChoiceQueue > 0 then
        text = "Choose Dealer Haulage"
    elseif self.activeDelivery ~= nil then
        if self.activeDelivery.unauthorisedCargoVehicle ~= nil then
            text = "Unauthorised Cargo"
        elseif self.activeDelivery.stage == "loading" then
            text = "Haulage Kit Preparing"
        elseif self.activeDelivery.stage == "transport" then
            text = "Mark Haulage Complete"
        elseif self.activeDelivery.stage == "returning" then
            text = "Return For Next Job"
        elseif self.activeDelivery.stage == "delivered" then
            if #self.deliveryQueue > 0 then
                text = "Continue Or Recall"
            else
                text = "Recall Haulage Kit"
            end
        end
    elseif #self.deliveryQueue > 0 then
        text = "Dealer Haulage Queue"
    end

    for _, eventId in ipairs(self.actionEventIds) do
        g_inputBinding:setActionEventText(eventId, text)
        g_inputBinding:setActionEventTextVisibility(eventId, true)
        g_inputBinding:setActionEventActive(eventId, true)
    end
end

function DeliveryService:clearActionEvents()
    if PlayerInputComponent ~= nil then
        g_inputBinding:beginActionEventsModification(PlayerInputComponent.INPUT_CONTEXT_NAME)
        g_inputBinding:removeActionEventsByTarget(self)
        g_inputBinding:endActionEventsModification()
    end

    if Vehicle ~= nil then
        g_inputBinding:beginActionEventsModification(Vehicle.INPUT_CONTEXT_NAME)
        g_inputBinding:removeActionEventsByTarget(self)
        g_inputBinding:endActionEventsModification()
    end

    self.actionEventIds = {}
end

function DeliveryService:onDeliveryAction(actionName, inputValue)
    print("DeliveryService action pressed")

    if self.currentShopChoice ~= nil then
        self:showShopDeliveryPrompt()
        return
    end

    if #self.pendingChoiceQueue > 0 then
        self.currentShopChoice = table.remove(self.pendingChoiceQueue, 1)
        self.nextPromptTimer = nil
        self:showShopDeliveryPrompt()
        return
    end

    if self.activeDelivery == nil and #self.deliveryQueue > 0 then
        if self:showNearestQueuedCargoStatus() then
            return
        end

        self:showDeliveryQueueStatus()
        return
    end

    if self.activeDelivery == nil then
        self:notify("No dealer haulage contracts queued.", true)
        self:notify("Buy or lease machinery and choose haulage from the dealer prompt. Saved queues are not restored yet.")
        return
    end

    local serviceVehicleKind = self:getCurrentActiveServiceVehicleKind()

    if self.activeDelivery.unauthorisedCargoVehicle ~= nil then
        if serviceVehicleKind ~= nil then
            self:showServiceCabActionReminder(self:getServiceCabActionReminderMessage(self.activeDelivery, serviceVehicleKind))
            return
        end

        self:showUnauthorisedCargoFeePrompt(self.activeDelivery)
        return
    end

    if serviceVehicleKind ~= nil then
        self:showServiceCabActionReminder(self:getServiceCabActionReminderMessage(self.activeDelivery, serviceVehicleKind))
        return
    end

    if self.activeDelivery.stage == "loading" then
        self:notify("Haulage kit is still being prepared. Please wait.", true)
        return
    end

    if self.activeDelivery.stage == "transport" then
        self:markDelivered()
        return
    end

    if self.activeDelivery.stage == "returning" then
        self:tryStartNextQueuedDeliveryWithCurrentRig()
        return
    end

    if self.activeDelivery.stage == "delivered" then
        self:recallDeliveryRig()
        return
    end
end

function DeliveryService:startDeliveryService()
    local cargoVehicle = self:getSelectedCargoVehicle()

    if cargoVehicle == nil then
        self:notify("No bought/leased item found nearby.", true)
        print("DeliveryService start failed: no cargo vehicle found")
        return
    end

    if cargoVehicle.deliveryServiceDeclined then
        self:notify("Dealer haulage was declined for this bought/leased item. Collect it from the dealer yard yourself.", true)
        print("DeliveryService start blocked: delivery declined")
        return
    end

    if cargoVehicle.deliveryServiceBooked then
        self:notify("Dealer haulage is already booked for this bought/leased item.", true)
        print("DeliveryService start blocked: delivery already booked")
        return
    end

    self:startDeliveryServiceForVehicle(cargoVehicle, self.deliveryFee, "Manual Dealer Haulage", false)
end

function DeliveryService:getStoreItemForXmlFilename(xmlFilename)
    if g_storeManager == nil or xmlFilename == nil then
        return nil, xmlFilename
    end

    local candidates = {}
    local seen = {}

    local function addCandidate(filename)
        if filename == nil then
            return
        end

        filename = tostring(filename)
        if filename == "" then
            return
        end

        if seen[filename] == nil then
            table.insert(candidates, filename)
            seen[filename] = true
        end

        local lowerFilename = string.lower(filename)
        if seen[lowerFilename] == nil then
            table.insert(candidates, lowerFilename)
            seen[lowerFilename] = true
        end
    end

    addCandidate(xmlFilename)

    if Utils ~= nil and Utils.getFilename ~= nil then
        addCandidate(Utils.getFilename(xmlFilename))
    end

    local moddirPrefix = "$moddir$"
    if g_modsDirectory ~= nil and string.sub(xmlFilename, 1, string.len(moddirPrefix)) == moddirPrefix then
        addCandidate(g_modsDirectory .. string.sub(xmlFilename, string.len(moddirPrefix) + 1))
    end

    for _, filename in ipairs(candidates) do
        local storeItem = g_storeManager:getItemByXMLFilename(filename)
        if storeItem ~= nil then
            return storeItem, filename
        end
    end

    local function normalizeFilename(filename)
        return string.gsub(string.lower(tostring(filename or "")), "\\", "/")
    end

    local wantedSuffix = normalizeFilename(xmlFilename)
    if string.sub(wantedSuffix, 1, string.len(moddirPrefix)) == moddirPrefix then
        wantedSuffix = string.sub(wantedSuffix, string.len(moddirPrefix) + 1)
    end

    local wantedFilename = string.match(wantedSuffix, "([^/]+)$")

    if type(g_storeManager.items) == "table" then
        for _, storeItem in pairs(g_storeManager.items) do
            if type(storeItem) == "table" and storeItem.xmlFilename ~= nil then
                local storeXmlFilename = normalizeFilename(storeItem.xmlFilename)

                if storeXmlFilename == wantedSuffix
                    or string.sub(storeXmlFilename, -string.len(wantedSuffix)) == wantedSuffix
                    or (wantedFilename ~= nil and string.sub(storeXmlFilename, -string.len(wantedFilename)) == wantedFilename) then
                    return storeItem, storeItem.xmlFilename
                end
            end
        end
    end

    return nil, candidates[1] or xmlFilename
end

function DeliveryService:spawnServiceVehicle(kind, xmlFilename, x, z, rotY, shopPlacement)
    local farmId = self:getCurrentFarmId()

    if VehicleLoadingData ~= nil then
        local loadingData = VehicleLoadingData.new()

        local storeItem, resolvedFilename = self:getStoreItemForXmlFilename(xmlFilename)
        if storeItem ~= nil then
            loadingData:setStoreItem(storeItem)
        else
            loadingData:setFilename(resolvedFilename or xmlFilename)
        end

        if loadingData.storeItem == nil then
            self:notify("Could not prepare " .. self:getServiceVehicleDisplayName(kind) .. ". Check the required trailer mod is active.", true)
            print("DeliveryService spawn failed: no store item for " .. tostring(xmlFilename))
            return
        end

        loadingData:setOwnerFarmId(farmId)
        loadingData:setIsSaved(false)

        local placedAtShop = false

        if shopPlacement ~= nil and shopPlacement.storePlaces ~= nil and loadingData.setLoadingPlace ~= nil then
            placedAtShop = loadingData:setLoadingPlace(
                shopPlacement.storePlaces,
                shopPlacement.usedStorePlaces or {},
                1,
                false
            ) == true

            if placedAtShop then
                print("DeliveryService positioned " .. tostring(kind) .. " at shop loading area")
            else
                loadingData.validLocation = true
                print("DeliveryService shop loading area unavailable for " .. tostring(kind) .. ", using fallback placement")
            end
        end

        if not placedAtShop then
            loadingData:setPosition(x, nil, z, 0.2)
            loadingData:setRotation(0, rotY or 0, 0)
        end

        if VehiclePropertyState ~= nil and VehiclePropertyState.MISSION ~= nil then
            loadingData:setPropertyState(VehiclePropertyState.MISSION)
        elseif VehiclePropertyState ~= nil and VehiclePropertyState.NONE ~= nil then
            loadingData:setPropertyState(VehiclePropertyState.NONE)
        end

        loadingData:load(DeliveryService.onServiceVehicleLoaded, self, {kind = kind})
        return
    end

    self:notify("Dealer haulage tools are not available.", true)
    print("DeliveryService spawn failed: no VehicleLoadingData")
end

function DeliveryService:onServiceVehicleLoaded(loadedVehicles, loadingState, args)
    if self.activeDelivery == nil then
        return
    end

    local vehicle = nil

    if loadedVehicles ~= nil then
        for _, loadedVehicle in ipairs(loadedVehicles) do
            vehicle = loadedVehicle
            break
        end
    end

    if vehicle == nil then
        self:notify("Failed to prepare " .. self:getServiceVehicleDisplayName(args.kind) .. ".", true)
        print("DeliveryService failed to spawn " .. tostring(args.kind))
        return
    end

    vehicle.deliveryServiceVehicle = true
    vehicle.isVehicleSaved = false
    vehicle.showInVehicleOverview = false

    if vehicle.setIsTabbable ~= nil then
        vehicle:setIsTabbable(false)
    end

    if vehicle.deleteMapHotspot ~= nil then
        vehicle:deleteMapHotspot()
    end

    if args.kind == "truck" then
        self.activeDelivery.truck = vehicle
        print("DeliveryService truck spawned")
    elseif args.kind == "lowLoader" then
        self.activeDelivery.lowLoader = vehicle
        print("DeliveryService low loader spawned")
    elseif args.kind == "courtesyTractor" then
        vehicle.deliveryServiceCourtesyTractor = true
        self.activeDelivery.courtesyTractor = vehicle
        print("DeliveryService courtesy tractor spawned")
    end

    if self:getActiveDeliveryIsReady() then
        self:notifyActiveDeliveryReady()
    end
end

function DeliveryService:getServiceVehicleDisplayName(kind)
    if kind == "truck" then
        return "tractor unit"
    end

    if kind == "lowLoader" then
        return "low loader"
    end

    if kind == "courtesyTractor" then
        return "dealer courtesy tractor"
    end

    return tostring(kind or "haulage equipment")
end

function DeliveryService:getActiveDeliveryIsReady()
    local delivery = self.activeDelivery

    if delivery == nil then
        return false
    end

    if delivery.stage ~= "loading" then
        return false
    end

    if delivery.truck == nil or delivery.lowLoader == nil then
        return false
    end

    if delivery.needsCourtesyTractor and delivery.courtesyTractor == nil then
        return false
    end

    return true
end

function DeliveryService:updateServiceVehicleTabbable()
    local delivery = self.activeDelivery

    if delivery == nil then
        return
    end

    local tabbable = delivery.stage == "loading" or delivery.stage == "transport" or delivery.stage == "returning"

    self:setServiceVehicleTabbable(delivery.truck, tabbable)
    self:setServiceVehicleTabbable(delivery.lowLoader, tabbable)
    self:setServiceVehicleTabbable(delivery.courtesyTractor, tabbable)
end

function DeliveryService:updateLowLoaderExtensionSafety(dt)
    local delivery = self.activeDelivery

    if delivery == nil or delivery.lowLoader == nil or delivery.lowLoader.isDeleted then
        return
    end

    if delivery.stage ~= "transport" and delivery.stage ~= "returning" and delivery.stage ~= "delivered" then
        return
    end

    delivery.lowLoaderSafetyState = delivery.lowLoaderSafetyState or {
        checkTimer = 0,
        notifyCooldown = 0,
        readings = {}
    }

    local state = delivery.lowLoaderSafetyState
    local deltaTime = dt or 0

    state.checkTimer = (state.checkTimer or 0) - deltaTime
    state.notifyCooldown = math.max((state.notifyCooldown or 0) - deltaTime, 0)

    if state.checkTimer > 0 then
        return
    end

    state.checkTimer = self.lowLoaderSafetyCheckInterval

    for _, animation in ipairs(self.lowLoaderSafetyAnimations) do
        local currentTime = self:getLowLoaderAnimationTime(delivery.lowLoader, animation.animationName)

        if currentTime ~= nil then
            self:updateLowLoaderSafetyAnimationState(state, animation, currentTime)
        end
    end
end

function DeliveryService:updateLowLoaderSafetyAnimationState(state, animation, currentTime)
    local reading = state.readings[animation.key]

    if reading == nil then
        state.readings[animation.key] = {
            lastTime = currentTime,
            moving = false,
            stableMs = 0
        }
        return
    end

    local difference = math.abs(currentTime - (reading.lastTime or currentTime))

    if difference > self.lowLoaderSafetyMoveThreshold then
        if not reading.moving and (state.notifyCooldown or 0) <= 0 then
            self:notifyLowLoaderSafetyTrigger(animation.label, currentTime, reading.lastTime)
            state.notifyCooldown = self.lowLoaderSafetyNotifyCooldown
        end

        reading.moving = true
        reading.stableMs = 0
    else
        reading.stableMs = (reading.stableMs or 0) + (self.lowLoaderSafetyCheckInterval or 250)

        if reading.stableMs >= self.lowLoaderSafetyStableMs then
            reading.moving = false
        end
    end

    reading.lastTime = currentTime
end

function DeliveryService:notifyLowLoaderSafetyTrigger(label, currentTime, previousTime)
    local actionText = "changed"

    if currentTime ~= nil and previousTime ~= nil then
        if currentTime > previousTime then
            actionText = "extended"
        elseif currentTime < previousTime then
            actionText = "retracted"
        end
    end

    self:notify("H&S check: low loader " .. tostring(label or "extension") .. " " .. actionText .. ". Watch overhang and return to road-safe size before unloading or recall.", true)
end

function DeliveryService:updateUnauthorisedCargoLock(dt)
    local delivery = self.activeDelivery

    if delivery == nil or delivery.lowLoader == nil or delivery.lowLoader.isDeleted then
        return
    end

    if delivery.stage ~= "transport" and delivery.stage ~= "returning" and delivery.stage ~= "delivered" then
        return
    end

    delivery.unauthorisedCargoCheckTimer = (delivery.unauthorisedCargoCheckTimer or 0) - (dt or 0)

    if delivery.unauthorisedCargoCheckTimer > 0 then
        self:applyUnauthorisedCargoServiceLock(delivery)
        return
    end

    delivery.unauthorisedCargoCheckTimer = self.unauthorisedCargoCheckInterval

    local previousUnauthorisedVehicle = delivery.unauthorisedCargoVehicle
    local unauthorisedVehicle = self:getUnauthorisedCargoOnLowLoader(delivery)
    delivery.unauthorisedCargoVehicle = unauthorisedVehicle
    delivery.unauthorisedCargoName = self:getVehicleDisplayName(unauthorisedVehicle)

    if previousUnauthorisedVehicle ~= unauthorisedVehicle then
        self:updateActionEventText()
    end

    if unauthorisedVehicle ~= nil then
        self:applyUnauthorisedCargoServiceLock(delivery)
        self:showInCabUnauthorisedCargoReminder(delivery, dt)

        if not delivery.unauthorisedCargoNotified then
            delivery.unauthorisedCargoNotified = true
            self:notify("Unauthorised cargo detected on the haulage kit.", true)
            self:notify("Remove it or press Dealer Haulage nearby to pay an ad-hoc haulage fee.")
        end
    else
        delivery.unauthorisedCargoNotified = false
        self:clearUnauthorisedCargoServiceLock(delivery)
    end
end

function DeliveryService:showInCabUnauthorisedCargoReminder(delivery, dt)
    if delivery == nil or not self:getIsPlayerInActiveServiceVehicle() then
        return
    end

    delivery.unauthorisedCargoCabReminderTimer = (delivery.unauthorisedCargoCabReminderTimer or 0) - (dt or 0)

    if delivery.unauthorisedCargoCabReminderTimer > 0 then
        return
    end

    delivery.unauthorisedCargoCabReminderTimer = 5000
    self:notify("Unauthorised cargo detected. Stop and step out to pay the ad-hoc fee or unload it.", true)
end

function DeliveryService:updateServiceCabReminder(dt)
    local delivery = self.activeDelivery

    if delivery == nil then
        return
    end

    if delivery.unauthorisedCargoVehicle ~= nil then
        self:resetServiceCabReminderState(delivery)
        return
    end

    if not self:getIsPlayerInActiveDeliveryUnit() then
        self:resetServiceCabReminderState(delivery)
        return
    end

    if not self:getIsActiveServiceVehicleStoppedForReminder() then
        self:resetServiceCabReminderState(delivery)
        return
    end

    local message = self:getServiceCabReminderMessage(delivery)

    if message == nil then
        self:resetServiceCabReminderState(delivery)
        return
    end

    delivery.serviceCabStationaryTimer = (delivery.serviceCabStationaryTimer or 0) + (dt or 0)

    if delivery.serviceCabStationaryTimer < self.serviceCabReminderStationaryDelay then
        return
    end

    delivery.serviceCabReminderTimer = (delivery.serviceCabReminderTimer or 0) - (dt or 0)

    if delivery.serviceCabReminderTimer > 0 then
        return
    end

    delivery.serviceCabReminderTimer = self.serviceCabReminderInterval
    self:notify(message, true)
end

function DeliveryService:resetServiceCabReminderState(delivery)
    if delivery == nil then
        return
    end

    delivery.serviceCabReminderTimer = nil
    delivery.serviceCabStationaryTimer = nil
end

function DeliveryService:getServiceCabReminderMessage(delivery)
    if delivery == nil then
        return nil
    end

    local stage = delivery.stage

    if stage == "loading" then
        return "Step out of the haulage kit to view Dealer Haulage status."
    end

    if stage == "transport" then
        local lowLoaderClear = self:getIsLowLoaderClear(delivery)

        if lowLoaderClear then
            return "Step out of the haulage kit to mark haulage complete once unloaded."
        end

        return "Step out of the haulage kit to view Dealer Haulage status."
    end

    if stage == "returning" then
        return "Step out near the dealer yard item to continue the next haulage manifest."
    end

    if stage == "delivered" then
        if #self.deliveryQueue > 0 then
            return "Step out of the haulage kit to continue the next manifest or recall."
        end

        return "Step out of the haulage kit to recall it."
    end

    return nil
end

function DeliveryService:updateServiceCabInputReminder(dt)
    self.serviceCabInputReminderTimer = math.max((self.serviceCabInputReminderTimer or 0) - (dt or 0), 0)

    if not self:getIsDefaultDealerHaulageKeyDown() then
        self.serviceCabInputDown = false
        return
    end

    if self.serviceCabInputDown then
        return
    end

    self.serviceCabInputDown = true

    local delivery = self.activeDelivery

    local serviceVehicleKind = self:getCurrentActiveServiceVehicleKind()

    if delivery == nil or serviceVehicleKind == nil then
        return
    end

    self:showServiceCabActionReminder(self:getServiceCabActionReminderMessage(delivery, serviceVehicleKind))
end

function DeliveryService:showServiceCabActionReminder(message)
    if message == nil or (self.serviceCabInputReminderTimer or 0) > 0 then
        return
    end

    self.serviceCabInputReminderTimer = self.serviceCabInputReminderCooldown
    self:notify(message, true)
end

function DeliveryService:getServiceCabActionReminderMessage(delivery, serviceVehicleKind)
    if delivery ~= nil and delivery.unauthorisedCargoVehicle ~= nil then
        return "Unauthorised cargo on the low loader. Stop, step out, then pay the ad-hoc fee or unload it."
    end

    if serviceVehicleKind == "courtesyTractor" then
        return "Step out of the courtesy tractor to use Dealer Haulage controls."
    end

    if not self:getIsActiveServiceVehicleStoppedForReminder() then
        return "Stop the haulage kit and step out to use Dealer Haulage controls."
    end

    return "Step out of the haulage kit to use Dealer Haulage information or recall controls."
end

function DeliveryService:getIsActiveServiceVehicleStoppedForReminder()
    local speedKph = self:getCurrentServiceVehicleSpeedKph()

    if speedKph == nil then
        return true
    end

    return speedKph <= self.serviceCabReminderStationarySpeedKph
end

function DeliveryService:getCurrentServiceVehicleSpeedKph()
    local currentVehicle = self:getCurrentVehicle()

    if currentVehicle == nil then
        return nil
    end

    local rootVehicle = currentVehicle.rootVehicle or currentVehicle
    local speedKph = self:getVehicleSpeedKph(currentVehicle)

    if speedKph ~= nil then
        return speedKph
    end

    if rootVehicle ~= currentVehicle then
        return self:getVehicleSpeedKph(rootVehicle)
    end

    return nil
end

function DeliveryService:getVehicleSpeedKph(vehicle)
    if vehicle == nil then
        return nil
    end

    if vehicle.getLastSpeed ~= nil then
        local ok, speed = pcall(vehicle.getLastSpeed, vehicle, true)

        if ok and type(speed) == "number" then
            return math.abs(speed)
        end
    end

    if type(vehicle.lastSpeed) == "number" then
        return math.abs(vehicle.lastSpeed * 3600)
    end

    if type(vehicle.lastSpeedReal) == "number" then
        return math.abs(vehicle.lastSpeedReal * 3600)
    end

    return nil
end

function DeliveryService:getIsDefaultDealerHaulageKeyDown()
    if self:getIsInputActionPressed("DS_TEST") then
        return true
    end

    local altPressed = self:getIsAnyInputKeyPressed({
        "KEY_lalt",
        "KEY_LALT",
        "KEY_ralt",
        "KEY_RALT"
    })

    if not altPressed then
        return false
    end

    return self:getIsAnyInputKeyPressed({
        "KEY_j",
        "KEY_J"
    })
end

function DeliveryService:getIsInputActionPressed(actionName)
    if g_inputBinding == nil or InputAction == nil or actionName == nil then
        return false
    end

    local action = InputAction[actionName] or actionName
    local methods = {
        "getDigitalInput",
        "getInputActionValue",
        "getActionValue",
        "getInputValue"
    }

    for _, methodName in ipairs(methods) do
        local method = g_inputBinding[methodName]

        if type(method) == "function" then
            local ok, value = pcall(method, g_inputBinding, action)

            if ok and (value == true or (type(value) == "number" and value > 0.5)) then
                return true
            end
        end
    end

    return false
end

function DeliveryService:getIsAnyInputKeyPressed(keyNames)
    for _, keyName in ipairs(keyNames or {}) do
        if self:getIsInputKeyPressed(keyName) then
            return true
        end
    end

    return false
end

function DeliveryService:getIsInputKeyPressed(keyName)
    if Input == nil or Input.isKeyPressed == nil or keyName == nil then
        return false
    end

    local key = Input[keyName]

    if key == nil then
        return false
    end

    local ok, pressed = pcall(Input.isKeyPressed, key)

    if ok and (pressed == true or (type(pressed) == "number" and pressed > 0.5)) then
        return true
    end

    ok, pressed = pcall(Input.isKeyPressed, Input, key)

    return ok and (pressed == true or (type(pressed) == "number" and pressed > 0.5))
end

function DeliveryService:applyUnauthorisedCargoServiceLock(delivery)
    if delivery == nil or delivery.unauthorisedCargoVehicle == nil then
        return
    end

    self:setDeliveryRigUnauthorisedCargoLock(delivery, true)
    self:holdDeliveryRigForUnauthorisedCargo(delivery)
end

function DeliveryService:clearUnauthorisedCargoServiceLock(delivery)
    if delivery == nil then
        return
    end

    self:setDeliveryRigUnauthorisedCargoLock(delivery, false)
end

function DeliveryService:setDeliveryRigUnauthorisedCargoLock(delivery, locked)
    if delivery == nil then
        return
    end

    self:setServiceVehicleUnauthorisedCargoLock(delivery.truck, locked)
    self:setServiceVehicleUnauthorisedCargoLock(delivery.lowLoader, locked)

    local rootVehicle = self:getDeliveryRigRootVehicle(delivery)

    if rootVehicle ~= nil then
        self:setServiceVehicleUnauthorisedCargoLock(rootVehicle, locked)

        for _, childVehicle in ipairs(rootVehicle.childVehicles or {}) do
            self:setServiceVehicleUnauthorisedCargoLock(childVehicle, locked)
        end
    end
end

function DeliveryService:holdDeliveryRigForUnauthorisedCargo(delivery)
    if delivery == nil then
        return
    end

    self:holdServiceVehicleForUnauthorisedCargo(delivery.truck)
    self:holdServiceVehicleForUnauthorisedCargo(delivery.lowLoader)

    local rootVehicle = self:getDeliveryRigRootVehicle(delivery)

    if rootVehicle ~= nil then
        self:holdServiceVehicleForUnauthorisedCargo(rootVehicle)

        for _, childVehicle in ipairs(rootVehicle.childVehicles or {}) do
            self:holdServiceVehicleForUnauthorisedCargo(childVehicle)
        end
    end
end

function DeliveryService:getDeliveryRigRootVehicle(delivery)
    if delivery == nil then
        return nil
    end

    if delivery.truck ~= nil then
        return delivery.truck.rootVehicle or delivery.truck
    end

    if delivery.lowLoader ~= nil then
        return delivery.lowLoader.rootVehicle or delivery.lowLoader
    end

    return nil
end

function DeliveryService:holdServiceVehicleForUnauthorisedCargo(vehicle)
    if vehicle == nil or vehicle.isDeleted then
        return
    end

    self:forceStopVehicleMotor(vehicle)

    if vehicle.setCruiseControlState ~= nil and Drivable ~= nil and Drivable.CRUISECONTROL_STATE_OFF ~= nil then
        vehicle:setCruiseControlState(Drivable.CRUISECONTROL_STATE_OFF, true)
    end

    if vehicle.setTargetSpeedAndDirection ~= nil then
        pcall(vehicle.setTargetSpeedAndDirection, vehicle, 0, 1)
        pcall(vehicle.setTargetSpeedAndDirection, vehicle, 0, -1)
    end

    if vehicle.setAccelerationPedalInput ~= nil then
        vehicle:setAccelerationPedalInput(0)
    end

    if vehicle.setBrakePedalInput ~= nil then
        vehicle:setBrakePedalInput(1)
    end

    if vehicle.brakeToStop ~= nil then
        vehicle:brakeToStop()
    end

    if vehicle.setSteeringInput ~= nil then
        pcall(vehicle.setSteeringInput, vehicle, 0, false)
    end

    self:settleVehiclePhysics(vehicle)
end

function DeliveryService:setServiceVehicleUnauthorisedCargoLock(vehicle, locked)
    if vehicle == nil or vehicle.isDeleted then
        return
    end

    vehicle.deliveryServiceUnauthorisedCargoBlocked = locked == true

    local rootVehicle = vehicle.rootVehicle or vehicle

    if rootVehicle ~= nil then
        rootVehicle.deliveryServiceUnauthorisedCargoBlocked = locked == true
    end

    if rootVehicle ~= nil and rootVehicle.registerPlayerVehicleControlAllowedFunction ~= nil then
        rootVehicle:registerPlayerVehicleControlAllowedFunction(vehicle, DeliveryService.serviceVehicleControlAllowed)
        rootVehicle:registerPlayerVehicleControlAllowedFunction(rootVehicle, DeliveryService.serviceVehicleControlAllowed)
    end
end

function DeliveryService.serviceVehicleControlAllowed(vehicle)
    if vehicle ~= nil and vehicle.deliveryServiceUnauthorisedCargoBlocked then
        return false, "Unauthorised cargo on low loader. Remove it or pay the ad-hoc haulage fee."
    end

    return true, nil
end

function DeliveryService:getLowLoaderAnimationTime(lowLoader, animationName)
    if lowLoader == nil or animationName == nil then
        return nil
    end

    if lowLoader.getAnimationTime ~= nil then
        local ok, value = pcall(lowLoader.getAnimationTime, lowLoader, animationName)

        if ok and type(value) == "number" then
            return value
        end
    end

    return self:getLowLoaderAnimationTimeFromSpecs(lowLoader, animationName)
end

function DeliveryService:getLowLoaderAnimationTimeFromSpecs(lowLoader, animationName)
    local animatedSpec = lowLoader.spec_animatedVehicle

    if animatedSpec ~= nil and animatedSpec.animations ~= nil then
        local directAnimation = animatedSpec.animations[animationName]
        local directTime = self:getAnimationTableTime(directAnimation)

        if directTime ~= nil then
            return directTime
        end

        for _, animation in pairs(animatedSpec.animations) do
            if type(animation) == "table" and (animation.name == animationName or animation.animationName == animationName) then
                local time = self:getAnimationTableTime(animation)

                if time ~= nil then
                    return time
                end
            end
        end
    end

    local cylinderedSpec = lowLoader.spec_cylindered

    if cylinderedSpec ~= nil and cylinderedSpec.movingTools ~= nil then
        for _, movingTool in pairs(cylinderedSpec.movingTools) do
            if type(movingTool) == "table" and movingTool.animationName == animationName then
                local time = self:getAnimationTableTime(movingTool)

                if time ~= nil then
                    return time
                end
            end
        end
    end

    return nil
end

function DeliveryService:getAnimationTableTime(animation)
    if type(animation) ~= "table" then
        return nil
    end

    local fields = {
        "currentTime",
        "animTime",
        "animationTime",
        "time"
    }

    for _, fieldName in ipairs(fields) do
        local value = animation[fieldName]

        if type(value) == "number" then
            return value
        end
    end

    return nil
end

function DeliveryService:setServiceVehicleTabbable(vehicle, tabbable)
    if vehicle == nil or vehicle.isDeleted or vehicle.setIsTabbable == nil then
        return
    end

    if vehicle.deliveryServiceCurrentTabbable == tabbable then
        return
    end

    vehicle:setIsTabbable(tabbable)
    vehicle.deliveryServiceCurrentTabbable = tabbable
end

function DeliveryService:getIsPlayerInActiveServiceVehicle()
    return self:getCurrentActiveServiceVehicleKind() ~= nil
end

function DeliveryService:getIsPlayerInActiveDeliveryUnit()
    return self:getCurrentActiveServiceVehicleKind() == "deliveryUnit"
end

function DeliveryService:getCurrentActiveServiceVehicleKind()
    local delivery = self.activeDelivery

    if delivery == nil then
        return nil
    end

    local currentVehicle = self:getCurrentVehicle()

    if currentVehicle == nil then
        return nil
    end

    if self:getIsSameVehicleOrRoot(currentVehicle, delivery.truck)
        or self:getIsSameVehicleOrRoot(currentVehicle, delivery.lowLoader) then
        return "deliveryUnit"
    end

    if self:getIsSameVehicleOrRoot(currentVehicle, delivery.courtesyTractor) then
        return "courtesyTractor"
    end

    return nil
end

function DeliveryService:notifyActiveDeliveryReady()
    local delivery = self.activeDelivery

    if delivery == nil or delivery.readyNotified then
        return
    end

    delivery.stage = "transport"
    delivery.readyNotified = true
    self:updateActionEventText()
    self:updateServiceVehicleTabbable()

    local count = 1

    if delivery.cargoVehicles ~= nil then
        count = #delivery.cargoVehicles
    end

    if count > 1 then
        self:notify("Haulage manifest ready: " .. tostring(count) .. " items.")
    else
        self:notify("Haulage lorry and low loader ready.")
    end

    if delivery.needsCourtesyTractor then
        self:notify("Dealer courtesy tractor provided for loading.")
    end

    self:notify("Load the released bought/leased item or items, haul them to your chosen point, unload, then press Dealer Haulage.")
    print("DeliveryService delivery rig ready")
end

function DeliveryService:markDelivered()
    if self.activeDelivery == nil then
        return
    end

    local lowLoaderClear, blockingItemName, blockingReason = self:getIsLowLoaderClear(self.activeDelivery)

    if not lowLoaderClear then
        self:notify("Unload " .. tostring(blockingItemName or "the machinery") .. " from the low loader before marking haulage complete.", true)

        if blockingReason == "nonManifest" then
            self:showUnauthorisedCargoFeePrompt(self.activeDelivery)
        else
            self:notify("Move the manifest item clear of the trailer, then press Dealer Haulage again.")
        end

        return
    end

    local readyIndex = self:getReadyQueuedDeliveryIndex()

    if readyIndex ~= nil then
        self.activeDelivery.stage = "delivered"
        self:updateActionEventText()
        self:updateServiceVehicleTabbable()

        self:notify("Haulage marked complete.")
        self:notify("Remaining manifest is ready. Choose whether to continue the manifest or recall the haulage kit.")

        if OptionDialog ~= nil and OptionDialog.show ~= nil then
            self:showRecallConfirmation()
        end

        print("DeliveryService marked delivered with queued manifest choice")
        return
    end

    self.activeDelivery.stage = "delivered"
    self:updateActionEventText()
    self:updateServiceVehicleTabbable()

    self:notify("Haulage marked complete.")

    if #self.deliveryQueue > 0 then
        self:notify("No queued haulage contract is ready yet. You can recall the lorry and low loader or wait for the next dealer yard job.")
    else
        self:notify("Press Dealer Haulage again near the haulage kit to recall the lorry and low loader.")
    end

    print("DeliveryService marked delivered")
end

function DeliveryService:recallDeliveryRig(skipConfirmation)
    local delivery = self.activeDelivery

    if delivery == nil then
        return
    end

    if self:getIsVehicleEntered(delivery.truck) or self:getIsVehicleEntered(delivery.lowLoader) or self:getIsVehicleEntered(delivery.courtesyTractor) then
        self:notify("Exit the haulage kit before recalling it.", true)
        print("DeliveryService recall blocked: player inside delivery equipment")
        return
    end

    if not self:getIsPlayerNearHaulageKit(delivery) then
        if self:getIsPlayerNearActiveCargoItem(delivery) or self:getIsPlayerNearQueuedCargoItem() then
            self:showActiveDeliveryStatus()
        end

        self:notify("Stand near the tractor unit or low loader to recall the haulage kit.", true)
        self:notify("Press Dealer Haulage near bought/leased items for manifest information and ETAs.")
        return
    end

    local isRoadSafe, unsafePart = self:getIsLowLoaderRoadSafe(delivery.lowLoader)

    if not isRoadSafe then
        self:notify("Retract the low loader " .. tostring(unsafePart or "extension") .. " before recalling the haulage kit.", true)
        self:notify("Return the trailer to road-safe length and width, then try recall again.")
        return
    end

    local lowLoaderClear, blockingItemName, blockingReason = self:getIsLowLoaderClear(delivery)
    if not lowLoaderClear then
        if blockingReason == "nonManifest" then
            self:notify(tostring(blockingItemName or "Another machine") .. " is on the low loader but is not on this manifest.", true)
            self:showUnauthorisedCargoFeePrompt(delivery)
        else
            self:notify("The low loader still appears to be carrying " .. tostring(blockingItemName or "a bought/leased item") .. ".", true)
            self:notify("Unload the low loader and move the item clear before recalling the haulage kit.")
        end

        return
    end

    if not skipConfirmation and OptionDialog ~= nil and OptionDialog.show ~= nil then
        self:showRecallConfirmation()
        return
    end

    self:finishRecallDeliveryRig()
end

function DeliveryService:showRecallConfirmation()
    if self.recallPromptOpen then
        return
    end

    local hasRemainingManifest = #self.deliveryQueue > 0
    local nextManifestText = self:getNextQueuedManifestDialogText()
    local title = "Recall Haulage Kit"
    local text = "Low loader must be empty and back to road-safe length/width before recall."
    local options = {
        "Recall haulage kit",
        "Cancel"
    }

    if hasRemainingManifest then
        title = "Continue Or Recall"
        text = nextManifestText or "Remaining haulage manifests are queued. Continue with them, or recall the empty, road-safe haulage kit now."
        options = {
            "Continue next manifest",
            "Recall haulage kit",
            "Cancel"
        }
    end

    self.recallPromptOpen = true

    OptionDialog.show(
        function(index)
            DeliveryService.recallPromptOpen = false

            if hasRemainingManifest then
                if index == 1 then
                    DeliveryService:continueRemainingManifestFromRecallPrompt()
                elseif index == 2 then
                    DeliveryService:recallDeliveryRig(true)
                end
            elseif index == 1 then
                DeliveryService:recallDeliveryRig(true)
            end
        end,
        title,
        text,
        options
    )
end

function DeliveryService:continueRemainingManifestFromRecallPrompt()
    local delivery = self.activeDelivery

    if delivery == nil then
        return
    end

    if #self.deliveryQueue == 0 then
        self:notify("No remaining haulage manifests queued.", true)
        return
    end

    if delivery.stage ~= "returning" then
        delivery.stage = "returning"
        self:updateActionEventText()
        self:updateServiceVehicleTabbable()
    end

    local readyIndex = self:getReadyQueuedDeliveryIndex()

    if readyIndex ~= nil then
        self:tryStartNextQueuedDeliveryWithCurrentRig()
        return
    end

    self:showDeliveryQueueStatus()
    self:notify("Haulage kit kept for the remaining manifest. Return to the dealer yard and wait for the next release.")
end

function DeliveryService:finishRecallDeliveryRig()
    local delivery = self.activeDelivery

    if delivery == nil then
        return
    end

    local hadCourtesyTractor = delivery.courtesyTractor ~= nil and not delivery.courtesyTractor.isDeleted

    self:clearUnauthorisedCargoServiceLock(delivery)
    self:deleteServiceVehicle(delivery.courtesyTractor)
    self:deleteServiceVehicle(delivery.lowLoader)
    self:deleteServiceVehicle(delivery.truck)

    if hadCourtesyTractor then
        self:notify("Dealer courtesy tractor recalled.")
    end

    self:notify("Haulage kit recalled.")
    print("DeliveryService rig removed")
    self.activeDelivery = nil
    self:updateActionEventText()
    self:resetManifestSequenceIfIdle()
end

function DeliveryService:getIsPlayerNearHaulageKit(delivery)
    return self:getPlayerDistanceToHaulageKit(delivery) <= self.recallDistance
end

function DeliveryService:getPlayerDistanceToHaulageKit(delivery)
    if delivery == nil then
        return math.huge
    end

    local bestDistance = math.huge
    local truckDistance = self:getPlayerDistanceToVehicle(delivery.truck)
    local lowLoaderDistance = self:getPlayerDistanceToVehicle(delivery.lowLoader)

    if truckDistance ~= nil then
        bestDistance = math.min(bestDistance, truckDistance)
    end

    if lowLoaderDistance ~= nil then
        bestDistance = math.min(bestDistance, lowLoaderDistance)
    end

    return bestDistance
end

function DeliveryService:getPlayerDistanceToVehicle(vehicle)
    if vehicle == nil or vehicle.rootNode == nil then
        return nil
    end

    local px, py, pz = self:getPlayerPosition()

    if px == nil then
        return nil
    end

    local vx, vy, vz = getWorldTranslation(vehicle.rootNode)

    return self:getDistance(px, pz, vx, vz)
end

function DeliveryService:getIsPlayerNearActiveCargoItem(delivery)
    if delivery == nil then
        return false
    end

    for _, cargoVehicle in ipairs(delivery.cargoVehicles or {}) do
        local distance = self:getPlayerDistanceToVehicle(cargoVehicle)

        if distance ~= nil and distance <= 30 then
            return true
        end
    end

    return false
end

function DeliveryService:getIsPlayerNearQueuedCargoItem()
    for _, queuedDelivery in ipairs(self.deliveryQueue or {}) do
        local distance = self:getPlayerDistanceToVehicle(queuedDelivery.cargoVehicle)

        if distance ~= nil and distance <= 30 then
            return true
        end
    end

    return false
end

function DeliveryService:showActiveDeliveryStatus()
    if self.activeDelivery ~= nil then
        local stage = self.activeDelivery.stage or "active"
        local name = self.activeDelivery.deliveryName or "Dealer Haulage"

        if stage == "delivered" then
            self:notify(name .. " is marked complete. Haulage kit is awaiting recall.")
        elseif stage == "transport" then
            self:notify(name .. " is active. Unload the bought/leased item, then mark haulage complete.")
        elseif stage == "returning" then
            self:notify(name .. " is returning for the next ready manifest.")
        else
            self:notify(name .. " is preparing at the dealer yard.")
        end
    end

    if #self.deliveryQueue > 0 then
        if self:showNearestQueuedCargoStatus() then
            return
        end

        self:showDeliveryQueueStatus()
    end
end

function DeliveryService:getIsLowLoaderClear(delivery)
    if delivery == nil or delivery.lowLoader == nil or delivery.lowLoader.isDeleted then
        return true, nil
    end

    for _, vehicle in ipairs(delivery.cargoVehicles or {}) do
        if vehicle ~= nil and not vehicle.isDeleted then
            if self:getCargoAppearsOnLowLoader(vehicle, delivery.lowLoader) then
                return false, self:getVehicleDisplayName(vehicle), "manifest"
            end
        end
    end

    local unauthorisedVehicle = self:getUnauthorisedCargoOnLowLoader(delivery)

    if unauthorisedVehicle ~= nil then
        return false, self:getVehicleDisplayName(unauthorisedVehicle), "nonManifest"
    end

    return true, nil
end

function DeliveryService:getUnauthorisedCargoOnLowLoader(delivery)
    if delivery == nil or delivery.lowLoader == nil or delivery.lowLoader.isDeleted then
        return nil
    end

    for _, vehicle in ipairs(self:getVehicleList()) do
        if vehicle ~= nil
            and not vehicle.isDeleted
            and not vehicle.deliveryServiceVehicle
            and self:getIsDeliverableVehicle(vehicle)
            and self:getIsPlayerOwnedOrLeasedVehicle(vehicle)
            and self:getIsVehicleVisibleInOverview(vehicle)
            and not self:getIsVehicleInManifest(vehicle, delivery)
            and not self:getIsSameVehicleOrRoot(vehicle, delivery.truck)
            and not self:getIsSameVehicleOrRoot(vehicle, delivery.lowLoader)
            and not self:getIsSameVehicleOrRoot(vehicle, delivery.courtesyTractor) then
            if self:getCargoAppearsOnLowLoader(vehicle, delivery.lowLoader) then
                return vehicle
            end
        end
    end

    return nil
end

function DeliveryService:getIsVehicleVisibleInOverview(vehicle)
    if vehicle == nil then
        return false
    end

    if vehicle.getShowInVehiclesOverview ~= nil then
        local ok, visible = pcall(vehicle.getShowInVehiclesOverview, vehicle)

        if ok then
            return visible == true
        end
    end

    if vehicle.showInVehicleOverview ~= nil then
        return vehicle.showInVehicleOverview == true
    end

    return false
end

function DeliveryService:getIsVehicleInManifest(vehicle, delivery)
    if vehicle == nil or delivery == nil then
        return false
    end

    for _, cargoVehicle in ipairs(delivery.cargoVehicles or {}) do
        if self:getIsSameVehicleOrRoot(vehicle, cargoVehicle) then
            return true
        end
    end

    return false
end

function DeliveryService:showUnauthorisedCargoFeePrompt(delivery)
    if delivery == nil then
        return
    end

    local vehicle = delivery.unauthorisedCargoVehicle or self:getUnauthorisedCargoOnLowLoader(delivery)

    if vehicle == nil then
        self:notify("Remove non-manifest cargo before completing or recalling the haulage kit.")
        return
    end

    delivery.unauthorisedCargoVehicle = vehicle
    delivery.unauthorisedCargoName = self:getVehicleDisplayName(vehicle)

    local fee = self:getUnauthorisedHaulageFee(vehicle)
    local vehicleName = self:getVehicleDisplayName(vehicle)

    if OptionDialog == nil or OptionDialog.show == nil then
        self:notify("Unauthorised cargo: " .. tostring(vehicleName) .. ". Remove it or pay " .. self:formatMoney(fee) .. ".", true)
        return
    end

    if delivery.unauthorisedCargoPromptOpen then
        return
    end

    delivery.unauthorisedCargoPromptOpen = true

    OptionDialog.show(
        function(index)
            local activeDelivery = DeliveryService.activeDelivery

            if activeDelivery ~= nil then
                activeDelivery.unauthorisedCargoPromptOpen = false
            end

            if index == 1 then
                DeliveryService:payUnauthorisedHaulageFee()
            end
        end,
        "Unauthorised Haulage",
        tostring(vehicleName) .. " is not on this manifest. Pay ad-hoc haulage fee " .. self:formatMoney(fee) .. " or remove it from the low loader.",
        {
            "Pay fee",
            "Remove cargo"
        }
    )
end

function DeliveryService:payUnauthorisedHaulageFee()
    local delivery = self.activeDelivery

    if delivery == nil then
        return
    end

    local vehicle = delivery.unauthorisedCargoVehicle or self:getUnauthorisedCargoOnLowLoader(delivery)

    if vehicle == nil or vehicle.isDeleted then
        self:notify("No unauthorised cargo found on the low loader.", true)
        self:clearUnauthorisedCargoServiceLock(delivery)
        return
    end

    local fee = self:getUnauthorisedHaulageFee(vehicle)
    self:chargeMoney(fee)

    delivery.cargoVehicles = delivery.cargoVehicles or {}

    if not self:getIsVehicleInManifest(vehicle, delivery) then
        table.insert(delivery.cargoVehicles, vehicle)
    end

    delivery.unauthorisedCargoVehicle = nil
    delivery.unauthorisedCargoName = nil
    delivery.unauthorisedCargoNotified = false
    self:clearUnauthorisedCargoServiceLock(delivery)
    self:updateActionEventText()

    self:notify("Ad-hoc haulage fee paid: " .. self:formatMoney(fee) .. ".")
    self:notify(tostring(self:getVehicleDisplayName(vehicle)) .. " added to the current haulage manifest.")
end

function DeliveryService:getUnauthorisedHaulageFee(vehicle)
    local price = self:getVehicleStorePrice(vehicle)
    local fee = math.floor((price * self.unauthorisedHaulageRate) + 0.5)

    return math.max(self.unauthorisedHaulageMinimumFee, fee)
end

function DeliveryService:getVehicleStorePrice(vehicle)
    local storeItem = self:getStoreItemFromVehicle(vehicle)

    if storeItem ~= nil and storeItem.price ~= nil then
        return math.max(0, math.floor(tonumber(storeItem.price) or 0))
    end

    if vehicle ~= nil then
        if vehicle.price ~= nil then
            return math.max(0, math.floor(tonumber(vehicle.price) or 0))
        end

        if vehicle.storeItem ~= nil and vehicle.storeItem.price ~= nil then
            return math.max(0, math.floor(tonumber(vehicle.storeItem.price) or 0))
        end
    end

    return 0
end

function DeliveryService:getIsLowLoaderRoadSafe(lowLoader)
    if lowLoader == nil or lowLoader.isDeleted then
        return true, nil
    end

    for _, animation in ipairs(self.lowLoaderSafetyAnimations) do
        local currentTime = self:getLowLoaderAnimationTime(lowLoader, animation.animationName)

        if currentTime ~= nil and currentTime > self.lowLoaderRoadSafeThreshold then
            return false, animation.label
        end
    end

    return true, nil
end

function DeliveryService:getCargoAppearsOnLowLoader(cargoVehicle, lowLoader, visited)
    if cargoVehicle == nil or cargoVehicle.rootNode == nil or lowLoader == nil or lowLoader.rootNode == nil then
        return false
    end

    visited = visited or {}

    if visited[cargoVehicle] then
        return false
    end

    visited[cargoVehicle] = true

    if self:getVehicleRootAppearsOnLowLoader(cargoVehicle, lowLoader) then
        return true
    end

    for _, childVehicle in ipairs(cargoVehicle.childVehicles or {}) do
        if childVehicle ~= cargoVehicle and self:getCargoAppearsOnLowLoader(childVehicle, lowLoader, visited) then
            return true
        end
    end

    return false
end

function DeliveryService:getVehicleRootAppearsOnLowLoader(vehicle, lowLoader)
    if vehicle == nil or vehicle.rootNode == nil then
        return false
    end

    return self:getVehiclePointAppearsOnLowLoader(vehicle.rootNode, lowLoader)
end

function DeliveryService:getVehiclePointAppearsOnLowLoader(node, lowLoader)
    if node == nil or lowLoader == nil or lowLoader.rootNode == nil then
        return false
    end

    local pointX, pointY, pointZ = getWorldTranslation(node)

    if worldToLocal ~= nil then
        local localX, localY, localZ = worldToLocal(lowLoader.rootNode, pointX, pointY, pointZ)
        local widthTime = self:getLowLoaderAnimationTime(lowLoader, "extensionAnim") or 0
        local lengthTime = self:getLowLoaderAnimationTime(lowLoader, "extensionAnim2") or 0
        local maxX = 2.4 + (widthTime * 1.2)
        local maxZ = 10.5 + (lengthTime * 6)

        if math.abs(localX) <= maxX and math.abs(localZ) <= maxZ and localY >= -2 and localY <= 5.5 then
            return true
        end

        return false
    end

    local lowLoaderX, lowLoaderY, lowLoaderZ = getWorldTranslation(lowLoader.rootNode)

    return self:getDistance(pointX, pointZ, lowLoaderX, lowLoaderZ) <= 6
end

function DeliveryService:getIsVehicleEntered(vehicle)
    if vehicle == nil then
        return false
    end

    if vehicle.getIsEnteredForInput ~= nil and vehicle:getIsEnteredForInput() then
        return true
    end

    if vehicle.getIsEntered ~= nil and vehicle:getIsEntered() then
        return true
    end

    return false
end

function DeliveryService:deleteServiceVehicle(vehicle)
    if vehicle == nil or vehicle.isDeleted then
        return
    end

    if vehicle.delete ~= nil then
        vehicle:delete()
    end
end

function DeliveryService:getSelectedCargoVehicle()
    local currentVehicle = self:getCurrentVehicle()

    if currentVehicle ~= nil and self:getIsDeliverableVehicle(currentVehicle) then
        print("DeliveryService selected current vehicle")
        return currentVehicle
    end

    local px, py, pz = self:getPlayerPosition()

    if px == nil then
        print("DeliveryService vehicle search failed: no player position")
        return nil
    end

    local vehicleList = self:getVehicleList()
    local nearestVehicle = nil
    local nearestDistance = 60
    local count = 0

    for _, vehicle in pairs(vehicleList) do
        count = count + 1

        if self:getIsDeliverableVehicle(vehicle) and vehicle.rootNode ~= nil then
            local x, y, z = getWorldTranslation(vehicle.rootNode)
            local distance = self:getDistance(px, pz, x, z)

            if distance < nearestDistance then
                nearestDistance = distance
                nearestVehicle = vehicle
            end
        end
    end

    print("DeliveryService vehicle search count: " .. tostring(count))

    if nearestVehicle ~= nil then
        print("DeliveryService selected nearest vehicle at " .. tostring(math.floor(nearestDistance)) .. " metres")
    else
        print("DeliveryService no vehicle found within search range")
    end

    return nearestVehicle
end

function DeliveryService:getVehicleList()
    if g_currentMission ~= nil then
        if g_currentMission.vehicleSystem ~= nil and g_currentMission.vehicleSystem.vehicles ~= nil then
            return g_currentMission.vehicleSystem.vehicles
        end

        if g_currentMission.vehicles ~= nil then
            return g_currentMission.vehicles
        end
    end

    return {}
end

function DeliveryService:getCurrentVehicle()
    if g_localPlayer ~= nil and g_localPlayer.getCurrentVehicle ~= nil then
        local vehicle = g_localPlayer:getCurrentVehicle()

        if vehicle ~= nil then
            if vehicle.getSelectedVehicle ~= nil then
                local selectedVehicle = vehicle:getSelectedVehicle()

                if selectedVehicle ~= nil then
                    return selectedVehicle
                end
            end

            return vehicle
        end
    end

    return nil
end

function DeliveryService:getPlayerPosition()
    if g_localPlayer ~= nil then
        if g_localPlayer.getPosition ~= nil then
            return g_localPlayer:getPosition()
        end

        if g_localPlayer.rootNode ~= nil and g_localPlayer.rootNode ~= 0 then
            return getWorldTranslation(g_localPlayer.rootNode)
        end
    end

    return nil, nil, nil
end

function DeliveryService:getVehiclePosition(vehicle)
    if vehicle == nil or vehicle.rootNode == nil then
        return nil, nil, nil, nil
    end

    local x, y, z = getWorldTranslation(vehicle.rootNode)
    local rx, ry, rz = getWorldRotation(vehicle.rootNode)

    return x, y, z, ry
end

function DeliveryService:getVehicleTransform(vehicle)
    if vehicle == nil or vehicle.rootNode == nil then
        return nil, nil, nil, nil, nil, nil
    end

    local x, y, z = getWorldTranslation(vehicle.rootNode)
    local rx, ry, rz = getWorldRotation(vehicle.rootNode)

    return x, y, z, rx, ry, rz
end

function DeliveryService:getOffsetPosition(x, z, rotY, forward, right)
    local sinY = math.sin(rotY or 0)
    local cosY = math.cos(rotY or 0)

    local offsetX = (sinY * forward) + (cosY * right)
    local offsetZ = (cosY * forward) - (sinY * right)

    return x + offsetX, z + offsetZ
end

function DeliveryService:getDistance(x1, z1, x2, z2)
    local dx = x1 - x2
    local dz = z1 - z2

    return math.sqrt((dx * dx) + (dz * dz))
end

function DeliveryService:chargeMoney(amount)
    local farmId = self:getCurrentFarmId()

    if farmId == nil then
        print("DeliveryService money skipped: no farm id")
        return
    end

    if g_currentMission ~= nil and g_currentMission.addMoney ~= nil then
        g_currentMission:addMoney(-amount, farmId, self:getMoneyType(), true, true)
        print("DeliveryService charged " .. tostring(amount))
    end
end

function DeliveryService:getCurrentFarmId()
    if g_currentMission ~= nil and g_currentMission.getFarmId ~= nil then
        return g_currentMission:getFarmId()
    end

    if g_localPlayer ~= nil and g_localPlayer.farmId ~= nil then
        return g_localPlayer.farmId
    end

    return 1
end

function DeliveryService:getMoneyType()
    if MoneyType ~= nil then
        return MoneyType.OTHER or MoneyType.AI or MoneyType.MISSIONS
    end

    return nil
end

function DeliveryService:notify(message, isError)
    print(message)

    if g_currentMission ~= nil and g_currentMission.addIngameNotification ~= nil and FSBaseMission ~= nil then
        local notificationType = FSBaseMission.INGAME_NOTIFICATION_OK

        if isError then
            notificationType = FSBaseMission.INGAME_NOTIFICATION_CRITICAL
        end

        g_currentMission:addIngameNotification(notificationType, message)
    end
end

addModEventListener(DeliveryService)



