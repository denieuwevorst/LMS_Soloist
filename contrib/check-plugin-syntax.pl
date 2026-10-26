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

print "Plugin.pm and Settings.pm syntax OK\n";
