package Plugins::SpotifySoloist::ProtocolHandler;

use strict;
use warnings;

use base qw(IO::Handle);

use Errno qw(EAGAIN EWOULDBLOCK);
use Fcntl qw(O_NONBLOCK O_RDWR);

use Slim::Utils::Log;
use Slim::Utils::Strings qw(cstring);

Slim::Player::ProtocolHandlers->registerHandler( 'soloist', __PACKAGE__ );

my $log = logger('plugin.spotifysoloist');

sub isRemote { 1 }
sub canSeek { 0 }
sub canHandleTranscode { 0 }
sub isAudioURL { 1 }
sub canDirectStream { 0 }

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
	${*$self}{contentType} = $format->{contentType};
	${*$self}{bitrate} = $format->{bitrateBps};
	${*$self}{prefix} = $format->{key} eq 'pcm' ? _wavHeader() : '';

	my $song = $args->{song};
	if ( $format->{key} eq 'pcm' ) {
		$song->samplerate(44100);
		$song->samplesize(16);
		$song->channels(2);
		$song->blockalign(4);
	}

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

	my $read = CORE::sysread( $self, $_[1], $length, $offset || 0 );
	if ( !defined $read && ( $! == EAGAIN || $! == EWOULDBLOCK ) ) {
		$! = EWOULDBLOCK;
		return;
	}
	return $read;
}

sub contentType {
	my ($self) = @_;
	return ${*$self}{contentType};
}

sub getStreamBitrate {
	my ( $self, $maxRate ) = @_;
	my $bitrate = ${*$self}{bitrate} || $maxRate;
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

	while (1) {
		my $read = CORE::sysread( $self, $discard, 32 * 1024 );
		last unless defined $read && $read > 0;
	}
}

1;
