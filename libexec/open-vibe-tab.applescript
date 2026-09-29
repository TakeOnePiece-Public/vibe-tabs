-- Open one named project in tmux, with one pane per configured coding command.
-- Usage: vibe-tab [options] [session-name] /path/to/project [command ...]

on run argv
	set requestedLayout to "auto"
	set terminalProfile to ""
	set forceNewWindow to false
	set effectiveArgs to {}
	set argumentPosition to 1

	repeat while argumentPosition <= (count of argv)
		set currentArgument to item argumentPosition of argv
		if currentArgument is "--layout" then
			if argumentPosition + 1 > (count of argv) then error "--layout requires a value"
			set requestedLayout to item (argumentPosition + 1) of argv
			set argumentPosition to argumentPosition + 2
		else if currentArgument is "--profile" then
			if argumentPosition + 1 > (count of argv) then error "--profile requires a value"
			set terminalProfile to item (argumentPosition + 1) of argv
			set argumentPosition to argumentPosition + 2
		else if currentArgument is "--new-window" then
			set forceNewWindow to true
			set argumentPosition to argumentPosition + 1
		else
			set effectiveArgs to items argumentPosition thru -1 of argv
			exit repeat
		end if
	end repeat

	if (count of effectiveArgs) is 1 then
		openProject(item 1 of effectiveArgs, "", {}, requestedLayout, terminalProfile, forceNewWindow)
	else if (count of effectiveArgs) is 2 then
		openProject(item 2 of effectiveArgs, item 1 of effectiveArgs, {}, requestedLayout, terminalProfile, forceNewWindow)
	else if (count of effectiveArgs) > 2 then
		set paneSpecs to items 3 thru -1 of effectiveArgs
		openProject(item 2 of effectiveArgs, item 1 of effectiveArgs, paneSpecs, requestedLayout, terminalProfile, forceNewWindow)
	else
		error "Usage: vibe-tab [--layout layout] [--profile name] [--new-window] [session-name] /path/to/project [command ...]"
	end if
end run

on openProject(rawFolder, requestedName, configuredPanes, requestedLayout, terminalProfile, forceNewWindow)
	set homeFolder to my homeDirectory()
	set tmuxBin to my resolveExecutable("tmux", {"/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"})
	set projectFolder to my expandHomePath(rawFolder, homeFolder)
	my validateTerminalProfile(terminalProfile)

	set folderExists to true
	try
		do shell script "/bin/test -d " & quoted form of projectFolder
	on error
		set folderExists to false
	end try

	set canonicalFolder to ""
	if folderExists then
		set canonicalFolder to do shell script "/bin/zsh -c " & quoted form of ("cd " & quoted form of projectFolder & " && /bin/pwd -P")
		set projectName to do shell script "/usr/bin/basename " & quoted form of canonicalFolder
		if requestedName is "" then set requestedName to projectName
	else
		-- `vibe-tab name` with no such folder: treat the argument as a session
		-- name and attach if that session is already running.
		if requestedName is not "" then error "Project folder not found: " & projectFolder
		set requestedName to rawFolder
	end if

	set sessionName to my slugify(requestedName)
	if sessionName is "" then error "Session name must contain a letter or number"

	set paneSpecs to {}
	repeat with configuredPane in configuredPanes
		set paneSpec to my trimText(contents of configuredPane)
		if paneSpec is not "" then set end of paneSpecs to paneSpec
	end repeat
	if (count of paneSpecs) is 0 then set paneSpecs to {"claude", "codex"}
	set layoutName to my normalizeLayout(requestedLayout)

	set sessionExists to true
	try
		do shell script quoted form of tmuxBin & " has-session -t " & quoted form of ("=" & sessionName)
	on error
		set sessionExists to false
	end try

	if sessionExists is false and folderExists is false then
		error "'" & rawFolder & "' is not a folder, and no tmux session named '" & sessionName & "' is running. Usage: vibe-tab [session-name] /path/to/project [command ...]"
	end if

	if sessionExists is false then
		set paneCommands to {}
		set paneTitles to {}
		set codexRenamePositions to {}
		set panePosition to 0

		repeat with paneSpecRef in paneSpecs
			set panePosition to panePosition + 1
			set paneSpec to contents of paneSpecRef
			set paneConfig to my parsePaneSpec(paneSpec, homeFolder)
			set paneAgent to paneAgent of paneConfig
			set configuredCommand to paneCommand of paneConfig
			set configuredTitle to paneTitle of paneConfig
			set extraArgs to paneArgs of paneConfig
			set dangerousMode to paneDangerous of paneConfig
			set dangerousArgs to paneDangerousArgs of paneConfig

			if paneAgent is "claude" then
				set paneCommand to my claudeCommand(sessionName, homeFolder, dangerousMode, extraArgs, dangerousArgs)
				set paneTitle to sessionName & "-claude"
			else if paneAgent is "codex" then
				set codexResult to my codexCommand(sessionName, homeFolder, dangerousMode, extraArgs, dangerousArgs)
				set paneCommand to commandText of codexResult
				set paneTitle to sessionName & "-codex"
				if renameAfterLaunch of codexResult then set end of codexRenamePositions to panePosition
			else
				if paneAgent is not "" then
					set configuredCommand to paneAgent
					set effectiveArgs to my effectiveAgentArgs(paneAgent, dangerousMode, extraArgs, dangerousArgs)
					if effectiveArgs is not "" then set configuredCommand to configuredCommand & " " & effectiveArgs
				else
					set effectiveArgs to my effectiveAgentArgs("", dangerousMode, extraArgs, dangerousArgs)
					if effectiveArgs is not "" then set configuredCommand to configuredCommand & " " & effectiveArgs
				end if
				set paneCommand to "/bin/zsh -lc " & quoted form of (configuredCommand & "; exec /bin/zsh -l")
				set paneTitle to sessionName & "-" & my commandLabel(configuredCommand, panePosition)
			end if

			if configuredTitle is not "" then set paneTitle to sessionName & "-" & my slugify(configuredTitle)

			set end of paneCommands to paneCommand
			set end of paneTitles to paneTitle
		end repeat

		set paneIDs to {}
		set firstPaneCommand to item 1 of paneCommands
		set createCommand to quoted form of tmuxBin & " new-session -d -P -F " & quoted form of "#{pane_id}" & " -s " & quoted form of sessionName & " -c " & quoted form of canonicalFolder & " " & quoted form of firstPaneCommand
		set firstPaneID to do shell script createCommand
		set end of paneIDs to firstPaneID

		if (count of paneCommands) > 1 then
			repeat with panePosition from 2 to count of paneCommands
				set splitCommand to quoted form of tmuxBin & " split-window -h -P -F " & quoted form of "#{pane_id}" & " -t " & quoted form of sessionName & " -c " & quoted form of canonicalFolder & " " & quoted form of (item panePosition of paneCommands)
				set newPaneID to do shell script splitCommand
				set end of paneIDs to newPaneID
			end repeat
		end if

		if (count of paneCommands) > 1 then
			if layoutName is "auto" then
				if (count of paneCommands) is 2 then
					set effectiveLayout to "even-horizontal"
				else
					set effectiveLayout to "tiled"
				end if
			else
				set effectiveLayout to layoutName
			end if
			do shell script quoted form of tmuxBin & " select-layout -t " & quoted form of sessionName & " " & quoted form of effectiveLayout
		end if

		repeat with panePosition from 1 to count of paneIDs
			do shell script quoted form of tmuxBin & " select-pane -t " & quoted form of (item panePosition of paneIDs) & " -T " & quoted form of (item panePosition of paneTitles)
		end repeat
		do shell script quoted form of tmuxBin & " rename-window -t " & quoted form of sessionName & " " & quoted form of sessionName
		do shell script quoted form of tmuxBin & " select-pane -t " & quoted form of firstPaneID

		if (count of codexRenamePositions) > 0 then
			delay 3
			repeat with renamePositionRef in codexRenamePositions
				set codexPaneID to item (contents of renamePositionRef) of paneIDs
				do shell script quoted form of tmuxBin & " send-keys -t " & quoted form of codexPaneID & " -l " & quoted form of ("/rename " & sessionName)
				do shell script quoted form of tmuxBin & " send-keys -t " & quoted form of codexPaneID & " C-m"
				delay 0.5
				do shell script quoted form of tmuxBin & " send-keys -t " & quoted form of codexPaneID & " C-m"
			end repeat
		end if
	end if

	-- Keep tmux from overwriting Terminal's stable custom tab title.
	try
		do shell script quoted form of tmuxBin & " set-option -t " & quoted form of sessionName & " set-titles off"
	on error
	end try

	if my focusNamedTerminalTab(sessionName, terminalProfile) then return

	set attachedTTY to ""
	try
		set attachedTTY to do shell script quoted form of tmuxBin & " list-clients -t " & quoted form of sessionName & " -F " & quoted form of "#{client_tty}" & " 2>/dev/null | /usr/bin/head -n 1"
	on error
		set attachedTTY to ""
	end try

	if attachedTTY is not "" then
		if my nameAndFocusTerminalTab(attachedTTY, sessionName, terminalProfile) then return
		tell application "Terminal" to activate
		return
	end if

	set attachCommand to quoted form of tmuxBin & " attach-session -t " & quoted form of sessionName
	tell application "Terminal"
		activate
		if forceNewWindow or (count of windows) is 0 then
			set launchedTab to do script attachCommand
			my waitForTmuxClient(tmuxBin, sessionName)
			set custom title of launchedTab to sessionName
			set title displays custom title of launchedTab to true
			my applyTerminalProfile(launchedTab, terminalProfile)
		else
			set targetWindow to front window
			set targetWindowID to id of targetWindow
			set previousWindowIDs to id of every window
			set previousTabCount to count of tabs of targetWindow

			set launchedTab to my openTerminalTab(targetWindowID, previousWindowIDs, previousTabCount)
			if launchedTab is missing value then
				-- Terminal swallowed the New Tab keystroke, or nothing is allowed to
				-- send it. Either way the session still deserves to open, so fall back
				-- to a window Terminal makes for us directly.
				log "vibe-tab: Terminal did not open a tab for " & sessionName & ", so it opened a window instead. If this keeps happening, allow the app that runs vibe-tab (Terminal, or Vibe Tabs.app) to control your computer in System Settings > Privacy & Security > Accessibility."
				set launchedTab to do script attachCommand
			else
				do script attachCommand in launchedTab
			end if
			my waitForTmuxClient(tmuxBin, sessionName)
			set custom title of launchedTab to sessionName
			set title displays custom title of launchedTab to true
			my applyTerminalProfile(launchedTab, terminalProfile)
		end if
	end tell
end openProject

on claudeCommand(sessionName, homeFolder, dangerousMode, extraArgs, dangerousArgs)
	set claudeBin to my resolveExecutable("claude", {homeFolder & "/.local/bin/claude", homeFolder & "/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"})
	set rgBin to my resolveExecutable("rg", {"/opt/homebrew/bin/rg", "/usr/local/bin/rg"})
	set claudeProjects to homeFolder & "/.claude/projects"
	set titleNeedle to "\"customTitle\":\"" & sessionName & "\""
	set claudeLookup to quoted form of rgBin & " -l -F " & quoted form of titleNeedle & " " & quoted form of claudeProjects & " --glob '*.jsonl' 2>/dev/null | /usr/bin/head -n 1 | /usr/bin/xargs /usr/bin/basename 2>/dev/null | /usr/bin/sed 's/\\.jsonl$//'"
	try
		set claudeSessionID to do shell script claudeLookup
	on error
		set claudeSessionID to ""
	end try

	set effectiveArgs to my effectiveAgentArgs("claude", dangerousMode, extraArgs, dangerousArgs)
	if claudeSessionID is "" then
		set claudeLaunch to quoted form of claudeBin & " --name " & quoted form of sessionName
	else
		set claudeLaunch to quoted form of claudeBin & " --resume " & quoted form of claudeSessionID & " --name " & quoted form of sessionName
	end if
	if effectiveArgs is not "" then set claudeLaunch to claudeLaunch & " " & effectiveArgs
	return claudeLaunch & "; exec /bin/zsh -l"
end claudeCommand

on codexCommand(sessionName, homeFolder, dangerousMode, extraArgs, dangerousArgs)
	set codexBin to my resolveExecutable("codex", {homeFolder & "/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"})
	set jqBin to my resolveExecutable("jq", {"/opt/homebrew/bin/jq", "/usr/local/bin/jq", "/usr/bin/jq"})
	set codexIndex to homeFolder & "/.codex/session_index.jsonl"
	set codexState to homeFolder & "/.codex/state_5.sqlite"
	set codexLookup to quoted form of jqBin & " -r --arg name " & quoted form of sessionName & " " & quoted form of "select(.thread_name == $name) | .id" & " " & quoted form of codexIndex & " 2>/dev/null | /usr/bin/tail -n 1"
	try
		set codexSessionID to do shell script codexLookup
	on error
		set codexSessionID to ""
	end try

	if codexSessionID is "" then
		set codexLookup to "/usr/bin/sqlite3 " & quoted form of codexState & " " & quoted form of ("SELECT id FROM threads WHERE name='" & sessionName & "' AND archived=0 ORDER BY updated_at DESC LIMIT 1;")
		try
			set codexSessionID to do shell script codexLookup
		on error
			set codexSessionID to ""
		end try
	end if

	set codexExtraArgs to my effectiveAgentArgs("codex", dangerousMode, extraArgs, dangerousArgs)

	if codexSessionID is "" then
		set codexLaunch to quoted form of codexBin
		if codexExtraArgs is not "" then set codexLaunch to codexLaunch & " " & codexExtraArgs
		return {commandText:(codexLaunch & "; exec /bin/zsh -l"), renameAfterLaunch:true}
	else
		set codexLaunch to quoted form of codexBin & " resume"
		if codexExtraArgs is not "" then set codexLaunch to codexLaunch & " " & codexExtraArgs
		return {commandText:(codexLaunch & " " & quoted form of codexSessionID & "; exec /bin/zsh -l"), renameAfterLaunch:false}
	end if
end codexCommand

on parsePaneSpec(paneSpec, homeFolder)
	if paneSpec starts with "vibe-json:" then
		set encodedConfig to text 11 thru -1 of paneSpec
		set paneJSON to do shell script "/usr/bin/printf '%s' " & quoted form of encodedConfig & " | /usr/bin/base64 -D"
		set jqBin to my resolveExecutable("jq", {"/opt/homebrew/bin/jq", "/usr/local/bin/jq", "/usr/bin/jq"})
		set agentValue to my jsonStringField(paneJSON, ".agent // \"\"", jqBin)
		set commandValue to my jsonStringField(paneJSON, ".command // \"\"", jqBin)
		set titleValue to my jsonStringField(paneJSON, ".title // \"\"", jqBin)
		set argsValue to my jsonStringField(paneJSON, ".args // \"\"", jqBin)
		set dangerousValue to my jsonStringField(paneJSON, ".dangerous // false | tostring", jqBin)
		set dangerousArgsValue to my jsonStringField(paneJSON, ".dangerous_args // \"\"", jqBin)
		return {paneAgent:agentValue, paneCommand:commandValue, paneTitle:titleValue, paneArgs:argsValue, paneDangerous:(dangerousValue is "true"), paneDangerousArgs:dangerousArgsValue}
	end if

	if paneSpec is "claude" or paneSpec is "codex" then
		return {paneAgent:paneSpec, paneCommand:"", paneTitle:"", paneArgs:"", paneDangerous:false, paneDangerousArgs:""}
	end if
	return {paneAgent:"", paneCommand:paneSpec, paneTitle:"", paneArgs:"", paneDangerous:false, paneDangerousArgs:""}
end parsePaneSpec

on jsonStringField(jsonText, jqFilter, jqBin)
	return do shell script "/usr/bin/printf '%s' " & quoted form of jsonText & " | " & quoted form of jqBin & " -er " & quoted form of jqFilter
end jsonStringField

on effectiveAgentArgs(agentName, dangerousMode, extraArgs, configuredDangerousArgs)
	set resultArgs to my trimText(extraArgs)
	if dangerousMode then
		set dangerousArgs to my trimText(configuredDangerousArgs)
		if dangerousArgs is "" then set dangerousArgs to my defaultDangerousArgs(agentName)
		if dangerousArgs is "" then error "dangerous: true requires dangerous_args for agent or command: " & agentName
		if resultArgs is "" then
			set resultArgs to dangerousArgs
		else
			set resultArgs to resultArgs & " " & dangerousArgs
		end if
	end if
	return resultArgs
end effectiveAgentArgs

on defaultDangerousArgs(agentName)
	if agentName is "claude" then return "--dangerously-skip-permissions"
	if agentName is "codex" then return "--yolo"
	if agentName is "gemini" then return "--yolo"
	return ""
end defaultDangerousArgs

on openTerminalTab(targetWindowID, previousWindowIDs, previousTabCount)
	-- Terminal drops the keystroke now and then, especially while it is busy
	-- drawing the tab we opened a moment ago, so send it again before giving up.
	repeat 2 times
		my pressCommandT()
		set launchedTab to my waitForNewTerminalTab(targetWindowID, previousWindowIDs, previousTabCount)
		if launchedTab is not missing value then return launchedTab
	end repeat
	return missing value
end openTerminalTab

on pressCommandT()
	tell application "Terminal" to activate
	tell application "System Events"
		tell process "Terminal"
			repeat 20 times
				if frontmost then exit repeat
				try
					set frontmost to true
				end try
				delay 0.1
			end repeat
			key code 17 using command down
		end tell
	end tell
end pressCommandT

on waitForNewTerminalTab(targetWindowID, previousWindowIDs, previousTabCount)
	-- Depending on the window tabbing preference, Cmd-T lands as a tab in the
	-- front window or as a whole new window. Watch for either, and keep watching
	-- long enough for a loaded Mac to catch up.
	repeat 30 times
		delay 0.1
		tell application "Terminal"
			repeat with candidateWindow in windows
				try
					if (id of candidateWindow) is not in previousWindowIDs and (count of tabs of candidateWindow) > 0 then
						return selected tab of candidateWindow
					end if
				end try
			end repeat
			try
				if (count of tabs of window id targetWindowID) > previousTabCount then
					return selected tab of window id targetWindowID
				end if
			end try
		end tell
	end repeat
	return missing value
end waitForNewTerminalTab

on waitForTmuxClient(tmuxBin, sessionName)
	repeat 20 times
		try
			set clientTTY to do shell script quoted form of tmuxBin & " list-clients -t " & quoted form of sessionName & " -F " & quoted form of "#{client_tty}" & " 2>/dev/null | /usr/bin/head -n 1"
			if clientTTY is not "" then
				delay 0.2
				return
			end if
		on error
		end try
		delay 0.25
	end repeat
end waitForTmuxClient

on focusNamedTerminalTab(sessionName, terminalProfile)
	tell application "Terminal"
		repeat with terminalWindow in windows
			repeat with terminalTab in tabs of terminalWindow
				try
					if (custom title of terminalTab as text) is sessionName then
						my applyTerminalProfile(terminalTab, terminalProfile)
						set selected tab of terminalWindow to terminalTab
						set frontmost of terminalWindow to true
						activate
						return true
					end if
				on error
				end try
			end repeat
		end repeat
	end tell
	return false
end focusNamedTerminalTab

on nameAndFocusTerminalTab(clientTTY, sessionName, terminalProfile)
	tell application "Terminal"
		repeat with terminalWindow in windows
			repeat with terminalTab in tabs of terminalWindow
				try
					if (tty of terminalTab as text) is clientTTY then
						set custom title of terminalTab to sessionName
						set title displays custom title of terminalTab to true
						my applyTerminalProfile(terminalTab, terminalProfile)
						set selected tab of terminalWindow to terminalTab
						set frontmost of terminalWindow to true
						activate
						return true
					end if
				on error
				end try
			end repeat
		end repeat
	end tell
	return false
end nameAndFocusTerminalTab

on validateTerminalProfile(terminalProfile)
	if terminalProfile is "" then return
	tell application "Terminal"
		if terminalProfile is not in (name of every settings set) then error "Unknown Terminal profile: " & terminalProfile
	end tell
end validateTerminalProfile

on applyTerminalProfile(terminalTab, terminalProfile)
	if terminalProfile is "" then return
	tell application "Terminal"
		set current settings of terminalTab to settings set terminalProfile
	end tell
end applyTerminalProfile

on resolveExecutable(commandName, fallbackPaths)
	try
		set resolvedPath to do shell script "/bin/zsh -lc " & quoted form of ("command -v " & commandName & " 2>/dev/null")
		if resolvedPath is not "" then return resolvedPath
	on error
	end try

	repeat with fallbackPath in fallbackPaths
		try
			do shell script "/bin/test -x " & quoted form of (contents of fallbackPath)
			return contents of fallbackPath
		on error
		end try
	end repeat

	error "Required command not found: " & commandName
end resolveExecutable

on commandLabel(commandText, panePosition)
	set firstWord to do shell script "/usr/bin/printf '%s' " & quoted form of commandText & " | /usr/bin/awk '{print $1}' | /usr/bin/xargs /usr/bin/basename 2>/dev/null"
	set labelText to my slugify(firstWord)
	if labelText is "" then set labelText to "pane-" & panePosition
	return labelText
end commandLabel

on normalizeLayout(layoutName)
	if layoutName is "" or layoutName is "auto" then return "auto"
	if layoutName is "even-horizontal" then return layoutName
	if layoutName is "even-vertical" then return layoutName
	if layoutName is "main-horizontal" then return layoutName
	if layoutName is "main-vertical" then return layoutName
	if layoutName is "tiled" then return layoutName
	error "Unsupported tmux layout: " & layoutName
end normalizeLayout

on slugify(inputText)
	return do shell script "/usr/bin/printf '%s' " & quoted form of inputText & " | /usr/bin/tr -cs '[:alnum:]_-' '-' | /usr/bin/sed 's/^-*//; s/-*$//'"
end slugify

on trimText(inputText)
	return do shell script "/usr/bin/printf '%s' " & quoted form of inputText & " | /usr/bin/sed 's/^[[:space:]]*//; s/[[:space:]]*$//'"
end trimText

on homeDirectory()
	set homeFolder to POSIX path of (path to home folder)
	if homeFolder ends with "/" then set homeFolder to text 1 thru -2 of homeFolder
	return homeFolder
end homeDirectory

on expandHomePath(rawPath, homeFolder)
	if rawPath is "~" then return homeFolder
	if rawPath starts with "~/" then return homeFolder & text 2 thru -1 of rawPath
	return rawPath
end expandHomePath
