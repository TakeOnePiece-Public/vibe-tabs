-- macOS app entry point. The command handles YAML and legacy configs.

use scripting additions

on run argv
	set homeFolder to my homeDirectory()
	try
		set launcherBin to my resolveExecutable("vibe-tabs", {homeFolder & "/bin/vibe-tabs", "/opt/homebrew/bin/vibe-tabs", "/usr/local/bin/vibe-tabs"})
	on error errorMessage
		display dialog "Vibe Tabs could not find its vibe-tabs command." & return & return & errorMessage & return & return & "Reinstall with: brew reinstall vibe-tabs" buttons {"OK"} default button "OK" with icon stop with title "Vibe Tabs"
		return
	end try
	set launchCommand to quoted form of launcherBin
	if (count of argv) is 1 then
		set launchCommand to launchCommand & " " & quoted form of (item 1 of argv)
	else if (count of argv) > 1 then
		error "Usage: vibe-tabs [config-file]"
	end if
	try
		do shell script launchCommand
	on error errorMessage number errorNumber
		if errorMessage contains "AppleScript error -1743" or errorMessage contains "Not authorized to send Apple events" then
			set dialogResult to display dialog "Vibe Tabs needs permission to control Terminal." & return & return & "Allow Vibe Tabs to control Terminal in System Settings > Privacy & Security > Automation, then click the Dock icon again." buttons {"Cancel", "Open Settings"} default button "Open Settings" with icon caution with title "Vibe Tabs"
			if button returned of dialogResult is "Open Settings" then do shell script "/usr/bin/open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Automation'"
		else if errorMessage contains "AppleScript error 1002" or errorMessage contains "not allowed to send keystrokes" then
			set dialogResult to display dialog "Vibe Tabs needs Accessibility access to create native Terminal tabs." & return & return & "Enable Vibe Tabs in System Settings, then click the Dock icon again." buttons {"Cancel", "Open Settings"} default button "Open Settings" with icon caution with title "Vibe Tabs"
			if button returned of dialogResult is "Open Settings" then do shell script "/usr/bin/open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility'"
		else
			if errorMessage is "The command exited with a non-zero status." then set errorMessage to "vibe-tabs exited with status " & errorNumber & " without an error message."
			display dialog "Vibe Tabs could not open all of your projects." & return & return & errorMessage buttons {"OK"} default button "OK" with icon stop with title "Vibe Tabs"
		end if
	end try
end run

on resolveExecutable(commandName, fallbackPaths)
	try
		set lookupOutput to do shell script "/bin/zsh -lc " & quoted form of ("command -v " & quoted form of commandName) & " 2>/dev/null"
		if lookupOutput is not "" then
			set resolvedPath to last paragraph of lookupOutput
			if resolvedPath starts with "/" then return resolvedPath
		end if
	end try

	repeat with fallbackPath in fallbackPaths
		try
			do shell script "/bin/test -x " & quoted form of (contents of fallbackPath)
			return contents of fallbackPath
		on error
		end try
	end repeat
	set AppleScript's text item delimiters to ", "
	set searchedText to fallbackPaths as text
	set AppleScript's text item delimiters to ""
	error "Required command not found: " & commandName & ". Looked in your login shell PATH and in " & searchedText & "."
end resolveExecutable

on homeDirectory()
	set homeFolder to POSIX path of (path to home folder)
	if homeFolder ends with "/" then set homeFolder to text 1 thru -2 of homeFolder
	return homeFolder
end homeDirectory
