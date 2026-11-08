package Plugins::SpotifySoloist::StreamSemantics;

use strict;
use warnings;

use Scalar::Util qw(looks_like_number);

sub isSoloistUrl {
	my ($url) = @_;
	return defined $url && $url =~ m{\Asoloist://player-\d+/soloist\.[A-Za-z0-9]+\z} ? 1 : 0;
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
