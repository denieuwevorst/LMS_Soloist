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
		soloistBin ffmpegBin pythonBin pipewireSink wsPortBase relayPortBase
		format bitrate deviceNameSuffix apiKey relayBind autostart
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

		for my $player (@players) {
			my $id    = $player->{id};
			my $isOn  = $params->{ 'enabled.' . $id } ? 1 : 0;
			my $wasOn = $oldSelected->{$id} ? 1 : 0;

			$newSelected->{$id} = 1 if $isOn;

			if ( $isOn && !$wasOn ) {
				Plugins::SpotifySoloist::Plugin::startBridgeForPlayer($id);
			}
			elsif ( !$isOn && $wasOn ) {
				Plugins::SpotifySoloist::Plugin::stopBridgeForPlayer($id);
			}
		}

		$prefs->set( 'selectedPlayers', $newSelected );
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
		$player->{enabled}   = $selected->{$id} ? 1 : 0;
		$player->{running}   = Plugins::SpotifySoloist::Plugin::bridgeRunning($id);
		$player->{streamUrl} = Plugins::SpotifySoloist::Plugin::bridgeStreamUrlFor($id);
	}
	$params->{players} = \@players;

	return $callback->( $client, $params, $class->SUPER::handler( $client, $params ), @args );
}

1;
