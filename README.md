Bedrock Linux 1.0alpha3 Bosco userland
======================================

This is the bulk of the userland for Bedrock Linux.  Further information can be
found at [http://bedrocklinux.org](http://bedrocklinux.org).

Specifically, this is the README and files for the third alpha, Bosco.  More
information about this release of Bedrock Linux can be found here:
[http://bedrocklinux.org/1.0alpha3/](http://bedrocklinux.org/1.0alpha3/).

You should probably read everything there before continuing to do anything with
these files, if you have not already.  The instructions in this README are not
sufficient on their own.

Installation
============

Unpackage
---------

First, unpackage the files in the location you would like Bedrock Linux to be
installed.  If you received this as a tarball, you can run:

    cd /path/to/bedrock's/root/directory
    tar xvf bedrock-userland-1.0alpha3.tar.gz

Or, if you are cloning this from git:

    cd /path/to/bedrock's/root/directory
    git clone https://github.com/paradigm/bedrocklinux-userland.git .
    mv * .. && cd ..

Compile binaries
----------------

To compile Bedrock Linux's binaries, run (as a normal user or root):

    make

If you get an error about a missing library (such as sys/capabilitiy.h),
install the corresponding package and try again.  On Debian-based systems, the
package for that specific library is libcap-dev.

Install
-------

Once you succeed in compiling, run (as root):

    make install

If this complaints about setcap, install the package which contains setcap and
try again.  On Debian-based systems, the package for setcap is libcap2-bin.

This will install the compiled binaries, ensure the directory structure isn't
missing empty directories (as git does not track them, they can easily be left
behind), and sets permissions.

Cleanup
-------

If all of the above worked, there are some left over files you are free to
remove, such as:

- the tarball itself, if you received this as a tarball
- the ".git" directory, if you received this through git
- the contents of the src directory
- the README and LICENSE files (if you have them - the tarball should not come
  with them)
- the Makefile files.

You can manually remove those of these you'd like, or if you prefer, you can
use the following to remove all of them (as root):

    make remove-unnecessary

Other components
----------------

You will still need to install the other components (the bootloader, the
kernel, and busybox), go through the configuration files, add users, and add
clients.  URL at the top for instructions on how to go about doing this.

Development
===========

If you'd like to develop with this, note that:

The following will clean up files which could have been created in development
that we probably don't care to track in git, and should probably be run
directly before commiting:

    make clean

You can use the following to create a tarball:

    make package

Note "make package" will remove things you want to keep in the repository but
not in the tarball, such as this README - be sure to reset the changes before
your next commit.
