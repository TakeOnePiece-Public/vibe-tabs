-- Open one named project in tmux, with one pane per configured coding command.
-- Usage: vibe-tab [options] [session-name] /path/to/project [command ...]
--
-- Errors raised with a plain `error "text"` (number -2700) are already written
-- for people. Any other error (a failed shell command, a Terminal permission
-- error) gets the step it happened in appended, so the cause is never a bare
-- "The command exited with a non-zero status."

property currentStep : ""

on run argv
	try
		my main(argv)
	on error errorMessage number errorNumber
		if errorNumber is not -2700 and currentStep is not "" then set errorMessage to errorMessage & " (while " & currentStep & ")"
		error errorMessage number errorNumber
	end try
end run

on main(argv)
	set usageText to "Usage: vibe-tab [--layout layout] [--profile name] [--new-window] [session-name] /path/to/project [command ...]"
	set requestedLayout to "auto"
	set terminalProfile to ""
	set forceNewWindow to false
	set effectiveArgs to {}
	set argumentPosition to 1

	set currentStep to "reading arguments"
	repeat while argumentPosition <= (count of argv)
		set currentArgument to item argumentPosition of argv
		if currentArgument is "--layout" then
			if argumentPosition + 1 > (count of argv) then error "--layout requires a value. " & usageText
			set requestedLayout to item (argumentPosition + 1) of argv
			set argumentPosition to argumentPosition + 2
		else if currentArgument is "--profile" then
			if argumentPosition + 1 > (count of argv) then error "--profile requires a value. " & usageText
			set terminalProfile to item (argumentPosition + 1) of argv
			set argumentPosition to argumentPosition + 2
		else if currentArgument is "--new-window" then
			set forceNewWindow to true
			set argumentPosition to argumentPosition + 1
		else if currentArgument starts with "--" then
			error "Unknown option: " & currentArgument & ". " & usageText
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
		error "Missing the project folder. " & usageText
	end if
end main

on openProject(rawFolder, requestedName, configuredPanes, requestedLayout, terminalProfile, forceNewWindow)
	set currentStep to "checking the environment"
	set homeFolder to my homeDirectory()
	set layoutName to my normalizeLayout(requestedLayout)
	set tmuxBin to my resolveExecutable("tmux", {"/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"})

	set currentStep to "checking the project folder " & rawFolder
	set projectFolder to my absoluteProjectPath(rawFolder, homeFolder)
	set folderExists to true
	set canonicalFolder to ""
	try
		my checkProjectFolder(projectFolder)
	on error folderProblem
		-- `vibe-tab name` with no such folder: treat the argument as a session
		-- name and attach if that session is already running.
		if requestedName is not "" then error folderProblem
		set folderExists to false
		set requestedName to rawFolder
	end try
	if folderExists then
		set canonicalFolder to do shell script "/bin/zsh -c " & quoted form of ("cd " & quoted form of projectFolder & " && /bin/pwd -P")
		set projectName to do shell script "/usr/bin/basename " & quoted form of canonicalFolder
		if requestedName is "" then set requestedName to projectName
	end if

	set sessionName to my slugify(requestedName)
	if sessionName is "" then error "Session name \"" & requestedName & "\" must contain a letter or number"

	set currentStep to "checking Terminal profile " & terminalProfile
	my validateTerminalProfile(terminalProfile)

	set paneSpecs to {}
	repeat with configuredPane in configuredPanes
		set paneSpec to my trimText(contents of configuredPane)
		if paneSpec is not "" then set end of paneSpecs to paneSpec
	end repeat
	if (count of paneSpecs) is 0 then set paneSpecs to {"claude", "codex"}

	set sessionExists to true
	try
		do shell script quoted form of tmuxBin & " has-session -t " & quoted form of ("=" & sessionName)
	on error
		set sessionExists to false
	end try

	if sessionExists is false and folderExists is false then
		error folderProblem & ", and no tmux session named '" & sessionName & "' is running. Usage: vibe-tab [session-name] /path/to/project [command ...]"
	end if

	if sessionExists is false then
		set paneCommands to {}
		set paneTitles to {}
		set codexRenamePositions to {}
		set panePosition to 0

		repeat with paneSpecRef in paneSpecs
			set panePosition to panePosition + 1
			set currentStep to "preparing pane " & panePosition & " of session " & sessionName
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
				my warnIfCommandMissing(configuredCommand, sessionName, panePosition)
				set paneCommand to "/bin/zsh -lc " & quoted form of (configuredCommand & "; exec /bin/zsh -l")
				set paneTitle to sessionName & "-" & my commandLabel(configuredCommand, panePosition)
			end if

			if configuredTitle is not "" then set paneTitle to sessionName & "-" & my slugify(configuredTitle)

			set end of paneCommands to paneCommand
			set end of paneTitles to paneTitle
		end repeat

		-- Build the whole session; if any step fails, remove the half-built
		-- session so the next run starts clean instead of attaching to it.
		set currentStep to "creating tmux session " & sessionName
		try
			set paneIDs to {}
			set firstPaneCommand to item 1 of paneCommands
			-- A large detached size leaves room for many side-by-side panes; tmux
			-- resizes the window to the Terminal tab when it attaches.
			set createCommand to quoted form of tmuxBin & " new-session -d -x 300 -y 80 -P -F " & quoted form of "#{pane_id}" & " -s " & quoted form of sessionName & " -c " & quoted form of canonicalFolder & " " & quoted form of firstPaneCommand
			set firstPaneID to my tmuxRun(createCommand, "create session " & sessionName)
			set end of paneIDs to firstPaneID

			if (count of paneCommands) > 1 then
				repeat with panePosition from 2 to count of paneCommands
					set splitCommand to quoted form of tmuxBin & " split-window -h -P -F " & quoted form of "#{pane_id}" & " -t " & quoted form of sessionName & " -c " & quoted form of canonicalFolder & " " & quoted form of (item panePosition of paneCommands)
					set newPaneID to my tmuxRun(splitCommand, "add pane " & panePosition & " to session " & sessionName)
					set end of paneIDs to newPaneID
					-- Re-tile after every split so the next split always has room.
					my tmuxRun(quoted form of tmuxBin & " select-layout -t " & quoted form of sessionName & " tiled", "arrange panes in session " & sessionName)
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
				my tmuxRun(quoted form of tmuxBin & " select-layout -t " & quoted form of sessionName & " " & quoted form of effectiveLayout, "apply layout " & effectiveLayout & " to session " & sessionName)
			end if

			repeat with panePosition from 1 to count of paneIDs
				my tmuxRun(quoted form of tmuxBin & " select-pane -t " & quoted form of (item panePosition of paneIDs) & " -T " & quoted form of (item panePosition of paneTitles), "title pane " & panePosition & " of session " & sessionName)
			end repeat
			my tmuxRun(quoted form of tmuxBin & " rename-window -t " & quoted form of sessionName & " " & quoted form of sessionName, "name the window of session " & sessionName)
			my tmuxRun(quoted form of tmuxBin & " select-pane -t " & quoted form of firstPaneID, "focus the first pane of session " & sessionName)
		on error errorMessage
			try
				do shell script quoted form of tmuxBin & " kill-session -t " & quoted form of ("=" & sessionName)
			end try
			error errorMessage & " The half-created session was removed."
		end try

		if (count of codexRenamePositions) > 0 then
			set currentStep to "naming the Codex thread for " & sessionName
			repeat with renamePositionRef in codexRenamePositions
				set codexPaneID to item (contents of renamePositionRef) of paneIDs
				-- Typing before the Codex TUI is ready loses the leading keystrokes
				-- (only the tail of "/rename <name>" arrives and is sent as a prompt).
				try
					if my waitForCodexComposer(tmuxBin, codexPaneID) then
						do shell script quoted form of tmuxBin & " send-keys -t " & quoted form of codexPaneID & " -l " & quoted form of ("/rename " & sessionName)
						delay 0.3
						do shell script quoted form of tmuxBin & " send-keys -t " & quoted form of codexPaneID & " C-m"
					else
						log "vibe-tab: warning: " & sessionName & ": Codex did not show its prompt within 60 seconds (it may be waiting on an update or login screen); skipped /rename " & sessionName
					end if
				on error renameError
					log "vibe-tab: warning: " & sessionName & ": could not name the Codex thread: " & renameError
				end try
			end repeat
		end if
	end if

	-- Keep tmux from overwriting Terminal's stable custom tab title.
	try
		do shell script quoted form of tmuxBin & " set-option -t " & quoted form of sessionName & " set-titles off"
	on error
	end try

	set currentStep to "looking for an existing Terminal tab for " & sessionName
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

	set currentStep to "opening a Terminal tab for " & sessionName
	set attachCommand to quoted form of tmuxBin & " attach-session -t " & quoted form of ("=" & sessionName)
	tell application "Terminal"
		activate
		if forceNewWindow or (count of windows) is 0 then
			set launchedTab to do script attachCommand
		else
			set launchedTab to my newTerminalTab()
			if launchedTab is missing value then
				-- Terminal swallowed the New Tab keystroke twice, or UI scripting was
				-- refused (no Accessibility permission). Open a window instead of failing.
				log "vibe-tab: Terminal did not open a tab for " & sessionName & ", so it opened a new window instead. If this keeps happening, allow your terminal app (or Vibe Tabs.app) under System Settings > Privacy & Security > Accessibility."
				set launchedTab to do script attachCommand
			else
				do script attachCommand in launchedTab
			end if
		end if
	end tell

	if not my waitForTmuxClient(tmuxBin, sessionName) then
		log "vibe-tab: warning: " & sessionName & ": the Terminal tab opened but tmux did not attach within 5 seconds; check that tab for an error"
	end if
	set currentStep to "titling the Terminal tab for " & sessionName
	tell application "Terminal"
		set custom title of launchedTab to sessionName
		set title displays custom title of launchedTab to true
	end tell
	my applyTerminalProfile(launchedTab, terminalProfile)
end openProject

-- Run a tmux command; on failure raise "tmux could not <purpose>: <tmux's message>".
on tmuxRun(shellCommand, purpose)
	try
		return do shell script shellCommand
	on error errorMessage number errorNumber
		if errorMessage is "The command exited with a non-zero status." then set errorMessage to "no details from tmux (exit status " & errorNumber & ")"
		error "tmux could not " & purpose & ": " & errorMessage & "."
	end try
end tmuxRun

on claudeCommand(sessionName, homeFolder, dangerousMode, extraArgs, dangerousArgs)
	set claudeBin to my resolveExecutable("claude", {homeFolder & "/.local/bin/claude", homeFolder & "/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"})
	set claudeProjects to homeFolder & "/.claude/projects"
	set titleNeedle to "\"customTitle\":\"" & sessionName & "\""
	set claudeSessionID to ""
	-- Finding the named conversation is best effort: without it Claude starts fresh.
	if my shellTest("-d", claudeProjects) then
		set rgBin to my findExecutable("rg", {"/opt/homebrew/bin/rg", "/usr/local/bin/rg"})
		if rgBin is not "" then
			set searchCommand to quoted form of rgBin & " -l -F " & quoted form of titleNeedle & " " & quoted form of claudeProjects & " --glob '*.jsonl'"
		else
			set searchCommand to "/usr/bin/grep -rlF --include='*.jsonl' -e " & quoted form of titleNeedle & " " & quoted form of claudeProjects
		end if
		try
			set claudeSessionID to do shell script searchCommand & " 2>/dev/null | /usr/bin/head -n 1 | /usr/bin/xargs /usr/bin/basename 2>/dev/null | /usr/bin/sed 's/\\.jsonl$//'"
		on error
			set claudeSessionID to ""
		end try
	end if

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
	set codexIndex to homeFolder & "/.codex/session_index.jsonl"
	set codexSessionID to ""

	-- Finding the named thread is best effort: without it Codex starts fresh.
	set jqBin to my findExecutable("jq", {"/opt/homebrew/bin/jq", "/usr/local/bin/jq", "/usr/bin/jq"})
	if jqBin is not "" and my shellTest("-f", codexIndex) then
		set codexLookup to quoted form of jqBin & " -r --arg name " & quoted form of sessionName & " " & quoted form of "select(.thread_name == $name) | .id" & " " & quoted form of codexIndex & " 2>/dev/null | /usr/bin/tail -n 1"
		try
			set codexSessionID to do shell script codexLookup
		on error
			set codexSessionID to ""
		end try
		if not my codexRolloutExists(homeFolder, codexSessionID) then set codexSessionID to ""
	end if

	if codexSessionID is "" then
		-- The state database is versioned (state_5.sqlite today); use the newest one.
		set codexState to ""
		try
			set codexState to do shell script "/bin/ls -t " & quoted form of (homeFolder & "/.codex") & "/state_*.sqlite 2>/dev/null | /usr/bin/head -n 1"
		end try
		if codexState is not "" and my shellTest("-x", "/usr/bin/sqlite3") then
			set codexLookup to "/usr/bin/sqlite3 -readonly " & quoted form of codexState & " " & quoted form of ("SELECT id FROM threads WHERE name='" & sessionName & "' AND archived=0 ORDER BY updated_at DESC LIMIT 1;") & " 2>/dev/null"
			try
				set codexSessionID to do shell script codexLookup
			on error
				set codexSessionID to ""
			end try
			if not my codexRolloutExists(homeFolder, codexSessionID) then set codexSessionID to ""
		end if
	end if

	set codexExtraArgs to my effectiveAgentArgs("codex", dangerousMode, extraArgs, dangerousArgs)

	if codexSessionID is "" then
		set codexLaunch to quoted form of codexBin
		if codexExtraArgs is not "" then set codexLaunch to codexLaunch & " " & codexExtraArgs
		return {commandText:(codexLaunch & "; exec /bin/zsh -l"), renameAfterLaunch:true}
	else
		-- Syntax is `codex resume [OPTIONS] [SESSION_ID] [PROMPT]`. Configured args
		-- such as "resume --last" must not be repeated here: a second "resume" would
		-- be taken as SESSION_ID and the real ID as PROMPT, and clap rejects
		-- "--last" together with a prompt.
		set resumeOptions to my codexResumeOptions(codexExtraArgs)
		set codexLaunch to quoted form of codexBin & " resume"
		if resumeOptions is not "" then set codexLaunch to codexLaunch & " " & resumeOptions
		return {commandText:(codexLaunch & " " & quoted form of codexSessionID & "; exec /bin/zsh -l"), renameAfterLaunch:false}
	end if
end codexCommand

-- The name index outlives the conversations it points at: once Codex prunes or
-- someone deletes a rollout file, `codex resume <id>` fails with "no rollout
-- found". Only resume a thread whose rollout is still on disk.
on codexRolloutExists(homeFolder, codexSessionID)
	if codexSessionID is "" then return false
	set codexHome to homeFolder & "/.codex"
	try
		set rolloutPath to do shell script "/usr/bin/find " & quoted form of (codexHome & "/sessions") & " " & quoted form of (codexHome & "/archived_sessions") & " -name " & quoted form of ("rollout-*" & codexSessionID & ".jsonl") & " -print -quit 2>/dev/null; true"
	on error
		return false
	end try
	return rolloutPath is not ""
end codexRolloutExists

-- Drop a leading "resume" subcommand and "--last" from configured codex args so
-- they can be combined with an explicit session ID.
on codexResumeOptions(argsText)
	set AppleScript's text item delimiters to " "
	set argWords to text items of argsText
	set AppleScript's text item delimiters to ""
	set keptWords to {}
	set seenFirstWord to false
	repeat with argWordRef in argWords
		set argWord to contents of argWordRef
		if argWord is not "" then
			if (not seenFirstWord) and argWord is "resume" then
				-- subcommand already supplied by the launcher
			else if argWord is "--last" then
				-- meaningless with an explicit session ID
			else
				set end of keptWords to argWord
			end if
			set seenFirstWord to true
		end if
	end repeat
	set AppleScript's text item delimiters to " "
	set joinedWords to keptWords as text
	set AppleScript's text item delimiters to ""
	return joinedWords
end codexResumeOptions

-- Poll a tmux pane until the Codex TUI shows its empty-composer placeholder.
-- Returns false if codex failed to start (CLI usage error on screen) or the
-- composer never appeared within about 60 seconds (for example an "Update now"
-- prompt that is still waiting for the user). Note: pane_current_command is
-- not usable here; tmux reports "zsh" for the wrapper shell even while codex runs.
on waitForCodexComposer(tmuxBin, paneID)
	repeat 120 times
		try
			set paneText to do shell script quoted form of tmuxBin & " capture-pane -p -t " & quoted form of paneID
			if paneText contains "Ask Codex to do anything" then
				delay 0.5
				return true
			end if
			if paneText contains "Usage: codex" then return false
		on error
		end try
		delay 0.5
	end repeat
	return false
end waitForCodexComposer

on parsePaneSpec(paneSpec, homeFolder)
	if paneSpec starts with "vibe-json:" then
		set encodedConfig to text 11 thru -1 of paneSpec
		try
			set paneJSON to do shell script "/usr/bin/printf '%s' " & quoted form of encodedConfig & " | /usr/bin/base64 -D"
		on error
			error "Pane settings passed by vibe-tabs are corrupted (invalid base64). Run vibe-tabs again; if it keeps happening, reinstall vibe-tabs."
		end try
		set jqBin to my resolveExecutable("jq", {"/opt/homebrew/bin/jq", "/usr/local/bin/jq", "/usr/bin/jq"})
		try
			set agentValue to my jsonStringField(paneJSON, ".agent // \"\"", jqBin)
			set commandValue to my jsonStringField(paneJSON, ".command // \"\"", jqBin)
			set titleValue to my jsonStringField(paneJSON, ".title // \"\"", jqBin)
			set argsValue to my jsonStringField(paneJSON, ".args // \"\"", jqBin)
			set dangerousValue to my jsonStringField(paneJSON, ".dangerous // false | tostring", jqBin)
			set dangerousArgsValue to my jsonStringField(paneJSON, ".dangerous_args // \"\"", jqBin)
		on error jqError
			error "Pane settings passed by vibe-tabs are not valid JSON: " & jqError
		end try
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

-- Create a new tab in the front Terminal window with Cmd+T via System Events.
-- Terminal drops the keystroke now and then, especially while it is still drawing
-- the previous tab, so it is sent twice before giving up. Returns missing value
-- when UI scripting is not allowed (Accessibility permission missing, error 1002)
-- or when no new tab appeared, so callers can fall back.
on newTerminalTab()
	tell application "Terminal"
		set targetWindowID to id of front window
		set previousWindowIDs to id of every window
		set previousTabCount to count of tabs of front window
	end tell
	repeat 2 times
		try
			my pressCommandT()
		on error
			return missing value
		end try
		set launchedTab to my waitForNewTerminalTab(targetWindowID, previousWindowIDs, previousTabCount)
		if launchedTab is not missing value then return launchedTab
	end repeat
	return missing value
end newTerminalTab

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

-- Depending on the window tabbing preference, Cmd+T lands as a tab in the front
-- window or as a whole new window. Watch for either for up to three seconds.
on waitForNewTerminalTab(targetWindowID, previousWindowIDs, previousTabCount)
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

-- Returns true once a tmux client is attached to the session, false after about 5 seconds.
on waitForTmuxClient(tmuxBin, sessionName)
	repeat 20 times
		try
			set clientTTY to do shell script quoted form of tmuxBin & " list-clients -t " & quoted form of sessionName & " -F " & quoted form of "#{client_tty}" & " 2>/dev/null | /usr/bin/head -n 1"
			if clientTTY is not "" then
				delay 0.2
				return true
			end if
		on error
		end try
		delay 0.25
	end repeat
	return false
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
		set profileNames to name of every settings set
	end tell
	if terminalProfile is not in profileNames then
		set AppleScript's text item delimiters to ", "
		set profileList to profileNames as text
		set AppleScript's text item delimiters to ""
		error "Unknown Terminal profile \"" & terminalProfile & "\". Available profiles: " & profileList
	end if
end validateTerminalProfile

on applyTerminalProfile(terminalTab, terminalProfile)
	if terminalProfile is "" then return
	tell application "Terminal"
		set current settings of terminalTab to settings set terminalProfile
	end tell
end applyTerminalProfile

-- Find an executable in the login shell PATH or the fallback paths; "" if missing.
on findExecutable(commandName, fallbackPaths)
	try
		set lookupOutput to do shell script "/bin/zsh -lc " & quoted form of ("command -v " & quoted form of commandName) & " 2>/dev/null"
		if lookupOutput is not "" then
			-- Login-shell startup files may print text; the path is the last line.
			set resolvedPath to last paragraph of lookupOutput
			if resolvedPath starts with "/" and my shellTest("-x", resolvedPath) then return resolvedPath
		end if
	end try
	repeat with fallbackPath in fallbackPaths
		set candidatePath to contents of fallbackPath
		if my shellTest("-x", candidatePath) then return candidatePath
	end repeat
	return ""
end findExecutable

on resolveExecutable(commandName, fallbackPaths)
	set resolvedPath to my findExecutable(commandName, fallbackPaths)
	if resolvedPath is not "" then return resolvedPath
	set AppleScript's text item delimiters to ", "
	set searchedText to fallbackPaths as text
	set AppleScript's text item delimiters to ""
	error "Required command not found: " & commandName & ". Looked in your login shell PATH and in " & searchedText & ". " & my installHint(commandName)
end resolveExecutable

on installHint(commandName)
	if commandName is "tmux" then return "Install it with: brew install tmux"
	if commandName is "jq" then return "Install it with: brew install jq"
	if commandName is "claude" then return "Install Claude Code (https://claude.com/claude-code) or remove the claude pane from your config."
	if commandName is "codex" then return "Install Codex (brew install codex, or npm install -g @openai/codex) or remove the codex pane from your config."
	return "Install " & commandName & " or remove it from your config."
end installHint

-- True when `/bin/test FLAG PATH` succeeds.
on shellTest(testFlag, targetPath)
	if targetPath is "" then return false
	try
		do shell script "/bin/test " & testFlag & " " & quoted form of targetPath
		return true
	on error
		return false
	end try
end shellTest

-- Expand ~ and make relative paths absolute from the caller's working folder
-- (do shell script itself always runs in /).
on absoluteProjectPath(rawFolder, homeFolder)
	set projectFolder to my trimText(rawFolder)
	if projectFolder is "" then error "The project folder path is empty"
	set projectFolder to my expandHomePath(projectFolder, homeFolder)
	if projectFolder starts with "~" then error "Project folder \"" & rawFolder & "\" uses ~user, which is not supported. Use ~/ or an absolute path."
	if projectFolder does not start with "/" then
		set callerFolder to system attribute "PWD"
		if callerFolder is "" then error "Project folder \"" & rawFolder & "\" is relative and the current folder is unknown. Use an absolute path."
		set projectFolder to callerFolder & "/" & projectFolder
	end if
	return projectFolder
end absoluteProjectPath

on checkProjectFolder(projectFolder)
	if not my shellTest("-e", projectFolder) then
		if my shellTest("-L", projectFolder) then error "Project folder is a broken symlink: " & projectFolder
		error "Project folder does not exist: " & projectFolder
	end if
	if not my shellTest("-d", projectFolder) then error "Project path is a file, not a folder: " & projectFolder
	if not my shellTest("-x", projectFolder) then error "Project folder is not accessible (permission denied): " & projectFolder
end checkProjectFolder

-- Warn (without failing) when a command pane's program is not installed; the
-- pane would otherwise just print "command not found" and drop to a shell.
on warnIfCommandMissing(commandText, sessionName, panePosition)
	try
		set firstWord to do shell script "/usr/bin/printf '%s' " & quoted form of commandText & " | /usr/bin/awk '{print $1}'"
	on error
		return
	end try
	if firstWord is "" or firstWord contains "=" or firstWord contains "$" then return
	try
		do shell script "/bin/zsh -lc " & quoted form of ("whence -- " & quoted form of firstWord & " >/dev/null 2>&1")
	on error
		log "vibe-tab: warning: " & sessionName & ": pane " & panePosition & " runs \"" & firstWord & "\", which was not found in your login shell PATH; that pane will show an error"
	end try
end warnIfCommandMissing

on normalizeLayout(layoutName)
	set supportedLayouts to {"even-horizontal", "even-vertical", "main-horizontal", "main-vertical", "tiled"}
	if layoutName is "" or layoutName is "auto" then return "auto"
	if layoutName is in supportedLayouts then return layoutName
	error "Unsupported tmux layout \"" & layoutName & "\". Use auto, even-horizontal, even-vertical, main-horizontal, main-vertical, or tiled."
end normalizeLayout

on commandLabel(commandText, panePosition)
	set labelText to ""
	try
		set firstWord to do shell script "/usr/bin/printf '%s' " & quoted form of commandText & " | /usr/bin/awk '{print $1}'"
		if firstWord is not "" then set labelText to my slugify(do shell script "/usr/bin/basename " & quoted form of firstWord)
	end try
	if labelText is "" then set labelText to "pane-" & panePosition
	return labelText
end commandLabel

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
