use strict;
use warnings;

use Test::More;

BEGIN {
	package Slim::Player::ProtocolHandlers;
	sub registerHandler { }
	$INC{'Slim/Player/ProtocolHandlers.pm'} = __FILE__;

	package Slim::Utils::Log;
	sub import {
		no strict 'refs';
		*{ caller() . '::logger' } = sub { bless {}, 'TestLogger' };
	}
	$INC{'Slim/Utils/Log.pm'} = __FILE__;

	package TestLogger;
	sub debug { }
	sub error { }
	sub info { }

	package Slim::Utils::Strings;
	sub import {
		no strict 'refs';
		*{ caller() . '::cstring' } = sub { $_[1] };
	}
	$INC{'Slim/Utils/Strings.pm'} = __FILE__;

	package Plugins::SpotifySoloist::Plugin;
	sub directStreamInfoForUrl { return }
}

require './ProtocolHandler.pm';

is(
	Plugins::SpotifySoloist::ProtocolHandler->trackGain(
		undef,
		'soloist://player-0/soloist.wav',
	),
	0,
	'soloist streams override LMS remote replay gain with unity gain',
);

done_testing;
