use strict;
use warnings;

use Test::More;

require './StreamSemantics.pm';

{
	package TestSong;
	sub new { bless { duration => 99, startOffset => 88 }, shift }
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
