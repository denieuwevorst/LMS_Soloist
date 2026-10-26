#!/usr/bin/env perl

use strict;
use warnings;

BEGIN {
	package main;
	sub WEBUI () { 0 }

	package SyntaxCheck::Prefs;
	sub init { }
	sub get { return }
	sub set { }

	package SyntaxCheck::Log;
	sub is_info { 0 }
	sub is_debug { 0 }
	sub info { }
	sub debug { }
	sub warn { }
	sub error { }

	package Slim::Plugin::OPMLBased;
	sub import { }
	$INC{'Slim/Plugin/OPMLBased.pm'} = __FILE__;

	package Slim::Web::Settings;
	sub import { }
	$INC{'Slim/Web/Settings.pm'} = __FILE__;

	package Slim::Utils::Prefs;
	sub preferences { bless {}, 'SyntaxCheck::Prefs' }
	sub import {
		my $caller = caller;
		no strict 'refs';
		*{"${caller}::preferences"} = \&preferences;
	}
	$INC{'Slim/Utils/Prefs.pm'} = __FILE__;

	package Slim::Utils::Log;
	sub addLogCategory { bless {}, 'SyntaxCheck::Log' }
	sub logger { bless {}, 'SyntaxCheck::Log' }
	sub import {
		my $caller = caller;
		no strict 'refs';
		*{"${caller}::logger"} = \&logger;
	}
	$INC{'Slim/Utils/Log.pm'} = __FILE__;

	package Slim::Utils::Strings;
	sub cstring { '' }
	sub import {
		my ( $class, @symbols ) = @_;
		my $caller = caller;
		no strict 'refs';
		for my $symbol (@symbols) {
			*{"${caller}::$symbol"} = \&{$symbol} if $symbol eq 'cstring';
		}
	}
	$INC{'Slim/Utils/Strings.pm'} = __FILE__;

	package JSON::XS;
	sub decode_json { {} }
	sub import {
		my ( $class, @symbols ) = @_;
		my $caller = caller;
		no strict 'refs';
		for my $symbol (@symbols) {
			*{"${caller}::$symbol"} = \&decode_json if $symbol eq 'decode_json';
		}
	}
	$INC{'JSON/XS.pm'} = __FILE__;

	for my $package (
		qw(
			Proc::Background
			Slim::Utils::Timers
			Slim::Utils::Network
			Slim::Utils::PluginManager
			Slim::Networking::SimpleAsyncHTTP
			Slim::Music::Info
			Slim::Player::Client
			Slim::Player::Playlist
			Slim::Control::Request
		)
	) {
		no strict 'refs';
		@{"${package}::ISA"} = ();
		*{"${package}::import"} = sub { };
		(my $file = "$package.pm") =~ s{::}{/}g;
		$INC{$file} = __FILE__;
	}
}

require './Plugin.pm';
require './Settings.pm';

my $build = Plugins::SpotifySoloist::Plugin::_buildInfoFromVersionOutput(
	'soloist 1.3.10.15 build 1792994471 (20261026) (g19412df6ea) (linux/x86_64)'
);
die "Unix build epoch was not parsed\n"
	unless $build
		&& $build->{epoch} == 1792994471
		&& $build->{timestamp} eq '2026-10-26T06:01:11Z';

my @plainCommand =
	Plugins::SpotifySoloist::Plugin::_soloistCommand(
		'contrib/check-plugin-syntax.pl',
		'ctl',
		'now',
	);
die "Non-ELF Soloist command was rewritten unexpectedly\n"
	unless join( "\0", @plainCommand )
		eq join( "\0", 'contrib/check-plugin-syntax.pl', 'ctl', 'now' );

my $probeDir = 'contrib/.version-probe-test';
mkdir $probeDir or die "Could not create $probeDir: $!\n";
my $probe = "$probeDir/soloist";
open my $probeFh, '>', $probe or die "Could not create $probe: $!\n";
print {$probeFh} <<'PROBE';
#!/bin/sh
echo 'soloist 1.3.10.15 build 1792994471 (20261026) (g19412df6ea) (linux/x86_64)'
PROBE
close $probeFh;
chmod 0755, $probe or die "Could not make $probe executable: $!\n";
{
	local $SIG{CHLD} = 'IGNORE';
	my $probeOutput =
		Plugins::SpotifySoloist::Plugin::_captureSoloistVersionOutput($probe);
	my $probeBuild =
		Plugins::SpotifySoloist::Plugin::_buildInfoFromVersionOutput($probeOutput);
	die "Version probe failed when SIGCHLD auto-reaped the child\n"
		unless $probeBuild && $probeBuild->{epoch} == 1792994471;
}
unlink $probe;
rmdir $probeDir;

print "Plugin.pm and Settings.pm syntax OK\n";
