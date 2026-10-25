package Plugins::SpotifySoloist::Settings;

use strict;
use warnings;

use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Slim::Player::Client;

my $prefs = preferences('plugin.spotifysoloist');
my $log   = logger('plugin.spotifysoloist');

sub name {
	return 'PLUGIN_SPOTIFYSOLOIST';
}

sub page {
	return 'plugins/SpotifySoloist/settings/basic.html';
}

sub prefs {
	return ( $prefs, qw(
		soloistBin ffmpegBin audioBackend pipewireSink pcmShimDir wsPortBase relayPortBase
		format bitrate initialVolume deviceNameSuffix apiKey relayBind autostart
		idleDisconnectSeconds
	) );
}

sub handler {
	my ( $class, $client, $params, $callback, @args ) = @_;

	my @players = sort { $a->{name} cmp $b->{name} }
		map { { id => $_->id, name => $_->name } }
		Slim::Player::Client::clients();

	if ( $params->{saveSettings} ) {
		$params->{pref_autostart} ||= 0;

		# Diff old vs new selection and start/stop exactly the players that
		# changed -- same pattern ShairTunes2's Settings.pm uses (their
		# addPlayer/removePlayer diff), rather than a blunt stop-everything
		# -then-restart-everything on every save.
		my $oldSelected = $prefs->get('selectedPlayers') || {};
		my $newSelected = {};
		my $oldPlayerFormats = $prefs->get('playerFormatOverrides') || {};
		my $newPlayerFormats = {
			%{ ref $oldPlayerFormats eq 'HASH' ? $oldPlayerFormats : {} }
		};
		my $oldGlobalFormat = $prefs->get('format')  || 'mp3';
		my $newGlobalFormat = $params->{pref_format} || $oldGlobalFormat;
		my $oldBitrate      = $prefs->get('bitrate') || '320k';
		my $newBitrate      = $params->{pref_bitrate} || $oldBitrate;
		my $oldBackend      = $prefs->get('audioBackend') || 'pcm-shim';
		my $newBackend      = $params->{pref_audioBackend} || $oldBackend;
		my $oldPcmShimDir   = $prefs->get('pcmShimDir') || '';
		my $newPcmShimDir   = $params->{pref_pcmShimDir} || '';
		my @toStart;
		my @toStop;
		my @toRestart;

		for my $player (@players) {
			my $id    = $player->{id};
			my $isOn  = $params->{ 'enabled.' . $id } ? 1 : 0;
			my $wasOn = $oldSelected->{$id} ? 1 : 0;
			my $oldOverride = ref $oldPlayerFormats eq 'HASH' ? $oldPlayerFormats->{$id} : undef;
			$oldOverride = undef unless defined $oldOverride && $oldOverride =~ /^(?:mp3|flac|pcm)$/;
			my $formatParam = 'format.' . $id;
			my $newOverride = exists $params->{$formatParam} ? $params->{$formatParam} : $oldOverride;
			$newOverride = undef unless defined $newOverride && $newOverride =~ /^(?:mp3|flac|pcm)$/;
			my $oldFormat = $oldOverride || $oldGlobalFormat;
			my $newFormat = $newOverride || $newGlobalFormat;

			$newSelected->{$id} = 1 if $isOn;
			if ( exists $params->{$formatParam} ) {
				if ($newOverride) {
					$newPlayerFormats->{$id} = $newOverride;
				}
				else {
					delete $newPlayerFormats->{$id};
				}
			}

			if ( $isOn && !$wasOn ) {
				push @toStart, $id;
			}
			elsif ( !$isOn && $wasOn ) {
				push @toStop, $id;
			}
			elsif (
				$isOn && $wasOn &&
				(
					$oldFormat ne $newFormat ||
					$oldBackend ne $newBackend ||
					$oldPcmShimDir ne $newPcmShimDir ||
					(
						$newFormat eq 'mp3' &&
						$oldBitrate ne $newBitrate
					)
				)
			) {
				push @toRestart, $id;
			}
		}

		$prefs->set( 'selectedPlayers', $newSelected );
		$prefs->set( 'playerFormatOverrides', $newPlayerFormats );
		$prefs->set( 'format',  $newGlobalFormat );
		$prefs->set( 'bitrate', $newBitrate );

		Plugins::SpotifySoloist::Plugin::stopBridgeForPlayer($_)    for @toStop;
		Plugins::SpotifySoloist::Plugin::startBridgeForPlayer($_)   for @toStart;
		Plugins::SpotifySoloist::Plugin::restartBridgeForPlayer($_) for @toRestart;
	}

	if ( $params->{startAll} ) {
		Plugins::SpotifySoloist::Plugin::reconcileBridges();
	}
	elsif ( $params->{stopAll} ) {
		Plugins::SpotifySoloist::Plugin::stopBridgeForPlayer($_)
			for Plugins::SpotifySoloist::Plugin::selectedPlayerIds();
	}

	my $selected = $prefs->get('selectedPlayers') || {};
	my $playerFormats = $prefs->get('playerFormatOverrides') || {};
	for my $player (@players) {
		my $id = $player->{id};
		$player->{enabled}   = $selected->{$id} ? 1 : 0;
		$player->{running}   = Plugins::SpotifySoloist::Plugin::bridgeRunning($id);
		$player->{streamUrl} = Plugins::SpotifySoloist::Plugin::bridgeStreamUrlFor($id);
		$player->{formatOverride} = ref $playerFormats eq 'HASH' ? ( $playerFormats->{$id} || '' ) : '';
	}
	$params->{players} = \@players;
	$params->{soloistBinaryStatus} = Plugins::SpotifySoloist::Plugin::soloistBinaryStatus();

	return $callback->( $client, $params, $class->SUPER::handler( $client, $params ), @args );
}

1;
