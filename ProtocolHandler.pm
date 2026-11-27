package Plugins::SpotifySoloist::ProtocolHandler;

use strict;
use warnings;

use base qw(IO::Handle);

use Errno qw(EAGAIN EWOULDBLOCK);
use Fcntl qw(O_NONBLOCK O_RDWR);
use Time::HiRes ();

use Slim::Utils::Log;
use Slim::Utils::Strings qw(cstring);

Slim::Player::ProtocolHandlers->registerHandler( 'soloist', __PACKAGE__ );

my $log = logger('plugin.spotifysoloist');

use constant STALE_READ_GAP_SECONDS => 1.0;
use constant STALE_DRAIN_SECONDS    => 0.25;
use constant MAX_DRAIN_BYTES        => 4 * 1024 * 1024;
use constant CONVERTER_CLOSE_GRACE_SECONDS => 0.12;

sub _delayTrace {
	my ( $self, $milestone, %fields ) = @_;
	return unless ${*$self}{delayDiagnostics};
	my $url = ${*$self}{url} || '';
	my $canonical =
		Plugins::SpotifySoloist::StreamSemantics::canonicalSoloistUrl($url)
		|| $url;
	my $now = Plugins::SpotifySoloist::StreamSemantics::monotonicNow();
	my @details = (
		'trace_client_id=' . ( ${*$self}{traceClientId} || 'unknown' ),
		'generation=' . ( ${*$self}{streamGeneration} || 0 ),
		"canonical=$canonical",
	);
	push @details, map {
		my $value = defined $fields{$_} ? $fields{$_} : 'unknown';
		$value =~ s/[\r\n\s]+/_/g;
		"$_=$value";
	} sort keys %fields;
	$log->warn(
		sprintf(
			'[delay-trace] milestone=%s monotonic=%.3f %s',
			$milestone, $now,
			join( ' ', @details ),
		)
	);
	return $now;
}

sub _noteDelayTraceProtocolMilestone {
	my ( $playerId, $generation, $milestone, $at, $url ) = @_;
	return unless defined $at;
	my $callback =
		Plugins::SpotifySoloist::Plugin->can('noteDelayTraceProtocolMilestone')
		or return;
	$callback->( $playerId, $generation, $milestone, $at, $url );
}

sub _fifoAvailableBytes {
	my ($self) = @_;
	my $value = pack( 'I', 0 );
	return ioctl( $self, 0x541B, $value ) ? unpack( 'I', $value ) : 'unknown';
}

sub _noteMidstreamStall {
	my ( $self, %fields ) = @_;
	return unless ${*$self}{delayDiagnostics};
	return if ${*$self}{stallEventLogged};
	my $callback =
		Plugins::SpotifySoloist::Plugin->can('noteMidstreamStall')
		or return;
	${*$self}{stallEventLogged} = 1;
	$callback->(
		${*$self}{traceClientId},
		${*$self}{streamGeneration} || 0,
		${*$self}{url},
		%fields,
	);
}

# LMS only forwards a protocol handler's bufferThreshold to the player's STRM
# command for remote streams. The bytes are still host-local, but this
# classification is required to avoid the Touch's default full input-buffer
# prefill (about 1 MiB / 5.8 seconds for S16LE).
sub isRemote { 1 }
sub canSeek { 0 }
sub canHandleTranscode { 0 }
sub isAudioURL { 1 }
sub canDirectStream { 0 }

# Soloist already supplies fully rendered audio. Returning unity gain here
# prevents LMS from applying the per-player remote/internet-radio replay gain
# fallback merely because soloist:// is a remote URL.
sub trackGain { 0 }

# The transport is one continuous externally controlled stream. Logical
# Spotify track boundaries are metadata updates, not LMS end-of-track events.
sub isRepeatingStream { 1 }

sub bufferThreshold {
	my ( $class, $client, $url ) = @_;
	my $stream = Plugins::SpotifySoloist::Plugin::directStreamInfoForUrl($url);
	return $stream ? $stream->{bufferKb} : 8;
}

sub scanUrl {
	my ( $class, $url, $args ) = @_;
	my $track = $args->{song}->currentTrack;
	if ( my $stream = Plugins::SpotifySoloist::Plugin::directStreamInfoForUrl($url) ) {
		Plugins::SpotifySoloist::StreamSemantics::applySongFormat(
			$args->{song},
			$stream->{format},
		);
	}
	$args->{cb}->($track);
}

sub formatOverride {
	my ( $class, $song ) = @_;
	my $track = $song && $song->currentTrack;
	my $url = $track && $track->can('url') ? $track->url : undef;
	my $stream = Plugins::SpotifySoloist::Plugin::directStreamInfoForUrl($url);
	return unless $stream;
	Plugins::SpotifySoloist::StreamSemantics::applySongFormat(
		$song,
		$stream->{format},
	);
	return $stream->{format}->{contentType};
}

sub new {
	my ( $class, $args ) = @_;
	my $url = $args->{url};
	my $stream = Plugins::SpotifySoloist::Plugin::directStreamInfoForUrl($url);

	unless ($stream) {
		$log->error("no active Soloist direct stream matches '$url'");
		return;
	}

	my $fifo = $stream->{fifoPath};
	unless ( -p $fifo ) {
		$log->error("Soloist direct stream FIFO is unavailable at '$fifo'");
		return;
	}

	# Opening both ends prevents a temporary capture exit from surfacing as
	# EOF. O_NONBLOCK keeps LMS's event loop responsive while capture starts.
	my $self = $class->SUPER::new();
	unless ( sysopen( $self, $fifo, O_RDWR | O_NONBLOCK ) ) {
		$log->error("couldn't open Soloist direct stream FIFO '$fifo': $!");
		return;
	}
	binmode($self);
	my $format = $stream->{format};
	my $initialDiscarded =
		$format->{key} eq 'pcm' ? _drainFifo($self) : 0;
	${*$self}{url} = $url;
	${*$self}{client} = $args->{client};
	${*$self}{traceClientId} =
		$stream->{playerId}
		|| eval { $args->{client}->master->id }
		|| eval { $args->{client}->id }
		|| 'unknown';
	${*$self}{contentType} = $format->{contentType};
	${*$self}{formatKey} = $format->{key};
	${*$self}{bitrate} = $format->{sourceBitrateBps} || 1_411_200;
	${*$self}{streamGeneration} = $stream->{streamGeneration} || 0;
	${*$self}{delayDiagnostics} = $stream->{delayDiagnostics} ? 1 : 0;
	${*$self}{transition} =
		Plugins::SpotifySoloist::Plugin::claimDirectStreamTransitionForUrl(
			$url,
			${*$self}{streamGeneration} || 0,
		);
	${*$self}{openedAt} = Time::HiRes::time();
	${*$self}{firstAudioReadLogged} = 0;
	${*$self}{prefix} = _wavHeader();
	${*$self}{lastAudioReadAt} = undef;
	${*$self}{staleDrainUntil} = undef;
	${*$self}{staleBytesDiscarded} = 0;
	${*$self}{readSummaryAt} = Time::HiRes::time();
	${*$self}{readCalls} = 0;
	${*$self}{readBytes} = 0;
	${*$self}{wouldBlockReads} = 0;
	${*$self}{maxReadGap} = 0;
	${*$self}{firstSysreadLogged} = 0;
	${*$self}{closeLogged} = 0;
	${*$self}{stallEventLogged} = 0;

	_delayTrace(
		$self, 'protocol-handler-new',
		buffer_threshold_kb => $stream->{bufferKb},
		content_type => $format->{contentType},
		transition_restart_buffer_ms => $stream->{transitionBufferMs} || 0,
		url => $url,
	);

	my $song = $args->{song};
	Plugins::SpotifySoloist::StreamSemantics::applySongFormat(
		$song,
		$format,
	);

	$log->info(
		"opened direct Soloist stream '$url' from '$fifo'"
		. " as final $format->{contentType} output"
		. " with $stream->{bufferKb} KiB input threshold"
		. ( $stream->{transitionBufferMs}
			? " for $stream->{transitionBufferMs}ms discontinuous restart buffering"
			: '' )
		. ( $initialDiscarded
			? " after discarding $initialDiscarded bytes queued while the LMS reader was replaced"
			: '' )
	);
	my $openedAt = _delayTrace(
		$self, 'protocol-handler-open',
		content_type => $format->{contentType},
		conversion => $format->{key} eq 'pcm' ? 'pcm-direct' : 'lms-transcoder',
		url => $url,
	);
	_noteDelayTraceProtocolMilestone(
		$stream->{playerId},
		${*$self}{streamGeneration} || 0,
		'handler-open', $openedAt, $url,
	);
	return $self;
}

sub sysread {
	my ( $self, undef, $length, $offset ) = @_;
	if ( !${*$self}{firstSysreadLogged} ) {
		${*$self}{firstSysreadLogged} = 1;
		_delayTrace(
			$self, 'protocol-first-sysread',
			requested_bytes => $length,
		);
	}
	my $prefix = ${*$self}{prefix};

	if ( length $prefix ) {
		my $chunk = substr( $prefix, 0, $length, '' );
		${*$self}{prefix} = $prefix;
		if ($offset) {
			substr( $_[1], $offset ) = $chunk;
		}
		else {
			$_[1] = $chunk;
		}
		if ( !${*$self}{wavPrefixLogged} ) {
			${*$self}{wavPrefixLogged} = 1;
			my $wavAt = _delayTrace(
				$self, 'protocol-wav-prefix',
				bytes => length($chunk),
				content_type => ${*$self}{contentType} || 'unknown',
			);
			_noteDelayTraceProtocolMilestone(
				${*$self}{traceClientId},
				${*$self}{streamGeneration} || 0,
				'wav-prefix', $wavAt, ${*$self}{url},
			);
		}
		return length $chunk;
	}

	my $now = Time::HiRes::time();
	${*$self}{readCalls}++;
	if ( my $lastRead = ${*$self}{lastAudioReadAt} ) {
		my $gap = $now - $lastRead;
		${*$self}{maxReadGap} = $gap
			if $gap > ( ${*$self}{maxReadGap} || 0 );
		if (
			( ${*$self}{formatKey} || '' ) eq 'pcm'
			&& $gap >= STALE_READ_GAP_SECONDS
			&& !${*$self}{staleDrainUntil}
		) {
			_noteMidstreamStall(
				$self,
				source => 'protocol-read-gap',
				read_gap_ms => sprintf( '%.0f', $gap * 1000 ),
				last_successful_read_age_ms => sprintf( '%.0f', $gap * 1000 ),
				fifo_available_bytes => _fifoAvailableBytes($self),
				transition_reason => ref ${*$self}{transition} eq 'HASH'
					? ( ${*$self}{transition}->{reason} || 'unknown' )
					: 'steady-state',
			);
			my $discarded = _drainFifo($self);
			if ($discarded) {
				${*$self}{staleDrainUntil} = $now + STALE_DRAIN_SECONDS;
				${*$self}{staleBytesDiscarded} = $discarded;
				$log->info(
					sprintf(
						'starting stale Soloist catch-up after %.3fs LMS read gap (%d bytes immediately discarded)',
						$gap,
						$discarded,
					)
				);
				$! = EWOULDBLOCK;
				return;
			}
		}
	}

	if (
		( ${*$self}{formatKey} || '' ) eq 'pcm'
		&& ( my $until = ${*$self}{staleDrainUntil} )
	) {
		${*$self}{staleBytesDiscarded} += _drainFifo($self);
		if ( $now < $until ) {
			$! = EWOULDBLOCK;
			return;
		}

		$log->info(
			'finished stale Soloist audio catch-up after discarding '
			. ${*$self}{staleBytesDiscarded}
			. ' bytes'
		);
		my $discarded = ${*$self}{staleBytesDiscarded};
		${*$self}{staleDrainUntil} = undef;
		${*$self}{staleBytesDiscarded} = 0;
		${*$self}{lastAudioReadAt} = $now;
		if ( my $client = ${*$self}{client} ) {
			$log->info(
				"requesting direct Soloist stream replacement for '${*$self}{url}' "
				. 'to clear downstream LMS/player buffers'
			);
			Plugins::SpotifySoloist::Plugin::recoverDirectStreamAfterStall(
				$client,
				${*$self}{url},
				$discarded,
			);
		}
		$! = EWOULDBLOCK;
		return;
	}

	my $read = CORE::sysread( $self, $_[1], $length, $offset || 0 );
	if ( !defined $read && ( $! == EAGAIN || $! == EWOULDBLOCK ) ) {
		${*$self}{wouldBlockReads}++;
		_logReadSummary( $self, $now );
		$! = EWOULDBLOCK;
		return;
	}
	if ($read) {
		${*$self}{readBytes} += $read;
		${*$self}{lastAudioReadAt} = $now;
		${*$self}{stallEventLogged} = 0;
		if ( !${*$self}{firstAudioReadLogged} ) {
			${*$self}{firstAudioReadLogged} = 1;
			my $transition = ${*$self}{transition};
			my $readAt = ref $transition eq 'HASH'
				? Plugins::SpotifySoloist::StreamSemantics::monotonicNow()
				: $now;
			$log->info(
				sprintf(
					'read first final %s audio for stream generation %d at monotonic %.3f '
					. '(%d bytes, handler_open_to_first_audio_ms=%.0f%s)',
					${*$self}{contentType} || 'unknown',
					${*$self}{streamGeneration} || 0,
					$readAt,
					$read,
					( $now - ( ${*$self}{openedAt} || $now ) ) * 1000,
					ref $transition eq 'HASH'
						? sprintf(
							', reason=%s, resync_to_first_audio_ms=%.0f',
							$transition->{reason} || 'unknown',
							( $readAt - ( $transition->{resyncAt} || $readAt ) ) * 1000,
						)
						: '',
				)
			);
			my $pcmAt = _delayTrace(
				$self, 'protocol-first-pcm-read',
				bytes => $read,
				handler_open_to_pcm_ms =>
					sprintf( '%.0f', ( $now - ( ${*$self}{openedAt} || $now ) ) * 1000 ),
				content_type => ${*$self}{contentType} || 'unknown',
			);
			_noteDelayTraceProtocolMilestone(
				${*$self}{traceClientId},
				${*$self}{streamGeneration} || 0,
				'first-pcm', $pcmAt, ${*$self}{url},
			);
		}
	}
	_logReadSummary( $self, $now );
	return $read;
}

sub _logReadSummary {
	my ( $self, $now ) = @_;
	return if $now - ( ${*$self}{readSummaryAt} || $now ) < 5;
	$log->info(
		sprintf(
			'LMS read summary for %s: calls=%d bytes=%d would_block=%d max_gap_ms=%.1f',
			${*$self}{url} || 'unknown',
			${*$self}{readCalls} || 0,
			${*$self}{readBytes} || 0,
			${*$self}{wouldBlockReads} || 0,
			1000 * ( ${*$self}{maxReadGap} || 0 ),
		)
	);
	${*$self}{readSummaryAt} = $now;
	${*$self}{readCalls} = 0;
	${*$self}{readBytes} = 0;
	${*$self}{wouldBlockReads} = 0;
	${*$self}{maxReadGap} = 0;
}

sub close {
	my ($self) = @_;
	my $url = ${*$self}{url} || 'unknown Soloist stream';
	$log->info(
		"closing direct Soloist protocol handler for '$url'"
		. '; the bridge keeps Soloist and the guarded S16 FIFO alive'
	);
	if ( !${*$self}{closeLogged} ) {
		${*$self}{closeLogged} = 1;
		my $closedAt =
			_delayTrace( $self, 'protocol-handler-close', url => $url );
		_noteDelayTraceProtocolMilestone(
			${*$self}{traceClientId},
			${*$self}{streamGeneration} || 0,
			'handler-close', $closedAt, $url,
		);
	}
	my $closed = $self->SUPER::close();
	# Preserve the existing bounded replacement interval so downstream decoder
	# state is cleared before LMS opens the next generation.
	select undef, undef, undef, CONVERTER_CLOSE_GRACE_SECONDS;
	return $closed;
}

sub contentType {
	my ($self) = @_;
	return ${*$self}{contentType};
}

sub getStreamBitrate {
	my ( $self, $maxRate ) = @_;
	my $bitrate = ${*$self}{bitrate};
	return $maxRate unless defined $bitrate;
	return $maxRate && $bitrate > $maxRate ? $maxRate : $bitrate;
}

sub getMetadataFor {
	my ( $class, $client ) = @_;
	my $metadata = $client->master->pluginData('metadata');

	return ( $metadata && %$metadata ) ? $metadata : {
		title => cstring( $client, 'PLUGIN_SPOTIFYSOLOIST_STREAM_NAME' ),
	};
}

sub _wavHeader {
	my $dataSize = 0xffffffff;
	my $byteRate = 44100 * 2 * 16 / 8;
	my $blockAlign = 2 * 16 / 8;

	return 'RIFF'
		. pack( 'V', ( 36 + $dataSize ) & 0xffffffff )
		. 'WAVEfmt '
		. pack( 'VvvVVvv', 16, 1, 2, 44100, $byteRate, $blockAlign, 16 )
		. 'data'
		. pack( 'V', $dataSize );
}

sub _drainFifo {
	my ($self) = @_;
	my $discard = '';
	my $total = 0;

	while ( $total < MAX_DRAIN_BYTES ) {
		my $remaining = MAX_DRAIN_BYTES - $total;
		my $read = CORE::sysread(
			$self,
			$discard,
			$remaining < 32 * 1024 ? $remaining : 32 * 1024,
		);
		last unless defined $read && $read > 0;
		$total += $read;
	}

	return $total;
}

1;
