strat
=====

strat runs the specified Bedrock Linux stratum's instance of an executable.

Usage
-----

To use, run:

    strat <stratum-name> <command-to-run>

Consider, for example, a Bedrock Linux install with both Debian and Ubuntu
strata.  If one would like to search for a package that provides vim, one could run:

    apt search vim

However, which instance of apt - Debian's or Ubuntu's - is in use is
context-dependent, which may not be desired.  To explicitly specify which to
use, one should use strat.  For example, to search Debian's repositories for vim,
one could run:

    strat debian apt search vim

Or to search Ubuntu's, one could run:

    strat ubuntu apt search vim

Some commands require a specific argv[0].  To explicitly set this, use `-a` or
`--arg0`.  For example:

    strat --arg0 ls gentoo busybox

It is often useful to restrict a given process to only the executables provided
by its local stratum.  For example, this helps avoid mixing dependencies across
strata when compiling.  To enforce this for the duration of a given command,
run with `-l` or `--local`.  For example:

    strat --local arch makepkg

Installation
------------

Bedrock Linux should be distributed with a script which handles installation,
but just in case:

The dependencies are:

- libcap (can be found here: https://sites.google.com/site/fullycapable/)

To compile, run

    make

To install into installdir, run

    make prefix=<installdir> install

Then proceed to use "setcap" to set the "cap_sys_chroot=ep" capability on the
installed brc executable:

    /bedrock/libexec/setcap cap_sys_chroot=ep /path/to/strat

To clean up, like usual:

    make clean

And finally, to remove it, run:

    make prefix=<installdir> uninstall
