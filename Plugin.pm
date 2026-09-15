package Plugins::SpotifySoloist::Plugin;

# Runs ONE independent Spotify Soloist instance PER selected Squeezebox
# player -- each with its own device name, own PipeWire sink, own control
# port, own audio relay -- so each shows up as a SEPARATE, individually
# selectable device in the Spotify app's picker (e.g. "Kitchen (Soloist)",
# "Living Room (Soloist)"), and picking one plays specifically on that one
# Lyrion player. This is the closest available analog to how ShairTunes2
# lets you pick a physical AirPlay target directly in the picker -- Spotify
# Connect has no multi-target-per-process mechanism the way AirPlay's mDNS
# advertising does, so "one process per player" is how you get an
# equivalent per-player selection experience.
#
# Real Now Playing metadata (including cover art) works the same way as
# before: a custom `soloist://` scheme routed through our own protocol
# handler (ProtocolHandler.pm), same pattern as ShairTunes2's
# `airplay://` + AIRPLAY.pm. No Icecast: Bin/audio-relay.py is a small
# embedded multi-client HTTP server per instance, fed by ffmpeg through a
# FIFO (so ffmpeg restarts don't disturb the relay or connected clients).
#
# Division of labour:
#   - Bin/soloist-bridge.sh: PipeWire/PulseAudio sink setup, launches one
#     Soloist instance, captures + feeds its own audio-relay.py via a
#     dedicated FIFO. Fully parameterized by env vars -- one script,
#     launched once per selected player with different env each time.
#   - This module: allocates a stable port/sink/data-dir "slot" per
#     player, starts/stops one bridge per selected player, polls each
#     instance's own `ctl ... now --json`, writes metadata straight into
#     that PLAYER's $client->master->pluginData('metadata'), and
#     (edge-triggered on that instance's status transitioning into
#     "playing") auto-starts playback on that same player.

use strict;
use warnings;

use base qw(Slim::Plugin::OPMLBased);

use File::Spec::Functions qw(catdir catfile);
use File::Path qw(make_path);
use File::Basename qw(dirname);
use JSON::XS qw(decode_json);
use Proc::Background;
use Time::HiRes ();
use POSIX qw(dup2);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;
use Slim::Utils::Network;
use Slim::Utils::PluginManager;
use Slim::Utils::Strings qw(cstring);
use Slim::Music::Info;
use Slim::Player::Client;
use Slim::Player::Playlist;
use Slim::Control::Request;

my $log = Slim::Utils::Log->addLogCategory({
	category     => 'plugin.spotifysoloist',
	defaultLevel => 'WARN',
	description  => getDisplayName(),
});

my $prefs = preferences('plugin.spotifysoloist');

use constant METADATA_POLL_INTERVAL => 0.5; # seconds
use constant IDLE_RESTART_DELAY     => 1;   # seconds

$prefs->init({
	soloistBin      => '/usr/local/bin/soloist',
	ffmpegBin       => '/usr/bin/ffmpeg',
	pythonBin       => 'python3',
	pipewireSink    => 'soloist_sink',    # base name; each player gets _<slot> appended
	wsPortBase      => 9091,              # each player gets +<slot>
	relayPortBase   => 9077,              # each player gets +<slot>
	format          => 'mp3',             # mp3 | flac | pcm
	bitrate         => '320k',            # only used when format = mp3
	initialVolume   => 100,               # applied once when a bridge starts
	deviceNameSuffix => ' (Soloist)',     # appended to each player's own name
	apiKey          => '',
	relayBind       => '0.0.0.0',
	autostart       => 1,
	idleDisconnectSeconds => 30,
	selectedPlayers => {},                # { playerID => 1, ... }
	playerSlots     => {},                # { playerID => slot int }, stable across restarts
});

my %bridges;      # playerID => { proc, wsPort, relayPort, sink, dataDir, cacheDir, fifoPath, deviceName, lastStatus, wasPlayingHere }
my $baseDataDir;
my $baseCacheDir;
my $originalButtonCommand;
my $originalPauseCommand;
my $originalPlayCommand;
my $originalStopCommand;

sub getDisplayName { 'PLUGIN_SPOTIFYSOLOIST' }

sub initPlugin {
	my $class = shift;

	# Registers the 'soloist' scheme as a side effect of loading.
	require Plugins::SpotifySoloist::ProtocolHandler;

	$baseDataDir  = catdir( Slim::Utils::OSDetect::dirsFor('prefs'), 'plugin-spotifysoloist', 'data' );
	$baseCacheDir = catdir( Slim::Utils::OSDetect::dirsFor('cache'), 'plugin-spotifysoloist', 'cache' );

	# Preserve the plugin cache tree across LMS restarts. The earlier
	# cache-wipe logic was added to suppress stale-player state, but that
	# is now handled from Soloist's own reported active-device state
	# (`is_active`) instead. Keeping the cache avoids yanking bridge-local
	# files out from under a still-running/orphaned bridge after an
	# ungraceful LMS shutdown, and also lets the currently playing device
	# resume more cleanly after LMS restarts.
	make_path( $baseDataDir, $baseCacheDir );

	if ( main::WEBUI ) {
		require Plugins::SpotifySoloist::Settings;
		Plugins::SpotifySoloist::Settings->new;
	}

	# soloistbridge start|stop|status -- operates on ALL selected players.
	# Per-player start/stop happens from the settings page checkboxes.
	Slim::Control::Request::addDispatch(
		[ 'soloistbridge', '_action' ],
		[ 0, 1, 0, \&cliBridge ]
	);
	# These are GLOBAL command wrappers by necessity, not by accident:
	# Lyrion's web UI transport controls still come through the core
	# play/pause/stop/button command dispatch path. LMS protocol handlers
	# can influence transport capability checks (e.g. canDoAction for
	# pause), but they do not get their own per-protocol pause/stop/play
	# implementation hook here that would let us forward those actions to
	# Soloist only when a soloist:// stream is active. So if Soloist
	# playback must respond from the web UI as well as player buttons, we
	# need these wrappers and must scope them carefully inside
	# _forwardLyrionTransport.
	#
	# This is safe in one important respect: Slim::Control::Request::
	# addDispatch explicitly returns the previous callback for the same
	# command slot, so falling back to $original...Command is an intended
	# LMS-supported pattern, not a guess. The remaining real risk is load
	# order if another plugin also globally overrides the same commands.
	$originalButtonCommand = Slim::Control::Request::addDispatch(
		[ 'button', '_buttoncode', '_time', '_orFunction' ],
		[ 1, 0, 0, \&soloistButtonCommand ],
	);
	$originalPauseCommand = Slim::Control::Request::addDispatch(
		[ 'pause', '_newvalue', '_fadein', '_suppressShowBriefly' ],
		[ 1, 0, 0, \&soloistPlayControlCommand ],
	);
	$originalPlayCommand = Slim::Control::Request::addDispatch(
		[ 'play', '_fadein' ],
		[ 1, 0, 0, \&soloistPlayControlCommand ],
	);
	$originalStopCommand = Slim::Control::Request::addDispatch(
		[ 'stop' ],
		[ 1, 0, 0, \&soloistPlayControlCommand ],
	);

	$class->SUPER::initPlugin(
		feed   => \&handleFeed,
		tag    => 'spotifysoloist',
		menu   => 'radios',
		weight => 100,
		type   => 'link',
	);

	if ( $prefs->get('autostart') ) {
		Slim::Utils::Timers::setTimer( undef, time() + 2, \&reconcileBridges );
	}

	Slim::Utils::Timers::setTimer( undef, time() + 5, \&pollMetadata );
}

sub shutdownPlugin {
	stopBridgeForPlayer($_) for keys %bridges;
}

# ---------------------------------------------------------------------------
# Slot allocation: each selected player gets a stable integer "slot" so its
# ports/sink/data-dir don't shuffle across Lyrion restarts. Persisted in
# prefs, assigned once, never reused even if a player is later deselected
# (simpler and safer than trying to recycle slots).
# ---------------------------------------------------------------------------

sub _slotFor {
	my ($playerId) = @_;

	my $slots = $prefs->get('playerSlots') || {};
	my $slot = $slots->{$playerId};
	if ( defined $slot ) {
		my $normalizedSlot = $slot =~ /\A\d+\z/ ? int($slot) : undef;
		if ( !defined $normalizedSlot ) {
			$log->warn("discarding invalid slot for player $playerId");
			delete $slots->{$playerId};
			$slot = undef;
		}
		elsif ( $slot ne $normalizedSlot ) {
			$slots->{$playerId} = $normalizedSlot;
			$slot = $normalizedSlot;
		}
	}

	unless ( defined $slot ) {
		my $next = 0;
		$next = $_ + 1 > $next ? $_ + 1 : $next for values %$slots;
		$slot = $slots->{$playerId} = $next;
	}

	$prefs->set( 'playerSlots', $slots );
	return $slot;
}

sub _configFor {
	my ( $playerId, $playerName ) = @_;
	my $slot = _slotFor($playerId);

	return {
		slot       => $slot,
		wsPort     => $prefs->get('wsPortBase') + $slot,
		relayPort  => $prefs->get('relayPortBase') + $slot,
		sink       => $prefs->get('pipewireSink') . '_' . $slot,
		dataDir    => catdir( $baseDataDir, "player_$slot" ),
		cacheDir   => catdir( $baseCacheDir, "player_$slot" ),
		fifoPath   => catfile( $baseCacheDir, "player_$slot", 'audio.fifo' ),
		deviceName => $playerName . $prefs->get('deviceNameSuffix'),
	};
}

sub streamUrlFor {
	my ($cfg) = @_;
	my $bind = $prefs->get('relayBind');
	my $host = ( !$bind || $bind eq '0.0.0.0' ) ? Slim::Utils::Network::serverAddr() : $bind;

	my $format = $prefs->get('format');
	my $ext = $format eq 'pcm' ? 'wav' : $format;

	return 'soloist://' . $host . ':' . $cfg->{relayPort} . '/soloist.' . $ext;
}

# ---------------------------------------------------------------------------
# OPML feed: still useful as a manual fallback / to see all configured
# per-player streams in one place, in case auto-tune is off for some.
# ---------------------------------------------------------------------------

sub handleFeed {
	my ( $client, $cb, $params, $args ) = @_;

	my @items;
	for my $playerId ( selectedPlayerIds() ) {
		my $pClient = Slim::Player::Client::getClient($playerId) or next;
		my $cfg = _configFor( $playerId, $pClient->name );
		push @items, {
			name => $cfg->{deviceName},
			type => 'audio',
			url  => streamUrlFor($cfg),
		};
	}

	$cb->({ items => \@items });
}

# ---------------------------------------------------------------------------
# Bridge process lifecycle -- one per selected player
# ---------------------------------------------------------------------------

sub _scriptPath {
	return catfile( dirname(__FILE__), 'Bin', 'soloist-bridge.sh' );
}

sub _initialVolume {
	my $volume = $prefs->get('initialVolume');
	return int($volume) if defined $volume && $volume =~ /\A\d+\z/ && $volume <= 100;

	$log->warn('invalid initial Soloist volume; using 100%');
	return 100;
}

sub startBridgeForPlayer {
	my ($playerId) = @_;

	return if $bridges{$playerId} && $bridges{$playerId}{proc} && $bridges{$playerId}{proc}->alive;

	my $client = Slim::Player::Client::getClient($playerId);
	unless ($client) {
		$log->warn("can't start bridge -- no such player: $playerId");
		return;
	}

	my $cfg = _configFor( $playerId, $client->name );

	# Preserve this player's cache dir across bridge starts/restarts. The
	# stale-player metadata/display issue is now handled via `is_active`,
	# so wiping Soloist's own cache here is no longer needed and can make
	# post-restart recovery of an already-playing device less reliable.
	make_path( $cfg->{dataDir}, $cfg->{cacheDir} );

	local $ENV{SOLOIST_BIN}       = $prefs->get('soloistBin');
	local $ENV{FFMPEG_BIN}        = $prefs->get('ffmpegBin');
	local $ENV{PYTHON_BIN}        = $prefs->get('pythonBin');
	local $ENV{PIPEWIRE_SINK}     = $cfg->{sink};
	local $ENV{FORMAT}            = $prefs->get('format');
	local $ENV{BITRATE}           = $prefs->get('bitrate');
	local $ENV{SOLOIST_INITIAL_VOLUME} = _initialVolume();
	local $ENV{WS_PORT}           = $cfg->{wsPort};
	local $ENV{DEVICE_NAME}       = $cfg->{deviceName};
	local $ENV{SOLOIST_API_KEY}   = $prefs->get('apiKey');
	local $ENV{SOLOIST_DATA_DIR}  = $cfg->{dataDir};
	local $ENV{SOLOIST_CACHE_DIR} = $cfg->{cacheDir};
	local $ENV{RELAY_PORT}        = $cfg->{relayPort};
	local $ENV{RELAY_BIND}        = $prefs->get('relayBind');
	local $ENV{FIFO_PATH}         = $cfg->{fifoPath};

	$log->info( "starting soloist bridge for player '" . $client->name . "' (device='$cfg->{deviceName}', slot=$cfg->{slot})" );

	my $scriptPath = _scriptPath();
	unless ( -f $scriptPath ) {
		$log->error("can't start bridge for '" . $client->name . "': bridge script not found at $scriptPath");
		return;
	}

	my $proc;
	eval { $proc = Proc::Background->new( '/bin/bash', $scriptPath ); };

	if ( $@ || !$proc ) {
		my $error = $@ || $! || 'unknown process launch failure';
		$log->error("failed to start bridge for '" . $client->name . "': $error");
		return;
	}

	$bridges{$playerId} = {
		%$cfg,
		proc                => $proc,
		lastStatus          => '',
		pausedSince         => undef,
		idleDisconnectArmed => 0,
	};
}

sub stopBridgeForPlayer {
	my ($playerId) = @_;
	my $b = $bridges{$playerId} or return;

	$log->info("stopping soloist bridge for player $playerId");
	eval { $b->{proc}->die if $b->{proc}->alive; };

	if ( my $client = Slim::Player::Client::getClient($playerId) ) {
		_clearMetadataForPlayer($client);
	}

	delete $bridges{$playerId};
}

sub _clearMetadataForPlayer {
	my ($client) = @_;
	my $master = $client->master;
	my $metadata = $master->pluginData('metadata') || {};
	return unless %$metadata;

	$master->pluginData( metadata => {} );
	Slim::Control::Request::notifyFromArray( $master, ['newmetadata'] );
}

sub reconcileBridges {
	my %selected = map { $_ => 1 } selectedPlayerIds();

	stopBridgeForPlayer($_) for grep { !$selected{$_} } keys %bridges;
	startBridgeForPlayer($_) for keys %selected;
}

sub restartBridgeForPlayer {
	my ($playerId) = @_;
	my %selected = map { $_ => 1 } selectedPlayerIds();

	unless ( $selected{$playerId} ) {
		$log->debug("not restarting idle Soloist bridge for deselected player $playerId");
		return;
	}

	$log->info("restarting idle Soloist bridge for player $playerId");
	startBridgeForPlayer($playerId);
}

sub _bridgeForSoloistStream {
	my ($client) = @_;
	my $master = $client->master;
	my $b = $bridges{ $master->id } or return;
	my $playing = eval { Slim::Player::Playlist::url($master) };

	return $playing && $playing eq streamUrlFor($b) ? $b : undef;
}

sub _runSoloistCtl {
	my ($b, @args) = @_;
	my @cmd = ( $prefs->get('soloistBin'), 'ctl', '-w', "127.0.0.1:$b->{wsPort}", @args );

	my $pid = open( my $fh, '-|' );
	if ( !defined $pid ) {
		$log->error("can't run soloist ctl: $!");
		return;
	}

	if ( $pid == 0 ) {
		if ( open( my $devnull, '>', '/dev/null' ) ) {
			POSIX::dup2( fileno($devnull), fileno(STDERR) );
		}
		exec(@cmd) or exit(1);
	}

	close $fh;
	if ( $? != 0 ) {
		$log->warn( 'soloist ctl ' . join( ' ', @args ) . " failed for port $b->{wsPort} (exit " . ( $? >> 8 ) . ')' );
		return;
	}

	return 1;
}

sub _forwardLyrionTransport {
	my ($request) = @_;
	my $client = $request->client or return;
	my $b = _bridgeForSoloistStream($client);
	unless ($b) {
		return;
	}

	if ( ( $b->{suppressLyrionTransportUntil} || 0 ) >= time() ) {
		return;
	}

	my $command = $request->getRequestString;
	if ( $command eq 'play' ) {
		$log->debug('forwarding Lyrion play to Soloist');
		return _runSoloistCtl( $b, 'play' );
	}
	elsif ( $command eq 'pause' ) {
		my $value = $request->getParam('_newvalue');
		$log->debug( 'forwarding Lyrion pause to Soloist as ' . ( defined $value && !$value ? 'play' : 'pause' ) );
		return _runSoloistCtl( $b, defined $value && !$value ? 'play' : 'pause' );
	}
	elsif ( $command eq 'stop' ) {
		$log->debug('forwarding Lyrion stop to Soloist as pause');
		return _runSoloistCtl( $b, 'pause' );
	}
	elsif ( $command eq 'button' ) {
		my $button = $request->getParam('_buttoncode') || '';
		my %buttonCommands = (
			play     => 'play',
			pause    => 'pause',
			stop     => 'pause',
			jump_fwd => 'next',
			jump_rew => 'prev',
		);
		my $soloistCommand = $buttonCommands{$button} or return;

		$log->debug("forwarding Lyrion button $button to Soloist $soloistCommand");
		return _runSoloistCtl( $b, $soloistCommand );
	}

	return;
}

sub soloistButtonCommand {
	my ($request) = @_;
	return $originalButtonCommand->($request) unless _forwardLyrionTransport($request);
	$request->setStatusDone();
}

sub soloistPlayControlCommand {
	my ($request) = @_;
	my $original = $request->getRequestString eq 'play'  ? $originalPlayCommand
	             : $request->getRequestString eq 'pause' ? $originalPauseCommand
	             :                                       $originalStopCommand;

	return $original->($request) unless _forwardLyrionTransport($request);
	$request->setStatusDone();
}

sub bridgeRunning {
	my ($playerId) = @_;
	return $bridges{$playerId} && $bridges{$playerId}{proc} && $bridges{$playerId}{proc}->alive ? 1 : 0;
}

sub bridgeStreamUrlFor {
	my ($playerId) = @_;
	my $b = $bridges{$playerId} or return '';
	return streamUrlFor($b);
}

sub cliBridge {
	my $request = shift;
	my $action  = $request->getParam('_action') || 'status';

	if    ( $action eq 'start' ) { reconcileBridges(); }
	elsif ( $action eq 'stop' )  { stopBridgeForPlayer($_) for keys %bridges; }
	elsif ( $action ne 'status' ) { $request->setStatusBadParams(); return; }

	$request->addResult( 'running', scalar keys %bridges );
	$request->setStatusDone();
}

# ---------------------------------------------------------------------------
# Player selection (settings UI reads/writes this pref directly, and calls
# startBridgeForPlayer/stopBridgeForPlayer as checkboxes are toggled)
# ---------------------------------------------------------------------------

sub selectedPlayerIds {
	my $sel = $prefs->get('selectedPlayers') || {};
	return grep { $sel->{$_} } keys %$sel;
}

# ---------------------------------------------------------------------------
# Metadata + auto-tune: poll EACH running instance's own `now --json`, push
# metadata into that SAME player's pluginData, and -- edge-triggered on
# that instance's status transitioning into "playing" -- start playback on
# that same player. No searching for "whichever client is listening"
# needed anymore: the player<->instance mapping is direct.
# ---------------------------------------------------------------------------

sub _fetchNowPlaying {
	my ($wsPort) = @_;
	my $ws = "127.0.0.1:$wsPort";
	my @cmd = ( $prefs->get('soloistBin'), 'ctl', '-w', $ws, 'now', '--json' );

	my $pid = open( my $fh, '-|' );
	if ( !defined $pid ) {
		$log->debug("fork failed for soloist ctl: $!");
		return undef;
	}

	if ( $pid == 0 ) {
		# Lyrion globally ties STDOUT/STDERR to its own logging class
		# (Slim::Utils::Log::Trapper) so it can capture server output --
		# that tie survives fork() into this child. Calling Perl's open()
		# directly on an already-tied STDERR routes through the tie's
		# OPEN method, which that class doesn't implement, and dies with
		# "Can't locate object method OPEN". POSIX::dup2 redirects the
		# raw OS file descriptor instead, bypassing Perl's tie layer
		# entirely, so this works regardless of what STDERR is tied to.
		if ( open( my $devnull, '>', '/dev/null' ) ) {
			POSIX::dup2( fileno($devnull), fileno(STDERR) );
		}
		exec(@cmd) or exit(1);
	}

	local $/;
	my $json = <$fh>;
	close $fh;

	return $json;
}

sub pollMetadata {
	Slim::Utils::Timers::setTimer( undef, time() + METADATA_POLL_INTERVAL, \&pollMetadata );

	for my $playerId ( keys %bridges ) {
		my $b = $bridges{$playerId};
		next unless $b->{proc} && $b->{proc}->alive;

		my $client = Slim::Player::Client::getClient($playerId) or next;
		my $url = streamUrlFor($b);

		# "Active" means this player's playlist is actually parked on ITS
		# OWN Soloist stream AND it's really playing (not just paused or
		# stopped while still sitting on the URL) -- otherwise it must not
		# keep receiving/holding Now Playing metadata pushes.
		my $isActive = sub {
			my $playing = eval { Slim::Player::Playlist::url($client) };
			return $playing && $playing eq $url && eval { $client->isPlaying(1) };
		};

		_clearMetadataForPlayer($client) unless $isActive->();

		my $json = _fetchNowPlaying( $b->{wsPort} );
		next unless $json;

		my $state = eval { decode_json($json) };
		next unless ref $state eq 'HASH';
		my $status = $state->{status} // '';

		# `status` reflects the Spotify ACCOUNT's current session -- every
		# device logged into that account observes the same status/track/
		# position via this same call, regardless of which one is actually
		# producing audio. Only `is_active` (also in this same payload)
		# tells us whether THIS particular Soloist instance is genuinely
		# the output device right now. Without checking it, every running
		# instance on the same account reports "playing" simultaneously
		# whenever Spotify plays on ANY device -- including ones that
		# aren't this plugin at all (your phone, a car, etc.) -- and every
		# selected player would auto-tune and show that track's metadata
		# at once, regardless of whether it's really the one playing.
		my $isActiveDevice    = $state->{is_active} ? 1 : 0;
		my $reallyPlayingHere = ( $status eq 'playing' && $isActiveDevice ) ? 1 : 0;

		if ( $reallyPlayingHere && !$b->{wasPlayingHere} ) {
			$log->info( 'auto-tuning ' . $client->name . ' to its Spotify Soloist instance' );
			$b->{suppressLyrionTransportUntil} = time() + 1;
			$client->execute( [ 'playlist', 'play', $url ] );
			$b->{pausedSince} = undef;
			$b->{idleDisconnectArmed} = 1;
		}
		elsif ( !$reallyPlayingHere && $b->{wasPlayingHere} ) {
			# Covers being paused locally, being stopped, AND Spotify
			# Connect handing the active session to a DIFFERENT device
			# (status may still say "playing" in that last case -- it's
			# is_active turning false that actually signals it, which is
			# exactly why this checks $reallyPlayingHere and not $status
			# directly). Any of these means this player must stop too.
			my $playing = eval { Slim::Player::Playlist::url($client) };
			if ( $playing && $playing eq $url ) {
				$log->info( "stopping " . $client->name . " after its Spotify Soloist instance stopped being the active device (status='$status', is_active=$isActiveDevice)" );
				$b->{suppressLyrionTransportUntil} = time() + 1;
				$client->execute( [ 'playlist', 'stop' ] );
				$client->execute( [ 'playlist', 'clear' ] );
			}
		}

		if ( $status eq 'paused' && $isActiveDevice ) {
			$b->{pausedSince} //= time() if $b->{idleDisconnectArmed};
		}
		else {
			$b->{pausedSince} = undef;
		}

		$b->{lastStatus}     = $status;
		$b->{wasPlayingHere} = $reallyPlayingHere;

		my $idleDisconnectSeconds = $prefs->get('idleDisconnectSeconds');
		if ( $status eq 'paused'
			&& $isActiveDevice
			&& $b->{pausedSince}
			&& $b->{idleDisconnectArmed}
			&& $idleDisconnectSeconds > 0
			&& time() - $b->{pausedSince} >= $idleDisconnectSeconds ) {
			$log->info( 'disconnecting ' . $client->name . " after $idleDisconnectSeconds seconds paused" );
			stopBridgeForPlayer($playerId);
			$log->debug("scheduling Soloist bridge restart for player $playerId");
			Slim::Utils::Timers::setTimer( undef, time() + IDLE_RESTART_DELAY, sub {
				restartBridgeForPlayer($playerId);
			} );
			next;
		}

		# Only push metadata if this player is actually playing ITS OWN
		# stream right now (not just parked on the URL while paused or
		# stopped). The cached plugin metadata was cleared above otherwise.
		next unless $isActive->();

		my $item = $state->{item} || {};
		my $deco = $item->{decorations} || {};

		my $title = $deco->{identity}->{name} // '';
		next unless length $title;

		my $artist = $deco->{creators}->[0]->{entity}->{decorations}->{identity}->{name} // '';
		my $album  = $deco->{parent}->{entity}->{decorations}->{identity}->{name} // '';

		my $cover = '';
		if ( my $covers = $deco->{visual_identity}->{cover} ) {
			my ($large)  = grep { ( $_->{size} // '' ) eq 'large' }  @$covers;
			my ($xlarge) = grep { ( $_->{size} // '' ) eq 'xlarge' } @$covers;
			$cover = ( $large || $xlarge || $covers->[0] || {} )->{url} // '';
		}

		my $master = $client->master;
		my $meta   = $master->pluginData('metadata') || {};
		my $format = uc( $prefs->get('format') );
		my $bitrate = $prefs->get('format') eq 'mp3' ? $prefs->get('bitrate') : undef;
		my $streamType = 'Spotify Soloist (' . $format
			. ( defined $bitrate ? " $bitrate" : '' ) . ')';

		next if ( $meta->{title}  // '' ) eq $title
		     && ( $meta->{artist} // '' ) eq $artist
		     && ( $meta->{cover}  // '' ) eq $cover
		     && ( $meta->{format} // '' ) eq $format
		     && ( $meta->{bitrate} // '' ) eq ( $bitrate // '' );

		$master->pluginData( metadata => {
			title    => $title,
			artist   => $artist,
			album    => $album,
			cover    => $cover,
			icon     => $cover,
			type     => $streamType,
			format   => $format,
			( defined $bitrate ? ( bitrate => $bitrate ) : () ),
		} );

		Slim::Music::Info::setCurrentTitle( $url, $title, $client );
		$master->currentPlaylistUpdateTime( Time::HiRes::time() );
		Slim::Control::Request::notifyFromArray( $master, ['newmetadata'] );

		$log->debug( 'metadata updated for ' . $client->name . ": $artist - $title" );
	}
}

1;
