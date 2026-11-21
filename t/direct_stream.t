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
	our @transitionClaims;
	sub directStreamInfoForUrl { return $stream }
	sub claimDirectStreamTransitionForUrl {
		push @transitionClaims, [@_];
		return { reason => 'track', resyncAt => 1 };
	}
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
	sub url { $_[0]->{url} = $_[1] if @_ > 1; $_[0]->{url} }
	sub currentTrack { $_[0] }
}

my $dir = tempdir( CLEANUP => 1 );
my $fifo = File::Spec->catfile( $dir, 'audio.fifo' );
my $fifoCreated = eval { mkfifo( $fifo, 0600 ) == 0 };
plan skip_all => "mkfifo unavailable: " . ( $@ || $! )
	unless $fifoCreated;

$Plugins::SpotifySoloist::Plugin::stream = {
	fifoPath => $fifo,
	format   => {
		key           => 'pcm',
		contentType   => 's32p',
		displayFormat => 'WAV',
		bitrateBps    => 1_411_200,
		sourceBitrateBps => 2_822_400,
		bitrateLabel  => '1411.2 kbps',
		sampleRate    => 44_100,
		sampleSize    => 16,
		sourceSampleSize => 32,
		channels      => 2,
		blockAlign    => 4,
		sourceBlockAlign => 8,
		bufferKb      => 35,
	},
};

my $song = TestSong->new;
my $pcmTranscoder = { streamformat => 'pcm', sampleSize => 32 };
my $handler = Plugins::SpotifySoloist::ProtocolHandler->new({
	url  => 'soloist://player-0/soloist.wav',
	song => $song,
	transcoder => $pcmTranscoder,
});
ok( $handler, 'opens the direct FIFO stream' );
is( $handler->contentType, 's32p', 'declares the Soloist S32-to-PCM source type' );
is( $handler->getStreamBitrate(3_000_000), 2_822_400, 'declares S32LE source bitrate' );
is( $song->samplerate, 44100, 'sets PCM sample rate' );
is( $song->samplesize, 16, 'sets Touch-compatible PCM output sample size after converter selection' );
is( $song->channels, 2, 'sets PCM channels' );
is( $song->blockalign, 4, 'sets S16LE PCM output block alignment' );
is( $pcmTranscoder->{sampleSize}, 16, 'overrides LMS transcoded PCM strm metadata to 16-bit' );

my $writer;
sysopen( $writer, $fifo, O_WRONLY | O_NONBLOCK ) or die "open FIFO writer: $!";
syswrite( $writer, 'audio-one' ) == 9 or die "write first payload: $!";

my $buffer = '';
is( $handler->sysread( $buffer, 44 ), 44, 'prepends a complete WAV header' );
is( substr( $buffer, 0, 4 ), 'RIFF', 'WAV header has RIFF marker' );
is( substr( $buffer, 8, 8 ), 'WAVEfmt ', 'WAV header has format marker' );
is( substr( $buffer, 36, 4 ), 'data', 'WAV header has data marker' );
is( unpack( 'v', substr( $buffer, 32, 2 ) ), 8, 'WAV header declares 8-byte block alignment' );
is( unpack( 'v', substr( $buffer, 34, 2 ) ), 32, 'WAV header declares 32-bit samples' );

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

$Plugins::SpotifySoloist::Plugin::stream->{streamGeneration} = 7;
my $generationSong = TestSong->new;
my $generationHandler = Plugins::SpotifySoloist::ProtocolHandler->new({
	url  => 'soloist://player-0/soloist.wav?g=7',
	song => $generationSong,
	transcoder => { streamformat => 'pcm', sampleSize => 32 },
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
	contentType   => 's32f',
	displayFormat => 'FLAC',
	bitrateLabel  => 'VBR (live stream)',
	sourceBitrateBps => 2_822_400,
	sampleRate    => 44_100,
	sampleSize    => 16,
	sourceSampleSize => 32,
	channels      => 2,
	blockAlign    => 8,
	sourceBlockAlign => 8,
	bufferKb      => 24,
};
my $flacSong = TestSong->new;
my $flacTranscoder = { streamformat => 'flc', sampleSize => 32 };
my $flacHandler = Plugins::SpotifySoloist::ProtocolHandler->new({
	url  => 'soloist://player-0/soloist.flac',
	song => $flacSong,
	transcoder => $flacTranscoder,
});
ok( $flacHandler, 'opens a variable-bitrate FLAC direct stream' );
is( $flacHandler->contentType, 's32f', 'declares the Soloist S32-to-FLAC source type' );
is(
	$flacHandler->getStreamBitrate(1_500_000),
	1_500_000,
	'caps the S32LE source bitrate at the LMS conversion rate limit',
);
is( $flacSong->bitrate, 0, 'leaves live FLAC output bitrate variable' );
is( $flacSong->samplerate, 44_100, 'sets the FLAC output sample rate' );
is( $flacSong->samplesize, 16, 'bounds FLAC output to Touch-compatible 16-bit samples' );
is( $flacSong->channels, 2, 'sets the FLAC output channel count' );
is( $flacTranscoder->{sampleSize}, 16, 'overrides LMS transcoded FLAC metadata to 16-bit' );
close $flacHandler;

my $overrideSong = TestSong->new;
$overrideSong->url('soloist://player-0/soloist.flac');
is(
	Plugins::SpotifySoloist::ProtocolHandler->formatOverride($overrideSong),
	's32f',
	'overrides the source type before LMS selects the conversion rule',
);
is( $overrideSong->samplesize, 32, 'format override publishes S32 source properties before conversion selection' );
is(
	Plugins::SpotifySoloist::ProtocolHandler->canDirectStream(),
	0,
	'S32 source cannot bypass LMS conversion through direct streaming',
);

done_testing;
