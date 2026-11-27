use strict;
use warnings;

use Test::More;

require './StreamSemantics.pm';

{
	package TestSong;
	sub new {
		my $class = shift;
		my $self = bless {
			duration => 99,
			startOffset => 88,
			track => bless( {}, 'TestTrack' ),
		}, $class;
		return $self;
	}
	sub currentTrack { $_[0]->{track} }
	sub duration {
		my ($self, $value) = @_;
		$self->{duration} = $value if @_ > 1;
		return $self->{duration};
	}
	sub startOffset {
		my ($self, $value) = @_;
		$self->{startOffset} = $value if @_ > 1;
		return $self->{startOffset};
	}
	sub bitrate { $_[0]->{bitrate} = $_[1] if @_ > 1; $_[0]->{bitrate} }
	sub samplerate { $_[0]->{samplerate} = $_[1] if @_ > 1; $_[0]->{samplerate} }
	sub samplesize { $_[0]->{samplesize} = $_[1] if @_ > 1; $_[0]->{samplesize} }
	sub channels { $_[0]->{channels} = $_[1] if @_ > 1; $_[0]->{channels} }
	sub blockalign { $_[0]->{blockalign} = $_[1] if @_ > 1; $_[0]->{blockalign} }

	package TestTrack;
	sub bitrate { $_[0]->{bitrate} = $_[1] if @_ > 1; $_[0]->{bitrate} }
	sub samplerate { $_[0]->{samplerate} = $_[1] if @_ > 1; $_[0]->{samplerate} }
	sub samplesize { $_[0]->{samplesize} = $_[1] if @_ > 1; $_[0]->{samplesize} }
	sub channels { $_[0]->{channels} = $_[1] if @_ > 1; $_[0]->{channels} }
	sub block_alignment {
		$_[0]->{block_alignment} = $_[1] if @_ > 1;
		$_[0]->{block_alignment};
	}
}

my $trackState = {
	item => {
		entity_type => 'track',
		decorations => { playback => { duration_ms => 210_500 } },
	},
	position => {
		position_ms  => 45_000,
		timestamp_ms => 1_000_000,
		speed        => 1,
	},
};

is(
	Plugins::SpotifySoloist::StreamSemantics::durationSeconds($trackState),
	210.5,
	'converts Spotify track duration from milliseconds to seconds',
);
is(
	Plugins::SpotifySoloist::StreamSemantics::positionSeconds( $trackState, 1_002_000 ),
	47,
	'extrapolates the current position from the Soloist timestamp and speed',
);

my $episodeState = {
	item => {
		entity_type => 'episode',
		decorations => { playback => { duration_ms => 3_600_000 } },
	},
	position => {
		position_ms  => 3_599_000,
		timestamp_ms => 2_000_000,
		speed        => 1,
	},
};
is(
	Plugins::SpotifySoloist::StreamSemantics::durationSeconds($episodeState),
	3600,
	'accepts episode duration from the same playback envelope',
);
is(
	Plugins::SpotifySoloist::StreamSemantics::positionSeconds( $episodeState, 2_005_000 ),
	3600,
	'clamps extrapolated position to the logical item duration',
);

my $song = TestSong->new;
is_deeply(
	Plugins::SpotifySoloist::StreamSemantics::applySongTiming(
		$song,
		$trackState,
		120,
		1_002_000,
	),
	{ duration => 210.5, position => 47 },
	'applies duration and position mapping to the LMS song',
);
is( $song->duration, 210.5, 'updates the LMS song duration' );
is( $song->startOffset, -73, 'offsets continuous transport elapsed time to logical track time' );

Plugins::SpotifySoloist::StreamSemantics::applySongTiming( $song, {}, 121, 1_003_000 );
is( $song->duration, 0, 'clears stale duration when the item has no duration' );
is( $song->startOffset, 0, 'clears stale elapsed mapping with missing item timing' );

is(
	Plugins::SpotifySoloist::StreamSemantics::parseBitrateBps('320k'),
	320_000,
	'parses the standard ffmpeg kilobit bitrate form',
);
is(
	Plugins::SpotifySoloist::StreamSemantics::parseBitrateBps('2M'),
	2_000_000,
	'parses an ffmpeg megabit bitrate form',
);
is(
	Plugins::SpotifySoloist::StreamSemantics::parseBitrateBps('192000'),
	192_000,
	'keeps a raw ffmpeg bits-per-second value in the correct units',
);
ok(
	!defined Plugins::SpotifySoloist::StreamSemantics::parseBitrateBps('fast'),
	'rejects an invalid encoder bitrate',
);
is(
	Plugins::SpotifySoloist::StreamSemantics::bitrateLabel(1_411_200),
	'1411.2 kbps',
	'formats non-integral kilobit rates without losing precision',
);

my $pcmFormat = {
	key           => 'pcm',
	displayFormat => 'WAV',
	contentType   => 'wav',
	bitrateBps    => 1_411_200,
	bitrateLabel  => '1411.2 kbps',
	sampleRate    => 44_100,
	sampleSize    => 16,
	channels      => 2,
	blockAlign    => 4,
};
is_deeply(
	Plugins::SpotifySoloist::StreamSemantics::applySongFormat(
		$song,
		$pcmFormat,
	),
	{
		type       => 'Spotify Soloist (WAV, 1411.2 kbps, 44.1 kHz, 16-bit, stereo)',
		format     => 'WAV',
		ct         => 'wav',
		bitrate    => '1411.2 kbps',
		samplerate => 44_100,
		samplesize => 16,
		channels   => 2,
	},
	'publishes exact final PCM transport metadata',
);
is( $song->bitrate, 1_411_200, 'sets exact PCM bitrate on the LMS song' );
is( $song->samplerate, 44_100, 'sets PCM sample rate on the LMS song' );
is( $song->samplesize, 16, 'sets PCM sample size on the LMS song' );
is( $song->channels, 2, 'sets PCM channel count on the LMS song' );
is( $song->blockalign, 4, 'sets PCM block alignment on the LMS song' );
is( $song->currentTrack->bitrate, 1_411_200, 'sets PCM bitrate on the LMS track' );
is( $song->currentTrack->samplerate, 44_100, 'sets PCM sample rate on the LMS track' );
is( $song->currentTrack->samplesize, 16, 'sets PCM sample size on the LMS track' );

my $mp3Meta = Plugins::SpotifySoloist::StreamSemantics::metadataForFormat({
	key           => 'mp3',
	displayFormat => 'MP3',
	contentType   => 'mp3',
	bitrateBps    => 192_000,
	bitrateLabel  => '192 kbps',
	sampleRate    => 44_100,
	channels      => 2,
});
is( $mp3Meta->{bitrate}, '192 kbps', 'publishes the selected MP3 encoder bitrate' );
is( $mp3Meta->{samplerate}, 44_100, 'publishes the final MP3 sample rate' );
ok( !exists $mp3Meta->{samplesize}, 'does not invent an MP3 sample size' );

my $flacFormat = {
	key           => 'flac',
	displayFormat => 'FLAC',
	contentType   => 'flc',
	bitrateLabel  => 'VBR (live stream)',
	sampleRate    => 44_100,
	sampleSize    => 16,
	channels      => 2,
};
my $flacMeta =
	Plugins::SpotifySoloist::StreamSemantics::applySongFormat( $song, $flacFormat );
is( $flacMeta->{bitrate}, 'VBR (live stream)', 'labels live FLAC bitrate without fabricating precision' );
is( $song->bitrate, 0, 'clears stale numeric bitrate for variable live FLAC' );
is( $song->currentTrack->bitrate, 0, 'clears stale track bitrate for variable live FLAC' );

ok(
	Plugins::SpotifySoloist::StreamSemantics::isSoloistUrl(
		'soloist://player-3/soloist.flac'
	),
	'DSTM suppression recognizes a Soloist stream',
);
ok(
	Plugins::SpotifySoloist::StreamSemantics::isSoloistUrl(
		'soloist://player-3/soloist.wav?g=17'
	),
	'DSTM suppression recognizes a generation-qualified Soloist stream',
);
is(
	Plugins::SpotifySoloist::StreamSemantics::canonicalSoloistUrl(
		'soloist://player-3/soloist.wav?g=17'
	),
	'soloist://player-3/soloist.wav',
	'canonicalizes generation-qualified playback URLs for metadata identity',
);
is(
	Plugins::SpotifySoloist::StreamSemantics::generationSoloistUrl(
		'soloist://player-3/soloist.wav', 17,
	),
	'soloist://player-3/soloist.wav?g=17',
	'builds a deterministic generation-qualified playback URL',
);
is(
	Plugins::SpotifySoloist::StreamSemantics::generationSoloistUrl(
		'soloist://player-3/soloist.wav?g=16', 17,
	),
	'soloist://player-3/soloist.wav?g=17',
	'retrying a generation replaces rather than stacks the token',
);
ok(
	Plugins::SpotifySoloist::StreamSemantics::sameSoloistStream(
		'soloist://player-3/soloist.wav?g=16',
		'soloist://player-3/soloist.wav?g=17',
	),
	'generation URLs retain one canonical per-player stream identity',
);
ok(
	!Plugins::SpotifySoloist::StreamSemantics::sameSoloistStream(
		'soloist://player-3/soloist.wav?g=17',
		'soloist://player-4/soloist.wav?g=17',
	),
	'generation canonicalization does not cross player identities',
);
ok(
	Plugins::SpotifySoloist::StreamSemantics::isCurrentSoloistPlaybackUrl(
		'soloist://player-3/soloist.wav?g=17',
		'soloist://player-3/soloist.wav',
		17,
	),
	'current generation URL is accepted for its canonical stream',
);
ok(
	!Plugins::SpotifySoloist::StreamSemantics::isCurrentSoloistPlaybackUrl(
		'soloist://player-3/soloist.wav?g=16',
		'soloist://player-3/soloist.wav',
		17,
	),
	'stale generation URL cannot claim the current stream',
);
ok(
	!Plugins::SpotifySoloist::StreamSemantics::isCurrentSoloistPlaybackUrl(
		'soloist://player-3/soloist.wav',
		'soloist://player-3/soloist.wav',
		17,
	),
	'canonical startup URL cannot reopen an older active generation',
);
my $generationTrace = {
	generation => 17,
	strmRequestedAt => 10,
};
ok(
	!Plugins::SpotifySoloist::StreamSemantics::delayTracePlayerStatusReady(
		$generationTrace,
		'soloist://player-3/soloist.wav?g=16',
		'soloist://player-3/soloist.wav',
		17,
	),
	'stale status before the new handler opens is not first status for the generation',
);
$generationTrace->{handlerOpenedAt} = 11;
ok(
	!Plugins::SpotifySoloist::StreamSemantics::delayTracePlayerStatusReady(
		$generationTrace,
		'soloist://player-3/soloist.wav?g=16',
		'soloist://player-3/soloist.wav',
		17,
	),
	'status from the outgoing handler is ignored after the replacement handler opens',
);
ok(
	Plugins::SpotifySoloist::StreamSemantics::delayTracePlayerStatusReady(
		$generationTrace,
		'soloist://player-3/soloist.wav?g=17',
		'soloist://player-3/soloist.wav',
		17,
	),
	'post-open status on the exact generation is eligible as first player status',
);
my $timing = Plugins::SpotifySoloist::StreamSemantics::delayTraceTimingSummary({
	startedAt => 20,
	generationFlushAt => 20.010,
	strmRequestedAt => 20.012,
	oldHandlerClosedAt => 20.013,
	handlerOpenedAt => 20.257,
	firstWavAt => 20.315,
	firstPcmAt => 20.326,
	playerStatusAt => 20.430,
});
is( $timing->{category}, 'handler_reopen', 'transition timing classifies the largest phase' );
is( $timing->{track_at}, '20.000', 'transition timing includes the track milestone time' );
is( $timing->{flush_at}, '20.010', 'transition timing includes the flush milestone time' );
is( $timing->{strm_at}, '20.012', 'transition timing includes the STRM milestone time' );
is( $timing->{close_at}, '20.013', 'transition timing includes the close milestone time' );
is( $timing->{open_at}, '20.257', 'transition timing includes the open milestone time' );
is( $timing->{wav_at}, '20.315', 'transition timing includes the WAV milestone time' );
is( $timing->{pcm_at}, '20.326', 'transition timing includes the PCM milestone time' );
is( $timing->{status_at}, '20.430', 'transition timing includes the status milestone time' );
is( $timing->{track_to_flush_ms}, 10, 'transition timing measures generation flush latency' );
is( $timing->{flush_to_strm_ms}, 2, 'transition timing measures STRM handoff latency' );
is( $timing->{close_to_open_ms}, 244, 'transition timing measures LMS handler replacement latency' );
is( $timing->{open_to_wav_ms}, 58, 'transition timing measures first WAV availability' );
is( $timing->{open_to_pcm_ms}, 69, 'transition timing measures first PCM availability' );
is( $timing->{pcm_to_status_ms}, 104, 'transition timing measures player/device buffering' );
is( $timing->{track_to_status_ms}, 430, 'transition timing reports total transition latency' );
my $progressTrace = {};
ok(
	!Plugins::SpotifySoloist::StreamSemantics::observePlayerProgressStall(
		$progressTrace, 10, 100, 1,
	),
	'first player progress observation establishes a baseline',
);
ok(
	!Plugins::SpotifySoloist::StreamSemantics::observePlayerProgressStall(
		$progressTrace, 10, 100.9, 1,
	),
	'unchanged player progress below one second is not a stall',
);
my $progressStall =
	Plugins::SpotifySoloist::StreamSemantics::observePlayerProgressStall(
		$progressTrace, 10, 101.1, 1,
	);
cmp_ok( $progressStall->{gapMs}, '>=', 1_000, 'one-second player progress stall is reported' );
ok(
	!Plugins::SpotifySoloist::StreamSemantics::observePlayerProgressStall(
		$progressTrace, 10, 102, 1,
	),
	'player progress stall is logged once until progress resumes',
);
ok(
	!Plugins::SpotifySoloist::StreamSemantics::observePlayerProgressStall(
		$progressTrace, 10.5, 102.1, 1,
	),
	'resumed player progress clears the stall latch',
);
ok(
	!Plugins::SpotifySoloist::StreamSemantics::observePlayerProgressStall(
		$progressTrace, 0.1, 102.2, 1,
	),
	'natural elapsed reset is treated as progress rather than a stall',
);
ok(
	!Plugins::SpotifySoloist::StreamSemantics::observePlayerProgressStall(
		$progressTrace, undef, 103, 0,
	),
	'leaving active playback resets player progress tracking',
);
ok(
	!Plugins::SpotifySoloist::StreamSemantics::isSoloistUrl(
		'https://radio.example/stream.mp3'
	),
	'DSTM suppression remains scoped away from other content',
);

my $timeline = {};
my $firstState = {
	item     => { uri => 'spotify:track:first', decorations => {} },
	position => { position_ms => 120_000 },
};
ok(
	!Plugins::SpotifySoloist::StreamSemantics::observeTimelineTransition(
		$timeline, $firstState, 10,
	),
	'initial timeline observation does not request a stream replacement',
);

my $sameTrackEnriched = {
	item => {
		uri         => 'spotify:track:first',
		decorations => { identity => { name => 'Enriched title' } },
	},
	position => { position_ms => 121_000 },
};
ok(
	!Plugins::SpotifySoloist::StreamSemantics::observeTimelineTransition(
		$timeline, $sameTrackEnriched, 10.1,
	),
	'same-track metadata enrichment does not request a replacement',
);

my $newTrackBeforeReset = {
	item     => { uri => 'spotify:track:second', decorations => {} },
};
my $trackTransition =
	Plugins::SpotifySoloist::StreamSemantics::observeTimelineTransition(
		$timeline, $newTrackBeforeReset, 10.2,
	);
is( $trackTransition->{reason}, 'track', 'detects a genuine logical track identity change' );
ok(
	!Plugins::SpotifySoloist::StreamSemantics::timelineResyncReady(
		$trackTransition, $newTrackBeforeReset, 10.2,
	),
	'waits for the new track position/audio timeline instead of reopening too early',
);

my $newTrackReset = {
	item     => { uri => 'spotify:track:second', decorations => {} },
	position => { position_ms => 250 },
};
ok(
	Plugins::SpotifySoloist::StreamSemantics::timelineResyncReady(
		$trackTransition, $newTrackReset, 10.3,
	),
	'requests live-edge resync as soon as the new track position resets',
);
ok(
	!Plugins::SpotifySoloist::StreamSemantics::observeTimelineTransition(
		$timeline, $newTrackReset, 10.3,
	),
	'does not request a second replacement for the same logical track',
);

my $snapshotOnlyTransition = {
	item     => { uri => 'spotify:episode:third', decorations => {} },
	position => { position_ms => 20_000 },
};
my $snapshotTransition =
	Plugins::SpotifySoloist::StreamSemantics::observeTimelineTransition(
		$timeline, $snapshotOnlyTransition, 20,
	);
is(
	$snapshotTransition->{reason},
	'track',
	'detects URI changes from full playback snapshots without a track_changed event',
);
ok(
	Plugins::SpotifySoloist::StreamSemantics::timelineResyncReady(
		$snapshotTransition, $snapshotOnlyTransition, 20.8,
	),
	'uses a bounded fallback when a URI change arrives without a fresh position reset',
);

my $backwardSeek = {
	item     => { uri => 'spotify:episode:third', decorations => {} },
	position => { position_ms => 5_000 },
};
my $seekTransition =
	Plugins::SpotifySoloist::StreamSemantics::observeTimelineTransition(
		$timeline, $backwardSeek, 21,
	);
is( $seekTransition->{reason}, 'backward-seek', 'detects a meaningful backward seek' );
ok(
	Plugins::SpotifySoloist::StreamSemantics::timelineResyncReady(
		$seekTransition, $backwardSeek, 21,
	),
	'backward seeks request an immediate live-edge resync',
);

my $naturalTimeline = {};
my $nearEnd = {
	item => {
		uri => 'spotify:track:natural-first',
		decorations => { playback => { duration_ms => 180_000 } },
	},
	position => {
		position_ms  => 500,
		timestamp_ms => 1_000,
		speed        => 1,
	},
};
Plugins::SpotifySoloist::StreamSemantics::observeTimelineTransition(
	$naturalTimeline, $nearEnd, 30, 179_000,
);
my $naturalNext = {
	item => {
		uri => 'spotify:track:natural-second',
		decorations => { playback => { duration_ms => 200_000 } },
	},
	position => { position_ms => 100 },
};
my $naturalTransition =
	Plugins::SpotifySoloist::StreamSemantics::observeTimelineTransition(
		$naturalTimeline, $naturalNext, 30.5, 179_500,
	);
is(
	$naturalTransition->{reason},
	'natural-track',
	'detects an expected end-of-track URI change',
);
ok(
	!$naturalTransition->{requiresResync},
	'natural gapless transitions retain the current playback URL and handler',
);

my $manualTimeline = {};
my $midTrack = {
	item => {
		uri => 'spotify:track:manual-first',
		decorations => { playback => { duration_ms => 240_000 } },
	},
	position => { position_ms => 90_000 },
};
Plugins::SpotifySoloist::StreamSemantics::observeTimelineTransition(
	$manualTimeline, $midTrack, 40,
);
my $manualTransition =
	Plugins::SpotifySoloist::StreamSemantics::observeTimelineTransition(
		$manualTimeline,
		{
			item => {
				uri => 'spotify:track:manual-second',
				decorations => { playback => { duration_ms => 210_000 } },
			},
			position => { position_ms => 0 },
		},
		40.1,
	);
is( $manualTransition->{reason}, 'track', 'manual playlist changes remain discontinuous' );
ok( $manualTransition->{requiresResync}, 'manual playlist changes require a new URL generation' );

is(
	Plugins::SpotifySoloist::StreamSemantics::shimGenerationCommand(
		7, 'backward seek',
	),
	"7 backward-seek\n",
	'formats a safe atomic shim request command',
);
ok(
	Plugins::SpotifySoloist::StreamSemantics::shimGenerationAcknowledged(
		"7 12 backward-seek\n", 7,
	),
	'accepts a matching request acknowledgement with an independent audio generation',
);
ok(
	!Plugins::SpotifySoloist::StreamSemantics::shimGenerationAcknowledged(
		"8 12 track\n", 7,
	),
	'rejects an acknowledgement for another request',
);

done_testing;
