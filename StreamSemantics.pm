package Plugins::SpotifySoloist::StreamSemantics;

use strict;
use warnings;

use Scalar::Util qw(looks_like_number);
use Time::HiRes ();

use constant BACKWARD_SEEK_THRESHOLD_MS => 2_000;
use constant TRACK_RESET_POSITION_MS     => 5_000;
use constant TRACK_RESET_TIMEOUT_SECONDS => 0.75;

sub isSoloistUrl {
	my ($url) = @_;
	return defined $url && $url =~ m{\Asoloist://player-\d+/soloist\.[A-Za-z0-9]+\z} ? 1 : 0;
}

sub monotonicNow {
	my $now = eval {
		Time::HiRes::clock_gettime( Time::HiRes::CLOCK_MONOTONIC() );
	};
	return defined $now ? $now : Time::HiRes::time();
}

sub parseBitrateBps {
	my ($value) = @_;
	return unless defined $value;
	return unless $value =~ /\A\s*(\d+(?:\.\d+)?)\s*([kKmM]?)\s*\z/;

	my ( $number, $suffix ) = ( $1 + 0, lc $2 );
	my $multiplier = $suffix eq 'm' ? 1_000_000
		: $suffix eq 'k' ? 1_000
		: 1;
	my $bitrate = int( $number * $multiplier + 0.5 );
	return $bitrate > 0 ? $bitrate : undef;
}

sub bitrateLabel {
	my ($bitrate) = @_;
	return unless defined $bitrate && looks_like_number($bitrate) && $bitrate > 0;
	return "$bitrate bps" if $bitrate < 1000;

	my $kbps = $bitrate / 1000;
	return ( $kbps == int($kbps) ? int($kbps) : sprintf( '%.1f', $kbps ) )
		. ' kbps';
}

sub metadataForFormat {
	my ($format) = @_;
	return {} unless ref $format eq 'HASH';

	my $display = $format->{displayFormat} || uc( $format->{key} || '' );
	my @details;
	push @details, $format->{bitrateLabel} if $format->{bitrateLabel};
	if ( $format->{key} eq 'pcm' ) {
		push @details, '44.1 kHz', '16-bit', 'stereo';
	}

	return {
		type   => 'Spotify Soloist (' . join( ', ', $display, @details ) . ')',
		format => $display,
		ct     => $format->{contentType},
		( $format->{bitrateLabel} ? ( bitrate => $format->{bitrateLabel} ) : () ),
		( $format->{sampleRate} ? ( samplerate => $format->{sampleRate} ) : () ),
		( $format->{sampleSize} ? ( samplesize => $format->{sampleSize} ) : () ),
		( $format->{channels} ? ( channels => $format->{channels} ) : () ),
	};
}

sub applySongFormat {
	my ( $song, $format ) = @_;
	return {} unless $song && ref $format eq 'HASH';

	my @targets = ($song);
	my $track = eval { $song->currentTrack() };
	push @targets, $track if $track;

	for my $target (@targets) {
		next unless $target;
		$target->bitrate( $format->{bitrateBps} || 0 )
			if $target->can('bitrate');
		$target->samplerate( $format->{sampleRate} || 0 )
			if $target->can('samplerate');
		$target->samplesize( $format->{sampleSize} || 0 )
			if $target->can('samplesize');
		$target->channels( $format->{channels} || 0 )
			if $target->can('channels');
	}

	$song->blockalign( $format->{blockAlign} || 0 )
		if $song->can('blockalign');
	$track->block_alignment( $format->{blockAlign} || 0 )
		if $track && $track->can('block_alignment');

	return metadataForFormat($format);
}

sub durationSeconds {
	my ($state) = @_;
	return unless ref $state eq 'HASH';
	my $item = $state->{item};
	return unless ref $item eq 'HASH';
	my $decorations = $item->{decorations};
	return unless ref $decorations eq 'HASH';
	my $playback = $decorations->{playback};
	return unless ref $playback eq 'HASH';
	my $durationMs = $playback->{duration_ms};
	return unless defined $durationMs && looks_like_number($durationMs) && $durationMs > 0;
	return $durationMs / 1000;
}

sub positionSeconds {
	my ( $state, $nowMs ) = @_;
	return unless ref $state eq 'HASH';
	my $position = $state->{position} || {};
	return unless ref $position eq 'HASH';
	my $positionMs = $position->{position_ms};
	return unless defined $positionMs && looks_like_number($positionMs) && $positionMs >= 0;

	my $timestampMs = $position->{timestamp_ms};
	my $speed = $position->{speed};
	if (
		defined $nowMs && looks_like_number($nowMs)
		&& defined $timestampMs && looks_like_number($timestampMs)
		&& defined $speed && looks_like_number($speed)
		&& $nowMs > $timestampMs
	) {
		$positionMs += ( $nowMs - $timestampMs ) * $speed;
	}

	my $duration = durationSeconds($state);
	$positionMs = $duration * 1000 if defined $duration && $positionMs > $duration * 1000;
	return $positionMs / 1000;
}

sub timelineObservation {
	my ($state) = @_;
	return {} unless ref $state eq 'HASH';
	my $item = $state->{item};
	my $position = $state->{position};

	return {
		( ref $item eq 'HASH' && defined $item->{uri}
			? ( uri => $item->{uri} ) : () ),
		( ref $position eq 'HASH'
				&& defined $position->{position_ms}
				&& looks_like_number( $position->{position_ms} )
			? ( positionMs => 0 + $position->{position_ms} ) : () ),
	};
}

sub observeTimelineTransition {
	my ( $tracker, $state, $now ) = @_;
	$tracker ||= {};
	my $current = timelineObservation($state);
	my $previous = $tracker->{observation} || {};
	return unless defined $current->{uri} && length $current->{uri};
	$current->{positionMs} = $previous->{positionMs}
		if !defined $current->{positionMs}
			&& defined $previous->{positionMs}
			&& ( $previous->{uri} || '' ) eq $current->{uri};
	$tracker->{observation} = $current;

	my $previousUri = $previous->{uri};
	my $currentUri = $current->{uri};
	if (
		defined $previousUri && length $previousUri
		&& defined $currentUri && length $currentUri
		&& $previousUri ne $currentUri
	) {
		return {
			reason             => 'track',
			fromUri            => $previousUri,
			toUri              => $currentUri,
			detectedAt         => $now,
			previousPositionMs => $previous->{positionMs},
		};
	}

	if (
		defined $currentUri && defined $previousUri
		&& $currentUri eq $previousUri
		&& defined $current->{positionMs}
		&& defined $previous->{positionMs}
		&& $current->{positionMs}
			< $previous->{positionMs} - BACKWARD_SEEK_THRESHOLD_MS
	) {
		return {
			reason             => 'backward-seek',
			fromUri            => $currentUri,
			toUri              => $currentUri,
			detectedAt         => $now,
			previousPositionMs => $previous->{positionMs},
		};
	}

	return;
}

sub timelineResyncReady {
	my ( $pending, $state, $now ) = @_;
	return 0 unless ref $pending eq 'HASH';
	return 1 if ( $pending->{reason} || '' ) eq 'backward-seek';

	my $current = timelineObservation($state);
	return 0 unless ( $pending->{reason} || '' ) eq 'track';
	return 0 unless defined $current->{uri}
		&& defined $pending->{toUri}
		&& $current->{uri} eq $pending->{toUri};

	return 1 if defined $current->{positionMs}
		&& (
			$current->{positionMs} <= TRACK_RESET_POSITION_MS
			|| (
				defined $pending->{previousPositionMs}
				&& $current->{positionMs}
					< $pending->{previousPositionMs}
						- BACKWARD_SEEK_THRESHOLD_MS
			)
		);

	return defined $now && defined $pending->{detectedAt}
		&& $now - $pending->{detectedAt} >= TRACK_RESET_TIMEOUT_SECONDS
		? 1 : 0;
}

sub applySongTiming {
	my ( $song, $state, $rawElapsed, $nowMs ) = @_;
	my $duration = durationSeconds($state);

	unless ( defined $duration ) {
		$song->duration(0);
		$song->startOffset(0);
		return {};
	}

	$song->duration($duration);
	my $position = positionSeconds( $state, $nowMs );
	if (
		defined $position
		&& defined $rawElapsed
		&& looks_like_number($rawElapsed)
	) {
		$song->startOffset( $position - $rawElapsed );
	}

	return {
		duration => $duration,
		( defined $position ? ( position => $position ) : () ),
	};
}

1;
