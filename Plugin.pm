package Plugins::SpotifySoloist::Plugin;

# Runs ONE independent Spotify Soloist instance PER selected Squeezebox
# player -- each with its own device name, own backend-specific audio
# target, own control port, own audio relay -- so each shows up as a
# SEPARATE, individually
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
# `airplay://` + AIRPLAY.pm. No Icecast: the bundled C audio relay is a small
# embedded multi-client HTTP server per instance, fed by ffmpeg through a
# FIFO (so ffmpeg restarts don't disturb the relay or connected clients).
#
# Division of labour:
#   - Bin/soloist-bridge.sh: backend-specific audio setup, launches one
#     Soloist instance, captures + feeds its own bundled audio relay via a
#     dedicated FIFO. Fully parameterized by env vars -- one script,
#     launched once per selected player with different env each time.
#   - This module: allocates a stable port/backend-target/data-dir "slot" per
#     player, starts/stops one bridge per selected player, consumes each
#     instance's pushed `soloist ctl ... trace` event stream (with an
#     occasional snapshot resync fallback), writes metadata straight into
#     that PLAYER's $client->master->pluginData('metadata'), and
#     (edge-triggered on that instance's status transitioning into
#     "playing") auto-starts playback on that same player.

use strict;
use warnings;

use base qw(Slim::Plugin::OPMLBased);

use File::Spec::Functions qw(catdir catfile);
use File::Path qw(make_path);
use File::Basename qw(dirname);
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use Errno qw(ECHILD);
use JSON::XS qw(decode_json);
use Proc::Background;
use Time::HiRes ();
use Time::Local qw(timegm);
use POSIX qw(dup2 WNOHANG uname);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;
use Slim::Utils::Network;
use Slim::Utils::PluginManager;
use Slim::Utils::Strings qw(cstring);
use Slim::Networking::SimpleAsyncHTTP;
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

use constant STATE_LOOP_INTERVAL       => 0.5;  # seconds
use constant IDLE_RESTART_DELAY        => 1;    # seconds
use constant STATE_RESYNC_INTERVAL     => 30;   # seconds
use constant TRACE_RESTART_DELAY       => 5;    # seconds
use constant BRIDGE_START_RETRY_DELAY  => 5;    # seconds
use constant PLAYER_OFFLINE_STOP_DELAY => 10;   # seconds
use constant PLAYBACK_TRANSITION_GRACE => 1.5; # seconds
use constant RELAY_AUTOPLAY_READY_TIMEOUT => 1.0; # seconds
use constant RELAY_AUTOPLAY_READY_MAX_AGE => 1.0; # seconds
use constant SOLOIST_BINARY_REFRESH_AFTER_DAYS => 75;
use constant SOLOIST_BINARY_WARN_AFTER_DAYS => 80;
use constant SOLOIST_UPDATE_CHECK_INTERVAL => 86400;
use constant SOLOIST_UPDATE_MAX_ARCHIVE_SIZE => 64 * 1024 * 1024;
use constant SOLOIST_DOWNLOADS_URL          => 'https://developer.spotify.com/documentation/soloist/reference/downloads-and-updates';
use constant SOLOIST_DOWNLOAD_BASE_URL      => 'https://soloist-builds.spotifycdn.com';
$prefs->init({
	soloistBin      => '/usr/local/bin/soloist',
	managedSoloistUpdates => 0,
	managedSoloistArch => 'auto',
	ffmpegBin       => '/usr/bin/ffmpeg',
	audioBackend    => 'pcm-shim',        # pcm-shim | pulse
	pipewireSink    => 'soloist_sink',    # base name; each player gets _<slot> appended
	pcmShimDir      => '',                # optional override; supported bundled architectures are selected automatically
	wsPortBase      => 9091,              # each player gets +<slot>
	relayPortBase   => 9077,              # each player gets +<slot>
	format          => 'mp3',             # mp3 | flac | pcm
	bitrate         => '320k',            # only used when format = mp3
	initialVolume   => 100,               # applied at bridge start and when the Soloist device reconnects
	deviceNameSuffix => ' (Soloist)',     # appended to each player's own name
	apiKey          => '',
	relayBind       => '0.0.0.0',
	autostart       => 1,
	idleDisconnectSeconds => 30,
	selectedPlayers => {},                # { playerID => 1, ... }
	playerFormatOverrides => {},          # { playerID => mp3|flac|pcm } (missing = global format)
	playerSlots     => {},                # { playerID => slot int }, stable across restarts
});

my %bridges;      # playerID => { proc, wsPort, relayPort, sink, dataDir, cacheDir, fifoPath, deviceName, lastStatus, wasPlayingHere }
my $baseDataDir;
my $baseCacheDir;
my %originalTransportCommand;    # command name -> original dispatch coderef
my $soloistBinaryAgeWarningLogged = 0;
my $soloistUpdatePid;
my $soloistUpdateContext;
my %soloistUpdateRuntime = ( state => 'idle' );
my $soloistVersionProbeError = '';
my %pendingBridgeStartRetries;
my %FORMAT_SPECS = (
	mp3 => {
		wireExt       => 'mp3',
		displayFormat => 'MP3',
		bufferKb      => sub {
			my ($bitrate) = @_;
			my ($kbps) = ( $bitrate || '' ) =~ /(\d+)/;
			my $threshold = $kbps ? int( ( $kbps / 8 ) * 0.2 + 0.5 ) : 8;
			$threshold = 3  if $threshold < 3;
			$threshold = 35 if $threshold > 35;
			return $threshold;
		},
	},
	flac => {
		wireExt       => 'flac',
		displayFormat => 'FLAC',
		bufferKb      => 24,
	},
	pcm => {
		wireExt       => 'wav',
		displayFormat => 'WAV',
		bufferKb      => 35,
	},
);

sub getDisplayName { 'PLUGIN_SPOTIFYSOLOIST' }

sub _normalizedFormatKey {
	my ($format) = @_;
	return unless defined $format;
	return $format if exists $FORMAT_SPECS{$format};
	return;
}

sub currentFormatSpec {
	my ($format) = @_;
	$format = _normalizedFormatKey($format);
	$format = _normalizedFormatKey( $prefs->get('format') ) || 'mp3' unless defined $format;
	my $spec = $FORMAT_SPECS{$format} || $FORMAT_SPECS{mp3};
	my $bitrate = $format eq 'mp3' ? ( $prefs->get('bitrate') || '320k' ) : undef;
	my $bufferKb = ref $spec->{bufferKb} eq 'CODE' ? $spec->{bufferKb}->($bitrate) : $spec->{bufferKb};

	return {
		key           => $format,
		wireExt       => $spec->{wireExt},
		displayFormat => $spec->{displayFormat},
		bufferKb      => $bufferKb,
		( defined $bitrate ? ( bitrate => $bitrate ) : () ),
	};
}

sub formatForPlayer {
	my ($playerId) = @_;
	my $overrides = $prefs->get('playerFormatOverrides') || {};
	my $format = ref $overrides eq 'HASH' ? _normalizedFormatKey( $overrides->{$playerId} ) : undef;
	return $format || currentFormatSpec()->{key};
}

sub currentFormatSpecForUrl {
	my ($url) = @_;
	my ($ext) = ( $url || '' ) =~ /\.([A-Za-z0-9]+)(?:\?.*)?\z/;
	return currentFormatSpec('flac') if defined $ext && lc($ext) eq 'flac';
	return currentFormatSpec('pcm')  if defined $ext && lc($ext) eq 'wav';
	return currentFormatSpec('mp3');
}

sub _managedSoloistDir {
	return $baseDataDir ? catdir( $baseDataDir, 'managed' ) : undef;
}

sub managedSoloistBin {
	my $dir = _managedSoloistDir() or return;
	return catfile( $dir, 'soloist' );
}

sub soloistBin {
	my $configured = $prefs->get('soloistBin') || '';
	return $configured unless $prefs->get('managedSoloistUpdates');

	my $managed = managedSoloistBin();
	return $managed if $managed && -x $managed;
	return $configured;
}

sub _soloistElfMachine {
	my ($path) = @_;
	$path ||= soloistBin();
	return unless -f $path;

	open my $fh, '<:raw', $path or return;
	my $header = '';
	my $read = read $fh, $header, 20;
	close $fh;
	return unless defined $read && $read == 20 && substr( $header, 0, 4 ) eq "\x7fELF";

	my $byteOrder = unpack( 'C', substr( $header, 5, 1 ) );
	return unless $byteOrder == 1 || $byteOrder == 2;
	my $machineTemplate = $byteOrder == 2 ? 'n' : 'v';
	return unpack( $machineTemplate, substr( $header, 18, 2 ) );
}

sub _hostBundledArch {
	my @uname = eval { POSIX::uname() };
	my $arch = lc( $uname[4] || '' );
	return 'X86_64'       if $arch eq 'x86_64' || $arch eq 'amd64';
	return 'ARMv7'        if $arch eq 'armv7l' || $arch eq 'armv7' || $arch eq 'armhf';
	return 'ARMv8_Arch64' if $arch eq 'aarch64' || $arch eq 'arm64';
	return;
}

sub _bundledPcmShimArch {
	my ($path) = @_;
	my $machine = _soloistElfMachine($path);
	return 'X86_64'       if defined $machine && $machine == 62;
	return 'ARMv7'        if defined $machine && $machine == 40;
	return 'ARMv8_Arch64' if defined $machine && $machine == 183;

	# A configured wrapper script has no ELF header. Fall back to the host
	# architecture, which is correct for normal native Soloist installs.
	return _hostBundledArch();
}

sub _bundledArchitectureDir {
	my ($arch) = @_;
	return unless $arch;
	my $dir = catdir( dirname(__FILE__), 'Bin', $arch );
	return -d $dir ? $dir : undef;
}

sub bundledPcmShimDir {
	my ($path) = @_;
	my $dir = _bundledArchitectureDir( _bundledPcmShimArch($path) ) or return;
	return -f catfile( $dir, 'libpulse.so.0' ) ? $dir : undef;
}

sub bundledRelayBin {
	my $dir = _bundledArchitectureDir( _hostBundledArch() ) or return;
	my $relay = catfile( $dir, 'audio-relay' );
	return -f $relay ? $relay : undef;
}

sub _applySoloistExecEnv {
	my ( $b, $path, $preferBundledShim ) = @_;
	my $backend = $prefs->get('audioBackend') || 'pcm-shim';

	return unless $backend eq 'pcm-shim';

	my $shimDir = $b
		? $b->{pcmShimDir}
		: (
			$preferBundledShim
				? bundledPcmShimDir($path)
				: ( $prefs->get('pcmShimDir') || bundledPcmShimDir($path) )
		);
	if ( $shimDir && length $shimDir ) {
		$ENV{LD_LIBRARY_PATH} = length( $ENV{LD_LIBRARY_PATH} || '' )
			? $shimDir . ':' . $ENV{LD_LIBRARY_PATH}
			: $shimDir;
	}
}

sub _captureSoloistVersionOutput {
	my ($path) = @_;
	$path ||= soloistBin();
	$soloistVersionProbeError = '';
	unless ( length $path && -f $path ) {
		$soloistVersionProbeError = 'the executable path does not exist';
		return;
	}

	my @cmd = ( $path, '--version' );
	my $pid = open( my $fh, '-|' );
	if ( !defined $pid ) {
		$soloistVersionProbeError = "could not start the version probe: $!";
		$log->warn("can't run soloist --version: $!");
		return;
	}

	if ( $pid == 0 ) {
		POSIX::dup2( fileno(STDOUT), fileno(STDERR) );
		_applySoloistExecEnv( undef, $path, 1 );
		exec(@cmd);
		print STDERR "could not execute $path: $!\n";
		exit(127);
	}

	local $/;
	my $output = <$fh>;
	$! = 0;
	my $closed = close $fh;
	my $closeError = 0 + $!;
	my $status = $?;

	unless ( defined $output && length $output ) {
		$soloistVersionProbeError = $closeError
			? "the version probe produced no output: $!"
			: 'the version probe produced no output';
		return;
	}
	if ( !$closed && $closeError != ECHILD ) {
		my $exitStatus = $status >= 0 ? $status >> 8 : 1;
		$output =~ s/\s+/ /g;
		$output = substr( $output, 0, 300 );
		$soloistVersionProbeError =
			"the version probe exited with status $exitStatus: $output";
		return;
	}

	# LMS may reap this short-lived child through its global SIGCHLD handler.
	# In that case close() reports ECHILD even though the pipe contains the
	# complete version output. The strict parser remains authoritative.
	return $output;
}

sub _epochFromIso8601Utc {
	my ($iso8601) = @_;
	return unless defined $iso8601;

	my ( $year, $month, $day, $hour, $minute, $second ) =
		$iso8601 =~ /\A(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z\z/;
	return unless defined $second;

	my $epoch = eval {
		timegm( $second, $minute, $hour, $day, $month - 1, $year )
	};
	return $@ ? undef : $epoch;
}

sub _buildInfoFromVersionOutput {
	my ($output) = @_;
	return unless defined $output;

	my ($timestamp) = $output =~ /(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z)/;
	my $epoch = _epochFromIso8601Utc($timestamp);
	if ( !defined $epoch ) {
		($epoch) = $output =~ /\bbuild\s+(\d{10})\b/;
		return unless defined $epoch && $epoch >= 946684800 && $epoch <= time() + 366 * 86400;
		my @utc = gmtime($epoch);
		$timestamp = sprintf(
			'%04d-%02d-%02dT%02d:%02d:%02dZ',
			$utc[5] + 1900,
			$utc[4] + 1,
			@utc[ 3, 2, 1, 0 ]
		);
	}

	return {
		output    => $output,
		timestamp => $timestamp,
		epoch     => 0 + $epoch,
	};
}

sub soloistBinaryStatus {
	my $path = soloistBin();
	my $configuredPath = $prefs->get('soloistBin') || '';
	my $managedPath = managedSoloistBin() || '';
	my %managed = (
		managedEnabled => $prefs->get('managedSoloistUpdates') ? 1 : 0,
		managedArch    => $prefs->get('managedSoloistArch') || 'auto',
		managedPath    => $managedPath,
		configuredPath => $configuredPath,
		updateState    => $soloistUpdateRuntime{state} || 'idle',
		updateMessage  => $soloistUpdateRuntime{message} || '',
		lastUpdateAt   => $prefs->get('managedSoloistLastUpdateAt') || 0,
		lastCheckAt    => $prefs->get('managedSoloistLastCheckAt') || 0,
		lastError      => $prefs->get('managedSoloistLastError') || '',
	);
	return {
		%managed,
		path             => $path,
		warnAfterDays    => SOLOIST_BINARY_WARN_AFTER_DAYS,
		downloadsUrl     => SOLOIST_DOWNLOADS_URL,
		ageCheckPossible => 0,
		stale            => 0,
	} unless length $path && -f $path;

	my $versionOutput = _captureSoloistVersionOutput($path);
	my $build = _buildInfoFromVersionOutput($versionOutput);
	return {
		%managed,
		path             => $path,
		warnAfterDays    => SOLOIST_BINARY_WARN_AFTER_DAYS,
		downloadsUrl     => SOLOIST_DOWNLOADS_URL,
		ageCheckPossible => 0,
		stale            => 0,
	} unless $build;

	my $ageSeconds = time() - $build->{epoch};
	$ageSeconds = 0 if $ageSeconds < 0;
	my $ageDays = int( $ageSeconds / 86400 );
	my $stale = $ageSeconds >= SOLOIST_BINARY_WARN_AFTER_DAYS * 86400 ? 1 : 0;

	return {
		%managed,
		path             => $path,
		ageSeconds       => $ageSeconds,
		ageDays          => $ageDays,
		buildTimestamp   => $build->{timestamp},
		warnAfterDays    => SOLOIST_BINARY_WARN_AFTER_DAYS,
		downloadsUrl     => SOLOIST_DOWNLOADS_URL,
		ageCheckPossible => 1,
		stale            => $stale,
	};
}

sub _managedSoloistArchInfo {
	my $arch = $prefs->get('managedSoloistArch') || 'auto';
	if ( $arch eq 'auto' ) {
		my $host = _hostBundledArch();
		$arch = $host eq 'X86_64'       ? 'x86_64'
			: $host eq 'ARMv7'        ? 'arm32'
			: $host eq 'ARMv8_Arch64' ? 'arm64'
			: '';
	}

	my %architectures = (
		x86_64 => { machine => 62,  archive => 'soloist_release_x86_64.tar.gz' },
		arm32  => { machine => 40,  archive => 'soloist_release_arm32.tar.gz' },
		arm64  => { machine => 183, archive => 'soloist_release_arm64.tar.gz' },
	);
	my $info = $architectures{$arch} or return;

	return {
		%$info,
		arch => $arch,
		url  => SOLOIST_DOWNLOAD_BASE_URL . '/' . $info->{archive},
	};
}

sub _setSoloistUpdateState {
	my ( $state, $message, $error ) = @_;
	$soloistUpdateRuntime{state} = $state;
	$soloistUpdateRuntime{message} = $message || '';
	if ( defined $error ) {
		$prefs->set( 'managedSoloistLastError', $error );
	}
}

sub _cleanupSoloistUpdateFiles {
	my $dir = _managedSoloistDir() or return;
	unlink catfile( $dir, 'soloist-update.tar.gz' );
	unlink catfile( $dir, 'soloist.candidate' );
}

sub _failSoloistUpdate {
	my ($message) = @_;
	$message ||= 'unknown update error';
	$log->error("Soloist managed update failed: $message");
	_setSoloistUpdateState( 'error', $message, $message );
	_cleanupSoloistUpdateFiles();
	$soloistUpdatePid = undef;
	$soloistUpdateContext = undef;
}

sub _candidateBuildInfo {
	my ($path) = @_;
	my $output = _captureSoloistVersionOutput($path);
	my $build = _buildInfoFromVersionOutput($output);
	if ( !$build && !$soloistVersionProbeError && defined $output ) {
		$output =~ s/\s+/ /g;
		$output = substr( $output, 0, 300 );
		$soloistVersionProbeError = "unexpected version output: $output";
	}
	return $build;
}

sub _installManagedSoloistCandidate {
	my ($context) = @_;
	my $candidate = $context->{candidate};
	my $managed = managedSoloistBin() or return _failSoloistUpdate('managed binary path is unavailable');

	return _failSoloistUpdate('the extracted candidate is missing or empty')
		unless -f $candidate && -s $candidate > 1024 * 1024;
	return _failSoloistUpdate('the extracted candidate exceeds the 64 MiB safety limit')
		if -s $candidate > SOLOIST_UPDATE_MAX_ARCHIVE_SIZE;
	return _failSoloistUpdate('the downloaded binary has the wrong ELF architecture')
		unless ( _soloistElfMachine($candidate) || 0 ) == $context->{machine};

	my $candidateBuild = _candidateBuildInfo($candidate);
	return _failSoloistUpdate(
		'the downloaded binary did not pass soloist --version validation' .
		( $soloistVersionProbeError ? ": $soloistVersionProbeError" : '' )
	) unless $candidateBuild;
	my $candidateAge = time() - $candidateBuild->{epoch};
	return _failSoloistUpdate('the downloaded binary is already expired')
		if $candidateAge >= 90 * 86400;

	if ( -f $managed ) {
		my $installedBuild = _candidateBuildInfo($managed);
		if ( $installedBuild && $candidateBuild->{epoch} <= $installedBuild->{epoch} ) {
			unlink $candidate;
			unlink $context->{archive};
			$prefs->set( 'managedSoloistLastCheckAt', time() );
			$prefs->set( 'managedSoloistLastError', '' );
			_setSoloistUpdateState( 'current', 'The managed Soloist binary is already current.' );
			$soloistUpdatePid = undef;
			$soloistUpdateContext = undef;
			return;
		}
	}

	chmod 0755, $candidate
		or return _failSoloistUpdate("could not make the candidate executable: $!");

	my $backup = "$managed.previous";
	unlink $backup if -e $backup;
	if ( -e $managed && !rename( $managed, $backup ) ) {
		return _failSoloistUpdate("could not preserve the previous managed binary: $!");
	}
	if ( !rename( $candidate, $managed ) ) {
		my $error = $!;
		rename $backup, $managed if -e $backup;
		return _failSoloistUpdate("could not install the managed binary atomically: $error");
	}

	unlink $context->{archive};
	$prefs->set( 'managedSoloistLastCheckAt', time() );
	$prefs->set( 'managedSoloistLastUpdateAt', time() );
	$prefs->set( 'managedSoloistLastError', '' );
	$soloistBinaryAgeWarningLogged = 0;
	_setSoloistUpdateState(
		'updated',
		"Installed Spotify Soloist build $candidateBuild->{timestamp}."
	);
	$soloistUpdatePid = undef;
	$soloistUpdateContext = undef;

	my $configuredShimDir = $prefs->get('pcmShimDir') || '';
	if ( !$configuredShimDir || $configuredShimDir =~ m{(?:^|[\\/])Bin[\\/](?:Shim[\\/])?(?:X86_64|ARMv7|ARMv8_Arch64)[\\/]?$} ) {
		my $bundledShimDir = bundledPcmShimDir($managed);
		$prefs->set( 'pcmShimDir', $bundledShimDir ) if $bundledShimDir;
	}

	if ( $prefs->get('managedSoloistUpdates') ) {
		$log->info("installed managed Soloist build $candidateBuild->{timestamp}; restarting selected bridges");
		restartBridgeForPlayer($_) for selectedPlayerIds();
	}
	else {
		$log->info("installed managed Soloist build $candidateBuild->{timestamp}; managed mode is disabled");
	}
}

sub _pollSoloistUpdateExtraction {
	return unless $soloistUpdatePid && $soloistUpdateContext;

	my $result = waitpid( $soloistUpdatePid, WNOHANG );
	if ( $result == 0 ) {
		Slim::Utils::Timers::setTimer( undef, time() + 0.25, \&_pollSoloistUpdateExtraction );
		return;
	}
	if ( $result < 0 ) {
		# LMS may reap short-lived children through its global SIGCHLD
		# handling before this timer runs. The extractor publishes the
		# candidate with an atomic rename only after successful completion,
		# so its presence is the authoritative success signal in that case.
		if ( -f $soloistUpdateContext->{candidate} ) {
			return _installManagedSoloistCandidate($soloistUpdateContext);
		}
		return _failSoloistUpdate("could not wait for the archive extractor: $!");
	}

	my $exitStatus = $? >> 8;
	return _failSoloistUpdate("archive extraction exited with status $exitStatus")
		if $exitStatus != 0;

	_installManagedSoloistCandidate($soloistUpdateContext);
}

sub _managedSoloistDownloadError {
	my ( $http, $error ) = @_;
	_failSoloistUpdate( 'download failed: ' . ( $error || $http->error || 'unknown HTTP error' ) );
}

sub _managedSoloistDownloadComplete {
	my ($http) = @_;
	my $context = $http->params('updateContext') || {};
	my $archive = $context->{archive} || '';

	return _failSoloistUpdate( 'Spotify CDN returned HTTP ' . ( $http->code || 'unknown' ) )
		unless ( $http->code || '' ) =~ /^2\d\d$/;
	return _failSoloistUpdate('the downloaded archive is missing or empty')
		unless -f $archive && -s $archive;
	return _failSoloistUpdate('the downloaded archive exceeds the 64 MiB safety limit')
		if -s $archive > SOLOIST_UPDATE_MAX_ARCHIVE_SIZE;

	my $contentLength = eval { $http->headers->content_length() };
	return _failSoloistUpdate("download size mismatch: expected $contentLength bytes")
		if $contentLength && -s $archive != $contentLength;

	my $extractor = catfile( dirname(__FILE__), 'Bin', 'extract-soloist-update.sh' );
	return _failSoloistUpdate("archive extractor not found at $extractor") unless -f $extractor;

	_setSoloistUpdateState( 'installing', 'Validating the downloaded Soloist binary.' );
	my $pid = fork();
	return _failSoloistUpdate("could not start archive extraction: $!") unless defined $pid;
	if ( $pid == 0 ) {
		exec( '/bin/sh', $extractor, $archive, $context->{candidate} ) or exit(127);
	}

	$soloistUpdatePid = $pid;
	$soloistUpdateContext = $context;
	Slim::Utils::Timers::setTimer( undef, time() + 0.25, \&_pollSoloistUpdateExtraction );
}

sub requestManagedSoloistUpdate {
	return 0 unless $prefs->get('managedSoloistUpdates');
	return 0 if $soloistUpdatePid || ( $soloistUpdateRuntime{state} || '' ) =~ /^(?:downloading|installing)$/;

	my $arch = _managedSoloistArchInfo();
	unless ($arch) {
		_failSoloistUpdate('could not determine a supported Soloist download architecture');
		return 0;
	}

	my $dir = _managedSoloistDir();
	eval { make_path($dir) };
	if ($@) {
		_failSoloistUpdate("could not create the managed binary directory: $@");
		return 0;
	}
	my $archive = catfile( $dir, 'soloist-update.tar.gz' );
	my $candidate = catfile( $dir, 'soloist.candidate' );
	unlink $archive;
	unlink $candidate;

	$prefs->set( 'managedSoloistLastCheckAt', time() );
	$prefs->set( 'managedSoloistLastError', '' );
	_setSoloistUpdateState( 'downloading', "Downloading Spotify Soloist for $arch->{arch}." );
	my $http = Slim::Networking::SimpleAsyncHTTP->new(
		\&_managedSoloistDownloadComplete,
		\&_managedSoloistDownloadError,
		{
			saveAs       => $archive,
			maxRedirect  => 3,
			updateContext => {
				archive   => $archive,
				candidate => $candidate,
				machine   => $arch->{machine},
				arch      => $arch->{arch},
			},
		}
	);
	$http->get( $arch->{url} );
	return 1;
}

sub checkManagedSoloistUpdate {
	Slim::Utils::Timers::killTimers( undef, \&checkManagedSoloistUpdate );
	Slim::Utils::Timers::setTimer(
		undef,
		time() + SOLOIST_UPDATE_CHECK_INTERVAL,
		\&checkManagedSoloistUpdate
	);
	return unless $prefs->get('managedSoloistUpdates');
	return if $soloistUpdatePid || ( $soloistUpdateRuntime{state} || '' ) =~ /^(?:downloading|installing)$/;

	my $lastCheck = $prefs->get('managedSoloistLastCheckAt') || 0;
	if ( $lastCheck && time() - $lastCheck < SOLOIST_UPDATE_CHECK_INTERVAL ) {
		Slim::Utils::Timers::killTimers( undef, \&checkManagedSoloistUpdate );
		Slim::Utils::Timers::setTimer(
			undef,
			$lastCheck + SOLOIST_UPDATE_CHECK_INTERVAL + 1,
			\&checkManagedSoloistUpdate
		);
		return;
	}

	my $managed = managedSoloistBin();
	return requestManagedSoloistUpdate() unless $managed && -x $managed;

	my $status = soloistBinaryStatus();
	return
		if $status->{ageCheckPossible}
			&& $status->{ageSeconds} < SOLOIST_BINARY_REFRESH_AFTER_DAYS * 86400;

	requestManagedSoloistUpdate();
}

sub _maybeWarnAboutSoloistBinaryAge {
	return if $soloistBinaryAgeWarningLogged;

	my $status = soloistBinaryStatus();
	return unless $status->{ageCheckPossible} && $status->{stale};

	$soloistBinaryAgeWarningLogged = 1;
	$log->warn(
		"configured Soloist executable '$status->{path}' is $status->{ageDays} days old; " .
		'Spotify Soloist builds expire after about 90 days. Download a newer build from ' .
		$status->{downloadsUrl} .
		'. If this path is a wrapper script, check the real Soloist binary behind it.'
	);
}

sub initPlugin {
	my $class = shift;

	# Registers the 'soloist' scheme as a side effect of loading.
	require Plugins::SpotifySoloist::ProtocolHandler;

	$baseDataDir  = catdir( Slim::Utils::OSDetect::dirsFor('prefs'), 'plugin-spotifysoloist', 'data' );
	$baseCacheDir = catdir( Slim::Utils::OSDetect::dirsFor('cache'), 'plugin-spotifysoloist', 'cache' );
	my $backend = $prefs->get('audioBackend') || 'pcm-shim';
	$prefs->set( 'audioBackend', 'pcm-shim' )
		unless $backend eq 'pulse' || $backend eq 'pcm-shim';
	my $bundledShimDir = bundledPcmShimDir();
	my $configuredShimDir = $prefs->get('pcmShimDir') || '';
	$prefs->set( 'pcmShimDir', $bundledShimDir )
		if $bundledShimDir
			&& (
				!length $configuredShimDir
				|| $configuredShimDir =~ m{
					(?:^|[\\/])Bin[\\/]
					(?:Shim[\\/])?
					(?:X86_64|ARMv7|ARMv8_Arch64)
					[\\/]?$
				}x
			);

	# Preserve the plugin cache tree across LMS restarts. The earlier
	# cache-wipe logic was added to suppress stale-player state, but that
	# is now handled from Soloist's own reported active-device state
	# (`is_active`) instead. Keeping the cache avoids yanking bridge-local
	# files out from under a still-running/orphaned bridge after an
	# ungraceful LMS shutdown, and also lets the currently playing device
	# resume more cleanly after LMS restarts.
	make_path( $baseDataDir, $baseCacheDir );
	_maybeWarnAboutSoloistBinaryAge();

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
	# One dispatch spec per command name, all routed through the same
	# wrapper (_soloistTransportCommand) -- it looks up the right original
	# via $request->getRequestString, so there's no need for a separate
	# wrapper sub or a separate stored coderef per command.
	for my $spec (
		[ 'button', [ 'button', '_buttoncode', '_time', '_orFunction' ] ],
		[ 'pause',  [ 'pause', '_newvalue', '_fadein', '_suppressShowBriefly' ] ],
		[ 'play',   [ 'play', '_fadein' ] ],
		[ 'stop',   [ 'stop' ] ],
	) {
		my ( $name, $dispatchSpec ) = @$spec;
		$originalTransportCommand{$name} = Slim::Control::Request::addDispatch(
			$dispatchSpec,
			[ 1, 0, 0, \&_soloistTransportCommand ],
		);
	}

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

	Slim::Utils::Timers::setTimer( undef, time() + 10, \&checkManagedSoloistUpdate );
	Slim::Utils::Timers::setTimer( undef, time() + 5, \&pollMetadata );
}

sub shutdownPlugin {
	Slim::Utils::Timers::killTimers( undef, \&checkManagedSoloistUpdate );
	Slim::Utils::Timers::killTimers( undef, \&_pollSoloistUpdateExtraction );
	if ($soloistUpdatePid) {
		kill 'TERM', $soloistUpdatePid;
		waitpid( $soloistUpdatePid, 0 );
		$soloistUpdatePid = undef;
		$soloistUpdateContext = undef;
	}
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
	my $backend = $prefs->get('audioBackend') || 'pcm-shim';
	$backend = 'pcm-shim' unless $backend eq 'pulse' || $backend eq 'pcm-shim';

	return {
		slot       => $slot,
		wsPort     => $prefs->get('wsPortBase') + $slot,
		relayPort  => $prefs->get('relayPortBase') + $slot,
		backend    => $backend,
		format     => formatForPlayer($playerId),
		sink       => $prefs->get('pipewireSink') . '_' . $slot,
		dataDir    => catdir( $baseDataDir, "player_$slot" ),
		cacheDir   => catdir( $baseCacheDir, "player_$slot" ),
		fifoPath   => catfile( $baseCacheDir, "player_$slot", 'audio.fifo' ),
		relayReadyFile => catfile( $baseCacheDir, "player_$slot", 'relay.ready' ),
		relayFlushFile => catfile( $baseCacheDir, "player_$slot", 'relay.flush' ),
		pcmShimDir => $prefs->get('pcmShimDir') || bundledPcmShimDir(),
		pcmShimFifo => catfile( $baseCacheDir, "player_$slot", 'pcm-shim.fifo' ),
		relayBin => bundledRelayBin(),
		deviceName => $playerName . $prefs->get('deviceNameSuffix'),
	};
}

sub streamUrlFor {
	my ($cfg) = @_;
	my $bind = $prefs->get('relayBind');
	my $host = ( !$bind || $bind eq '0.0.0.0' ) ? Slim::Utils::Network::serverAddr() : $bind;
	my $format = currentFormatSpec( $cfg->{format} );

	return 'soloist://' . $host . ':' . $cfg->{relayPort} . '/soloist.' . $format->{wireExt};
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

sub _bridgeRunning {
	my ($playerId) = @_;
	my $b = $bridges{$playerId} or return 0;
	return 1 if $b->{proc} && $b->{proc}->alive;

	_closeTraceObserver( $b, "bridge process exited for player $playerId" );
	delete $bridges{$playerId};
	return 0;
}

sub _bridgeExists {
	my ($playerId) = @_;
	return exists $bridges{$playerId} ? 1 : 0;
}

sub _cancelBridgeStartRetry {
	my ($playerId) = @_;
	delete $pendingBridgeStartRetries{$playerId};
}

sub _retryStartBridgeForPlayer {
	my ( $playerId, $expectedWhen ) = @_;
	return unless ( $pendingBridgeStartRetries{$playerId} || 0 ) == ( $expectedWhen || 0 );

	delete $pendingBridgeStartRetries{$playerId};
	return unless _isSelectedPlayer($playerId);

	$log->info("retrying delayed Soloist bridge start for player $playerId");
	_ensureBridgeState( $playerId, shouldRun => 1 );
}

sub _scheduleBridgeStartRetry {
	my ( $playerId, $reason ) = @_;
	return unless _isSelectedPlayer($playerId);
	return if $pendingBridgeStartRetries{$playerId};

	my $when = time() + BRIDGE_START_RETRY_DELAY;
	$pendingBridgeStartRetries{$playerId} = $when;
	$log->info(
		"delaying Soloist bridge start for player $playerId"
		. ( $reason ? " ($reason)" : '' )
		. '; retrying when LMS finishes registering that player'
	);
	Slim::Utils::Timers::setTimer( undef, $when, sub {
		_retryStartBridgeForPlayer( $playerId, $when );
	} );
}

sub _stopBridge {
	my ( $playerId, $reason ) = @_;
	my $b = $bridges{$playerId} or return;

	$log->info( ( $reason || 'stopping' ) . " soloist bridge for player $playerId" );
	_closeTraceObserver( $b, "bridge stop for player $playerId" );
	eval { $b->{proc}->die if $b->{proc}->alive; };

	if ( my $client = Slim::Player::Client::getClient($playerId) ) {
		_clearMetadataForPlayer($client);
	}

	delete $bridges{$playerId};
}

sub _startBridge {
	my ($playerId) = @_;

	my $client = Slim::Player::Client::getClient($playerId);
	unless ($client) {
		_scheduleBridgeStartRetry( $playerId, 'player not available yet' );
		return;
	}
	_cancelBridgeStartRetry($playerId);

	my $cfg = _configFor( $playerId, $client->name );
	_maybeWarnAboutSoloistBinaryAge();

	# Preserve this player's cache dir across bridge starts/restarts. The
	# stale-player metadata/display issue is now handled via `is_active`,
	# so wiping Soloist's own cache here is no longer needed and can make
	# post-restart recovery of an already-playing device less reliable.
	make_path( $cfg->{dataDir}, $cfg->{cacheDir} );

	local $ENV{SOLOIST_BIN}       = soloistBin();
	local $ENV{FFMPEG_BIN}        = $prefs->get('ffmpegBin');
	local $ENV{RELAY_BIN}         = $cfg->{relayBin};
	local $ENV{SOLOIST_AUDIO_BACKEND} = $cfg->{backend};
	local $ENV{PIPEWIRE_SINK}     = $cfg->{sink};
	local $ENV{FORMAT}            = $cfg->{format};
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
	local $ENV{RELAY_READY_FILE}  = $cfg->{relayReadyFile};
	local $ENV{RELAY_FLUSH_FILE}  = $cfg->{relayFlushFile};
	local $ENV{SOLOIST_PCM_SHIM_DIR}  = $cfg->{pcmShimDir};
	local $ENV{SOLOIST_PCM_SHIM_FIFO} = $cfg->{pcmShimFifo};

	$log->info( "starting soloist bridge for player '" . $client->name . "' (device='$cfg->{deviceName}', slot=$cfg->{slot})" );

	my $scriptPath = _scriptPath();
	unless ( -f $scriptPath ) {
		$log->error("can't start bridge for '" . $client->name . "': bridge script not found at $scriptPath");
		return;
	}

	my $proc;
	eval { $proc = Proc::Background->new( '/bin/sh', $scriptPath ); };

	if ( $@ || !$proc ) {
		my $error = $@ || $! || 'unknown process launch failure';
		$log->error("failed to start bridge for '" . $client->name . "': $error");
		return;
	}

	$bridges{$playerId} = {
		%$cfg,
		proc                  => $proc,
		lastStatus            => '',
		lastPlaybackState     => undef,
		lastSnapshotAt        => 0,
		lastTraceEventAt      => 0,
		lastTraceStartAttempt => 0,
		tracePid              => undef,
		traceHandle           => undef,
		traceBuffer           => '',
		missingClientSince    => undef,
		notPlayingSince       => undef,
		pausedSince           => undef,
		idleDisconnectArmed   => 0,
	};
}

sub _isSelectedPlayer {
	my ($playerId) = @_;
	my $sel = $prefs->get('selectedPlayers') || {};
	return $sel->{$playerId} ? 1 : 0;
}

sub _ensureBridgeState {
	my ( $playerId, %args ) = @_;
	my $shouldRun = $args{shouldRun} ? 1 : 0;
	my $restart   = $args{restart} ? 1 : 0;
	my $running   = _bridgeRunning($playerId);

	if ($restart) {
		_stopBridge( $playerId, $args{stopReason} || 'restarting' ) if _bridgeExists($playerId);
		$running = 0;
	}

	if ($shouldRun) {
		return if $running;
		return _startBridge($playerId);
	}

	_cancelBridgeStartRetry($playerId);
	_stopBridge( $playerId, $args{stopReason} ) if _bridgeExists($playerId);
	return;
}

sub startBridgeForPlayer {
	my ($playerId) = @_;
	return _ensureBridgeState( $playerId, shouldRun => 1 );
}

sub stopBridgeForPlayer {
	my ($playerId) = @_;
	return _ensureBridgeState( $playerId, shouldRun => 0, stopReason => 'stopping' );
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
	my %playerIds = map { $_ => 1 } ( keys %bridges, keys %selected );

	_ensureBridgeState( $_, shouldRun => $selected{$_} ? 1 : 0 ) for keys %playerIds;
}

sub restartBridgeForPlayer {
	my ($playerId) = @_;
	unless ( _isSelectedPlayer($playerId) ) {
		$log->debug("not restarting idle Soloist bridge for deselected player $playerId");
		return;
	}

	$log->info("restarting idle Soloist bridge for player $playerId");
	_ensureBridgeState(
		$playerId,
		shouldRun  => 1,
		restart    => 1,
		stopReason => 'restarting idle'
	);
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
	my @cmd = ( soloistBin(), 'ctl', '-w', "127.0.0.1:$b->{wsPort}", @args );

	my $pid = open( my $fh, '-|' );
	if ( !defined $pid ) {
		$log->error("can't run soloist ctl: $!");
		return;
	}

	if ( $pid == 0 ) {
		if ( open( my $devnull, '>', '/dev/null' ) ) {
			POSIX::dup2( fileno($devnull), fileno(STDERR) );
		}
		_applySoloistExecEnv($b);
		exec(@cmd) or exit(1);
	}

	close $fh;
	if ( $? != 0 ) {
		$log->warn( 'soloist ctl ' . join( ' ', @args ) . " failed for port $b->{wsPort} (exit " . ( $? >> 8 ) . ')' );
		return;
	}

	return 1;
}

sub _applyConfiguredSoloistVolume {
	my ( $b, $reason ) = @_;
	my $volume = _initialVolume();
	my $why = $reason ? " ($reason)" : '';

	if ( _runSoloistCtl( $b, 'volume', $volume ) ) {
		$log->info("set Soloist session volume to ${volume}%$why");
		return 1;
	}

	$log->warn("couldn't set Soloist session volume to ${volume}%$why");
	return;
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

sub _soloistTransportCommand {
	my ($request) = @_;
	my $original = $originalTransportCommand{ $request->getRequestString };

	return $original->($request) unless _forwardLyrionTransport($request);
	$request->setStatusDone();
}

sub bridgeRunning {
	my ($playerId) = @_;
	return _bridgeRunning($playerId);
}

sub bridgeStreamUrlFor {
	my ($playerId) = @_;
	return '' unless _bridgeRunning($playerId);
	my $b = $bridges{$playerId} or return '';
	return streamUrlFor($b);
}

sub cliBridge {
	my $request = shift;
	my $action  = $request->getParam('_action') || 'status';

	if    ( $action eq 'start' ) { reconcileBridges(); }
	elsif ( $action eq 'stop' )  { stopBridgeForPlayer($_) for keys %bridges; }
	elsif ( $action ne 'status' ) { $request->setStatusBadParams(); return; }

	$request->addResult( 'running', scalar grep { _bridgeRunning($_) } keys %bridges );
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
# Metadata + auto-tune: keep a lightweight timer loop, but consume EACH
# running instance's pushed `soloist ctl ... trace` event stream as the
# primary state source instead of asking Soloist for a fresh `now --json`
# snapshot twice a second. We still do an occasional snapshot resync as a
# fallback in case the trace observer reconnects mid-playback or an event
# is missed. No searching for "whichever client is listening" needed
# anymore: the player<->instance mapping is direct.
# ---------------------------------------------------------------------------

sub _fetchNowPlaying {
	my ($wsPort) = @_;
	my $ws = "127.0.0.1:$wsPort";
	my @cmd = ( soloistBin(), 'ctl', '-w', $ws, 'now', '--json' );

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
		_applySoloistExecEnv();
		exec(@cmd) or exit(1);
	}

	local $/;
	my $json = <$fh>;
	close $fh;

	return $json;
}

sub _closeTraceObserver {
	my ( $b, $reason ) = @_;

	my $pid = delete $b->{tracePid};
	kill 'TERM', $pid if $pid;

	if ( my $fh = delete $b->{traceHandle} ) {
		close $fh;
	}

	if ($pid) {
		waitpid( $pid, WNOHANG );
	}

	$b->{traceBuffer} = '';
	$log->debug("closed Soloist trace observer: $reason") if $reason;
}

sub _startTraceObserver {
	my ($b) = @_;
	return if $b->{traceHandle};
	return if time() - ( $b->{lastTraceStartAttempt} || 0 ) < TRACE_RESTART_DELAY;

	$b->{lastTraceStartAttempt} = time();
	my @cmd = ( soloistBin(), 'ctl', '-w', "127.0.0.1:$b->{wsPort}", 'trace' );

	my $pid = open( my $fh, '-|' );
	if ( !defined $pid ) {
		$log->warn("can't start soloist trace observer for port $b->{wsPort}: $!");
		return;
	}

	if ( $pid == 0 ) {
		if ( open( my $devnull, '>', '/dev/null' ) ) {
			POSIX::dup2( fileno($devnull), fileno(STDERR) );
		}
		_applySoloistExecEnv($b);
		exec(@cmd) or exit(1);
	}

	my $flags = fcntl( $fh, F_GETFL, 0 );
	if ( defined $flags ) {
		fcntl( $fh, F_SETFL, $flags | O_NONBLOCK );
	}

	$b->{traceHandle} = $fh;
	$b->{tracePid}    = $pid;
	$b->{traceBuffer} = '';
}

sub _mergeTraceEventIntoState {
	my ( $b, $event ) = @_;
	my $type = $event->{type} || '';

	if ( $type eq 'playback_state' ) {
		my %snapshot = %$event;
		delete $snapshot{type};
		$b->{lastPlaybackState} = \%snapshot;
		return 1;
	}

	my $state = $b->{lastPlaybackState} ||= {};

	if ( $type eq 'auth_state' ) {
		$state->{is_active} = $event->{is_active} ? 1 : 0 if exists $event->{is_active};
		if ( exists $event->{logged_in} && !$event->{logged_in} ) {
			$state->{status} = 'idle';
			delete @{$state}{ qw(item context position available_actions options volume) };
		}
		return 1;
	}
	elsif ( $type eq 'track_changed' ) {
		$state->{item} = $event->{item};
		if ( ( $b->{format} || '' ) eq 'pcm' ) {
			my $item = ref $event->{item} eq 'HASH' ? $event->{item} : {};
			my $decorations = ref $item->{decorations} eq 'HASH' ? $item->{decorations} : {};
			my $identity = ref $decorations->{identity} eq 'HASH' ? $decorations->{identity} : {};
			$b->{pendingSpotifyTrackChange} = 1;
			$b->{lastTraceFlushedTitle} = $identity->{name} // '';
			_requestRelayFlush( $b, 'Spotify track changed' );
		}
		return 1;
	}
	elsif ( $type eq 'playback_changed' ) {
		if ( exists $event->{status} ) {
			$state->{status} = $event->{status};
			if ( $event->{status} eq 'paused' ) {
				$b->{pendingSpotifyPause} = 1;
				$b->{pendingSpotifyResume} = 0;
			}
			elsif ( $event->{status} eq 'playing' ) {
				$b->{pendingSpotifyResume} = $b->{spotifyPauseApplied} ? 1 : 0;
				$b->{pendingSpotifyPause} = 0;
			}
		}
		return 1;
	}
	elsif ( $type eq 'volume_changed' ) {
		$state->{volume} = $event->{volume} if exists $event->{volume};
		return 1;
	}
	elsif ( $type eq 'device_changed' ) {
		$state->{is_active} = $event->{is_active} ? 1 : 0 if exists $event->{is_active};
		return 1;
	}
	elsif ( $type eq 'context_changed' ) {
		$state->{context} = $event->{context};
		return 1;
	}
	elsif ( $type eq 'options_changed' ) {
		$state->{options} = $event->{options};
		return 1;
	}
	elsif ( $type eq 'position_sync' ) {
		$state->{position} = $event->{position};
		return 1;
	}

	return 0;
}

sub _drainTraceObserver {
	my ($b) = @_;
	my $fh = $b->{traceHandle} or return 0;
	my $updated = 0;

	while (1) {
		my $chunk = '';
		my $bytes = sysread( $fh, $chunk, 8192 );

		if ( !defined $bytes ) {
			last if $!{EAGAIN} || $!{EWOULDBLOCK};
			_closeTraceObserver( $b, "read error on port $b->{wsPort}: $!" );
			last;
		}

		if ( $bytes == 0 ) {
			_closeTraceObserver( $b, "eof on port $b->{wsPort}" );
			last;
		}

		$b->{traceBuffer} .= $chunk;
		while ( $b->{traceBuffer} =~ s/^(.*?\n)// ) {
			my $line = $1;
			$line =~ s/\r?\n\z//;
			next unless length $line;

			my ( $ts, $json ) = split( /\s+/, $line, 2 );
			next unless defined $json && $ts =~ /^\d+$/;

			my $event = eval { decode_json($json) };
			next unless ref $event eq 'HASH';

			$b->{lastTraceEventAt} = time();
			$updated = 1 if _mergeTraceEventIntoState( $b, $event );
		}
	}

	return $updated;
}

sub _refreshPlaybackStateSnapshot {
	my ($b) = @_;
	my $json = _fetchNowPlaying( $b->{wsPort} );
	return unless $json;

	my $state = eval { decode_json($json) };
	return unless ref $state eq 'HASH';

	$b->{lastPlaybackState} = $state;
	$b->{lastSnapshotAt}    = time();
	return 1;
}

sub _currentPlaybackStateForBridge {
	my ($b) = @_;

	_startTraceObserver($b) unless $b->{traceHandle};
	_drainTraceObserver($b);

	my $needsSnapshot = !$b->{lastPlaybackState}
		|| ( !$b->{traceHandle} && time() - ( $b->{lastSnapshotAt} || 0 ) >= STATE_LOOP_INTERVAL )
		|| time() - ( $b->{lastSnapshotAt} || 0 ) >= STATE_RESYNC_INTERVAL;

	if ($needsSnapshot) {
		_refreshPlaybackStateSnapshot($b);
	}

	return $b->{lastPlaybackState};
}

sub _clientIsOnOwnSoloistStream {
	my ( $client, $url ) = @_;
	my $playing = eval { Slim::Player::Playlist::url($client) };
	return $playing && $playing eq $url;
}

sub _clientIsActivelyPlayingOwnSoloistStream {
	my ( $client, $url ) = @_;
	return _clientIsOnOwnSoloistStream( $client, $url ) && eval { $client->isPlaying(1) };
}

sub _playbackStateForBridge {
	my ( $state, $b ) = @_;
	my $status = $state->{status} // '';
	my $isActiveDevice = $state->{is_active} ? 1 : 0;
	my $reallyPlayingHere = ( $status eq 'playing' && $isActiveDevice ) ? 1 : 0;
	my $effectiveState = !$isActiveDevice            ? 'inactive'
	                   : $status eq 'playing'        ? 'playing'
	                   : $status eq 'paused'         ? 'paused'
	                   :                               'transitioning';

	return {
		status            => $status,
		isActiveDevice    => $isActiveDevice,
		reallyPlayingHere => $reallyPlayingHere,
		wasPlayingHere    => $b->{wasPlayingHere} ? 1 : 0,
		effectiveState    => $effectiveState,
	};
}

sub _relayAutoplayGateReady {
	my ($b) = @_;
	my $path = $b->{relayReadyFile} || '';
	return 0 unless length $path && -f $path;

	my @stat = stat($path);
	return 0 unless @stat && $stat[9];

	return ( Time::HiRes::time() - $stat[9] ) <= RELAY_AUTOPLAY_READY_MAX_AGE ? 1 : 0;
}

sub _maybeApplyConfiguredVolumeOnConnect {
	my ( $b, $playback ) = @_;

	if ( $playback->{isActiveDevice} && !( $b->{wasActiveDevice} || 0 ) ) {
		_applyConfiguredSoloistVolume( $b, 'Spotify Connect session became active' );
	}

	$b->{wasActiveDevice} = $playback->{isActiveDevice} ? 1 : 0;
}

sub _applySpotifyTransportEvents {
	my ( $b, $client, $url, $playback ) = @_;
	my $onOwnStream = _clientIsOnOwnSoloistStream( $client, $url );

	if ( $b->{pendingSpotifyPause} ) {
		$b->{pendingSpotifyPause} = 0;
		if ( $playback->{effectiveState} eq 'paused' && $onOwnStream ) {
			$log->info( 'pausing ' . $client->name . ' immediately after Spotify paused playback' );
			$b->{suppressLyrionTransportUntil} = time() + 1;
			$client->execute( [ 'pause', 1 ] );
			$b->{spotifyPauseApplied} = 1;
		}
	}

	if ( $b->{pendingSpotifyResume} ) {
		$b->{pendingSpotifyResume} = 0;
		if ( $playback->{reallyPlayingHere} && $onOwnStream ) {
			$log->info( 'resuming ' . $client->name . ' immediately after Spotify resumed playback' );
			$b->{suppressLyrionTransportUntil} = time() + 1;
			$client->execute( [ 'play' ] );
			$b->{spotifyPauseApplied} = 0;
		}
	}

	return unless $b->{pendingSpotifyTrackChange};
	return unless $playback->{reallyPlayingHere};

	$b->{pendingSpotifyTrackChange} = 0;
	$b->{spotifyPauseApplied} = 0;
	return unless $onOwnStream;

	# Reopen the continuous HTTP stream at the new track boundary. The relay
	# queue was flushed as soon as track_changed arrived; reconnecting here
	# also discards bytes already buffered by LMS/the player.
	$log->info( 'restarting ' . $client->name . ' stream immediately after Spotify changed track' );
	$b->{suppressLyrionTransportUntil} = time() + 1;
	$client->execute( [ 'playlist', 'play', $url ] );
}

sub _applyPlaybackTransition {
	my ( $playerId, $b, $client, $url, $playback ) = @_;

	if ( $playback->{reallyPlayingHere} && !$playback->{wasPlayingHere} ) {
		$b->{pendingAutoplaySince} ||= Time::HiRes::time();
		my $relayReady = _relayAutoplayGateReady($b);
		my $timedOut = ( Time::HiRes::time() - $b->{pendingAutoplaySince} ) >= RELAY_AUTOPLAY_READY_TIMEOUT ? 1 : 0;
		return unless $relayReady || $timedOut;

		$log->info(
			'auto-tuning ' . $client->name . ' to its Spotify Soloist instance'
			. ( $relayReady ? ' after relay readiness' : ' after relay readiness timeout' )
		);
		$b->{suppressLyrionTransportUntil} = time() + 1;
		$client->execute( [ 'playlist', 'play', $url ] );
		$b->{notPlayingSince} = undef;
		$b->{pausedSince} = undef;
		$b->{idleDisconnectArmed} = 1;
		$b->{pendingAutoplaySince} = undef;
		$b->{wasPlayingHere} = 1;
		$b->{spotifyPauseApplied} = 0;
		return;
	}

	$b->{pendingAutoplaySince} = undef;
	return unless !$playback->{reallyPlayingHere} && $playback->{wasPlayingHere};

	if ( $playback->{isActiveDevice} ) {
		$b->{notPlayingSince} //= time();
	}
	else {
		$b->{notPlayingSince} = time();
	}

	return if $playback->{isActiveDevice}
		&& time() - ( $b->{notPlayingSince} || 0 ) < PLAYBACK_TRANSITION_GRACE;

	if ( _clientIsOnOwnSoloistStream( $client, $url ) ) {
		$log->info( "stopping " . $client->name . " after its Spotify Soloist instance left active playback (status='$playback->{status}', is_active=$playback->{isActiveDevice})" );
		$b->{suppressLyrionTransportUntil} = time() + 1;
		$client->execute( [ 'playlist', 'stop' ] );
		$client->execute( [ 'playlist', 'clear' ] );
	}

	$b->{wasPlayingHere} = 0;
}

sub _updateIdleDisconnectState {
	my ( $b, $playback ) = @_;

	if ( $playback->{effectiveState} eq 'paused' ) {
		$b->{pausedSince} //= time() if $b->{idleDisconnectArmed};
	}
	else {
		$b->{pausedSince} = undef;
	}

	$b->{lastStatus} = $playback->{status};
	$b->{notPlayingSince} = undef if $playback->{reallyPlayingHere};
}

sub _maybeRestartIdleBridge {
	my ( $playerId, $b, $client, $playback ) = @_;
	my $idleDisconnectSeconds = $prefs->get('idleDisconnectSeconds');

	return 0 unless $playback->{effectiveState} eq 'paused'
		&& $b->{pausedSince}
		&& $b->{idleDisconnectArmed}
		&& $idleDisconnectSeconds > 0
		&& time() - $b->{pausedSince} >= $idleDisconnectSeconds;

	$log->info( 'disconnecting ' . $client->name . " after $idleDisconnectSeconds seconds paused" );
	stopBridgeForPlayer($playerId);
	$log->debug("scheduling Soloist bridge restart for player $playerId");
	Slim::Utils::Timers::setTimer( undef, time() + IDLE_RESTART_DELAY, sub {
		restartBridgeForPlayer($playerId);
	} );
	return 1;
}

sub _maybeDisconnectBridgeForExternalSource {
	my ( $playerId, $b, $client, $url, $playback ) = @_;
	my $onOwnStream = _clientIsOnOwnSoloistStream( $client, $url ) ? 1 : 0;
	my $leftOwnStream = ( $b->{lastClientOnOwnStream} || 0 ) && !$onOwnStream;
	$b->{lastClientOnOwnStream} = $onOwnStream;

	return 0 unless $leftOwnStream;
	return 0 unless $playback->{isActiveDevice};
	return 0 if ( $b->{suppressLyrionTransportUntil} || 0 ) >= time();

	$log->info( 'disconnecting ' . $client->name . ' from Spotify Soloist because it switched away to another Lyrion source' );
	stopBridgeForPlayer($playerId);
	Slim::Utils::Timers::setTimer( undef, time() + IDLE_RESTART_DELAY, sub {
		restartBridgeForPlayer($playerId);
	} );
	return 1;
}

sub _coverUrlFromDecorations {
	my ($deco) = @_;
	return '' unless my $covers = $deco->{visual_identity}->{cover};

	my ($large)  = grep { ( $_->{size} // '' ) eq 'large' }  @$covers;
	my ($xlarge) = grep { ( $_->{size} // '' ) eq 'xlarge' } @$covers;
	return ( $large || $xlarge || $covers->[0] || {} )->{url} // '';
}

sub _requestRelayFlush {
	my ( $b, $reason ) = @_;
	return unless $b->{format} && $b->{format} eq 'pcm';

	my $path = $b->{relayFlushFile} || '';
	return unless length $path;

	if ( open my $fh, '>>', $path ) {
		close $fh;
		utime undef, undef, $path;
		$log->info("requested relay flush for track change" . ( $reason ? " ($reason)" : '' ));
	}
	else {
		$log->warn("couldn't request relay flush for '$path': $!");
	}
}

sub _publishMetadataForPlayer {
	my ( $b, $client, $url, $state ) = @_;
	return unless _clientIsActivelyPlayingOwnSoloistStream( $client, $url );

	my $item = $state->{item} || {};
	my $deco = $item->{decorations} || {};
	my $title = $deco->{identity}->{name} // '';
	return unless length $title;

	my $artist = $deco->{creators}->[0]->{entity}->{decorations}->{identity}->{name} // '';
	my $album  = $deco->{parent}->{entity}->{decorations}->{identity}->{name} // '';
	my $cover  = _coverUrlFromDecorations($deco);
	my $format = currentFormatSpec( $b->{format} );
	my $master = $client->master;
	my $meta   = $master->pluginData('metadata') || {};
	my $streamType = 'Spotify Soloist (' . $format->{displayFormat}
		. ( defined $format->{bitrate} ? " $format->{bitrate}" : '' ) . ')';

	return if ( $meta->{title}  // '' ) eq $title
	     && ( $meta->{artist} // '' ) eq $artist
	     && ( $meta->{cover}  // '' ) eq $cover
	     && ( $meta->{format} // '' ) eq $format->{displayFormat}
	     && ( $meta->{bitrate} // '' ) eq ( $format->{bitrate} // '' );

	$master->pluginData( metadata => {
		title    => $title,
		artist   => $artist,
		album    => $album,
		cover    => $cover,
		icon     => $cover,
		type     => $streamType,
		format   => $format->{displayFormat},
		( defined $format->{bitrate} ? ( bitrate => $format->{bitrate} ) : () ),
	} );

	Slim::Music::Info::setCurrentTitle( $url, $title, $client );
	$master->currentPlaylistUpdateTime( Time::HiRes::time() );
	Slim::Control::Request::notifyFromArray( $master, ['newmetadata'] );

	if ( ( $meta->{title} // '' ) ne '' && ( $meta->{title} // '' ) ne $title ) {
		if ( ( $b->{lastTraceFlushedTitle} // '' ) eq $title ) {
			delete $b->{lastTraceFlushedTitle};
		}
		else {
			_requestRelayFlush( $b, $title );
		}
	}

	$log->debug( 'metadata updated for ' . $client->name . ": $artist - $title" );
}

sub _handleMissingPlayerClient {
	my ( $playerId, $b ) = @_;

	$b->{missingClientSince} //= time();
	return 0 if time() - $b->{missingClientSince} < PLAYER_OFFLINE_STOP_DELAY;

	$log->info(
		"stopping Soloist bridge for player $playerId after "
		. PLAYER_OFFLINE_STOP_DELAY
		. " seconds offline; LMS will keep retrying until that player returns"
	);

	_stopBridge( $playerId, 'player went offline' );
	_scheduleBridgeStartRetry( $playerId, 'player offline' );
	return 1;
}

sub pollMetadata {
	Slim::Utils::Timers::setTimer( undef, time() + STATE_LOOP_INTERVAL, \&pollMetadata );

	for my $playerId ( keys %bridges ) {
		next unless _bridgeRunning($playerId);
		my $b = $bridges{$playerId} or next;

		my $client = Slim::Player::Client::getClient($playerId);
		unless ($client) {
			_handleMissingPlayerClient( $playerId, $b );
			next;
		}

		$b->{missingClientSince} = undef;
		my $url = streamUrlFor($b);
		_clearMetadataForPlayer($client) unless _clientIsActivelyPlayingOwnSoloistStream( $client, $url );

		my $state = _currentPlaybackStateForBridge($b);
		next unless ref $state eq 'HASH';
		my $playback = _playbackStateForBridge( $state, $b );

		# `status` reflects the Spotify ACCOUNT's current session, while
		# `is_active` tells us whether THIS specific Soloist instance is
		# really the audio device. The effective state machine below keeps
		# same-device track transitions from looking like a disconnect, but
		# still stops immediately when the active device is lost.
		_maybeApplyConfiguredVolumeOnConnect( $b, $playback );
		next if _maybeDisconnectBridgeForExternalSource( $playerId, $b, $client, $url, $playback );
		_applySpotifyTransportEvents( $b, $client, $url, $playback );
		_applyPlaybackTransition( $playerId, $b, $client, $url, $playback );
		_updateIdleDisconnectState( $b, $playback );
		next if _maybeRestartIdleBridge( $playerId, $b, $client, $playback );
		_publishMetadataForPlayer( $b, $client, $url, $state );
	}
}

1;
