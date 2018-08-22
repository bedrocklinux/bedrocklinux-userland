etcfs
=====

etcfs is a virtual filesystem which redirects file access to either the global
stratum's instance of a file, or the calling process' local stratum instance of
a file.  It may also modify files as needed to enforce specific file content,
such as configuration file values.

Configuration
-------------

etcfs creates a virtual `.bedrock-config-filesystem` file in the root of its
mount point to handle its configuration.  `.bedrock-config-filesystem` may be
read to get the current configuration and is written to by `brl reload`.

Installation
------------

Bedrock Linux should be distributed with a script which handles installation,
but just in case:

The dependencies are:

- libfuse

To compile, run

    make

To install into installdir, run

    make prefix=<installdir> install

To clean up, like usual:

    make clean

And finally, to remove it, run:

    make prefix=<installdir> uninstall
