use strict;
use warnings;

use Errno qw(EAGAIN EWOULDBLOCK);
use Fcntl qw(O_NONBLOCK O_WRONLY);
use File::Spec;
use File::Temp qw(tempdir);
use POSIX qw(mkfifo);
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

	package Slim::Utils::Strings;
	sub import {
		no strict 'refs';
		*{ caller() . '::cstring' } = sub { $_[1] };
	}
	$INC{'Slim/Utils/Strings.pm'} = __FILE__;

	package Plugins::SpotifySoloist::Plugin;
	our $stream;
	sub directStreamInfoForUrl { return $stream }
}

require './ProtocolHandler.pm';

{
	package TestSong;
	sub new { bless {}, shift }
	sub samplerate { $_[0]->{samplerate} = $_[1] if @_ > 1; $_[0]->{samplerate} }
	sub samplesize { $_[0]->{samplesize} = $_[1] if @_ > 1; $_[0]->{samplesize} }
	sub channels { $_[0]->{channels} = $_[1] if @_ > 1; $_[0]->{channels} }
	sub blockalign { $_[0]->{blockalign} = $_[1] if @_ > 1; $_[0]->{blockalign} }
}

my $dir = tempdir( CLEANUP => 1 );
my $fifo = File::Spec->catfile( $dir, 'audio.fifo' );
my $fifoCreated = eval { mkfifo( $fifo, 0600 ) == 0 };
plan skip_all => "mkfifo unavailable: " . ( $@ || $! )
	unless $fifoCreated;

$Plugins::SpotifySoloist::Plugin::stream = {
	fifoPath => $fifo,
	format   => {
		key         => 'pcm',
		contentType => 'wav',
		bitrateBps  => 1_411_200,
		bufferKb    => 35,
	},
};

my $song = TestSong->new;
my $handler = Plugins::SpotifySoloist::ProtocolHandler->new({
	url  => 'soloist://player-0/soloist.wav',
	song => $song,
});
ok( $handler, 'opens the direct FIFO stream' );
is( $handler->contentType, 'wav', 'declares the LMS WAV content type' );
is( $handler->getStreamBitrate(2_000_000), 1_411_200, 'declares PCM bitrate' );
is( $song->samplerate, 44100, 'sets PCM sample rate' );
is( $song->samplesize, 16, 'sets PCM sample size' );
is( $song->channels, 2, 'sets PCM channels' );
is( $song->blockalign, 4, 'sets PCM block alignment' );

my $writer;
sysopen( $writer, $fifo, O_WRONLY | O_NONBLOCK ) or die "open FIFO writer: $!";
syswrite( $writer, 'audio-one' ) == 9 or die "write first payload: $!";

my $buffer = '';
is( $handler->sysread( $buffer, 44 ), 44, 'prepends a complete WAV header' );
is( substr( $buffer, 0, 4 ), 'RIFF', 'WAV header has RIFF marker' );
is( substr( $buffer, 8, 8 ), 'WAVEfmt ', 'WAV header has format marker' );
is( substr( $buffer, 36, 4 ), 'data', 'WAV header has data marker' );

$buffer = '';
is( $handler->sysread( $buffer, 32 ), 9, 'reads FIFO audio after the header' );
is( $buffer, 'audio-one', 'forwards FIFO audio unchanged' );

select undef, undef, undef, 1.05;
syswrite( $writer, 'stale-audio' ) == 11 or die "write stale payload: $!";
$buffer = '';
my $staleRead = $handler->sysread( $buffer, 32 );
ok(
	!defined $staleRead && ( $! == EAGAIN || $! == EWOULDBLOCK ),
	'starts catch-up instead of forwarding audio queued during an LMS read stall'
);

select undef, undef, undef, 0.30;
$buffer = '';
my $catchupRead = $handler->sysread( $buffer, 32 );
ok(
	!defined $catchupRead && ( $! == EAGAIN || $! == EWOULDBLOCK ),
	'finishes catch-up with the FIFO empty'
);

syswrite( $writer, 'audio-live' ) == 10 or die "write live payload: $!";
$buffer = '';
is( $handler->sysread( $buffer, 32 ), 10, 'reads live audio after catch-up' );
is( $buffer, 'audio-live', 'does not forward the stale queued payload' );

close $writer;
$buffer = '';
my $emptyRead = $handler->sysread( $buffer, 32 );
ok(
	!defined $emptyRead && ( $! == EAGAIN || $! == EWOULDBLOCK ),
	'keeps the FIFO open instead of returning EOF when capture exits'
);

sysopen( $writer, $fifo, O_WRONLY | O_NONBLOCK ) or die "reopen FIFO writer: $!";
syswrite( $writer, 'audio-two' ) == 9 or die "write second payload: $!";
$buffer = '';
is( $handler->sysread( $buffer, 32 ), 9, 'reads audio after capture reconnects' );
is( $buffer, 'audio-two', 'forwards restarted capture audio unchanged' );

close $writer;
close $handler;

done_testing;
