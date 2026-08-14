#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"

controller_path = ARGV.fetch(0, "/usr/lib/lua/luci/controller/openclash.lua")
view_path = ARGV.fetch(1, "/usr/lib/lua/luci/view/openclash/oix_login.htm")
fragment_path = File.join(__dir__, "openclash-oixcloud-controller.lua")

controller = File.binread(controller_path)
start_marker = "local function fetch_oix_sub(token)"
end_marker = "function oix_logout(oldtoken)"
start_offset = controller.index(start_marker)
end_offset = start_offset && controller.index(end_marker, start_offset)
raise "OpenClash oixCloud controller markers changed" unless start_offset && end_offset

upstream_region = controller[start_offset...end_offset]
expected_sha256 = "6f6716cfb63ebd5dd4750668d472aa6182ecab415c2209393af71df0c9d6fc07"
actual_sha256 = Digest::SHA256.hexdigest(upstream_region)
unless actual_sha256 == expected_sha256
  raise "OpenClash oixCloud controller changed (#{actual_sha256}); review the compatibility patch"
end

replacement = File.binread(fragment_path).rstrip + "\n\n"
patched_controller = controller[0...start_offset] + replacement + controller[end_offset..]
raise "vulnerable oixCloud download command remains" if patched_controller.include?(
  'curl -sL -m 10 --retry 2 --user-agent "clash"'
)

controller_temporary = "#{controller_path}.patched"
File.binwrite(controller_temporary, patched_controller)
File.chmod(File.stat(controller_path).mode & 0o7777, controller_temporary)
File.rename(controller_temporary, controller_path)

view = File.binread(view_path)
error_handler = <<'JAVASCRIPT'.chomp
		var onLoginError = function(msg) {
			btns.forEach(function(b){ setBtnBusy(b, false); });
			OixMsg.show('<%:oixCloud Login Failed:%> ' + msg, 'error');
			self.rebuildCredentials();
		};
JAVASCRIPT
sync_handler = error_handler + <<'JAVASCRIPT'


		var onSyncError = function(msg) {
			btns.forEach(function(b){ setBtnBusy(b, false); });
			OixMsg.show('<%:oixCloud Login Successful%>, <%:subscription synchronization failed%>: ' + msg, 'error', 20000);
			self.loggedIn = true; self.showLoggedIn(); self.loadAccountInfo(); self.startPolling(); self.fetchParams();
		};
JAVASCRIPT
raise "oixCloud login error handler changed" unless view.scan(error_handler).length == 1
view = view.sub(error_handler, sync_handler)

parse_error = <<'JAVASCRIPT'.chomp
						} else if (obj.stage === 'error') {
							onLoginError(obj.result || '<%:oixCloud Login Failed%>');
JAVASCRIPT
parse_sync_error = <<'JAVASCRIPT'.chomp
						} else if (obj.stage === 'sync_error') {
							onSyncError(obj.result || '<%:subscription synchronization failed%>');
						} else if (obj.stage === 'error') {
							onLoginError(obj.result || '<%:oixCloud Login Failed%>');
JAVASCRIPT
raise "oixCloud stream parser changed" unless view.scan(parse_error).length == 1
view = view.sub(parse_error, parse_sync_error)

terminal_check = <<'JAVASCRIPT'.chomp
				} else if (xhr.responseText.indexOf('"stage":"done"') === -1 &&
				           xhr.responseText.indexOf('"stage":"error"') === -1) {
JAVASCRIPT
patched_terminal_check = <<'JAVASCRIPT'.chomp
				} else if (xhr.responseText.indexOf('"stage":"done"') === -1 &&
				           xhr.responseText.indexOf('"stage":"sync_error"') === -1 &&
				           xhr.responseText.indexOf('"stage":"error"') === -1) {
JAVASCRIPT
raise "oixCloud terminal response check changed" unless view.scan(terminal_check).length == 1
view = view.sub(terminal_check, patched_terminal_check)

view_temporary = "#{view_path}.patched"
File.binwrite(view_temporary, view)
File.chmod(File.stat(view_path).mode & 0o7777, view_temporary)
File.rename(view_temporary, view_path)

warn "[build] Applied oixCloud subscription synchronization compatibility patch"
