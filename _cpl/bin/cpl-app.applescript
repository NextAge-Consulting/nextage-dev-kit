-- CPL.app — dumb executor. All resolution (config, fingerprint, profile, placement,
-- geometry, slot claim) happens in cpl-picker. This script only: runs the picker,
-- parses the resolved spec, handles the iTerm cold-launch dance, and opens the window.
--
-- Picker stdout contract (single tab-separated line):
--   L \t T \t R \t B \t itermProfile \t sessionName \t command

on run
	set homePath to POSIX path of (path to home folder)

	-- Run picker UI. Non-zero exit (Cancel / config-save) → no output → abort.
	try
		set pickerResult to do shell script homePath & "bin/cpl-picker"
	on error
		return
	end try

	set AppleScript's text item delimiters to tab
	set parts to text items of pickerResult
	set AppleScript's text item delimiters to ""
	if (count of parts) < 7 then return

	set L to (item 1 of parts) as integer
	set T to (item 2 of parts) as integer
	set R to (item 3 of parts) as integer
	set B to (item 4 of parts) as integer
	set profileName to item 5 of parts
	set sessionName to item 6 of parts
	set cmd to item 7 of parts

	-- Detect cold launch BEFORE telling iTerm anything
	set iTermWasRunning to application "iTerm" is running

	-- Cold launch: suppress iTerm's default startup window, then start it
	if not iTermWasRunning then
		do shell script "defaults write com.googlecode.iterm2 OpenNoWindowsAtStartup -bool true"

		tell application "iTerm" to activate

		repeat 30 times
			try
				tell application "iTerm" to count of windows
				exit repeat
			on error
				delay 0.5
			end try
		end repeat

		do shell script "defaults write com.googlecode.iterm2 OpenNoWindowsAtStartup -bool false"

		try
			tell application "iTerm"
				repeat while (count of windows) > 0
					close window 1
					delay 0.2
				end repeat
			end tell
		end try
	end if

	-- Create the window (retry transient -609 on cold launch)
	repeat 5 times
		try
			tell application "iTerm"
				activate
				set newWindow to (create window with profile profileName)
				set bounds of newWindow to {L, T, R, B}
				tell current session of newWindow
					set name to sessionName
					write text cmd
				end tell
			end tell
			exit repeat
		on error errMsg number errNum
			if errNum is -609 then
				delay 0.5
			else
				display dialog errMsg buttons {"OK"} default button "OK"
				exit repeat
			end if
		end try
	end repeat
end run
