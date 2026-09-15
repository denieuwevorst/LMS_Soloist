package Plugins::SpotifySoloist::ProtocolHandler;

# Registers a custom `soloist://` URL scheme so Lyrion routes both playback
# AND metadata lookups for our stream through this handler instead of the
# generic HTTP handler a plain http://...  Favorite URL would use. This is
# the same pattern ShairTunes2's AIRPLAY.pm uses for `airplay://` -- it's
# what makes real Now Playing metadata (title/artist/album/cover art)
# possible at all; a plain HTTP Favorite only ever gets ICY text metadata
# at best, never artwork.
#
# Unlike ShairTunes2 (which has to run its own embedded HTTP server to
# proxy raw AirPlay artwork bytes into a fetchable URL -- see its
# Plugin.pm SET_PARAMETER/image handling), we don't need a proxy: Soloist's
# own playback_state already gives us a direct https:// cover URL
# (decorations.visual_identity.cover[].url), so Plugin.pm just assigns it
# straight into the metadata hash below.

use strict;
use warnings;

use base qw(Slim::Player::Protocols::HTTP);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(cstring);

Slim::Player::ProtocolHandlers->registerHandler( 'soloist', __PACKAGE__ );

my $log   = logger('plugin.spotifysoloist');
my $prefs = preferences('plugin.spotifysoloist');

sub isRemote { 1 }
sub canSeek { 0 }
sub canHandleTranscode { 0 }
sub isAudioURL { 1 }

sub bufferThreshold {
	my ( $class, $client, $url ) = @_;
	my $format = $prefs->get('format') || 'mp3';

	# LMS applies this only when the continuous remote stream itself
	# starts buffering, not at per-track boundaries inside the stream
	# (there aren't any transport-level song starts here, only metadata
	# changes). Still, a slightly larger format-aware startup buffer helps
	# absorb brief starvation around track transitions without changing the
	# bridge's continuous-stream design.
	if ( $format eq 'pcm' ) {
		return 255;
	}
	elsif ( $format eq 'flac' ) {
		return 192;
	}

	my $bitrate = $prefs->get('bitrate') || '320k';
	my ($kbps) = $bitrate =~ /(\d+)/;
	my $threshold = $kbps ? int( ( $kbps / 8 ) * 2 ) : 64;

	$threshold = 32  if $threshold < 32;
	$threshold = 255 if $threshold > 255;

	return $threshold;
}

sub new {
	my $class = shift;
	my $args  = shift;

	my $client = $args->{client};
	my $song   = $args->{song};
	my $url    = $args->{url};

	# Actual audio transport is plain HTTP (Icecast) -- only the scheme
	# Lyrion sees when choosing a protocol handler/metadata source differs.
	( my $httpUrl = $url ) =~ s/^soloist:/http:/;

	my $sock = $class->SUPER::new({
		url    => $httpUrl,
		song   => $song,
		client => $client,
	}) || return;

	$log->debug("new: $url -> $httpUrl");

	return $sock;
}

sub getMetadataFor {
	my ( $class, $client ) = @_;

	my $metadata = $client->master->pluginData('metadata');

	return ( $metadata && %$metadata ) ? $metadata : {
		title => cstring( $client, 'PLUGIN_SPOTIFYSOLOIST_STREAM_NAME' ),
	};
}

1;
