use strict;
use warnings;

use Errno qw(EAGAIN EWOULDBLOCK);
use Fcntl qw(O_APPEND O_RDWR O_WRONLY);
use File::Temp qw(tempfile);
use Test::More;

BEGIN {
	package Slim::Player::ProtocolHandlers;
	sub registerHandler { }
	$INC{'Slim/Player/ProtocolHandlers.pm'} = __FILE__;

	package Slim::Utils::Log;
	sub import {
		no strict 'refs';
		*{ caller() . '::logger' } = sub { bless {}, 'TestLogger' };
	}
	$INC{'Slim/Utils/Log.pm'} = __FILE__;

	package TestLogger;
	sub debug { }
	sub error { }
	sub info { }

	package Plugins::SpotifySoloist::Plugin;
	our @recovery;
	sub recoverDirectStreamAfterStall { push @recovery, [@_] }

	package Slim::Utils::Strings;
	sub import {
		no strict 'refs';
		*{ caller() . '::cstring' } = sub { $_[1] };
	}
	$INC{'Slim/Utils/Strings.pm'} = __FILE__;
}

require './ProtocolHandler.pm';

my ( undef, $path ) = tempfile();
my ( $reader, $writer );
sysopen( $reader, $path, O_RDWR ) or die "open reader: $!";
sysopen( $writer, $path, O_WRONLY | O_APPEND ) or die "open writer: $!";
bless $reader, 'Plugins::SpotifySoloist::ProtocolHandler';

${*$reader}{prefix} = '';
${*$reader}{client} = bless {}, 'TestClient';
${*$reader}{url} = 'soloist://player-0/soloist.wav';
${*$reader}{lastAudioReadAt} = undef;
${*$reader}{staleDrainUntil} = undef;
${*$reader}{staleBytesDiscarded} = 0;

syswrite( $writer, 'audio-one' ) == 9 or die "write first payload: $!";
my $buffer = '';
is( $reader->sysread( $buffer, 32 ), 9, 'reads uninterrupted audio normally' );
is( $buffer, 'audio-one', 'normal audio is unchanged' );

select undef, undef, undef, 1.05;
syswrite( $writer, 'stale-audio' ) == 11 or die "write stale payload: $!";
$buffer = '';
my $staleRead = $reader->sysread( $buffer, 32 );
ok(
	!defined $staleRead && ( $! == EAGAIN || $! == EWOULDBLOCK ),
	'does not return audio queued across a read stall'
);

select undef, undef, undef, 0.30;
$buffer = '';
my $catchupRead = $reader->sysread( $buffer, 32 );
ok(
	!defined $catchupRead && ( $! == EAGAIN || $! == EWOULDBLOCK ),
	'finishes the bounded catch-up window with the source empty'
);
is( scalar @Plugins::SpotifySoloist::Plugin::recovery, 1, 'requests one downstream buffer reset' );
is(
	$Plugins::SpotifySoloist::Plugin::recovery[0]->[2],
	11,
	'reports the discarded stale byte count'
);

syswrite( $writer, 'audio-live' ) == 10 or die "write live payload: $!";
$buffer = '';
is( $reader->sysread( $buffer, 32 ), 10, 'resumes with newly produced audio' );
is( $buffer, 'audio-live', 'stale audio was discarded before resuming' );

close $writer;
close $reader;
unlink $path;

done_testing;
