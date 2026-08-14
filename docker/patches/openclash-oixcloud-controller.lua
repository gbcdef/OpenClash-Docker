local OIX_CONFIG_PATH = "/etc/openclash/config/oixCloud - smart.yaml"

local function sync_oix_config(subscription_url)
	if type(subscription_url) ~= "string" or not subscription_url:match("^https://") then
		return false, luci.i18n.translate("subscription URL must use HTTPS")
	end

	local command = "/usr/local/sbin/openclash-oix-sync " .. UTIL.shellquote(subscription_url)
	local output = (SYS.exec(command) or ""):gsub("[\r\n]+", " "):gsub("%s+$", "")
	if output:match("^OK%s+") and fs.access(OIX_CONFIG_PATH) then
		local config_stat = fs.stat(OIX_CONFIG_PATH)
		if config_stat and config_stat.size and config_stat.size > 0 then
			return true
		end
	end

	local message = output:match("^ERROR%s+(.+)")
	if not message or message == "" then
		message = luci.i18n.translate("subscription synchronization failed")
	end
	return false, message:sub(1, 256)
end

local function save_oix_subscription(subscription_url)
	local subscription_id
	uci:foreach("openclash", "config_subscribe", function(section)
		if section.name == "oixCloud - smart" then
			subscription_id = section['.name']
			return false
		end
	end)

	if not subscription_id then
		subscription_id = uci:add("openclash", "config_subscribe")
		uci:set("openclash", subscription_id, "name", "oixCloud - smart")
	end
	uci:set("openclash", subscription_id, "address", subscription_url)
	uci:set("openclash", "config", "config_path", OIX_CONFIG_PATH)
	uci:commit("openclash")
end

local function fetch_oix_sub(token)
	write_padded('{"stage":"fetching_sub","text":"' .. luci.i18n.translate("Fetching subscription...") .. '"}')
	local get_sub = table.concat({
		"curl -fsSL --connect-timeout 10 -m 30 --retry 2",
		"-H " .. UTIL.shellquote("Content-Type: application/json"),
		"-H " .. UTIL.shellquote("Authorization: Bearer " .. token),
		"-X POST",
		UTIL.shellquote("https://oix-api.dler.io/api/v1/managed/clash"),
		"2>/dev/null"
	}, " ")
	local raw_sub_info = SYS.exec(get_sub)
	local parse_ok, sub_info = pcall(json.parse, raw_sub_info or "")
	if not parse_ok or not sub_info or sub_info.ret ~= 200 then
		return false, luci.i18n.translate("invalid token"), false
	end

	local subscription_url = sub_info.openclash
	if type(subscription_url) ~= "string" or subscription_url == "" then
		return false, luci.i18n.translate("subscription address is missing"), true
	end

	write_padded('{"stage":"downloading_config","text":"' .. luci.i18n.translate("Downloading config...") .. '"}')
	local sync_ok, sync_error = sync_oix_config(subscription_url)
	if not sync_ok then
		return false, sync_error, true
	end

	save_oix_subscription(subscription_url)
	local core = coremetacv()
	if core ~= "0" and not string.match(core, "oix") then
		write_padded('{"stage":"downloading_core","text":"' .. luci.i18n.translate("Downloading core...") .. '"}')
		SYS.exec("/usr/share/openclash/openclash_core.sh Oix")
	else
		write_padded('{"stage":"restarting","text":"' .. luci.i18n.translate("Restarting...") .. '"}')
		SYS.call("/etc/init.d/openclash restart >/dev/null 2>&1 &")
	end
	return true, nil, true
end

local function save_oix_token(token)
	uci:set("openclash", "config", "oix_token", token)
	uci:commit("openclash")
end

function oix_login()
	HTTP.prepare_content("text/plain; charset=utf-8")
	local info, token
	local input_token = HTTP.formvalue("token")
	local email = fs.uci_get_config("config", "oix_email")
	local passwd = fs.uci_get_config("config", "oix_passwd")
	if input_token and input_token ~= "" then
		write_padded('{"stage":"saving_token","text":"' .. luci.i18n.translate("Saving token...") .. '"}')
		token = input_token
		local sync_ok, sync_error, authenticated = fetch_oix_sub(token)
		if authenticated then
			save_oix_token(token)
		end
		if sync_ok then
			write_padded('{"stage":"done","result":200}')
		elseif authenticated then
			write_padded('{"stage":"sync_error","result":' .. json.stringify(sync_error) .. '}')
		else
			write_padded('{"stage":"error","result":' .. json.stringify(sync_error or luci.i18n.translate("invalid token")) .. '}')
		end
		return
	end

	token = fs.uci_get_config("config", "oix_token")
	if not email or not passwd then
		uci:delete("openclash", "config", "oix_token")
		uci:commit("openclash")
		fs.unlink("/tmp/oix_checkin")
		fs.unlink("/tmp/oix_info")
		write_padded('{"stage":"error","result":' .. json.stringify(luci.i18n.translate("email or passwd is wrong")) .. '}')
		return
	end

	write_padded('{"stage":"logging_in","text":"' .. luci.i18n.translate("Logging in...") .. '"}')
	local login_payload = json.stringify({email = email, passwd = passwd, token_expire = "365"})
	local login_command = table.concat({
		"curl -fsSL --connect-timeout 10 -m 30 --retry 2",
		"-H " .. UTIL.shellquote("Content-Type: application/json"),
		"-H " .. UTIL.shellquote("User-Agent: OpenClash for oixCloud"),
		"-d " .. UTIL.shellquote(login_payload),
		"-X POST",
		UTIL.shellquote("https://oix-api.dler.io/api/v1/login"),
		"2>/dev/null"
	}, " ")
	local raw_info = SYS.exec(login_command)
	local parse_ok
	parse_ok, info = pcall(json.parse, raw_info or "")
	if parse_ok and info and info.ret == 200 and info.data and info.data.token then
		if token and token ~= "" then
			oix_logout(token)
		end
		token = info.data.token
		save_oix_token(token)
		local sync_ok, sync_error = fetch_oix_sub(token)
		if sync_ok then
			write_padded('{"stage":"done","result":200}')
		else
			write_padded('{"stage":"sync_error","result":' .. json.stringify(sync_error or luci.i18n.translate("subscription synchronization failed")) .. '}')
		end
	else
		uci:delete("openclash", "config", "oix_token")
		uci:commit("openclash")
		fs.unlink("/tmp/oix_checkin")
		fs.unlink("/tmp/oix_info")
		local result = parse_ok and info and info.msg or luci.i18n.translate("login failed")
		write_padded('{"stage":"error","result":' .. json.stringify(result) .. '}')
	end
end
