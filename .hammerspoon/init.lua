hs = hs

-- Function to set network location to "Home"
local function setNetworkLocation(locationName)
	local config = hs.network.configuration.open()
	local currentLocation = config:location()

	if currentLocation ~= locationName then
		local success = config:setLocation(locationName)
		if not success then
			hs.notify
				.new({
					title = "Hammerspoon",
					informativeText = "Failed to switch to location: " .. locationName,
				})
				:send()
		end
	end
end

-- Load and start the ReloadConfiguration Spoon
hs.loadSpoon("ReloadConfiguration")
spoon.ReloadConfiguration:start()

wifiWatcher = nil
homeSSID = "Telekom-GCh6tN"
lastSSID = hs.wifi.currentNetwork()

if hs.location.servicesEnabled() then
	hs.location.start()

	local location = hs.location.get()
	if not location then
		print("Unable to retrieve location information.")
	end
	hs.location.stop()
else
	print("Location services are not enabled.")
end

function ssidChangedCallback()
	newSSID = hs.wifi.currentNetwork()

	if newSSID == homeSSID and lastSSID ~= homeSSID then
		-- We just joined our home WiFi network
		setNetworkLocation("Home")
	elseif newSSID ~= homeSSID and lastSSID == homeSSID then
		-- We just departed our home WiFi network
		setNetworkLocation("Automatic")
	end

	lastSSID = newSSID
end

wifiWatcher = hs.wifi.watcher.new(ssidChangedCallback)
wifiWatcher:start()
print("Started wifiWatcher\n")
