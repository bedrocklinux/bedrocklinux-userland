# fish tab completion for strat
#
#      This program is free software; you can redistribute it and/or
#      modify it under the terms of the GNU General Public License
#      version 2 as published by the Free Software Foundation.
#
# Copyright (c) 2018 Daniel Thau <danthau@bedrocklinux.org>
#
function _strat_opts
	set args (commandline -opc)

	set saw_help "0"
	set saw_restrict "0"
	set saw_arg0 "0"
	set saw_arg0_arg "0"
	set saw_stratum "0"
	set saw_command "0"
	for i in (seq 2 (count $args))
		switch "$args[$i]"
		case "-h"
			set saw_help "$i"
		case "--help"
			set saw_help "$i"
		case "-r"
			set saw_restrict "$i"
		case "--restrict"
			set saw_restrict "$i"
		case "-a"
			set saw_arg0 "$i"
		case "--arg0"
			set saw_arg0 "$i"
		case "*"
			if [ "$saw_arg0" -ne 0 ]; and  [ "$saw_arg0_arg" -eq 0 ]
				set saw_arg0_arg "$i"
			else if [ "$saw_stratum" -eq 0 ]
				set saw_stratum "$i"
			else
				set saw_command "$i"
			end
		end
	end

	set opts ""
	if [ "$saw_arg0" -ne 0 ]; and  [ "$saw_arg0_arg" -eq 0 ]
		set opts "$opts newarg"
	else if [ "$saw_stratum" -eq 0 ]
		set opts "$opts stratum"
		if [ "$saw_help" -eq 0 ]
			set opts "$opts help"
		end
		if [ "$saw_restrict" -eq 0 ]
			set opts "$opts restrict"
		end
		if [ "$saw_arg0" -eq 0 ]
			set opts "$opts arg0"
		end
	else if [ "$saw_command" -eq 0 ]
		set opts "$opts command"
	else
		set opts "$opts pass"
	end

	if echo "$opts" | grep -q "\<$argv\>"
		return 0
	else
		return 1
	end
end

function _strat_subcommand
	set args (commandline -opc)

	set saw_help "0"
	set saw_restrict "0"
	set saw_arg0 "0"
	set saw_arg0_arg "0"
	set saw_stratum "0"
	set saw_command "0"
	for i in (seq 2 (count $args))
		switch "$args[$i]"
			case "-h"
				set saw_help "$i"
			case "--help"
				set saw_help "$i"
			case "-r"
				set saw_restrict "$i"
			case "--restrict"
				set saw_restrict "$i"
			case "-a"
				set saw_arg0 "$i"
			case "--arg0"
				set saw_arg0 "$i"
			case "*"
				if [ "$saw_arg0" -ne 0 ]; and  [ "$saw_arg0_arg" -eq 0 ]
					set saw_arg0_arg "$i"
				else if [ "$saw_stratum" -eq 0 ]
					set saw_stratum "$i"
				else
					set saw_command "$i"
				end
		end
	end

	__fish_complete_subcommand --fcs-skip=(math $saw_command - 1)
end

function _strat_command
	set args (commandline -opc)

	set saw_help "0"
	set saw_restrict "0"
	set saw_arg0 "0"
	set saw_arg0_arg "0"
	set saw_stratum "0"
	set saw_command "0"
	for i in (seq 2 (count $args))
		switch "$args[$i]"
			case "-h"
				set saw_help "$i"
			case "--help"
				set saw_help "$i"
			case "-r"
				set saw_restrict "$i"
			case "--restrict"
				set saw_restrict "$i"
			case "-a"
				set saw_arg0 "$i"
			case "--arg0"
				set saw_arg0 "$i"
			case "*"
				if [ "$saw_arg0" -ne 0 ]; and  [ "$saw_arg0_arg" -eq 0 ]
					set saw_arg0_arg "$i"
				else if [ "$saw_stratum" -eq 0 ]
					set saw_stratum "$i"
				else
					set saw_command "$i"
				end
		end
	end

	set prefix "/bedrock/strata/$args[$saw_stratum]"
	for dir in $PATH
		if not echo "$dir" | grep -q "^/bedrock/cross"
			ls -1 $prefix$dir 2>/dev/null
		end
	end
end

complete -f -c strat -o 'h' -d 'print help message' -n '_strat_opts help'
complete -f -c strat -l 'help' -d 'print help message' -n '_strat_opts help'
complete -f -c strat -o 'r' -d 'disable cross-stratum hooks' -n '_strat_opts restrict'
complete -f -c strat -l 'restrict' -d 'disable cross-stratum hooks' -n '_strat_opts restrict'
complete -f -c strat -o 'a' -d 'specify arg0' -n '_strat_opts arg0'
complete -f -c strat -l 'arg0' -d 'specify arg0' -n '_strat_opts arg0'
complete -f -c strat -a '(/bedrock/bin/brl list)' -d 'stratum' -n '_strat_opts stratum'
complete -f -c strat -a '(_strat_command)' -n '_strat_opts command'
complete -x -c strat -a '(_strat_subcommand)' -n '_strat_opts pass'
