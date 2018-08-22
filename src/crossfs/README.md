crossfs
=======

crossfs is a virtual filesystem which dynamically populates a specified
directory with content from other strata, modified as necessary so the files
are consumable across strata.  For example, it wraps binary executables so that
they are implicit run through strat to the appropriate stratum.

crossfs takes the typical libfuse arguments such as `-o allow_other` and `-f`.
See libfuse for details.

Configuration
-------------

crossfs creates a virtual `.bedrock-config-filesystem` file in the root of its
mount point to handle its configuration.  `.bedrock-config-filesystem` may be
read to get the current configuration and is written to by `brl reload`.

Installation
------------

Bedrock Linux should be distributed with a script which handles installation,
but just in case:

The dependencies are:

- libfuse
- uthash

To compile, run

    make

To install into installdir, run

    make prefix=<installdir> install

To clean up, like usual:

    make clean

And finally, to remove it, run:

    make prefix=<installdir> uninstall
