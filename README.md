Rolling Release Of Kreyrock Linux Userland
======================

Do you have an issue? Then go fuck yourself with it! Make Merge Request like a real man or use Original Fork (https://github.com/bedrocklinux/bedrocklinux-userland) this ain't no noob distro for babysitting

Kreyrock Linux is a Linux distribution composed of user-selected components from
various other Linux distributions.  For example, with Kreyrock one may use the
installation process from one distribution, the init from another, a window
manager from a third, and a web browser from a fourth.  Kreyrock strives to make
these components work together as transparently as possible such that for
day-to-day operations it is not readily evident that the various components
were originally intended for disparate distributions.

This repository contains all the userland code for a Kreyrock Linux system.  It
can create a script which may be used to install or update a Kreyrock Linux
system.

Building the installer/updater
------------------------------

On a Linux system, install the build dependencies:

- Standard UNIX utilities: grep, sed, awk, etc.
- gcc 4.9.1 or newer
- git 1.8 or newer
- meson 0.38 or newer
- ninja-build
- libtool
- autoconf
- pkg-config
- fakeroot
- make
- gzip
- gpg (optional)

Ensure you have internet access (to fetch upstream dependencies), then run:

	make GPGID=<gpg-id-with-which-to-sign>

to build a signed install/update script or

	make SKIPSIGN=true

to build an unsigned install/update script.

The build process can be customized in the same fashion as most make and C
projects:

- You may use `-jN` to tell make to parallelize the build process with `N`
  jobs.
- You may set `CFLAGS` to pass flags to the C compiler such as `-Os` and
  `-march=native`.
	- Kreyrock's components *must* be statically compiled.  The build system
	  sets `-static` in various places.  Do not set `-dynamic` or otherwise
	  try to change away from a static build.

This will produce a script such as:

	Kreyrock-linux-0.7-x86_64.sh

which may be used to install or update a Kreyrock Linux system.

Installation

- Install another, traditional Linux distribution.
	- Select a filesystem which supports extended filesystem attributes.
- Setup users, networking, etc as one would typically do.
- Reboot into the fresh install.
- Get the `Kreyrock-linux-<version>-<arch>.sh` script onto the system, either by
  building it locally or getting a pre-built version from elsewhere.
- Run the script as root with the `--hijack` flag.
- Follow the prompts.
- Reboot.  Re-select the new install at any bootloader prompt.
- You're now running Kreyrock Linux, but with only the initial install's files.
  To leverage Kreyrock's features, we need other distribution's files as well.
- Run `brl fetch --list` to see the various distributions which Kreyrock knows
  how to fetch.
- As root, run `brl fetch <distros>` to acquire upstream distribution files.
	- If this fails, you may need to manually look up release and mirror
	  information for the desired distribution and provide the information
	  with `--release` and `--mirror` flags.

Basic usage
-----------

A Kreyrock Linux system is composed of "strata".  These are collections of
interrelated files.  These are often, but not always, one-to-one with other,
traditional Linux distributions.  Kreyrock integrates these strata together,
creating a single, largely cohesive system with desirable features from other
distributions.

To list the currently installed (and enabled) strata, run:

	$ brl list

To list distros which can be easily acquired as strata, run:

	$ brl fetch --list

To acquire new strata, run (as root):

	# brl fetch <distros>

Once that has completed, you may run commands from the new strata.  For
example, the following series of commands make sense on a Kreyrock system:

	$ sudo brl fetch arch debian
	$ sudo pacman -S mupdf && sudo apt install texlive
	$ man pdflatex
	$ pdflatex preexisting-file.tex && mupdf preexisting-file.pdf

Kreyrock's integration is not limited to the command line.  For example,
graphical application menus or launchers will automatically pick up
applications across strata, and Xorg fonts installed from one stratum will be
picked up in an X11 graphical application from another stratum.

If there are multiple instances of an executable, Kreyrock will select one by
default in a given context.  If there are hints it can pick up on for which one
to use, it is normally correct.  `brl which` can be used to query which Kreyrock
will select in a given context.  For example:

	$ # arch, debian, and centos are installed.
	$ # running debian's init, and thus must use debian's reboot
	$ sudo brl which -b reboot
	debian
	$ # only arch provides pacman, so arch's pacman will be used
	$ brl which -b pacman
	arch
	$ # yum is a python script.  Since yum comes from centos, the python
	$ # interpreter used to run yum will also come from centos.
	$ sudo yum update
	^Z
	$ brl which $(pidof python | cut -d' ' -f1)
	centos

If you would like a specific instance, you may select it with `strat`:

	$ # arch, debian, and ubuntu are installed
	$ # install vlc from arch
	$ sudo pacman -S vlc
	$ # install vlc from debian
	$ sudo strat debian apt install vlc
	$ # install vlc from ubuntu
	$ sudo strat ubuntu apt install vlc
	$ # run default vlc
	$ vlc /path/to/video
	$ # run arch's vlc
	$ strat arch vlc /path/to/video
	$ # run debian's vlc
	$ strat debian vlc /path/to/video
	$ # run ubuntu's vlc
	$ strat ubuntu vlc /path/to/video

To avoid conflicts, processes from one stratum may see its own stratum's
instance of a given file.  For example, Debian's `apt` and Ubuntu's `apt` must
both see their own instance of `/etc/apt/sources.list`.  Other files must be
shared across strata to ensure they work together, and thus all strata see the
same file.  For example, `/home`.  Such shared files are referred to as
"global".  Which stratum provides a file in a given context can be queried by
`brl which`:

	$ # which stratum is my shell from?
	$ brl which --pid $$
	gentoo
	$ # that query is common enough the PID may be dropped
	$ brl which
	gentoo
	$ # which stratum provides ~/.vimrc
	$ brl which --filepath ~/.vimrc
	global
	$ # global indicates all stratum seem the same file; not specific to any
	$ # stratum.
	$ brl which --filepath /bin/bash
	gentoo
	$ brl which --bin pacman
	arch

If you would like to specify which non-global file to read or write, prefix
`/Kreyrock/strata/<stratum>/` to its path.

	$ brl which --filepath /Kreyrock/strata/debian/etc/apt/sources.list
	debian
	$ brl which --filepath /Kreyrock/strata/ubuntu/etc/apt/sources.list
	ubuntu
	$ # edit debian's sources.list with ubuntu's vi
	$ strat ubuntu vi /Kreyrock/strata/debian/etc/apt/sources.list

`brl` provides much more functionality which can be read from `brl --help`.

A concrete list of everything Kreyrock can integrate, work-arounds for known
limitations, and other useful information may be found at Kreyrocklinux.org.

Hacking
-------

To sanity check your work (e.g. before upstream changes to Kreyrock Linux),
install:

- shellcheck
- cppcheck
- clang
- gcc
- tcc
- scan-build (usually distributed with clang)
- shfmt (https://github.com/mvdan/sh)
- indent (GNU)
- uthash
- libfuse3
- libcap
- libattr

Run

	make format

to standardize the formatting of any changes you may have made, then run

	make check

to run various sanity checks against the code base.

Where To Get Help
-----------------

- Wiki: http://kreyrock.rixotstudio.cz/wiki/Main_Page
- IRC: `#Bedrock-kreyren` on irc.freenode.net
	- https://webchat.freenode.net/?channels=Kreyrock
