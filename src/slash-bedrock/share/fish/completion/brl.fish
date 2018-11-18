# fish tab completion for brl
#
#      This program is free software; you can redistribute it and/or
#      modify it under the terms of the GNU General Public License
#      version 2 as published by the Free Software Foundation.
#
# Copyright (c) 2018 Daniel Thau <danthau@bedrocklinux.org>
#
function _brl_argnum
	if [ (count (commandline -opc)) -eq "$argv" ]
		return 0
	else
		return 1
	end
end

function _brl_arg_is
	set args (commandline -opc)

	if [ (count $args) -lt $argv[1] ]
		return 1
	else if [ "$args[$argv[1]]" != "$argv[2]" ]
		return 1
	else
		return 0
	end
end

function _brl_which_bin
	for dir in $PATH
		ls -1 $dir 2>/dev/null
	end
end

function _brl_which_any
	if _brl_arg_is 3 -c
		return 1
	else if _brl_arg_is 3 --current
		return 1
	else if _brl_arg_is 3 -b
		return 1
	else if _brl_arg_is 3 --bin
		return 1
	else if _brl_arg_is 3 -f
		return 1
	else if _brl_arg_is 3 --file
		return 1
	else if _brl_arg_is 3 --p
		return 1
	else if _brl_arg_is 3 --pid
		return 1
	else if _brl_arg_is 3 -x
		return 1
	else if _brl_arg_is 3 --xwindow
		return 1
	end
	return 0
end

complete -f -c brl -a 'help strat list which fetch remove rename copy status enable disable repair hide show alias deref update reload version report' -d 'brl subcommand' -n "_brl_argnum 1"

complete -f -c brl -o 'h' -d 'print help message' -n "_brl_argnum 1"
complete -f -c brl -o 'h' -d 'print help message' -n "_brl_argnum 2"
complete -f -c brl -l 'help' -d 'print help message' -n "_brl_argnum 1"
complete -f -c brl -l 'help' -d 'print help message' -n "_brl_argnum 2"

complete -f -c brl -n '_brl_arg_is 2 list; and _brl_argnum 2' -o 'e' -d 'list enabled strata'
complete -f -c brl -n '_brl_arg_is 2 list; and _brl_argnum 2' -o 'E' -d 'list aliases to enabled strata'
complete -f -c brl -n '_brl_arg_is 2 list; and _brl_argnum 2' -o 'd' -d 'list disabled strata'
complete -f -c brl -n '_brl_arg_is 2 list; and _brl_argnum 2' -o 'D' -d 'list aliases to disabled strata'
complete -f -c brl -n '_brl_arg_is 2 list; and _brl_argnum 2' -o 'a' -d 'list all strata'
complete -f -c brl -n '_brl_arg_is 2 list; and _brl_argnum 2' -o 'A' -d 'list all aliases'
complete -f -c brl -n '_brl_arg_is 2 list; and _brl_argnum 2' -o 'r' -d 'dereference aliases'
complete -f -c brl -n '_brl_arg_is 2 list; and _brl_argnum 2' -o 'i' -d 'include hidden strata'

complete -f -c brl -n '_brl_arg_is 2 which; and _brl_argnum 2' -o 'c' -d 'which stratum provides current process'
complete -f -c brl -n '_brl_arg_is 2 which; and _brl_argnum 2' -l 'current' -d 'which stratum provides current process'
complete -f -c brl -n '_brl_arg_is 2 which; and _brl_argnum 2' -o 'b' -d 'which stratum provides binary in $PATH'
complete -f -c brl -n '_brl_arg_is 2 which; and _brl_argnum 2' -l 'bin' -d 'which stratum provides binary in $PATH'
complete -f -c brl -n '_brl_arg_is 2 which; and _brl_argnum 2' -o 'f' -d 'which stratum provides a given file path'
complete -f -c brl -n '_brl_arg_is 2 which; and _brl_argnum 2' -l 'file' -d 'which stratum provides a given file path'
complete -f -c brl -n '_brl_arg_is 2 which; and _brl_argnum 2' -o 'p' -d 'which stratum provides a given process ID'
complete -f -c brl -n '_brl_arg_is 2 which; and _brl_argnum 2' -l 'pid' -d 'which stratum provides a given process ID'
complete -f -c brl -n '_brl_arg_is 2 which; and _brl_argnum 2' -o 'x' -d 'which stratum provides a given process ID'
complete -f -c brl -n '_brl_arg_is 2 which; and _brl_argnum 2' -l 'xwindow' -d 'which stratum provides a given X11 window'
complete -f -c brl -n '_brl_arg_is 2 which; and _brl_arg_is 3 -b' -a '(_brl_which_bin)' -d 'binary'
complete -f -c brl -n '_brl_arg_is 2 which; and _brl_arg_is 3 --bin' -a '(_brl_which_bin)' -d 'binary'
complete -f -c brl -n '_brl_arg_is 2 which; and _brl_arg_is 3 -f' -a '(__fish_complete_path)' -d 'file'
complete -f -c brl -n '_brl_arg_is 2 which; and _brl_arg_is 3 --file' -a '(__fish_complete_path)' -d 'file'
complete -f -c brl -n '_brl_arg_is 2 which; and _brl_arg_is 3 -p' -a '(__fish_complete_pids)' -d 'pid'
complete -f -c brl -n '_brl_arg_is 2 which; and _brl_arg_is 3 --pid' -a '(__fish_complete_pids)' -d 'pid'
complete -f -c brl -n '_brl_arg_is 2 which; and _brl_which_any' -a '(_brl_which_bin)' -d 'binary'
complete -f -c brl -n '_brl_arg_is 2 which; and _brl_which_any' -a '(__fish_complete_path)' -d 'file'
complete -f -c brl -n '_brl_arg_is 2 which; and _brl_which_any' -a '(__fish_complete_pids)' -d 'pid'

complete -f -c brl -n '_brl_arg_is 2 fetch; and _brl_argnum 3' -o 'l' -d 'list supported distros'
complete -f -c brl -n '_brl_arg_is 2 fetch; and _brl_argnum 3' -l 'list' -d 'list supported distros'
complete -f -c brl -n '_brl_arg_is 2 fetch; and _brl_argnum 3' -o 'x' -d 'list experimental distros'
complete -f -c brl -n '_brl_arg_is 2 fetch; and _brl_argnum 3' -l 'experimental' -d 'list experimental distros'
complete -f -c brl -n '_brl_arg_is 2 fetch' -o 'R' -d 'list releases provided by distros'
complete -f -c brl -n '_brl_arg_is 2 fetch' -l 'releases' -d 'list releases provided by distros'
complete -f -c brl -n '_brl_arg_is 2 fetch' -o 'n' -d 'specify new stratum name'
complete -f -c brl -n '_brl_arg_is 2 fetch' -l 'name' -d 'specify new stratum name'
complete -f -c brl -n '_brl_arg_is 2 fetch' -o 'r' -d 'specify release'
complete -f -c brl -n '_brl_arg_is 2 fetch' -l 'release' -d 'specify release'
complete -f -c brl -n '_brl_arg_is 2 fetch' -o 'm' -d 'specify mirror'
complete -f -c brl -n '_brl_arg_is 2 fetch' -l 'mirror' -d 'specify mirror'
complete -f -c brl -n '_brl_arg_is 2 fetch' -o 'e' -d 'skip enabling newly fetched strata'
complete -f -c brl -n '_brl_arg_is 2 fetch' -l 'dont-enable' -d 'skip enabling newly fetched strata'
complete -f -c brl -n '_brl_arg_is 2 fetch' -o 's' -d 'skip showing newly fetched strata'
complete -f -c brl -n '_brl_arg_is 2 fetch' -l 'dont-show' -d 'skip showing newly fetched strata'
complete -f -c brl -n '_brl_arg_is 2 fetch' -a '(/bedrock/bin/brl fetch --list)' -d 'distro'

complete -f -c brl -n '_brl_arg_is 2 remove' -a '(/bedrock/bin/brl list -aA)' -d 'aliases and strata'

complete -f -c brl -n '_brl_arg_is 2 rename; and _brl_argnum 2' -a '(/bedrock/bin/brl list -dD)' -d 'aliases and disabled strata'

complete -f -c brl -n '_brl_arg_is 2 copy; and _brl_argnum 2' -a '(/bedrock/bin/brl list -dD)' -d 'stratum'

complete -f -c brl -n '_brl_arg_is 2 status' -a '(/bedrock/bin/brl list -aA)' -d 'strata or aliases'

complete -f -c brl -n '_brl_arg_is 2 enable' -a '(/bedrock/bin/brl list -dD)' -d 'strata or aliases'

complete -f -c brl -n '_brl_arg_is 2 disable' -a '(/bedrock/bin/brl list -eE)' -d 'enabled strata or aliases'

complete -f -c brl -n '_brl_arg_is 2 repair' -a '(/bedrock/bin/brl list -aA)' -d 'strata or aliases'

complete -f -c brl -n '_brl_arg_is 2 hide; and _brl_argnum 2' -o 'a' -d 'hide from all subsystems'
complete -f -c brl -n '_brl_arg_is 2 hide; and _brl_argnum 2' -l 'all' -d 'hide from all subsystems'
complete -f -c brl -n '_brl_arg_is 2 hide; and _brl_argnum 2' -o 'b' -d 'do not automatically enable stratum during boot'
complete -f -c brl -n '_brl_arg_is 2 hide; and _brl_argnum 2' -l 'boot' -d 'do not automatically enable stratum during boot'
complete -f -c brl -n '_brl_arg_is 2 hide; and _brl_argnum 2' -o 'c' -d 'do not include stratum files in /bedrock/cross'
complete -f -c brl -n '_brl_arg_is 2 hide; and _brl_argnum 2' -l 'cross' -d 'do not include stratum files in /bedrock/cross'
complete -f -c brl -n '_brl_arg_is 2 hide; and _brl_argnum 2' -o 'i' -d 'do not include stratum init option during boot'
complete -f -c brl -n '_brl_arg_is 2 hide; and _brl_argnum 2' -l 'init' -d 'do not include stratum init option during boot'
complete -f -c brl -n '_brl_arg_is 2 hide' -a '(/bedrock/bin/brl list -aA)' -d 'strata or aliases'

complete -f -c brl -n '_brl_arg_is 2 show; and _brl_argnum 2' -o 'a' -d 'show in all subsystems'
complete -f -c brl -n '_brl_arg_is 2 show; and _brl_argnum 2' -l 'all' -d 'show in all subsystems'
complete -f -c brl -n '_brl_arg_is 2 show; and _brl_argnum 2' -o 'b' -d 'automatically enable stratum during boot'
complete -f -c brl -n '_brl_arg_is 2 show; and _brl_argnum 2' -l 'boot' -d 'automatically enable stratum during boot'
complete -f -c brl -n '_brl_arg_is 2 show; and _brl_argnum 2' -o 'c' -d 'include stratum files in /bedrock/cross'
complete -f -c brl -n '_brl_arg_is 2 show; and _brl_argnum 2' -l 'cross' -d 'include stratum files in /bedrock/cross'
complete -f -c brl -n '_brl_arg_is 2 show; and _brl_argnum 2' -o 'i' -d 'include stratum init option during boot'
complete -f -c brl -n '_brl_arg_is 2 show; and _brl_argnum 2' -l 'init' -d 'include stratum init option during boot'
complete -f -c brl -n '_brl_arg_is 2 show' -a '(/bedrock/bin/brl list -aAi)' -d 'strata or aliases'

complete -f -c brl -n '_brl_arg_is 2 alias; and _brl_argnum 2' -a '(/bedrock/bin/brl list -a)' -d 'stratum'

complete -f -c brl -n '_brl_arg_is 2 deref' -a '(/bedrock/bin/brl list -A)' -d 'aliases'

complete -f -c brl -n '_brl_arg_is 2 update' -o 'm' -d 'specify mirror'
complete -f -c brl -n '_brl_arg_is 2 update' -l 'mirror' -d 'specify mirror'
complete -f -c brl -n '_brl_arg_is 2 fetch' -o 's' -d 'skip cryptographic signature check'
complete -f -c brl -n '_brl_arg_is 2 fetch' -l 'skip-check' -d 'skip cryptographic signature check'

complete -f -c brl -n '_brl_arg_is 2 report; and _brl_argnum 2' -o 'o' -d 'overwrite file at report path'
complete -f -c brl -n '_brl_arg_is 2 report; and _brl_argnum 2' -l 'overwrite' -d 'overwrite file at report path'

