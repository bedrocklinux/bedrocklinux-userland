bouncer
=======

bouncer redirects calls to another executable based on the following xattrs as
set on the bouncer executable:

- `user.bedrock.stratum` indicates the stratum which should provide the
  executable
- `user.bedrock.localpath` indicates stratum-local path of the desired
  executable

bouncer passes its arg0 to the executable it is calling.  This is in contrast
to a hashbang file such as:

	#!/bin/sh
	exec strat <stratum> <local-path>

which would lose its argv[0].

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
