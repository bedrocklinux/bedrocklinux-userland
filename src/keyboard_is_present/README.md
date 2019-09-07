keyboard_is_present
===================

Detects if Linux system has an initialized keyboard

Usage
-----

Simply run the executable.  It will return zero if a keyboard is detected and
non-zero otherwise.

Installation
------------

Bedrock Linux should be distributed with a script which handles installation,
but just in case:

To compile, run

    make

To install into installdir, run

    make prefix=<installdir> install

To clean up, like usual:

    make clean

And finally, to remove it, run:

    make prefix=<installdir> uninstall
