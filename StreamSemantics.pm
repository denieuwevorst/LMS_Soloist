package Plugins::SpotifySoloist::StreamSemantics;

use strict;
use warnings;

use Scalar::Util qw(looks_like_number);

sub isSoloistUrl {
	my ($url) = @_;
	return defined $url && $url =~ m{\Asoloist://player-\d+/soloist\.[A-Za-z0-9]+\z} ? 1 : 0;
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
