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
	!Plugins::SpotifySoloist::StreamSemantics::isSoloistUrl(
		'https://radio.example/stream.mp3'
	),
	'DSTM suppression remains scoped away from other content',
);

done_testing;
