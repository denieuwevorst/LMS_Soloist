package Plugins::SpotifySoloist::Settings;

use strict;
use warnings;

use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Slim::Player::Client;

my $prefs = preferences('plugin.spotifysoloist');
my $log   = logger('plugin.spotifysoloist');

sub _normalizedFormatKey {
	my ($format) = @_;
	return unless defined $format && length $format;
	return $format if $format eq 'mp3' || $format eq 'flac' || $format eq 'pcm';
	return;
}

sub _effectiveFormatKey {
	my ( $override, $globalDefault ) = @_;
	return _normalizedFormatKey($override) || _normalizedFormatKey($globalDefault) || 'mp3';
}

sub name {
	return 'PLUGIN_SPOTIFYSOLOIST';
}

sub page {
	return 'plugins/SpotifySoloist/settings/basic.html';
}

sub prefs {
	return ( $prefs, qw(
		soloistBin ffmpegBin pythonBin audioBackend pipewireSink alsaDevicePrefix wsPortBase relayPortBase
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
		my $oldFormats  = $prefs->get('playerFormats') || {};
		my $newSelected = {};
		my $newFormats  = {};
		my $oldGlobalFormat = $prefs->get('format');
		my $newGlobalFormat = $params->{pref_format} // $oldGlobalFormat;
		my @toStart;
		my @toStop;
		my @toRestart;

		for my $player (@players) {
			my $id    = $player->{id};
			my $isOn  = $params->{ 'enabled.' . $id } ? 1 : 0;
			my $wasOn = $oldSelected->{$id} ? 1 : 0;
			my $override = _normalizedFormatKey( $params->{ 'formatOverride.' . $id } );
			my $oldEffectiveFormat = _effectiveFormatKey( $oldFormats->{$id}, $oldGlobalFormat );
			my $newEffectiveFormat = _effectiveFormatKey( $override, $newGlobalFormat );

			$newSelected->{$id} = 1 if $isOn;
			$newFormats->{$id} = $override if defined $override;

			if ( $isOn && !$wasOn ) {
				push @toStart, $id;
			}
			elsif ( !$isOn && $wasOn ) {
				push @toStop, $id;
			}
			elsif ( $isOn && $wasOn && $oldEffectiveFormat ne $newEffectiveFormat ) {
				push @toRestart, $id;
			}
		}

		$prefs->set( 'selectedPlayers', $newSelected );
		$prefs->set( 'playerFormats',   $newFormats );

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
	for my $player (@players) {
		my $id = $player->{id};
		my $override = _normalizedFormatKey( ($prefs->get('playerFormats') || {})->{$id} );
		my $effective = Plugins::SpotifySoloist::Plugin::configuredFormatKeyForPlayer($id);
		my $effectiveSpec = Plugins::SpotifySoloist::Plugin::currentFormatSpec($effective);
		my $effectiveLabel = $effectiveSpec->{displayFormat}
			. ( defined $effectiveSpec->{bitrate} ? ' ' . $effectiveSpec->{bitrate} : '' );

		$player->{enabled}        = $selected->{$id} ? 1 : 0;
		$player->{running}        = Plugins::SpotifySoloist::Plugin::bridgeRunning($id);
		$player->{streamUrl}      = Plugins::SpotifySoloist::Plugin::bridgeStreamUrlFor($id);
		$player->{formatOverride} = defined $override ? $override : '';
		$player->{formatEffective}= $effective;
		$player->{formatEffectiveLabel} = $effectiveLabel;
	}
	$params->{players} = \@players;
	$params->{soloistBinaryStatus} = Plugins::SpotifySoloist::Plugin::soloistBinaryStatus();

	return $callback->( $client, $params, $class->SUPER::handler( $client, $params ), @args );
}

1;
