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
	our @info;
	sub info { push @info, $_[1] }
	sub warn { push @info, $_[1] }

	package Slim::Utils::Strings;
	sub import {
		no strict 'refs';
		*{ caller() . '::cstring' } = sub { $_[1] };
	}
	$INC{'Slim/Utils/Strings.pm'} = __FILE__;

	package Plugins::SpotifySoloist::Plugin;
	our $stream;
	our @transitionClaims;
	our @protocolMilestones;
	our @midstreamStalls;
	sub directStreamInfoForUrl { return $stream }
	sub claimDirectStreamTransitionForUrl {
		push @transitionClaims, [@_];
		return { reason => 'track', resyncAt => 1 };
	}
	sub noteDelayTraceProtocolMilestone { push @protocolMilestones, [@_] }
	sub noteMidstreamStall { push @midstreamStalls, [@_] }
}

require './StreamSemantics.pm';
require './ProtocolHandler.pm';

{
	package TestSong;
	sub new { bless {}, shift }
	sub bitrate { $_[0]->{bitrate} = $_[1] if @_ > 1; $_[0]->{bitrate} }
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
	playerId => 'test-player-0',
	delayDiagnostics => 1,
	format   => {
		key           => 'pcm',
		contentType   => 'wav',
		displayFormat => 'WAV',
		bitrateBps    => 1_411_200,
		sourceBitrateBps => 1_411_200,
		sourceSampleSize => 16,
		sourceBlockAlign => 4,
		bitrateLabel  => '1411.2 kbps',
		sampleRate    => 44_100,
		sampleSize    => 16,
		channels      => 2,
		blockAlign    => 4,
		bufferKb      => 35,
	},
};

my $song = TestSong->new;
my $handler = Plugins::SpotifySoloist::ProtocolHandler->new({
	url  => 'soloist://player-0/soloist.wav',
	song => $song,
});
ok( $handler, 'opens the direct FIFO stream' );
like(
	join( "\n", @TestLogger::info ),
	qr/milestone=protocol-handler-new .*trace_client_id=test-player-0 .*generation=0 .*canonical=soloist:\/\/player-0\/soloist\.wav/,
	'diagnostic creation milestone identifies the LMS client and generation',
);
like(
	join( "\n", @TestLogger::info ),
	qr/milestone=protocol-handler-open .*trace_client_id=test-player-0 .*generation=0 .*canonical=soloist:\/\/player-0\/soloist\.wav/,
	'diagnostic open milestone carries canonical URL and generation',
);
is_deeply(
	[
		@{
			$Plugins::SpotifySoloist::Plugin::protocolMilestones[0]
		}[ 0 .. 2 ]
	],
	[ 'test-player-0', 0, 'handler-open' ],
	'protocol open associates the handler with the exact trace generation',
);
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
like(
	join( "\n", @TestLogger::info ),
	qr/milestone=protocol-first-sysread .*trace_client_id=test-player-0 .*requested_bytes=44/,
	'diagnostic trace records the first LMS read request',
);
like(
	join( "\n", @TestLogger::info ),
	qr/milestone=protocol-wav-prefix .*generation=0 .*bytes=44/,
	'diagnostic trace records the first WAV bytes once',
);

$buffer = '';
is( $handler->sysread( $buffer, 32 ), 9, 'reads FIFO audio after the header' );
is( $buffer, 'audio-one', 'forwards FIFO audio unchanged' );
like(
	join( "\n", @TestLogger::info ),
	qr/milestone=protocol-first-pcm-read .*generation=0 .*bytes=9/,
	'diagnostic trace records the first FIFO audio read',
);

select undef, undef, undef, 1.05;
syswrite( $writer, 'stale-audio' ) == 11 or die "write stale payload: $!";
$buffer = '';
my $staleRead = $handler->sysread( $buffer, 32 );
ok(
	!defined $staleRead && ( $! == EAGAIN || $! == EWOULDBLOCK ),
	'starts catch-up instead of forwarding audio queued during an LMS read stall'
);
is( scalar @Plugins::SpotifySoloist::Plugin::midstreamStalls, 1, 'read gap emits one correlated midstream stall event' );
my %stallFields = @{
	$Plugins::SpotifySoloist::Plugin::midstreamStalls[0]
}[ 3 .. $#{ $Plugins::SpotifySoloist::Plugin::midstreamStalls[0] } ];
is(
	$stallFields{source},
	'protocol-read-gap',
	'midstream stall event identifies the protocol read gap source',
);

select undef, undef, undef, 0.30;
$buffer = '';
my $catchupRead = $handler->sysread( $buffer, 32 );
ok(
	!defined $catchupRead && ( $! == EAGAIN || $! == EWOULDBLOCK ),
	'finishes catch-up with the FIFO empty'
);
is(
	scalar @Plugins::SpotifySoloist::Plugin::midstreamStalls,
	1,
	'catch-up does not flood duplicate midstream stall events',
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
$handler->close;
$handler->close;
like(
	join( "\n", @TestLogger::info ),
	qr/milestone=protocol-handler-close .*generation=0/,
	'diagnostic trace records handler closure',
);
is(
	scalar( grep { /milestone=protocol-handler-close/ } @TestLogger::info ),
	1,
	'duplicate LMS close callbacks emit one close milestone',
);

$Plugins::SpotifySoloist::Plugin::stream->{streamGeneration} = 7;
my $generationSong = TestSong->new;
my $generationHandler = Plugins::SpotifySoloist::ProtocolHandler->new({
	url  => 'soloist://player-0/soloist.wav?g=7',
	song => $generationSong,
});
ok( $generationHandler, 'generation-qualified PCM URL opens the same player FIFO' );
is_deeply(
	$Plugins::SpotifySoloist::Plugin::transitionClaims[-1],
	[ 'soloist://player-0/soloist.wav?g=7', 7 ],
	'handler claims transition context only for its URL generation',
);
$buffer = '';
is( $generationHandler->sysread( $buffer, 44 ), 44, 'new generation emits a fresh WAV header' );
close $generationHandler;

$Plugins::SpotifySoloist::Plugin::stream->{format} = {
	key           => 'flac',
	contentType   => 's16f',
	displayFormat => 'FLAC',
	bitrateLabel  => 'VBR (live stream)',
	sourceBitrateBps => 1_411_200,
	transcodeBitrateBps => 1_411_200,
	sourceSampleSize => 16,
	sourceBlockAlign => 4,
	sampleRate    => 44_100,
	sampleSize    => 16,
	channels      => 2,
	bufferKb      => 24,
};
my $flacSong = TestSong->new;
my $flacHandler = Plugins::SpotifySoloist::ProtocolHandler->new({
	url  => 'soloist://player-0/soloist.flac',
	song => $flacSong,
});
ok( $flacHandler, 'opens the S16 source selected for LMS FLAC conversion' );
is( $flacHandler->contentType, 's16f', 'declares the custom LMS S16-to-FLAC source type' );
is(
	$flacHandler->getStreamBitrate(1_500_000),
	1_411_200,
	'declares the exact S16 source bitrate to the LMS converter',
);
is( $flacSong->bitrate, 1_411_200, 'sets the LMS converter input bitrate' );
is( $flacSong->samplerate, 44_100, 'sets the converter input sample rate' );
is( $flacSong->samplesize, 16, 'sets the converter input sample size' );
is( $flacSong->channels, 2, 'sets the converter input channel count' );
$buffer = '';
is( $flacHandler->sysread( $buffer, 44 ), 44, 'FLAC conversion source starts with a WAV header' );
is( substr( $buffer, 0, 4 ), 'RIFF', 'FLAC conversion source header is WAV' );
close $flacHandler;

done_testing;
