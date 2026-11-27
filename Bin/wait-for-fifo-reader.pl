#!/usr/bin/env perl

use strict;
use warnings;

use Errno qw(EINTR ENOENT ENXIO);
use Fcntl qw(O_NONBLOCK O_WRONLY);
use Time::HiRes qw(sleep);

my ( $fifo, $source_pid ) = @ARGV;
die "usage: $0 FIFO SOURCE_PID\n"
	unless defined $fifo && defined $source_pid && $source_pid =~ /^\d+$/;

while ( kill 0, $source_pid ) {
	my $writer;
	if ( sysopen( $writer, $fifo, O_WRONLY | O_NONBLOCK ) ) {
		close $writer;
		exit 0;
	}

	if ( $! == ENXIO || $! == ENOENT || $! == EINTR ) {
		sleep 0.02;
		next;
	}

	die "cannot probe final FIFO '$fifo' for an LMS reader: $!\n";
}

exit 2;
