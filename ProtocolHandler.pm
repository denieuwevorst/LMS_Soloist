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
	return $stream ? $stream->{format}->{bufferKb} : 8;
}

sub scanUrl {
	my ( $class, $url, $args ) = @_;
	$args->{cb}->( $args->{song}->currentTrack );
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
	_drainFifo($self);

	my $format = $stream->{format};
	${*$self}{url} = $url;
	${*$self}{client} = $args->{client};
	${*$self}{contentType} = $format->{contentType};
	${*$self}{bitrate} = $format->{bitrateBps};
	${*$self}{prefix} = $format->{key} eq 'pcm' ? _wavHeader() : '';
	${*$self}{lastAudioReadAt} = undef;
	${*$self}{staleDrainUntil} = undef;
	${*$self}{staleBytesDiscarded} = 0;

	my $song = $args->{song};
	Plugins::SpotifySoloist::StreamSemantics::applySongFormat( $song, $format );

	$log->debug("opened direct Soloist stream '$url' from '$fifo'");
	return $self;
}

sub sysread {
	my ( $self, undef, $length, $offset ) = @_;
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
		return length $chunk;
	}

	my $now = Time::HiRes::time();
	if ( my $lastRead = ${*$self}{lastAudioReadAt} ) {
		my $gap = $now - $lastRead;
		if ( $gap >= STALE_READ_GAP_SECONDS && !${*$self}{staleDrainUntil} ) {
			my $discarded = _drainFifo($self);
			if ($discarded) {
				${*$self}{staleDrainUntil} = $now + STALE_DRAIN_SECONDS;
				${*$self}{staleBytesDiscarded} = $discarded;
				$log->info(
					sprintf(
						'discarding stale Soloist audio after %.3fs LMS read gap (%d bytes immediately queued)',
						$gap,
						$discarded,
					)
				);
				$! = EWOULDBLOCK;
				return;
			}
		}
	}

	if ( my $until = ${*$self}{staleDrainUntil} ) {
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
		$! = EWOULDBLOCK;
		return;
	}
	${*$self}{lastAudioReadAt} = $now if $read;
	return $read;
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
